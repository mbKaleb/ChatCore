//
//  ModelVendor.swift
//  ChatCore
//

import Foundation

/// A frontier-model vendor the app can be asked to talk to.
///
/// A case here is a claim about who serves the models, not about whether we
/// can reach them yet — `backend()` returning nil is what says "no wire for
/// this one", and the Models pane reads that rather than a second list.
nonisolated enum ModelVendor: String, CaseIterable, Identifiable, Codable, Sendable {

	case apple
	case anthropic
	case openAI
	case google
	case xAI
	case meta
	case mistral
	case deepSeek

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .apple:     "Apple"
		case .anthropic: "Anthropic"
		case .openAI:    "OpenAI"
		case .google:    "Google"
		case .xAI:       "xAI"
		case .meta:      "Meta"
		case .mistral:   "Mistral AI"
		case .deepSeek:  "DeepSeek"
		}
	}

	/// Wording for the section's switch, e.g. "Use Anthropic AI Models".
	var toggleTitle: String { "Use \(displayName) AI Models" }

	var icon: ModelIcon {
		switch self {
		case .apple:     .symbol("apple.intelligence")
		case .anthropic: .asset("AnthropicSymbol")
		default:         .symbol("sparkles")
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
}
