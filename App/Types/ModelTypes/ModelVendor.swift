//
//  ModelVendor.swift
//  ChatCore
//

import Foundation

/// A frontier-model vendor the app can be asked to talk to.
///
/// A case here is a claim about who serves the models, not about whether we
/// can reach them yet — `backend()` returning nil is what says "no wire for
/// this one", and the Models pane reads that rather than a second list. The
/// Accounts pane reads the same list from the other end: a vendor that needs a
/// key gets a field there, wired or not, because the key outlives the wiring.
nonisolated enum ModelVendor: String, CaseIterable, Identifiable, Codable, Sendable {

	case apple
	case anthropic
	case openAI
	case google
	case xAI
	case meta
	case mistral
	case deepSeek
	case alibaba
	case moonshot
	case cohere
	case huggingFace

	var id: String { rawValue }

	// MARK: - Ordering

	/// How prominently a vendor is listed in the Models pane.
	///
	/// The list is long enough that the handful of vendors anyone actually
	/// reaches for gets lost among the ones kept for completeness, so the pane
	/// splits on this rather than on `isSupported` — wiring comes and goes, but
	/// which vendors are worth putting first doesn't.
	enum Tier {
		case frontier
		case additional
	}

	var tier: Tier {
		switch self {
		case .apple, .anthropic, .openAI, .google, .xAI: .frontier
		default: .additional
		}
	}

	/// The vendors of a tier, in the order the pane shows them.
	static func vendors(in tier: Tier) -> [ModelVendor] {
		allCases.filter { $0.tier == tier }
	}

	var displayName: String {
		switch self {
		case .apple:       "Apple"
		case .anthropic:   "Anthropic"
		case .openAI:      "OpenAI"
		case .google:      "Google"
		case .xAI:         "xAI"
		case .meta:        "Meta"
		case .mistral:     "Mistral"
		case .deepSeek:    "DeepSeek"
		case .alibaba:     "Alibaba Cloud"
		case .moonshot:    "Moonshot"
		case .cohere:      "Cohere"
		case .huggingFace: "Hugging Face"
		}
	}

	/// Wording for the section's switch, e.g. "Use Anthropic AI Models".
	var toggleTitle: String { "Use \(displayName) AI Models" }

	var icon: ModelIcon {
		switch self {
		case .apple:       .symbol("apple.intelligence")
		case .anthropic:   .asset("AnthropicSymbol")
		case .openAI:      .symbol("circle.hexagongrid")
		case .google:      .symbol("sparkle")
		case .xAI:         .symbol("x.circle")
		case .meta:        .symbol("infinity")
		case .mistral:     .symbol("wind")
		case .deepSeek:    .symbol("water.waves")
		case .alibaba:     .symbol("cloud")
		case .moonshot:    .symbol("moon.stars")
		case .cohere:      .symbol("circle.grid.3x3")
		case .huggingFace: .symbol("face.smiling")
		}
	}

	var backendID: BackendID {
		switch self {
		case .apple:     .apple
		case .anthropic: .anthropic
		default:         BackendID(rawValue: rawValue)
		}
	}

	/// What the vendor's models cost the user in privacy terms — shown as the
	/// section footer so enabling a switch isn't a blind choice.
	var residencyNote: String {
		switch self {
		case .apple:
			"Runs on this Mac or in Apple's Private Cloud Compute."
		default:
			"Prompts and attachments leave this Mac for \(displayName)'s servers."
		}
	}

	/// The backend that serves this vendor, or nil when the app has no wire to
	/// it yet. Nil is what dims the switch — there is no separate flag to keep
	/// in step with the factory.
	func backend() -> (any ChatBackend)? {
		switch self {
		case .apple:
			return AppleBackend()
		case .anthropic:
			#if canImport(ClaudeForFoundationModels)
			return ClaudeBackend()
			#else
			return nil
			#endif
		default:
			return nil
		}
	}

	var isSupported: Bool { backend() != nil }

	/// Vendors that need a key before they can vend anything.
	var needsAPIKey: Bool { self != .apple }

	var defaultsKey: String { Defaults.Key.vendorEnabled(self) }

	/// Enabled out of the box only where nothing has to be configured first.
	var isEnabledByDefault: Bool { self == .apple || self == .anthropic }

	// MARK: - Accounts

	/// Where this vendor's key lives in the Keychain, under the app's service.
	///
	/// Derived from the case so a new vendor can't forget to pick one — and
	/// shaped to match what Anthropic's key was already saved under, so keys
	/// stored before there was more than one vendor stay found.
	var keychainRef: String { "\(rawValue).api-key" }

	/// What a key here actually unlocks. The Accounts field names the models
	/// rather than repeating the vendor's name back at the user, since the two
	/// often aren't the same word — Alibaba Cloud serves Qwen, Moonshot Kimi.
	var keyPurpose: String {
		switch self {
		case .apple:       "Apple's models need no key."
		case .anthropic:   "Used for Claude models."
		case .openAI:      "Used for GPT models."
		case .google:      "Used for Gemini models."
		case .xAI:         "Used for Grok models."
		case .meta:        "Used for Llama models."
		case .mistral:     "Used for Mistral and Magistral models."
		case .deepSeek:    "Used for DeepSeek models."
		case .alibaba:     "Used for Qwen models, through Model Studio."
		case .moonshot:    "Used for Kimi models."
		case .cohere:      "Used for Command models."
		case .huggingFace: "Used for models served through Hugging Face Inference Providers."
		}
	}

	/// The vendor's own page for minting a key — the one link that saves a
	/// user from guessing which of a vendor's several consoles issues them.
	var apiKeyConsole: URL? {
		switch self {
		case .apple:       nil
		case .anthropic:   URL(string: "https://platform.claude.com/settings/keys")
		case .openAI:      URL(string: "https://platform.openai.com/api-keys")
		case .google:      URL(string: "https://aistudio.google.com/apikey")
		case .xAI:         URL(string: "https://console.x.ai")
		case .meta:        URL(string: "https://ai.developer.meta.com/api-keys")
		case .mistral:     URL(string: "https://console.mistral.ai/api-keys")
		case .deepSeek:    URL(string: "https://platform.deepseek.com/api_keys")
		case .alibaba:     URL(string: "https://modelstudio.console.alibabacloud.com/#/api-key")
		case .moonshot:    URL(string: "https://platform.kimi.ai/console/api-keys")
		case .cohere:      URL(string: "https://dashboard.cohere.com/api-keys")
		case .huggingFace: URL(string: "https://huggingface.co/settings/tokens")
		}
	}

	/// A shape hint for the field, where the vendor's keys have a recognizable
	/// prefix. Anything else gets the generic placeholder rather than a guess —
	/// a wrong hint reads as "your key is malformed".
	var keyPlaceholder: String {
		switch self {
		case .anthropic:   "sk-ant-…"
		case .openAI:      "sk-…"
		case .google:      "AIza…"
		case .xAI:         "xai-…"
		case .huggingFace: "hf_…"
		default:           "API Key"
		}
	}
}
