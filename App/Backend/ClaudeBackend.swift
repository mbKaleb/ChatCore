//
//  ClaudeBackend.swift
//  ChatCore
//

import Foundation
import FoundationModels
import ClaudeForFoundationModels

nonisolated extension GenerativeChatModel {

	static let claudeSonnet = GenerativeChatModel(
		id: "vendor.anthropic.claude-sonnet-4-6",
		displayName: "Claude Sonnet 4.6",
		icon: .asset("ClaudeIcon"),
		weights: .closed,
		dataResidency: .cloud,
		contextWindowTokens: 200_000
	)

	static let claudeOpus = GenerativeChatModel(
		id: "vendor.anthropic.claude-opus-4-8",
		displayName: "Claude Opus 4.8",
		icon: .asset("ClaudeIcon"),
		weights: .closed,
		dataResidency: .cloud,
		contextWindowTokens: 200_000
	)
}

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
		if let stored = KeychainStore.read(KeychainStore.anthropicAPIKeyRef), !stored.isEmpty {
			return stored
		}
		if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
			return env
		}
		return nil
	}

	/// Ask Anthropic what it serves. Without a key there is nothing to ask
	/// with, so the compiled-in pair stands in — the picker still has rows to
	/// show, dimmed, which is what tells the user a key is what's missing.
	func availableModels() async throws -> [GenerativeChatModel] {
		guard #available(macOS 27.0, *) else { return [] }
		guard let apiKey else { return Self.fallbackModels }

		guard let discovered = try? await AnthropicModelsAPI.models(apiKey: apiKey),
		      !discovered.isEmpty else {
			// An offline launch or a transient failure shouldn't empty the
			// sidebar of every Claude model the user was mid-conversation with.
			return Self.fallbackModels
		}

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

	func verifyConnection(to model: GenerativeChatModel) async -> ConnectionState {
		guard #available(macOS 27.0, *) else { return .failed }
		guard apiKey != nil else { return .unauthorized }
		guard NetworkMonitor.shared.isOnline else { return .offline }

		do {
			let session = try await makeSession(for: model, instructions: nil)
			_ = try await session.respond(
				to: ConnectionProbe.prompt,
				options: GenerationOptions(maximumResponseTokens: ConnectionProbe.maximumResponseTokens)
			)
			return .verified
		} catch ClaudeError.missingCredential {
			return .unauthorized
		} catch {
			return .diagnosing(error)
		}
	}

	func reply(
		to turns: [ChatTurn],
		model: GenerativeChatModel,
		options: ChatOptions
	) -> AsyncThrowingStream<String, Error> {
		AsyncThrowingStream { continuation in
			let task = Task {
				do {
					let session = try await makeSession(
						for: model,
						instructions: Array(turns.dropLast()).historyInstructions
					)
					let stream = session.streamResponse(
						to: turns.foundationModelsPrompt,
						options: options.generationOptions
					)
					for try await partial in stream {
						try Task.checkCancellation()
						continuation.yield(partial.content)
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

	static let fallbackModels: [GenerativeChatModel] = [.claudeSonnet, .claudeOpus]

	/// Resolve the wire model — and its capabilities — for a descriptor we
	/// handed out. Discovery is the source of truth; the compiled-in table
	/// covers the fallback list and any descriptor that outlived a refresh.
	private func claudeModel(for model: GenerativeChatModel) async -> ClaudeModel {
		if let entry = await AnthropicModelCatalog.shared.entry(for: model.id) {
			return entry.claudeModel
		}
		let vendorID = String(model.id.dropFirst(AnthropicModelEntry.idPrefix.count))
		return ClaudeModel.compiledIn(for: vendorID) ?? .sonnet4_6
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
