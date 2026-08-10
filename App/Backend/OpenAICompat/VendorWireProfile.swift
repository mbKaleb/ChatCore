//
//  VendorWireProfile.swift
//  ChatCore
//
//  Where an OpenAI-dialect vendor differs from the dialect. One profile per
//  vendor: endpoints, auth shape, and the heuristics for reading a bare model
//  id — everything the generic wire code must not have to know.
//

import Foundation

nonisolated struct VendorWireProfile: Sendable {

	let vendor: ModelVendor

	/// Where chat completions POST.
	let chatURL: URL

	/// Where the catalog lives. Usually `<base>/models`, but not always —
	/// Cohere's compatibility layer and Meta's Llama API list models on a
	/// different base than they serve chat.
	let modelsURL: URL

	/// `max_completion_tokens` for OpenAI (which rejects the old field on
	/// reasoning models), `max_tokens` for everyone still on the original name.
	let maxTokensField: String

	/// Whether `stream_options: {"include_usage": true}` is safe to send.
	/// Strict endpoints 4xx on fields they don't know, so this stays false
	/// wherever it isn't documented.
	let supportsStreamOptions: Bool

	/// Whether `response_format: {"type": "json_schema"}` is served.
	let supportsJSONSchema: Bool

	/// What the vendor's model weights are, as a catalog-wide default.
	let weights: ModelWeights

	/// Environment variable consulted when the Keychain has no key — the same
	/// courtesy `ClaudeBackend` extends to `ANTHROPIC_API_KEY`.
	let apiKeyEnvironmentVariable: String

	// MARK: - Auth

	/// Every vendor in this family fronts its endpoint behind a bearer token.
	/// (The two that don't — Apple and Anthropic — have their own backends.)
	func authHeaders(key: String) -> [String: String] {
		["Authorization": "Bearer \(key)"]
	}

	// MARK: - Catalog Heuristics

	/// Substrings that mark a model id as not-a-chat-model. `/models` mixes
	/// embeddings, audio, image, and moderation models into one list; a chat
	/// picker offering `text-embedding-3-small` is a bug report waiting.
	private static let nonChatMarkers: [String] = [
		"embed", "whisper", "tts", "audio", "dall-e", "davinci", "babbage",
		"moderation", "rerank", "transcribe", "realtime", "image", "imagen",
		"sora", "veo", "aqa", "guard", "computer-use", "ocr", "voxtral",
	]

	func isChatModel(_ id: String) -> Bool {
		let lowered = id.lowercased()
		return !Self.nonChatMarkers.contains { lowered.contains($0) }
	}

	/// Whether the model reads images, judged from its id. The catalogs in
	/// this family carry no capability fields, so a family-name heuristic is
	/// the only signal there is. Erring closed: a vision model wrongly marked
	/// text-only refuses an attachment, which beats a text model erroring
	/// mid-send.
	func supportsVision(_ id: String) -> Bool {
		let lowered = id.lowercased()
		switch vendor {
		case .openAI:
			return ["gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4", "chatgpt"]
				.contains { lowered.hasPrefix($0) }
		case .google:
			return lowered.contains("gemini")
		case .xAI:
			return lowered.contains("vision") || lowered.hasPrefix("grok-4")
		case .meta:
			return lowered.contains("llama-4") || lowered.contains("vision")
		case .mistral:
			return lowered.contains("pixtral") || lowered.contains("vision")
		case .alibaba:
			return lowered.contains("-vl") || lowered.contains("omni")
		case .moonshot:
			return lowered.contains("vision")
		case .cohere:
			return lowered.contains("vision")
		case .huggingFace:
			return lowered.contains("-vl") || lowered.contains("vision")
				|| lowered.contains("pixtral") || lowered.contains("llama-4")
		case .deepSeek, .apple, .anthropic:
			return false
		}
	}

	/// Whether the model streams its reasoning over this wire (the
	/// `reasoning_content` delta). Only models that actually send it get the
	/// `.reasoning` capability — advertising it elsewhere would promise a
	/// thinking pane that never fills.
	func streamsReasoning(_ id: String) -> Bool {
		let lowered = id.lowercased()
		switch vendor {
		case .deepSeek:
			return lowered.contains("reasoner") || lowered.contains("r1")
		case .xAI:
			return lowered.contains("grok-3-mini")
		case .alibaba:
			return lowered.contains("thinking") || lowered.contains("qwq")
		case .moonshot:
			return lowered.contains("thinking")
		case .mistral:
			return lowered.contains("magistral")
		case .huggingFace:
			return lowered.contains("r1") || lowered.contains("qwq")
				|| lowered.contains("thinking")
		default:
			return false
		}
	}

	/// Whether the model rejects sampling parameters outright. OpenAI's
	/// reasoning family 400s on `temperature`; everyone else ignores what they
	/// don't use.
	func locksSampling(_ id: String) -> Bool {
		guard vendor == .openAI else { return false }
		let lowered = id.lowercased()
		if lowered.hasPrefix("gpt-5") || lowered.hasPrefix("codex") { return true }
		// o1, o3, o4… — an "o" followed by a digit.
		if lowered.count >= 2, lowered.hasPrefix("o"),
		   lowered[lowered.index(after: lowered.startIndex)].isNumber {
			return true
		}
		return false
	}

	/// A context-window size where the family makes it well known, nil where
	/// guessing would just be wrong somewhere. Nil renders as no claim; a
	/// number renders as a promise the budget code may act on.
	func contextWindowTokens(_ id: String) -> Int? {
		let lowered = id.lowercased()
		switch vendor {
		case .openAI:
			if lowered.hasPrefix("gpt-4.1") { return 1_047_576 }
			if lowered.hasPrefix("gpt-5") { return 400_000 }
			if lowered.hasPrefix("o3") || lowered.hasPrefix("o4") { return 200_000 }
			if lowered.hasPrefix("gpt-4o") || lowered.hasPrefix("chatgpt") { return 128_000 }
			return nil
		case .google:
			return lowered.contains("gemini") ? 1_048_576 : nil
		case .xAI:
			if lowered.hasPrefix("grok-4") { return 256_000 }
			if lowered.hasPrefix("grok-3") { return 131_072 }
			return nil
		case .deepSeek:
			return 128_000
		case .moonshot:
			if lowered.contains("k2") { return 256_000 }
			return nil
		default:
			return nil
		}
	}

	// MARK: - Display Names

	/// Words whose conventional casing a naive capitalizer gets wrong.
	private static let knownCasing: [String: String] = [
		"gpt": "GPT", "oss": "OSS", "glm": "GLM", "qwq": "QwQ", "qwen": "Qwen",
		"vl": "VL", "deepseek": "DeepSeek", "moe": "MoE", "ai": "AI",
		"xai": "xAI", "llm": "LLM", "chatgpt": "ChatGPT", "learnlm": "LearnLM",
	]

	/// A bare wire id, made readable: `deepseek-reasoner` → "DeepSeek Reasoner".
	/// These vendors' catalogs carry no display names, so the id is all there
	/// is to work with — the goal is legible, not marketing-exact.
	func displayName(for id: String) -> String {
		// Gemini ids arrive as "models/gemini-…"; Hugging Face ids as
		// "org/model". The last path component is the model's own name.
		let bare = id.split(separator: "/").last.map(String.init) ?? id

		return bare.split(separator: "-").map { token -> String in
			let word = String(token)
			if let known = Self.knownCasing[word.lowercased()] { return known }
			// Leave date stamps, versions, and mixed tokens ("4o", "20b") alone;
			// capitalize plain words.
			guard let first = word.first, first.isLetter, first.isLowercase else {
				return word
			}
			return word.prefix(1).uppercased() + word.dropFirst()
		}
		.joined(separator: " ")
	}

	// MARK: - Namespacing

	/// `vendor.openAI.gpt-4o` — same convention as Anthropic's entries, so a
	/// persisted model id names its vendor forever.
	var idPrefix: String { "vendor.\(vendor.rawValue)." }

	func namespacedID(for wireID: String) -> GenerativeChatModel.ID {
		idPrefix + wireID
	}

	func wireID(for namespacedID: GenerativeChatModel.ID) -> String {
		namespacedID.hasPrefix(idPrefix)
			? String(namespacedID.dropFirst(idPrefix.count))
			: namespacedID
	}

	// MARK: - The Profiles

	/// The vendor's profile, or nil for the two that don't speak this dialect.
	static func profile(for vendor: ModelVendor) -> VendorWireProfile? {
		func make(
			base: String,
			models: String? = nil,
			maxTokensField: String = "max_tokens",
			streamOptions: Bool = false,
			jsonSchema: Bool = false,
			weights: ModelWeights,
			env: String
		) -> VendorWireProfile {
			VendorWireProfile(
				vendor: vendor,
				chatURL: URL(string: base + "/chat/completions")!,
				modelsURL: URL(string: models ?? (base + "/models"))!,
				maxTokensField: maxTokensField,
				supportsStreamOptions: streamOptions,
				supportsJSONSchema: jsonSchema,
				weights: weights,
				apiKeyEnvironmentVariable: env
			)
		}

		switch vendor {
		case .apple, .anthropic:
			return nil

		case .openAI:
			return make(
				base: "https://api.openai.com/v1",
				maxTokensField: "max_completion_tokens",
				streamOptions: true, jsonSchema: true,
				weights: .closed, env: "OPENAI_API_KEY"
			)

		case .google:
			// The Gemini OpenAI-compatibility layer; ids arrive "models/…"-
			// prefixed and go back on the wire the same way.
			return make(
				base: "https://generativelanguage.googleapis.com/v1beta/openai",
				jsonSchema: true,
				weights: .closed, env: "GEMINI_API_KEY"
			)

		case .xAI:
			return make(
				base: "https://api.x.ai/v1",
				streamOptions: true, jsonSchema: true,
				weights: .closed, env: "XAI_API_KEY"
			)

		case .meta:
			// Chat is served on the compat base; the catalog on the native one.
			return make(
				base: "https://api.llama.com/compat/v1",
				models: "https://api.llama.com/v1/models",
				weights: .open, env: "LLAMA_API_KEY"
			)

		case .mistral:
			return make(
				base: "https://api.mistral.ai/v1",
				weights: .open, env: "MISTRAL_API_KEY"
			)

		case .deepSeek:
			return make(
				base: "https://api.deepseek.com",
				streamOptions: true,
				weights: .open, env: "DEEPSEEK_API_KEY"
			)

		case .alibaba:
			return make(
				base: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
				streamOptions: true,
				weights: .open, env: "DASHSCOPE_API_KEY"
			)

		case .moonshot:
			return make(
				base: "https://api.moonshot.ai/v1",
				streamOptions: true,
				weights: .open, env: "MOONSHOT_API_KEY"
			)

		case .cohere:
			// Chat on the compatibility base; the catalog on the native API,
			// which answers in its own shape — the models API decodes both.
			return make(
				base: "https://api.cohere.ai/compatibility/v1",
				models: "https://api.cohere.com/v1/models",
				weights: .closed, env: "CO_API_KEY"
			)

		case .huggingFace:
			return make(
				base: "https://router.huggingface.co/v1",
				weights: .open, env: "HF_TOKEN"
			)
		}
	}
}
