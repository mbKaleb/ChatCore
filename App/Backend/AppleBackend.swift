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

		let base: Transcript
		if let key, let cached = await TranscriptStore.shared.cached(for: key, history: history) {
			base = cached
		} else {
			base = history.transcript()
		}

		var yielded = false
		var answer = ""
		do {
			let ended = try await stream(prompt, from: base, model: model, options: options) {
				yielded = true
				answer = $0
				continuation.yield($0)
			}
			await commit(ended, for: key, answering: turns, with: answer)
		} catch {
			if let key { await TranscriptStore.shared.invalidate(key) }

			// Overflow is the one failure with a local remedy: the prompt didn't
			// fit, so shed the oldest turns and ask again. Worth doing only
			// before anything reached the screen — a retry after tokens have
			// streamed restarts the answer mid-sentence in front of the user.
			guard !yielded, let overflow = error.contextOverflow else { throw error }

			let trimmed = base.shedding(tokens: overflow.tokenCount - overflow.contextSize)
			let ended = try await stream(prompt, from: trimmed, model: model, options: options) {
				answer = $0
				continuation.yield($0)
			}
			await commit(ended, for: key, answering: turns, with: answer)
		}
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
		session.prewarm()
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

extension Transcript {

	/// Drop the oldest turns until roughly `tokens` worth of them are gone.
	///
	/// Instructions stay. They are the app's own rules, and dropping them to
	/// save a few tokens changes what the model *is* rather than what it
	/// remembers. Everything else goes oldest first and in whole entries —
	/// half a response is worse context than none of it.
	func shedding(tokens: Int) -> Transcript {
		guard tokens > 0 else { return self }

		var entries = Array(self)
		var preamble: [Transcript.Entry] = []
		if let first = entries.first, case .instructions = first {
			preamble.append(entries.removeFirst())
		}

		// No per-entry token count is exposed, so this estimates from characters
		// and overshoots on purpose: landing under the limit on the one retry
		// matters more than keeping one extra turn.
		var budget = Double(tokens) * Self.charactersPerToken * Self.overshoot
		while budget > 0, !entries.isEmpty {
			budget -= Double(entries.removeFirst().estimatedCharacters)
		}

		// A response whose prompt just went is a reply to nothing. Drop it too,
		// rather than leave the model reading its own words as the opener.
		if let first = entries.first, case .response = first {
			entries.removeFirst()
		}

		return Transcript(entries: preamble + entries)
	}

	private static let charactersPerToken = 4.0
	private static let overshoot = 1.25
}

private extension Transcript.Entry {

	/// Text length, with a flat charge for anything that isn't text.
	var estimatedCharacters: Int {
		let segments: [Transcript.Segment]
		switch self {
		case .instructions(let entry): segments = entry.segments
		case .prompt(let entry):       segments = entry.segments
		case .response(let entry):     segments = entry.segments
		case .reasoning(let entry):    segments = entry.segments
		case .toolCalls, .toolOutput:  return Self.nonTextCharacters
		@unknown default:              return Self.nonTextCharacters
		}
		return segments.reduce(0) { total, segment in
			if case .text(let text) = segment { return total + text.content.count }
			return total + Self.nonTextCharacters
		}
	}

	/// What one image is worth in characters. Rough on purpose — it only has to
	/// be the right order of magnitude to stop a transcript full of screenshots
	/// from shedding nothing.
	private static let nonTextCharacters = 4 * 1024
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
