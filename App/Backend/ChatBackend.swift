//
//  ChatBackend.swift
//  ChatCore
//

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Backend Protocol

protocol ChatBackend: Sendable {

	var id: BackendID { get }

	var logoName: String { get }

	func availableModels() async throws -> [GenerativeChatModel]

	func capabilities(of model: GenerativeChatModel) async -> ModelCapabilities

	func verifyConnection(to model: GenerativeChatModel) async -> ConnectionState

	func reply(
		to turns: [ChatTurn],
		model: GenerativeChatModel,
		options: ChatOptions
	) -> AsyncThrowingStream<String, Error>
}

// MARK: - Connection Probe

nonisolated enum ConnectionProbe {

	static let prompt = "Reply with the single word: ok"

	static let maximumResponseTokens = 64
}

// MARK: - Wire-Neutral Message

nonisolated struct ChatTurn: Sendable {
	enum Role: String, Sendable {
		case system
		case user
		case assistant
	}

	var role: Role
	var content: String
	var images: [ChatImage] = []
}

nonisolated struct ChatImage: Sendable, Hashable {
	var data: Data
	var label: String
	var title: String

	func decoded() -> CGImage? {
		AttachmentImage.decode(data)
	}
}

extension Array where Element == ChatTurn {

	var allImages: [ChatImage] { flatMap(\.images) }

	var historyInstructions: String? {
		guard !isEmpty else { return nil }
		let lines = map { turn -> String in
			let markers = turn.images
				.map { "[\($0.label): \($0.title)]" }
				.joined(separator: " ")
			let body = [markers, turn.content]
				.filter { !$0.isEmpty }
				.joined(separator: "\n")
			return "\(turn.role.rawValue): \(body)"
		}
		return "This is a continuation of a prior conversation. History:\n"
			+ lines.joined(separator: "\n")
	}
}

// MARK: - Generation Options

nonisolated struct ChatOptions: Sendable {
	var temperature: Double = 1.0
	var maxResponseTokens: Int? = nil

	/// Which conversation this send belongs to, when it belongs to one.
	///
	/// A backend that keeps per-conversation state keys it on this. It rides in
	/// the options rather than the protocol because a stateless HTTP backend
	/// should be free to ignore it, and it's a bare UUID rather than the
	/// conversation because nothing below the seam sees SwiftData.
	///
	/// Nil means a one-shot with no conversation behind it — a title, a summary
	/// — which must leave no trace in any chat's history.
	var sessionKey: UUID? = nil

	static let `default` = ChatOptions()
}

// MARK: - Backend Errors

nonisolated enum ChatBackendError: Error {
	case modelUnavailable(GenerativeChatModel.ID)

	/// The current message alone outsizes the model's context window — no
	/// amount of shedding older turns can make this send fit.
	case promptTooLarge

	/// The context window ran out while the answer was streaming. The partial
	/// answer is already on screen, so no retry can fix it quietly.
	case contextWindowFull

	case notImplemented
}

/// What the user reads when one of these surfaces. The raw framework
/// descriptions talk about token counts and exceeded sizes; nobody who hasn't
/// read this file deserves those.
nonisolated extension ChatBackendError: LocalizedError {
	var errorDescription: String? {
		switch self {
		case .modelUnavailable:
			"That model isn't available right now."
		case .promptTooLarge:
			"This message doesn't fit in the model's context window, even with older messages set aside. Shorten it, remove attachments, or switch to a model with a larger window."
		case .contextWindowFull:
			"The model ran out of context window mid-answer, so the reply may be incomplete. Ask for less at once, or switch to a model with a larger window."
		case .notImplemented:
			"This backend doesn't support that yet."
		}
	}
}
