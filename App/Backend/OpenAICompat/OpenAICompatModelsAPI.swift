//
//  OpenAICompatModelsAPI.swift
//  ChatCore
//
//  Model discovery for the OpenAI-dialect vendors. Same posture as
//  AnthropicModelsAPI: the vendor's answer is the whole catalog, retried while
//  the failure still looks like weather, and no built-in list to fall back to.
//

import Foundation

nonisolated enum OpenAICompatModelsAPI {

	/// The ids the vendor serves, in the order it lists them.
	static func modelIDs(for profile: VendorWireProfile, apiKey: String) async throws -> [String] {
		var request = URLRequest(url: profile.modelsURL)
		request.httpMethod = "GET"
		for (field, value) in profile.authHeaders(key: apiKey) {
			request.setValue(value, forHTTPHeaderField: field)
		}
		request.timeoutInterval = 15

		let data = try await send(request, vendorName: profile.vendor.displayName)
		let page = try JSONDecoder().decode(ModelsPage.self, from: data)
		return page.ids
	}

	/// The two catalog shapes in play: the dialect's `{"data": [{"id": …}]}`
	/// and Cohere's native `{"models": [{"name": …}]}`. Decoding both here
	/// keeps the difference out of the call path.
	private struct ModelsPage: Decodable {
		struct Entry: Decodable {
			var id: String?
			var name: String?
		}
		var data: [Entry]?
		var models: [Entry]?

		var ids: [String] {
			((data ?? []) + (models ?? [])).compactMap { $0.id ?? $0.name }
		}
	}

	/// One request, retried while the failure still looks transient — the same
	/// judgment `AnthropicModelsAPI.send` applies, because losing a whole
	/// catalog to one 529 costs the same either side of the dialect line.
	private static func send(_ request: URLRequest, vendorName: String) async throws -> Data {
		let attempts = 3

		for attempt in 1...attempts {
			try Task.checkCancellation()
			do {
				let (data, response) = try await URLSession.shared.data(for: request)
				guard let http = response as? HTTPURLResponse else {
					throw OpenAICompatError.badResponse
				}
				if http.statusCode == 200 { return data }

				let error = OpenAICompatError.status(
					http.statusCode,
					vendorName: vendorName,
					message: OpenAIErrorEnvelope.message(in: data),
					code: OpenAIErrorEnvelope.code(in: data)
				)
				guard isTransient(status: http.statusCode), attempt < attempts else {
					throw error
				}
				let advised = http.value(forHTTPHeaderField: "Retry-After")
					.flatMap(TimeInterval.init)
				try await Task.sleep(for: .seconds(advised ?? pow(2, Double(attempt - 1))))
			} catch let error as URLError {
				guard isTransient(error), attempt < attempts else { throw error }
				try await Task.sleep(for: .seconds(pow(2, Double(attempt - 1))))
			}
		}

		throw OpenAICompatError.badResponse
	}

	private static func isTransient(status: Int) -> Bool {
		status == 408 || status == 409 || status == 429 || (500...599).contains(status)
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
