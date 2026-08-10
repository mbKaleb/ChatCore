//
//  OpenAIWire.swift
//  ChatCore
//
//  The chat-completions dialect most vendors speak. One set of wire types
//  serves every OpenAI-compatible endpoint; per-vendor differences (which
//  max-tokens field, whether stream_options exists) stay in VendorWireProfile.
//

import Foundation

// MARK: - JSON Value

/// A JSON tree the request builder can assemble field by field.
///
/// Request bodies here can't be plain `Encodable` structs: which fields exist
/// varies by vendor (`max_tokens` vs `max_completion_tokens`), and strict
/// endpoints reject unknown keys, so absent has to be genuinely absent rather
/// than null.
nonisolated indirect enum WireJSON: Sendable, Hashable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([WireJSON])
	case object([String: WireJSON])
}

extension WireJSON: Codable {

	init(from decoder: any Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([WireJSON].self) {
			self = .array(value)
		} else if let value = try? container.decode([String: WireJSON].self) {
			self = .object(value)
		} else {
			throw DecodingError.dataCorruptedError(
				in: container, debugDescription: "Unrecognized JSON value"
			)
		}
	}

	func encode(to encoder: any Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null:               try container.encodeNil()
		case .bool(let value):    try container.encode(value)
		case .number(let value):  try container.encode(value)
		case .string(let value):  try container.encode(value)
		case .array(let value):   try container.encode(value)
		case .object(let value):  try container.encode(value)
		}
	}
}

nonisolated extension WireJSON {

	static func int(_ value: Int) -> WireJSON { .number(Double(value)) }

	/// Any `Encodable` re-expressed as a tree, or nil if it won't round-trip.
	/// This is how `GenerationSchema` (Codable, encodes as JSON Schema) becomes
	/// editable before it goes on the wire.
	static func encoded(_ value: some Encodable) -> WireJSON? {
		guard let data = try? JSONEncoder().encode(value) else { return nil }
		return try? JSONDecoder().decode(WireJSON.self, from: data)
	}

	static func parsed(_ text: String) -> WireJSON? {
		try? JSONDecoder().decode(WireJSON.self, from: Data(text.utf8))
	}
}

// MARK: - Streamed Chunk

/// One `data:` line of a chat-completions SSE stream, decoded leniently —
/// every field optional, because every vendor omits a different subset.
nonisolated struct OpenAIChatChunk: Decodable, Sendable {

	var choices: [Choice]?
	var usage: Usage?

	struct Choice: Decodable, Sendable {
		var delta: Delta?
		var finishReason: String?

		enum CodingKeys: String, CodingKey {
			case delta
			case finishReason = "finish_reason"
		}
	}

	struct Delta: Decodable, Sendable {
		var content: String?
		/// DeepSeek, xAI, Alibaba, and Moonshot stream thinking here.
		var reasoningContent: String?
		/// A handful of routers (OpenRouter-style, some Hugging Face providers)
		/// use the bare key instead.
		var reasoning: String?
		var toolCalls: [ToolCallDelta]?

		enum CodingKeys: String, CodingKey {
			case content
			case reasoningContent = "reasoning_content"
			case reasoning
			case toolCalls = "tool_calls"
		}
	}

	struct ToolCallDelta: Decodable, Sendable {
		/// Which in-flight call this delta extends. The id and name arrive only
		/// on the first delta for a call; the index is the thread that ties the
		/// argument fragments to them.
		var index: Int?
		var id: String?
		var function: FunctionDelta?
	}

	struct FunctionDelta: Decodable, Sendable {
		var name: String?
		var arguments: String?
	}

	struct Usage: Decodable, Sendable {
		var promptTokens: Int?
		var completionTokens: Int?
		var promptTokensDetails: PromptDetails?
		var completionTokensDetails: CompletionDetails?

		struct PromptDetails: Decodable, Sendable {
			var cachedTokens: Int?
			enum CodingKeys: String, CodingKey {
				case cachedTokens = "cached_tokens"
			}
		}

		struct CompletionDetails: Decodable, Sendable {
			var reasoningTokens: Int?
			enum CodingKeys: String, CodingKey {
				case reasoningTokens = "reasoning_tokens"
			}
		}

		enum CodingKeys: String, CodingKey {
			case promptTokens = "prompt_tokens"
			case completionTokens = "completion_tokens"
			case promptTokensDetails = "prompt_tokens_details"
			case completionTokensDetails = "completion_tokens_details"
		}
	}
}

// MARK: - Error Envelope

/// The error body most of these endpoints agree on: `{"error": {...}}`, with
/// `message` the one field everyone fills.
nonisolated struct OpenAIErrorEnvelope: Decodable, Sendable {

	var error: Payload?
	/// Some endpoints (Gemini's compat layer among them) return the payload
	/// bare, or an array of envelopes; `message` at top level catches the rest.
	var message: String?
	/// xAI puts the machine-readable code beside `error` rather than inside it.
	var code: StringOrNumber?
	/// Meta's Llama API answers in RFC 7807 problem-details shape:
	/// `{"title": …, "detail": …, "status": 401}`, with no `error` and no
	/// `message` anywhere. `detail` is the sentence worth showing.
	var detail: String?
	var title: String?

	struct Payload: Decodable, Sendable {
		var message: String?
		var type: String?
		var code: StringOrNumber?
	}

	private enum CodingKeys: String, CodingKey {
		case error, message, code, detail, title
	}

	/// xAI answers `{"code": "permission-denied", "error": "<prose>"}` — `error`
	/// is the message itself, not an object around it. Decoding that shape as a
	/// `Payload` throws, which would lose the whole envelope and leave the user
	/// staring at a bare status code, so the string form is read as a payload
	/// carrying only its message.
	init(from decoder: any Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		if let payload = try? container.decodeIfPresent(Payload.self, forKey: .error) {
			error = payload
		} else if let text = try? container.decodeIfPresent(String.self, forKey: .error) {
			error = Payload(message: text, type: nil, code: nil)
		}
		message = try? container.decodeIfPresent(String.self, forKey: .message)
		code = try? container.decodeIfPresent(StringOrNumber.self, forKey: .code)
		detail = try? container.decodeIfPresent(String.self, forKey: .detail)
		title = try? container.decodeIfPresent(String.self, forKey: .title)
	}

	/// `code` arrives as a string from OpenAI and a number from others.
	enum StringOrNumber: Decodable, Sendable {
		case string(String)
		case number(Double)

		init(from decoder: any Decoder) throws {
			let container = try decoder.singleValueContainer()
			if let value = try? container.decode(String.self) {
				self = .string(value)
			} else {
				self = .number(try container.decode(Double.self))
			}
		}

		var text: String {
			switch self {
			case .string(let value): value
			case .number(let value): String(Int(value))
			}
		}
	}

	static func message(in data: Data) -> String? {
		guard let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) else {
			return nil
		}
		// `title` last: it's a category ("Authentication Error"), not a
		// sentence, so it only speaks when nothing better did.
		return envelope.error?.message ?? envelope.message
			?? envelope.detail ?? envelope.title
	}

	static func code(in data: Data) -> String? {
		guard let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) else {
			return nil
		}
		return (envelope.error?.code ?? envelope.code)?.text
	}
}

// MARK: - Errors

nonisolated enum OpenAICompatError: Error {

	/// No key in the Keychain or the environment — nothing was even sent.
	case missingCredential

	/// The endpoint answered with something that isn't SSE or isn't HTTP.
	case badResponse

	/// A non-200, with whatever the body said. `vendorName` is carried so the
	/// user-facing text can name who refused, not just that someone did.
	case status(Int, vendorName: String, message: String?, code: String?)

	/// Whether this is the request-doesn't-fit failure, which the backend maps
	/// to `ChatBackendError.promptTooLarge`. Vendors don't share an error code
	/// for it, so the code is checked where one exists and the message sniffed
	/// where one doesn't.
	var isContextOverflow: Bool {
		guard case .status(let status, _, let message, let code) = self,
		      status == 400 || status == 413 else { return false }
		if let code, code.contains("context_length") || code.contains("too_long") {
			return true
		}
		guard let lowered = message?.lowercased() else { return false }
		return (lowered.contains("context") || lowered.contains("token"))
			&& (lowered.contains("exceed") || lowered.contains("too long")
				|| lowered.contains("too large") || lowered.contains("maximum"))
	}

	var isUnauthorized: Bool {
		if case .status(let status, _, _, _) = self {
			return status == 401 || status == 403
		}
		if case .missingCredential = self { return true }
		return false
	}
}

extension OpenAICompatError: LocalizedError {

	var errorDescription: String? {
		switch self {
		case .missingCredential:
			"No API key is set for this vendor. Add one in Settings → Accounts."
		case .badResponse:
			"Couldn't read the vendor's reply."
		case .status(let status, let vendor, let message, _):
			switch status {
			case 401, 403:
				"\(vendor) rejected the API key."
			case 429:
				"\(vendor) is rate limiting this key."
			case 500...599:
				"\(vendor) is unavailable right now."
			default:
				message.map { "\(vendor): \($0)" }
					?? "\(vendor) returned an error (\(status))."
			}
		}
	}
}

// MARK: - SSE Transport

/// Streams a chat-completions request as decoded chunks.
nonisolated enum OpenAISSE {

	/// POST the body and yield each `data:` payload as a chunk. Non-200s read
	/// the whole body (it's small — an error envelope) and throw.
	static func stream(
		_ body: Data,
		to url: URL,
		headers: [String: String],
		vendorName: String,
		timeout: TimeInterval
	) -> AsyncThrowingStream<OpenAIChatChunk, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					var request = URLRequest(url: url)
					request.httpMethod = "POST"
					request.httpBody = body
					request.timeoutInterval = timeout
					request.setValue("application/json", forHTTPHeaderField: "Content-Type")
					request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
					for (field, value) in headers {
						request.setValue(value, forHTTPHeaderField: field)
					}

					let (bytes, response) = try await URLSession.shared.bytes(for: request)
					guard let http = response as? HTTPURLResponse else {
						throw OpenAICompatError.badResponse
					}
					guard http.statusCode == 200 else {
						var data = Data()
						// Error bodies are envelopes, not streams; still, cap the
						// read so a misbehaving endpoint can't grow it unbounded.
						for try await byte in bytes.prefix(64 * 1024) {
							data.append(byte)
						}
						throw OpenAICompatError.status(
							http.statusCode,
							vendorName: vendorName,
							message: OpenAIErrorEnvelope.message(in: data),
							code: OpenAIErrorEnvelope.code(in: data)
						)
					}

					let decoder = JSONDecoder()
					for try await line in bytes.lines {
						try Task.checkCancellation()
						guard line.hasPrefix("data:") else { continue }
						let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
						if payload == "[DONE]" { break }
						guard let data = payload.data(using: .utf8) else { continue }
						// A line that doesn't decode is a vendor extension, not a
						// failure — skip it rather than kill the stream.
						guard let chunk = try? decoder.decode(OpenAIChatChunk.self, from: data) else {
							continue
						}
						continuation.yield(chunk)
					}
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
			continuation.onTermination = { termination in
				if case .cancelled = termination {
					task.cancel()
				}
			}
		}
	}
}
