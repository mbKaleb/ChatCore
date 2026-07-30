//
//  AnthropicModelsAPI.swift
//  ChatCore
//

import Foundation
import ClaudeForFoundationModels

// MARK: - Wire Types

/// One entry from `GET /v1/models`.
///
/// The vendor is the authority on what it serves, so the app asks rather than
/// hardcoding a list that silently rots the week a model ships or retires.
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

	/// The capability tree, decoded leniently: every node is optional and a
	/// missing one reads as unsupported. A field the API adds later can't break
	/// decoding, and a field it drops degrades to "don't send it" — the safe
	/// direction, since sending a field a model rejects is a hard 400.
	nonisolated struct Capabilities: Decodable, Sendable {

		struct Flag: Decodable, Sendable {
			var supported: Bool?
		}

		struct Thinking: Decodable, Sendable {
			struct Types: Decodable, Sendable {
				var adaptive: Flag?
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

	/// Pages are followed rather than assumed away — the endpoint is a cursor
	/// list, and a single page is a coincidence of today's catalog size.
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

			var request = URLRequest(url: components.url!)
			request.httpMethod = "GET"
			request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
			request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

			let (data, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse else {
				throw AnthropicModelsError.badResponse
			}
			guard http.statusCode == 200 else {
				throw AnthropicModelsError.status(http.statusCode)
			}

			let page = try JSONDecoder().decode(AnthropicModelsPage.self, from: data)
			entries.append(contentsOf: page.data)

			guard page.hasMore == true, let last = page.lastID else { break }
			afterID = last
		}

		return entries
	}
}

nonisolated enum AnthropicModelsError: Error {
	case badResponse
	case status(Int)
}

// MARK: - Mapping

nonisolated extension AnthropicModelEntry {

	/// Namespaced so a vendor id can't collide with Apple's, and so persisted
	/// conversations keep pointing at the same model across launches.
	static let idPrefix = "vendor.anthropic."

	var namespacedID: GenerativeChatModel.ID { Self.idPrefix + id }

	var chatModel: GenerativeChatModel {
		GenerativeChatModel(
			id: namespacedID,
			displayName: displayName,
			icon: .asset("ClaudeIcon"),
			weights: .closed,
			dataResidency: .cloud,
			contextWindowTokens: maxInputTokens
		)
	}

	/// The bridge needs a capability set to decide which request fields to
	/// send. A model the package compiled in already carries a hand-checked
	/// one — including `samplingParams`, which the API doesn't report — so
	/// that wins; anything newer is described by the wire capabilities.
	var claudeModel: ClaudeModel {
		if let known = ClaudeModel.compiledIn[id] { return known }

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
				samplingParams: false,
				effortLevels: levels,
				adaptiveThinking: caps?.thinking?.types?.adaptive?.supported == true,
				structuredOutput: caps?.structuredOutputs?.supported == true,
				imageInput: caps?.imageInput?.supported == true
			)
		)
	}
}

nonisolated extension ClaudeModel {

	static let compiledIn: [String: ClaudeModel] = [
		opus4_8.id: .opus4_8,
		opus4_7.id: .opus4_7,
		opus4_6.id: .opus4_6,
		sonnet4_6.id: .sonnet4_6,
		haiku4_5.id: .haiku4_5,
	]
}
