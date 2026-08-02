//
//  APIKeyValidator.swift
//  ChatCore
//

import Foundation

/// What a vendor said about a key the user just saved.
///
/// "Rejected" and "couldn't ask" are different answers, and only one of them is
/// the user's mistake. Collapsing them into a bool sends someone back to retype
/// a perfectly good key because their Wi-Fi dropped, so the two stay apart all
/// the way to the row that reports them.
nonisolated enum APIKeyVerdict: Sendable, Equatable {

	/// The vendor answered, with this key, and was happy.
	case valid

	/// The vendor answered and refused the key.
	case rejected

	/// Nobody answered, or answered with something that isn't about the key —
	/// a rate limit, an outage, an endpoint that moved.
	case unreachable

	/// No endpoint we know how to ask. The key is kept, unverified.
	case unchecked
}

/// Asks a vendor whether a key works, using the cheapest authenticated request
/// it serves — listing models, mostly, which every one of these fronts behind
/// the same key its chat endpoint takes.
///
/// This runs for vendors the app has no chat wire to yet. That's deliberate:
/// the question "is this key good?" is answerable long before the question
/// "what can it generate?", and answering it early is what keeps a typo from
/// sitting in the Keychain until the day support lands.
nonisolated enum APIKeyValidator {

	/// Where to ask, and how the vendor wants the key presented.
	private struct Probe {
		var url: URL
		var headers: [String: String]
	}

	static func verify(_ key: String, for vendor: ModelVendor) async -> APIKeyVerdict {
		guard let probe = probe(for: vendor, key: key) else { return .unchecked }

		var request = URLRequest(url: probe.url)
		request.httpMethod = "GET"
		for (field, value) in probe.headers {
			request.setValue(value, forHTTPHeaderField: field)
		}
		// Someone is watching a spinner: give up well short of URLSession's own
		// 60-second default.
		request.timeoutInterval = 15

		guard let (_, response) = try? await URLSession.shared.data(for: request),
		      let http = response as? HTTPURLResponse else {
			return .unreachable
		}

		switch http.statusCode {
		case 200...299: return .valid
		case 401, 403:  return .rejected
		default:        return .unreachable
		}
	}

	/// Keys go in headers, never in the query string — a URL is the one part of
	/// a request that gets logged, cached, and pasted into bug reports.
	private static func probe(for vendor: ModelVendor, key: String) -> Probe? {
		switch vendor {
		case .apple:
			return nil

		case .anthropic:
			return Probe(
				url: URL(string: "https://api.anthropic.com/v1/models")!,
				headers: ["x-api-key": key, "anthropic-version": "2023-06-01"]
			)

		case .google:
			return Probe(
				url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!,
				headers: ["x-goog-api-key": key]
			)

		case .openAI:      return bearer("https://api.openai.com/v1/models", key)
		case .xAI:         return bearer("https://api.x.ai/v1/models", key)
		case .meta:        return bearer("https://api.llama.com/v1/models", key)
		case .mistral:     return bearer("https://api.mistral.ai/v1/models", key)
		case .deepSeek:    return bearer("https://api.deepseek.com/models", key)
		case .alibaba:     return bearer("https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models", key)
		case .moonshot:    return bearer("https://api.moonshot.ai/v1/models", key)
		case .cohere:      return bearer("https://api.cohere.com/v1/models", key)

		// Hugging Face has no per-key model list — every token can see the hub.
		// Asking who the token belongs to is the check that means anything.
		case .huggingFace: return bearer("https://huggingface.co/api/whoami-v2", key)
		}
	}

	private static func bearer(_ url: String, _ key: String) -> Probe {
		Probe(url: URL(string: url)!, headers: ["Authorization": "Bearer \(key)"])
	}
}
