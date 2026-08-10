//
//  OpenAICompatExecutor.swift
//  ChatCore
//
//  Framework request → chat-completions wire → channel events. The dialect
//  counterpart of ClaudeExecutor: RequestBuilder and EventTranslator folded
//  into one file, because this wire has no signatures, no server tools, and
//  no redacted thinking to juggle.
//

import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

nonisolated struct OpenAICompatExecutor: LanguageModelExecutor {
	typealias Model = OpenAICompatLanguageModel

	struct Configuration: Hashable, Sendable {
		let wireModelID: String
		let chatURL: URL
		let headers: [String: String]
		let vendorName: String
		let maxTokensField: String
		let supportsStreamOptions: Bool
		let supportsJSONSchema: Bool
		let locksSampling: Bool
		let timeout: TimeInterval
	}

	private let configuration: Configuration

	init(configuration: Configuration) throws {
		self.configuration = configuration
	}

	func respond(
		to request: LanguageModelExecutorGenerationRequest,
		model: OpenAICompatLanguageModel,
		streamingInto channel: LanguageModelExecutorGenerationChannel
	) async throws {
		let body = try Self.requestBody(from: request, configuration: configuration)
		let payload = try JSONEncoder().encode(body)

		let stream = OpenAISSE.stream(
			payload,
			to: configuration.chatURL,
			headers: configuration.headers,
			vendorName: configuration.vendorName,
			timeout: configuration.timeout
		)
		try await translate(stream, into: channel)
	}

	// MARK: - Request Building

	private static func requestBody(
		from request: LanguageModelExecutorGenerationRequest,
		configuration: Configuration
	) throws -> WireJSON {
		var system = ""
		var messages: [WireJSON] = []

		for entry in request.transcript {
			switch entry {
			case .instructions(let instructions):
				let text = flattenedText(of: instructions.segments)
				system += system.isEmpty ? text : "\n\n" + text

			case .prompt(let prompt):
				messages.append(userMessage(from: prompt.segments))

			case .reasoning:
				// Never replayed. This dialect has no slot for prior thinking —
				// DeepSeek documents that sending `reasoning_content` back is
				// an error — and the reasoning lives on in the answer it led to.
				continue

			case .toolCalls(let calls):
				let wireCalls: [WireJSON] = calls.map { call in
					.object([
						"id": .string(call.id),
						"type": .string("function"),
						"function": .object([
							"name": .string(call.toolName),
							"arguments": .string(call.arguments.jsonString),
						]),
					])
				}
				messages.append(.object([
					"role": .string("assistant"),
					"tool_calls": .array(wireCalls),
				]))

			case .toolOutput(let output):
				messages.append(.object([
					"role": .string("tool"),
					"tool_call_id": .string(output.id),
					"content": .string(flattenedText(of: output.segments)),
				]))

			case .response(let response):
				messages.append(.object([
					"role": .string("assistant"),
					"content": .string(flattenedText(of: response.segments)),
				]))

			@unknown default:
				break
			}
		}

		if !system.isEmpty {
			messages.insert(.object([
				"role": .string("system"),
				"content": .string(system),
			]), at: 0)
		}

		var body: [String: WireJSON] = [
			"model": .string(configuration.wireModelID),
			"messages": .array(messages),
			"stream": .bool(true),
		]

		let options = request.generationOptions
		if let maximum = options.maximumResponseTokens {
			body[configuration.maxTokensField] = .int(maximum)
		}
		if !configuration.locksSampling {
			applySampling(options, to: &body)
		}
		if let choice = toolChoice(for: options.toolCallingMode) {
			body["tool_choice"] = .string(choice)
		}

		let tools = request.enabledToolDefinitions.map(toolDefinition)
		if !tools.isEmpty {
			body["tools"] = .array(tools)
		}

		if configuration.supportsStreamOptions {
			body["stream_options"] = .object(["include_usage": .bool(true)])
		}

		if let schema = request.schema {
			guard configuration.supportsJSONSchema else {
				throw LanguageModelError.unsupportedGenerationGuide(
					.init(
						schemaName: nil,
						debugDescription:
							"\(configuration.wireModelID) does not support structured output (response_format json_schema)."
					)
				)
			}
			body["response_format"] = .object([
				"type": .string("json_schema"),
				"json_schema": .object([
					"name": .string("response"),
					"strict": .bool(true),
					"schema": jsonSchema(from: schema),
				]),
			])
		}

		return .object(body)
	}

	/// Sampling is a hint everywhere on this wire; fields the model ignores
	/// are just ignored, but only known fields are ever sent.
	private static func applySampling(
		_ options: GenerationOptions,
		to body: inout [String: WireJSON]
	) {
		if let temperature = options.temperature {
			body["temperature"] = .number(temperature)
		}
		switch options.samplingMode?.kind {
		case .greedy:
			body["temperature"] = .number(0)
		case .randomProbabilityThreshold(let threshold, seed: _):
			body["top_p"] = .number(threshold)
		case .randomTopK, nil:
			// `top_k` isn't part of this dialect — dropped rather than sent to
			// endpoints that 4xx on unknown fields.
			break
		@unknown default:
			break
		}
	}

	/// `"auto"` is the wire default — omitted rather than sent.
	private static func toolChoice(for mode: GenerationOptions.ToolCallingMode?) -> String? {
		guard let mode else { return nil }
		switch mode.kind {
		case .required:   return "required"
		case .disallowed: return "none"
		case .allowed:    return nil
		@unknown default: return nil
		}
	}

	private static func toolDefinition(_ definition: Transcript.ToolDefinition) -> WireJSON {
		.object([
			"type": .string("function"),
			"function": .object([
				"name": .string(definition.name),
				"description": .string(definition.description),
				"parameters": jsonSchema(from: definition.parameters),
			]),
		])
	}

	// MARK: - Segments → Wire Content

	private static func flattenedText(of segments: [Transcript.Segment]) -> String {
		segments.compactMap { segment -> String? in
			switch segment {
			case .text(let text): text.content
			case .structure(let structure): structure.content.jsonString
			case .attachment, .custom: nil
			@unknown default: nil
			}
		}
		.joined(separator: "\n")
	}

	/// A user turn: a bare string when it's text alone, content parts when
	/// images ride along — the string form is the one every endpoint in the
	/// family accepts, so it's the default.
	private static func userMessage(from segments: [Transcript.Segment]) -> WireJSON {
		var parts: [WireJSON] = []
		var textOnly = true

		for segment in segments {
			switch segment {
			case .text(let text) where !text.content.isEmpty:
				parts.append(.object([
					"type": .string("text"),
					"text": .string(text.content),
				]))
			case .text:
				break
			case .structure(let structure):
				parts.append(.object([
					"type": .string("text"),
					"text": .string(structure.content.jsonString),
				]))
			case .attachment(let attachment):
				if case .image(let image) = attachment.content,
				   let dataURI = jpegDataURI(of: image.cgImage, orientation: image.orientation) {
					textOnly = false
					parts.append(.object([
						"type": .string("image_url"),
						"image_url": .object(["url": .string(dataURI)]),
					]))
				}
			case .custom:
				break
			@unknown default:
				break
			}
		}

		if textOnly {
			return .object([
				"role": .string("user"),
				"content": .string(flattenedText(of: segments)),
			])
		}
		return .object([
			"role": .string("user"),
			"content": .array(parts),
		])
	}

	/// The wire takes images as URLs; a data URI keeps the bytes in the same
	/// request. JPEG at 0.8: attachments were already normalized on the way
	/// into the transcript, this is just re-encoding for the trip out.
	private static func jpegDataURI(
		of image: CGImage,
		orientation: CGImagePropertyOrientation
	) -> String? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(
			data, UTType.jpeg.identifier as CFString, 1, nil
		) else { return nil }
		CGImageDestinationAddImage(destination, image, [
			kCGImageDestinationLossyCompressionQuality: 0.8,
			kCGImagePropertyOrientation: orientation.rawValue,
		] as CFDictionary)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
	}

	// MARK: - Schema Sanitizing

	/// `GenerationSchema` encodes as JSON Schema with framework extension keys
	/// strict validators reject — same cleanup the Claude bridge does, against
	/// the keyset OpenAI's `strict: true` accepts.
	private static let allowedSchemaKeys: Set<String> = [
		"type", "properties", "required", "items", "enum", "const",
		"anyOf", "allOf", "oneOf", "$ref", "$defs", "definitions",
		"description", "additionalProperties",
	]

	private static let mapValuedKeys: Set<String> = ["properties", "$defs", "definitions"]

	static func jsonSchema(from schema: GenerationSchema) -> WireJSON {
		guard let value = WireJSON.encoded(schema) else {
			return .object(["type": .string("object")])
		}
		return sanitize(value)
	}

	private static func sanitize(_ value: WireJSON) -> WireJSON {
		switch value {
		case .object(let dictionary):
			var out: [String: WireJSON] = [:]
			for (key, nested) in dictionary where allowedSchemaKeys.contains(key) {
				if mapValuedKeys.contains(key), case .object(let map) = nested {
					out[key] = .object(map.mapValues(sanitize))
				} else {
					out[key] = sanitize(nested)
				}
			}
			// Strict mode requires the claim on every object, not just the root.
			if out["type"] == .string("object"), out["additionalProperties"] == nil {
				out["additionalProperties"] = .bool(false)
			}
			return .object(out)
		case .array(let values):
			return .array(values.map(sanitize))
		default:
			return value
		}
	}

	// MARK: - Stream → Channel

	/// No real per-delta count exists — usage arrives once, at the end — and a
	/// zero suppresses partial-snapshot delivery, so deltas claim one token.
	private static let deltaTokenCount = 1

	private func translate(
		_ chunks: AsyncThrowingStream<OpenAIChatChunk, Error>,
		into channel: LanguageModelExecutorGenerationChannel
	) async throws {
		let responseEntryID = UUID().uuidString
		let toolCallsEntryID = UUID().uuidString
		let reasoningEntryID = UUID().uuidString

		/// Tool-call identity by stream index — the id and name arrive once,
		/// on the first delta, and the argument fragments after ride the index.
		var toolCalls: [Int: (id: String, name: String)] = [:]
		var usage: OpenAIChatChunk.Usage?

		for try await chunk in chunks {
			try Task.checkCancellation()

			if let reported = chunk.usage { usage = reported }

			for choice in chunk.choices ?? [] {
				guard let delta = choice.delta else { continue }

				if let thinking = delta.reasoningContent ?? delta.reasoning,
				   !thinking.isEmpty {
					await channel.send(
						.reasoning(
							entryID: reasoningEntryID,
							action: .appendText(thinking, tokenCount: Self.deltaTokenCount)
						)
					)
				}

				if let content = delta.content, !content.isEmpty {
					await channel.send(
						.response(
							entryID: responseEntryID,
							action: .appendText(content, tokenCount: Self.deltaTokenCount)
						)
					)
				}

				for call in delta.toolCalls ?? [] {
					let index = call.index ?? 0
					if let id = call.id, !id.isEmpty {
						toolCalls[index] = (id, call.function?.name ?? "")
					} else if let name = call.function?.name,
					          let known = toolCalls[index], known.name.isEmpty {
						toolCalls[index] = (known.id, name)
					}
					guard let known = toolCalls[index] else { continue }
					await channel.send(
						.toolCalls(
							entryID: toolCallsEntryID,
							action: .toolCall(
								id: known.id,
								name: known.name,
								action: .appendArguments(
									call.function?.arguments ?? "",
									tokenCount: Self.deltaTokenCount
								)
							)
						)
					)
				}
			}
		}

		if let usage {
			await channel.send(
				.response(
					entryID: responseEntryID,
					action: .updateUsage(
						input: .init(
							totalTokenCount: usage.promptTokens ?? 0,
							cachedTokenCount: usage.promptTokensDetails?.cachedTokens ?? 0
						),
						output: .init(
							totalTokenCount: usage.completionTokens ?? 0,
							reasoningTokenCount: usage.completionTokensDetails?.reasoningTokens ?? 0
						)
					)
				)
			)
		}
	}
}
