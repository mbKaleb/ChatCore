//
//  OpenAICompatBackend.swift
//  ChatCore
//
//  ChatBackend for every OpenAI-dialect vendor — one implementation,
//  parameterized by profile, mirroring ClaudeBackend seam for seam: history
//  as instructions, ThinkingWatcher on the session transcript, cumulative
//  snapshots out.
//

import Foundation
import FoundationModels

/// What each vendor told us it serves, held across the struct's copies —
/// the same job `AnthropicModelCatalog` does, keyed by namespaced id, which
/// can't collide across vendors.
actor OpenAICompatCatalog {

	static let shared = OpenAICompatCatalog()

	private var wireIDs: [GenerativeChatModel.ID: String] = [:]

	/// Replace one vendor's slice of the catalog, leaving the others alone —
	/// discovery runs per backend, and one vendor answering must not erase
	/// what another one said.
	func replace(_ discovered: [GenerativeChatModel.ID: String], for profile: VendorWireProfile) {
		wireIDs = wireIDs.filter { !$0.key.hasPrefix(profile.idPrefix) }
			.merging(discovered) { _, new in new }
	}

	func wireID(for id: GenerativeChatModel.ID) -> String? {
		wireIDs[id]
	}
}

struct OpenAICompatBackend: ChatBackend {

	let profile: VendorWireProfile

	var id: BackendID { profile.vendor.backendID }

	/// The watermark falls back to `Image(systemName:)` for anything that
	/// isn't the Claude asset, so the vendor's symbol is the right shape here.
	var logoName: String {
		switch profile.vendor.icon {
		case .symbol(let name): name
		case .asset(let name):  name
		}
	}

	nonisolated init(profile: VendorWireProfile) {
		self.profile = profile
	}

	nonisolated init?(vendor: ModelVendor) {
		guard let profile = VendorWireProfile.profile(for: vendor) else { return nil }
		self.init(profile: profile)
	}

	private var apiKey: String? {
		if let stored = KeychainStore.read(profile.vendor.keychainRef), !stored.isEmpty {
			return stored
		}
		let env = ProcessInfo.processInfo.environment[profile.apiKeyEnvironmentVariable]
		if let env, !env.isEmpty {
			return env
		}
		return nil
	}

	// MARK: - Discovery

	/// Ask the vendor what it serves and keep only what a chat picker should
	/// offer. No key or no answer means no rows — the honest state.
	func availableModels() async throws -> [GenerativeChatModel] {
		guard let apiKey else { return [] }

		let ids = try await OpenAICompatModelsAPI.modelIDs(for: profile, apiKey: apiKey)
			.filter(profile.isChatModel)

		var mapping: [GenerativeChatModel.ID: String] = [:]
		let models = ids.map { wireID -> GenerativeChatModel in
			let namespaced = profile.namespacedID(for: wireID)
			mapping[namespaced] = wireID
			return GenerativeChatModel(
				id: namespaced,
				displayName: profile.displayName(for: wireID),
				icon: profile.vendor.icon,
				weights: profile.weights,
				dataResidency: .cloud,
				contextWindowTokens: profile.contextWindowTokens(wireID)
			)
		}
		await OpenAICompatCatalog.shared.replace(mapping, for: profile)
		return models
	}

	// MARK: - Capabilities

	func capabilities(of model: GenerativeChatModel) async -> ModelCapabilities {
		let wireID = await resolvedWireID(for: model)
		return ModelCapabilities(
			availabilityState: apiKey != nil ? .available : .disabled,
			dataResidency: model.dataResidency,
			contextWindowTokens: model.contextWindowTokens,
			supportedLanguages: nil,
			supportsImageInput: profile.supportsVision(wireID)
		)
	}

	// MARK: - Connection

	func verifyConnection(to model: GenerativeChatModel) async -> ConnectionState {
		guard apiKey != nil else { return .unauthorized }
		guard NetworkMonitor.shared.isOnline else { return .offline }

		do {
			let session = try await makeSession(for: model, instructions: nil)
			_ = try await session.respond(
				to: ConnectionProbe.prompt,
				options: GenerationOptions(maximumResponseTokens: ConnectionProbe.maximumResponseTokens)
			)
			return .verified
		} catch let error as OpenAICompatError where error.isUnauthorized {
			return .unauthorized
		} catch {
			return .diagnosing(error)
		}
	}

	// MARK: - Chat

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
				} catch let error as OpenAICompatError where error.isContextOverflow {
					continuation.finish(throwing: ChatBackendError.promptTooLarge)
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

	// MARK: - Session

	/// The wire id from the catalog, or recovered from the namespace — a
	/// conversation pinned to a model the account no longer serves is still
	/// addressed by its own id, never silently rerouted.
	private func resolvedWireID(for model: GenerativeChatModel) async -> String {
		await OpenAICompatCatalog.shared.wireID(for: model.id)
			?? profile.wireID(for: model.id)
	}

	private func makeSession(
		for model: GenerativeChatModel,
		instructions: String?
	) async throws -> LanguageModelSession {
		guard let apiKey else {
			throw OpenAICompatError.missingCredential
		}

		let languageModel = OpenAICompatLanguageModel(
			wireModelID: await resolvedWireID(for: model),
			profile: profile,
			apiKey: apiKey
		)

		if let instructions {
			return LanguageModelSession(model: languageModel, instructions: instructions)
		}
		return LanguageModelSession(model: languageModel)
	}
}
