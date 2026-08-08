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

		/// Which transcript cache a session on this route draws from. The two
		/// never share one — see `TranscriptStore.Key`.
		var cacheTag: String {
			switch self {
			case .device: "device"
			case .cloud:  "cloud"
			}
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
			if !MemoryPressureMonitor.shared.isConstrained {
				session.prewarm()
			}
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
					try await respond(to: turns, model: model, options: options, into: continuation)
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

	/// One turn, against the transcript the conversation left behind.
	///
	/// The seam hands over the whole conversation on every send, but only the
	/// last turn is new — the rest is prefix the model has already been given.
	/// So prior turns go in as transcript entries and only the new one is
	/// prompted. That is both the shape the framework expects and what lets the
	/// runtime recognize a prefix it just read instead of re-reading it whole.
	private func respond(
		to turns: [ChatTurn],
		model: GenerativeChatModel,
		options: ChatOptions,
		into continuation: AsyncThrowingStream<String, Error>.Continuation
	) async throws {
		guard let current = turns.last else { return }

		let history = Array(turns.dropLast())
		let prompt = [current].foundationModelsPrompt
		let key = options.sessionKey.map {
			TranscriptStore.Key(conversation: $0, route: Route(model).cacheTag)
		}

		var base: Transcript
		if let key, let cached = await TranscriptStore.shared.cached(for: key, history: history) {
			base = cached
		} else {
			base = history.transcript()
		}

		// Fit the send to the window before the model ever sees it. Overflow
		// is not discovered cheaply: the error only comes back after a full
		// prompt-processing pass — the most memory-hungry work a turn does —
		// so a conversation that has outgrown the window would pay that pass
		// on every send just to fail it. Shedding up front spends the
		// estimate's imprecision on one old turn instead.
		var options = options
		let budget = await contextBudget(for: model, options: options)
		if let budget {
			let overrun = base.estimatedTokens + current.estimatedPromptTokens
				- budget.promptAllowance
			if overrun > 0 {
				base = base.shedding(tokens: overrun)

				// Refusing outright is reserved for certainty. The estimate
				// is rough and the allowance is deliberately stricter than
				// the window, so a send that merely estimates over still gets
				// attempted — the real tokenizer has the last word, through
				// the retry loop below. Only a message whose text alone
				// outsizes the whole unmargined window is refused without
				// paying a prompt pass, because no shed can ever make it fit.
				let irreducible = base.estimatedTokens
					+ TokenEstimate.tokens(forCharacters: current.content.count)
				guard irreducible <= budget.contextSize else {
					throw ChatBackendError.promptTooLarge
				}
			}
			if Route(model) == .device {
				// Generation shares the window with the prompt, and the
				// device window is small enough for an answer to run it out
				// mid-sentence — the one overflow a retry can't hide. Cap the
				// answer at whatever the (post-shed) prompt actually left,
				// never less than the budget's reserve; a user-set ceiling is
				// honored by clamping, not just in the budget's arithmetic.
				let spent = base.estimatedTokens + current.estimatedPromptTokens
				let headroom = max(budget.responseReserve, budget.usableTokens - spent)
				options.maxResponseTokens = min(options.maxResponseTokens ?? headroom, headroom)
			}
		}

		var attempt = 0
		while true {
			var yielded = false
			var answer = ""
			do {
				let ended = try await stream(prompt, from: base, model: model, options: options) {
					// An empty snapshot puts nothing on screen, so it doesn't
					// spend the retry — only visible text does.
					if !$0.isEmpty { yielded = true }
					answer = $0
					continuation.yield($0)
				}
				await commit(ended, for: key, answering: turns, with: answer)
				return
			} catch {
				if let key { await TranscriptStore.shared.invalidate(key) }

				// Overflow is the one failure with a local remedy: the prompt
				// didn't fit, so shed the oldest turns and ask again.
				guard let overflow = error.contextOverflow else { throw error }

				// ...but only before anything reached the screen — a retry
				// after tokens have streamed restarts the answer mid-sentence
				// in front of the user. The window simply ran out mid-answer,
				// and saying so beats a framework error.
				guard !yielded else { throw ChatBackendError.contextWindowFull }

				attempt += 1
				guard attempt <= Self.overflowRetryLimit else {
					throw ChatBackendError.promptTooLarge
				}

				// Shed to the same target the pre-flight aims for — margin and
				// response reserve included. A prompt trimmed to just under
				// the raw window leaves the answer no room and merely trades
				// this overflow for one mid-answer. Scaled up each failed
				// attempt since the estimate already missed once, floored at
				// one token so a boundary report still makes progress, and
				// abandoned the moment shedding stops shrinking the
				// transcript: retrying an unchanged prompt can only fail the
				// same way.
				let target = budget?.promptAllowance ?? overflow.contextSize
				let deficit = max(overflow.tokenCount - target, 1) * attempt
				let trimmed = base.shedding(tokens: deficit)
				guard trimmed.count < base.count else {
					throw ChatBackendError.promptTooLarge
				}
				base = trimmed
			}
		}
	}

	/// How many overflow retries one send may spend before the failure is
	/// declared structural rather than an estimation miss.
	private static let overflowRetryLimit = 2

	/// The window this send must fit inside, when the route can name its size.
	///
	/// The device asks the framework for its real window where it can — the
	/// static number is a floor for older systems, and budgeting against a
	/// wrong window sheds turns the model had room for.
	private func contextBudget(
		for model: GenerativeChatModel,
		options: ChatOptions
	) async -> ContextBudget? {
		var size = model.contextWindowTokens
		#if compiler(>=6.4)
		if #available(macOS 27.0, *), Route(model) == .device {
			size = await DeviceContextSize.shared.value()
		}
		#endif
		guard let size, size > 0 else { return nil }
		return ContextBudget(contextSize: size, requestedResponseTokens: options.maxResponseTokens)
	}

	/// File the ending transcript under the turns it will arrive as next time.
	///
	/// The conversation handed over on the next send includes the reply this one
	/// just produced, so that reply has to be part of what the transcript is
	/// filed under. Fingerprinting the turns as they arrived here would leave
	/// every lookup one turn short and miss forever — a cache that silently
	/// never hits, which is the failure mode that looks exactly like working.
	private func commit(
		_ transcript: Transcript,
		for key: TranscriptStore.Key?,
		answering turns: [ChatTurn],
		with answer: String
	) async {
		guard let key else { return }

		// An empty reply gets dropped from the conversation rather than kept, so
		// the next send won't carry it and this transcript would describe turns
		// that no longer exist.
		guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			await TranscriptStore.shared.invalidate(key)
			return
		}

		await TranscriptStore.shared.commit(
			transcript,
			for: key,
			history: turns + [ChatTurn(role: .assistant, content: answer)]
		)
	}

	/// Runs one prompt and hands back the transcript the session ended with.
	private func stream(
		_ prompt: Prompt,
		from transcript: Transcript,
		model: GenerativeChatModel,
		options: ChatOptions,
		onSnapshot: (String) -> Void
	) async throws -> Transcript {
		let session = try makeSession(for: model, transcript: transcript)
		// Prewarming trades memory now for latency later; under pressure that
		// trade runs the wrong way. The model still loads on demand.
		if !MemoryPressureMonitor.shared.isConstrained {
			session.prewarm()
		}
		let stream = session.streamResponse(to: prompt, options: options.generationOptions)
		for try await partial in stream {
			onSnapshot(partial.content)
		}
		return session.transcript
	}

	private func makeSession(
		for model: GenerativeChatModel,
		transcript: Transcript
	) throws -> LanguageModelSession {
		switch Route(model) {
		case .device:
			return LanguageModelSession(transcript: transcript)

		case .cloud:
			#if compiler(>=6.4)
			if #available(macOS 27.0, *), hasPCCEntitlement {
				let pcc = PrivateCloudComputeLanguageModel()
				guard pcc.isAvailable, !pcc.quotaUsage.isLimitReached else {
					throw ChatBackendError.modelUnavailable(model.id)
				}
				return LanguageModelSession(model: pcc, transcript: transcript)
			}
			#endif
			throw ChatBackendError.modelUnavailable(model.id)
		}
	}
}

// MARK: - Context Overflow

private extension Error {

	/// The context-window numbers, when running out of window is what went
	/// wrong. Nil for every other failure.
	var contextOverflow: (contextSize: Int, tokenCount: Int)? {
		guard let error = self as? LanguageModelError,
			  case .contextSizeExceeded(let info) = error
		else { return nil }
		return (info.contextSize, info.tokenCount)
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
