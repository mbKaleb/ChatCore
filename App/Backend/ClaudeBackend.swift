//
//  ClaudeBackend.swift
//  ChatCore
//

import Foundation
import FoundationModels
import ClaudeForFoundationModels

/// What the vendor told us it serves, held across the struct's copies.
///
/// `ClaudeBackend` is a value type the manager stores behind an existential, so
/// there is nowhere in it to keep the answer. The catalog is the one place the
/// discovered models live between `availableModels()` and the calls that need
/// their capabilities.
actor AnthropicModelCatalog {

	static let shared = AnthropicModelCatalog()

	private var entries: [GenerativeChatModel.ID: AnthropicModelEntry] = [:]

	func replace(with discovered: [AnthropicModelEntry]) {
		entries = Dictionary(
			discovered.map { ($0.namespacedID, $0) },
			uniquingKeysWith: { first, _ in first }
		)
	}

	func entry(for id: GenerativeChatModel.ID) -> AnthropicModelEntry? {
		entries[id]
	}
}

struct ClaudeBackend: ChatBackend {

	let id = BackendID.anthropic
	let logoName = "ClaudeLogo"

	private var apiKey: String? {
		if let stored = KeychainStore.read(ModelVendor.anthropic.keychainRef), !stored.isEmpty {
			return stored
		}
		if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
			return env
		}
		return nil
	}

	/// Ask Anthropic what it serves. Every field of every row comes from that
	/// answer — there is no built-in list to fall back to, because a built-in
	/// list is a claim about the vendor's catalog that we can't keep true.
	/// No key or no answer means no Claude rows, which is the honest state.
	func availableModels() async throws -> [GenerativeChatModel] {
		guard #available(macOS 27.0, *) else { return [] }
		guard let apiKey else { return [] }

		let discovered = try await AnthropicModelsAPI.models(apiKey: apiKey)
		await AnthropicModelCatalog.shared.replace(with: discovered)
		return discovered.map(\.chatModel)
	}

	func capabilities(of model: GenerativeChatModel) async -> ModelCapabilities {
		let supportsImages = await claudeModel(for: model).capabilities.imageInput

		return ModelCapabilities(
			availabilityState: apiKey != nil ? .available : .disabled,
			dataResidency: model.dataResidency,
			contextWindowTokens: model.contextWindowTokens,
			supportedLanguages: nil,
			supportsImageInput: supportsImages
		)
	}

	/// Anthropic's API is stateless HTTPS — there is no connection to hold open
	/// ahead of a send, and nothing server-side a speculative inference would
	/// warm: the prompt cache is keyed to a conversation's exact prefix, which
	/// no probe can share. So verification asks the cheapest authenticated
	/// question the vendor serves — the free models list. That proves the key
	/// and the route, leaves URLSession's TLS connection warm for the send
	/// that actually needs one, and costs no tokens.
	func verifyConnection(to model: GenerativeChatModel) async -> ConnectionState {
		guard let apiKey else { return .unauthorized }
		guard NetworkMonitor.shared.isOnline else { return .offline }

		switch await APIKeyValidator.verify(apiKey, for: .anthropic) {
		case .valid:       return .verified
		case .rejected:    return .unauthorized
		// A key the account isn't entitled to spend is still a key that won't
		// send: same dead end for the composer as a rejected one.
		case .forbidden:   return .unauthorized
		case .unreachable: return NetworkMonitor.shared.isOnline ? .failed : .offline
		case .unchecked:   return .unverified
		}
	}

	func reply(
		to turns: [ChatTurn],
		model: GenerativeChatModel,
		options: ChatOptions
	) -> AsyncThrowingStream<ReplyEvent, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let session = try await makeSession(
						for: model,
						instructions: Array(turns.dropLast()).historyInstructions
					)
					// The session is fresh each turn — history rides in the
					// instructions — so every reasoning entry the transcript
					// grows belongs to this turn and no baseline is skipped.
					let watcher = ThinkingWatcher.watch(session, into: continuation)
					defer { watcher.cancel() }
					let stream = session.streamResponse(
						to: turns.foundationModelsPrompt,
						options: options.generationOptions
					)
					for try await partial in stream {
						try Task.checkCancellation()
						continuation.yield(.content(partial.content))
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

	/// Resolve the wire model for a descriptor we handed out. The catalog is
	/// the only source; a descriptor that outlived its entry — a conversation
	/// pinned to a model the account no longer serves — is still addressed by
	/// its own id, never silently rerouted to a different model, and carries
	/// the minimal request shape every Claude model accepts.
	private func claudeModel(for model: GenerativeChatModel) async -> ClaudeModel {
		if let entry = await AnthropicModelCatalog.shared.entry(for: model.id) {
			return entry.claudeModel
		}
		return ClaudeModel(
			id: String(model.id.dropFirst(AnthropicModelEntry.idPrefix.count)),
			capabilities: .init(imageInput: true)
		)
	}

	private func makeSession(
		for model: GenerativeChatModel,
		instructions: String?
	) async throws -> LanguageModelSession {
		guard #available(macOS 27.0, *) else {
			throw ChatBackendError.modelUnavailable(model.id)
		}
		guard let apiKey else {
			throw ChatBackendError.modelUnavailable(model.id)
		}

		let claude = ClaudeLanguageModel(
			name: await claudeModel(for: model),
			auth: .apiKey(apiKey)
		)

		if let instructions {
			return LanguageModelSession(model: claude, instructions: instructions)
		}
		return LanguageModelSession(model: claude)
	}
}
