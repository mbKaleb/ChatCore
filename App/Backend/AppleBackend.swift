//
//  AppleBackend.swift
//  ChatCore
//

import Foundation
import FoundationModels
import Security

struct AppleBackend: ChatBackend {

	let id = BackendID.apple
	let logoName = "apple.intelligence"

	private var hasPCCEntitlement: Bool {
		guard let task = SecTaskCreateFromSelf(nil) else { return false }
		return SecTaskCopyValueForEntitlement(
			task,
			"com.apple.developer.private-cloud-compute" as CFString,
			nil
		) != nil
	}

	enum Route {
		case device
		case cloud

		init(_ model: GenerativeChatModel) {
			self = model.id == GenerativeChatModel.privateCloud.id ? .cloud : .device
		}
	}

	// MARK: - Models

	func availableModels() async throws -> [GenerativeChatModel] {
		[.onDevice, .privateCloud]
	}

	// MARK: - Capabilities

	func capabilities(of model: GenerativeChatModel) async -> ModelCapabilities {
		switch Route(model) {
		case .device: await deviceCapabilities(of: model)
		case .cloud:  await cloudCapabilities(of: model)
		}
	}

	private func deviceCapabilities(of model: GenerativeChatModel) async -> ModelCapabilities {
		let state: AvailabilityState
		switch SystemLanguageModel.default.availability {
		case .available:
			state = .available
		case .unavailable(let reason):
			switch reason {
			case .deviceNotEligible:           state = .deviceNotEligible
			case .appleIntelligenceNotEnabled: state = .disabled
			case .modelNotReady:               state = .downloading
			@unknown default:                  state = .unknown
			}
		}

		var contextTokens = model.contextWindowTokens
		var supportsImages = false
		#if compiler(>=6.4)
		if #available(macOS 27.0, *) {
			contextTokens = await DeviceContextSize.shared.value()
			supportsImages = SystemLanguageModel.default.capabilities.contains(.vision)
		}
		#endif

		return ModelCapabilities(
			availabilityState: state,
			dataResidency: model.dataResidency,
			contextWindowTokens: contextTokens,
			supportedLanguages: SystemLanguageModel.default.supportedLanguages.count,
			supportsImageInput: supportsImages
		)
	}

	private func cloudCapabilities(of model: GenerativeChatModel) async -> ModelCapabilities {
		#if compiler(>=6.4)
		if #available(macOS 27.0, *), hasPCCEntitlement {
			let pcc = PrivateCloudComputeLanguageModel()
			let state: AvailabilityState =
				pcc.quotaUsage.isLimitReached ? .quotaExceeded
				: pcc.isAvailable             ? .available
				: .unknown
			return ModelCapabilities(
				availabilityState: state,
				dataResidency: model.dataResidency,
				contextWindowTokens: (try? await pcc.contextSize) ?? model.contextWindowTokens,
				supportedLanguages: pcc.supportedLanguages.count,
				supportsImageInput: pcc.capabilities.contains(.vision)
			)
		}
		#endif
		return ModelCapabilities(
			availabilityState: .deviceNotEligible,
			dataResidency: model.dataResidency,
			contextWindowTokens: model.contextWindowTokens,
			supportedLanguages: nil,
			supportsImageInput: false
		)
	}

	// MARK: - Connection

	func verifyConnection(to model: GenerativeChatModel) async -> ConnectionState {
		switch Route(model) {
		case .device: await verifyDevice()
		case .cloud:  await verifyCloud()
		}
	}

	private func verifyDevice() async -> ConnectionState {
		guard case .available = SystemLanguageModel.default.availability else {
			return .failed
		}
		do {
			let session = LanguageModelSession()
			session.prewarm()
			_ = try await session.respond(
				to: ConnectionProbe.prompt,
				options: GenerationOptions(maximumResponseTokens: ConnectionProbe.maximumResponseTokens)
			)
			return .verified
		} catch {
			return .diagnosing(error)
		}
	}

	private func verifyCloud() async -> ConnectionState {
		#if compiler(>=6.4)
		if #available(macOS 27.0, *), hasPCCEntitlement {
			guard NetworkMonitor.shared.isOnline else { return .offline }

			let pcc = PrivateCloudComputeLanguageModel()
			guard pcc.isAvailable, !pcc.quotaUsage.isLimitReached else { return .failed }
			do {
				_ = try await LanguageModelSession(model: pcc).respond(
					to: ConnectionProbe.prompt,
					options: GenerationOptions(maximumResponseTokens: ConnectionProbe.maximumResponseTokens)
				)
				return .verified
			} catch {
				return .diagnosing(error)
			}
		}
		#endif
		return .failed
	}

	// MARK: - Reply

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

	private func makeSession(
		for model: GenerativeChatModel,
		instructions: String?
	) throws -> LanguageModelSession {
		switch Route(model) {
		case .device:
			if let instructions {
				return LanguageModelSession(instructions: instructions)
			}
			return LanguageModelSession()

		case .cloud:
			#if compiler(>=6.4)
			if #available(macOS 27.0, *), hasPCCEntitlement {
				let pcc = PrivateCloudComputeLanguageModel()
				guard pcc.isAvailable, !pcc.quotaUsage.isLimitReached else {
					throw ChatBackendError.modelUnavailable(model.id)
				}
				if let instructions {
					return LanguageModelSession(model: pcc, instructions: instructions)
				}
				return LanguageModelSession(model: pcc)
			}
			#endif
			throw ChatBackendError.modelUnavailable(model.id)
		}
	}
}

// MARK: - Options Mapping

extension ChatOptions {
	var generationOptions: GenerationOptions {
		GenerationOptions(
			temperature: temperature,
			maximumResponseTokens: maxResponseTokens
		)
	}
}

#if compiler(>=6.4)
@available(macOS 27.0, *)
private actor DeviceContextSize {
	static let shared = DeviceContextSize()
	private var cached: Int?

	func value() async -> Int {
		if let cached { return cached }
		let size = await Task.detached(priority: .utility) {
			SystemLanguageModel.default.contextSize
		}.value
		cached = size
		return size
	}
}
#endif
