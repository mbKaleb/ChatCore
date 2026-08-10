//
//  AnthropicModelsAPI.swift
//  ChatCore
//

import Foundation
import ClaudeForFoundationModels

// MARK: - Wire Types

nonisolated struct AnthropicModelEntry: Decodable, Sendable {

	var id: String
	var displayName: String
	var maxInputTokens: Int?
	var capabilities: Capabilities?

	enum CodingKeys: String, CodingKey {
		case id
		case displayName = "display_name"
		case maxInputTokens = "max_input_tokens"
		case capabilities
	}
	
	nonisolated struct Capabilities: Decodable, Sendable {

		struct Flag: Decodable, Sendable {
			var supported: Bool?
		}

		struct Thinking: Decodable, Sendable {
			struct Types: Decodable, Sendable {
				var adaptive: Flag?
				var enabled: Flag?
			}
			var types: Types?
		}

		struct Effort: Decodable, Sendable {
			var low: Flag?
			var medium: Flag?
			var high: Flag?
			var xhigh: Flag?
			var max: Flag?
		}

		var imageInput: Flag?
		var structuredOutputs: Flag?
		var thinking: Thinking?
		var effort: Effort?

		enum CodingKeys: String, CodingKey {
			case imageInput = "image_input"
			case structuredOutputs = "structured_outputs"
			case thinking
			case effort
		}
	}
}

private nonisolated struct AnthropicModelsPage: Decodable, Sendable {
	var data: [AnthropicModelEntry]
	var hasMore: Bool?
	var lastID: String?

	enum CodingKeys: String, CodingKey {
		case data
		case hasMore = "has_more"
		case lastID = "last_id"
	}
}

// MARK: - Fetch

nonisolated enum AnthropicModelsAPI {

	static func models(apiKey: String) async throws -> [AnthropicModelEntry] {
		var entries: [AnthropicModelEntry] = []
		var afterID: String?

		// A hard page ceiling: the loop's exit depends on a field the server
		// controls, and a stuck cursor shouldn't become an endless refresh.
		for _ in 0..<10 {
			var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
			var query = [URLQueryItem(name: "limit", value: "100")]
			if let afterID {
				query.append(URLQueryItem(name: "after_id", value: afterID))
			}
			components.queryItems = query

			try Task.checkCancellation()

			var request = URLRequest(url: components.url!)
			request.httpMethod = "GET"
			request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
			request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
			// URLSession's default is 60s per request, and this loop can make
			// ten of them — a wedged route shouldn't be able to hold a refresh
			// open for ten minutes.
			request.timeoutInterval = 15

			let data = try await send(request)
			let page = try JSONDecoder().decode(AnthropicModelsPage.self, from: data)
			entries.append(contentsOf: page.data)

			guard page.hasMore == true, let last = page.lastID else { break }
			afterID = last
		}

		return entries
	}

	/// One request, retried while the failure still looks like weather.
	///
	/// A rejected key and an overloaded server both arrive as "no models", but
	/// only one of them is worth asking again about — and with no built-in
	/// model list behind it, giving up on a 529 costs the user their whole
	/// catalog until the next activation happens to succeed.
	private static func send(_ request: URLRequest) async throws -> Data {
		let attempts = 3

		for attempt in 1...attempts {
			do {
				let (data, response) = try await URLSession.shared.data(for: request)
				guard let http = response as? HTTPURLResponse else {
					throw AnthropicModelsError.badResponse
				}
				if http.statusCode == 200 { return data }

				let error = AnthropicModelsError.status(http.statusCode)
				guard error.isTransient, attempt < attempts else { throw error }

				// The server's own pacing wins when it states one; otherwise
				// back off so a retry doesn't land in the same overload.
				let advised = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
				try await Task.sleep(for: .seconds(advised ?? pow(2, Double(attempt - 1))))
			} catch let error as URLError {
				guard Self.isTransient(error), attempt < attempts else { throw error }
				try await Task.sleep(for: .seconds(pow(2, Double(attempt - 1))))
			}
		}

		throw AnthropicModelsError.badResponse
	}

	private static func isTransient(_ error: URLError) -> Bool {
		switch error.code {
		case .timedOut, .networkConnectionLost, .cannotConnectToHost,
		     .dnsLookupFailed, .cannotFindHost, .notConnectedToInternet:
			return true
		default:
			return false
		}
	}
}

nonisolated enum AnthropicModelsError: Error {
	case badResponse
	case status(Int)

	/// Whether asking again could plausibly get a different answer. A key the
	/// server rejected will be rejected just as fast three times in a row.
	var isTransient: Bool {
		switch self {
		case .badResponse:
			return false
		case .status(let code):
			return code == 408 || code == 409 || code == 429 || (500...599).contains(code)
		}
	}
}

extension AnthropicModelsError: LocalizedError {

	var errorDescription: String? {
		switch self {
		case .badResponse:
			"Couldn't read Anthropic's reply."
		case .status(401), .status(403):
			"Anthropic rejected the API key."
		case .status(429):
			"Anthropic is rate limiting this key."
		case .status(let code) where (500...599).contains(code):
			"Anthropic is unavailable right now."
		case .status(let code):
			"Anthropic returned an error (\(code))."
		}
	}
}

// MARK: - Mapping

nonisolated extension AnthropicModelEntry {

	/// Namespaced so a vendor id can't collide with Apples
	static let idPrefix = "vendor.anthropic."

	var namespacedID: GenerativeChatModel.ID { Self.idPrefix + id }

	/// The catalog prefixes every name with the vendor ("Claude Opus 4.5"), which
	/// is redundant once the models sit under Anthropic's own heading.
	var shortDisplayName: String {
		let trimmed = displayName.trimmingCharacters(in: .whitespaces)
		guard trimmed.hasPrefix("Claude ") else { return trimmed }
		let stripped = trimmed.dropFirst("Claude ".count).trimmingCharacters(in: .whitespaces)
		return stripped.isEmpty ? trimmed : stripped
	}

	var chatModel: GenerativeChatModel {
		GenerativeChatModel(
			id: namespacedID,
			displayName: shortDisplayName,
			icon: .asset("ClaudeIcon"),
			weights: .closed,
			dataResidency: .cloud,
			contextWindowTokens: maxInputTokens
		)
	}

	/// The capability set the bridge uses to decide which request fields to
	/// send — derived entirely from what the catalog reported.
	///
	/// `samplingParams` is the one field the catalog has no key for, so it is
	/// inferred from `thinking.types.enabled`: manual extended thinking and
	/// `temperature`/`top_p`/`top_k` were withdrawn in the same API generation
	/// (Opus 4.7), so a model that still accepts the one accepts the other.
	/// Verified against all 11 served models and the five the bridge package
	/// hand-checked — no disagreements.
	var claudeModel: ClaudeModel {
		let caps = capabilities

		var levels: Set<ClaudeModel.Effort> = []
		if caps?.effort?.low?.supported == true { levels.insert(.low) }
		if caps?.effort?.medium?.supported == true { levels.insert(.medium) }
		if caps?.effort?.high?.supported == true { levels.insert(.high) }
		if caps?.effort?.xhigh?.supported == true { levels.insert(.xhigh) }
		if caps?.effort?.max?.supported == true { levels.insert(.max) }

		return ClaudeModel(
			id: id,
			capabilities: .init(
				samplingParams: caps?.thinking?.types?.enabled?.supported == true,
				effortLevels: levels,
				adaptiveThinking: caps?.thinking?.types?.adaptive?.supported == true,
				structuredOutput: caps?.structuredOutputs?.supported == true,
				imageInput: caps?.imageInput?.supported == true
			)
		)
	}
}
