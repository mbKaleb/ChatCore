//
//  AnthropicAPIKeyValidator.swift
//  ChatCore
//

import Foundation

nonisolated enum AnthropicAPIKeyValidator {

	static func verify(apiKey: String) async -> Bool {
		var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
		request.httpMethod = "GET"
		request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
		request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

		guard let (_, response) = try? await URLSession.shared.data(for: request),
		      let http = response as? HTTPURLResponse else {
			return false
		}
		return http.statusCode == 200
	}
}
