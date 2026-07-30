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

	func availableModels() async throws -> [GenerativeChatModel] {
		guard #available(macOS 27.0, *) else { return [] }
		return [.claudeSonnet, .claudeOpus]
	}

	func capabilities(of model: GenerativeChatModel) async -> ModelCapabilities {
		let supportsImages = claudeModel(for: model).capabilities.imageInput

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
			let session = try makeSession(for: model, instructions: nil)
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
					let session = try makeSession(
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

	private func claudeModel(for model: GenerativeChatModel) -> ClaudeModel {
		model.id == GenerativeChatModel.claudeOpus.id ? .opus4_8 : .sonnet4_6
	}

	private func makeSession(
		for model: GenerativeChatModel,
		instructions: String?
	) throws -> LanguageModelSession {
		guard #available(macOS 27.0, *) else {
			throw ChatBackendError.modelUnavailable(model.id)
		}
		guard let apiKey else {
			throw ChatBackendError.modelUnavailable(model.id)
		}

		let claude = ClaudeLanguageModel(
			name: claudeModel(for: model),
			auth: .apiKey(apiKey)
		)

		if let instructions {
			return LanguageModelSession(model: claude, instructions: instructions)
		}
		return LanguageModelSession(model: claude)
	}
}
