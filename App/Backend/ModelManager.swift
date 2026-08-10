//
//  ModelManager.swift
//  ChatCore
//
//  Created by Kaleb Franken on 7/10/26.
//

import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class ModelManager {

	// MARK: - Published State (what views read)

	private(set) var chatModels: [GenerativeChatModel] = []

	/// The models a newer release of the same family has replaced, computed over
	/// the whole vended catalog.
	///
	/// Every list that leads with what a vendor ships today reads this one set
	/// rather than deriving its own. Derived per-list, the answer changes with
	/// the list: run it over the models that survived a filter and the newest
	/// *surviving* Opus becomes current, so a pane and a picker looking at the
	/// same catalog would disagree about which models are the old ones.
	private(set) var supersededModelIDs: Set<GenerativeChatModel.ID> = []

	/// Switch positions someone has actually set, for the models the vendors
	/// currently vend.
	///
	/// Rebuilt from `UserDefaults` on every discovery, so it can only ever name
	/// models a vendor just offered — and the stored value stays put for the ones
	/// it doesn't, since a vendor that failed to answer hasn't retired anything.
	/// A model with no entry here has never been switched either way, which is
	/// not the same as being switched on.
	private(set) var modelOverrides: [GenerativeChatModel.ID: Bool] = [:]

	private(set) var capabilities: [GenerativeChatModel.ID: ModelCapabilities] = [:]

	/// Why a backend vended nothing, when the reason was that we couldn't ask.
	///
	/// An empty model list means the same thing on screen whether the vendor
	/// serves nothing or the request failed, so the two have to be told apart
	/// here — this is what lets the Models pane say "couldn't reach Anthropic"
	/// instead of letting the rows disappear without explanation.
	private(set) var discoveryErrors: [BackendID: String] = [:]

	/// Refreshes are serialized, but a caller can still join one already in
	/// flight, so the depth is counted rather than flagged — a bare `Bool` with
	/// a `defer` lets whichever run finishes first clear it for the other.
	private(set) var activeRefreshes = 0

	var isRefreshing: Bool { activeRefreshes > 0 }

	private(set) var probeGeneration = 0

	private(set) var liveText: [Message.ID: String] = [:]

	/// The reasoning streamed for a turn in flight, when the model reasons out
	/// loud. Display-only: nothing persists it, and `endGeneration` drops it
	/// with the rest of the live state.
	private(set) var liveThinking: [Message.ID: String] = [:]

	/// The turns in flight, published separately from `liveText` so chrome that
	/// only needs on/off — the send button flipping to a stop square — isn't
	/// invalidated by every token flush. A set rather than a scalar: two
	/// conversations can stream at once, and a scalar let the second send
	/// overwrite the first, turning the older chat's stop button back into a
	/// send arrow while its stream was still running.
	private(set) var generatingMessageIDs: Set<Message.ID> = []

	/// The conversations those turns belong to, for chrome that stands outside
	/// any one chat view — the window tab's spinner needs "is *this window's*
	/// chat busy" without holding the messages themselves.
	private(set) var generatingConversationIDs: Set<UUID> = []

	@ObservationIgnored
	private var conversationForMessage: [Message.ID: UUID] = [:]

	@ObservationIgnored
	private var cancelHandlers: [Message.ID: @MainActor () -> Void] = [:]

	private(set) var liveChunks: [Message.ID: [StreamChunk]] = [:]

	private struct ChunkCursor {
		var text: String
		var byteCount: Int
		/// When the next recorded piece may become visible. The model streams
		/// per token but delivers in decode batches ~300ms apart, so arrivals
		/// are re-spread at a steady pace to read as tokens, not blocks.
		///
		/// Optional rather than a sentinel: a monotonic instant has no
		/// `.distantPast` to reach for, and "nothing scheduled yet" is what nil
		/// already says.
		var nextArrival: ContinuousClock.Instant?
	}

	/// Target delay between two pieces of one delta becoming visible.
	private static let paceSpacing: Duration = .milliseconds(25)

	/// How far past "now" a piece may be scheduled. Deltas that would push
	/// beyond this get compressed instead — the reveal stays a beat behind the
	/// stream at most, rather than drifting into a minutes-long typewriter.
	private static let paceWindow: Duration = .milliseconds(350)
	@ObservationIgnored
	private var chunkCursor: [Message.ID: ChunkCursor] = [:]

	func beginGeneration(for messageID: Message.ID, in conversationID: UUID) {
		liveText[messageID] = ""
		liveChunks[messageID] = []
		chunkCursor[messageID] = ChunkCursor(text: "", byteCount: 0)
		generatingMessageIDs.insert(messageID)
		conversationForMessage[messageID] = conversationID
		generatingConversationIDs.insert(conversationID)
	}

	func registerCancellation(for messageID: Message.ID, _ cancel: @escaping @MainActor () -> Void) {
		cancelHandlers[messageID] = cancel
	}

	func updateGeneration(_ messageID: Message.ID, text: String) {
		liveText[messageID] = text
	}

	func updateThinking(_ messageID: Message.ID, text: String) {
		liveThinking[messageID] = text
	}

	func recordChunk(_ full: String, for messageID: Message.ID) {
		let cursor = chunkCursor[messageID] ?? ChunkCursor(text: "", byteCount: 0)
		guard full != cursor.text else { return }

		guard full.utf8.starts(with: cursor.text.utf8) else {
			chunkCursor[messageID] = ChunkCursor(text: full, byteCount: full.utf8.count)
			liveChunks[messageID] = [StreamChunk(id: 0, text: full, arrival: ContinuousClock.now)]
			return
		}

		let delta = String(decoding: full.utf8.dropFirst(cursor.byteCount), as: UTF8.self)
		guard !delta.isEmpty else { return }

		var chunks = liveChunks[messageID] ?? []
		let pieces = Self.pieces(of: delta)
		let now = ContinuousClock.now
		var arrival = max(now, cursor.nextArrival ?? now)
		let deadline = now + Self.paceWindow
		// Negative once the cursor is already past the window; the clamp below
		// is what absorbs that, as the interval arithmetic here used to.
		let headroom = deadline - arrival
		// `pieces.count` is non-zero — the empty delta is turned away above —
		// and that guard is load-bearing now in a way it was not: dividing a
		// `Duration` by zero traps where dividing a `Double` did not.
		let spacing = min(Self.paceSpacing, max(.zero, headroom) / pieces.count)
		for piece in pieces {
			chunks.append(StreamChunk(id: chunks.count, text: piece, arrival: arrival))
			arrival += spacing
		}

		chunkCursor[messageID] = ChunkCursor(
			text: full, byteCount: full.utf8.count, nextArrival: arrival
		)
		liveChunks[messageID] = chunks
	}

	/// Word-sized pieces of a delta, each keeping the whitespace that precedes
	/// it, so scattering their arrivals reads as one word landing at a time.
	private static func pieces(of delta: String) -> [String] {
		var pieces: [String] = []
		var current = ""
		var sawWord = false
		for character in delta {
			if character.isWhitespace, sawWord {
				pieces.append(current)
				current = ""
				sawWord = false
			}
			current.append(character)
			if !character.isWhitespace { sawWord = true }
		}
		if !current.isEmpty { pieces.append(current) }
		return pieces
	}

	func cancelGeneration(for messageID: Message.ID) {
		cancelHandlers[messageID]?()
	}

	func isGenerating(_ messageID: Message.ID) -> Bool {
		liveText[messageID] != nil
	}

	func endGeneration(for messageID: Message.ID) {
		liveText.removeValue(forKey: messageID)
		liveThinking.removeValue(forKey: messageID)
		liveChunks.removeValue(forKey: messageID)
		chunkCursor.removeValue(forKey: messageID)
		cancelHandlers.removeValue(forKey: messageID)
		generatingMessageIDs.remove(messageID)
		// Only clear the conversation once its *last* turn ends — the set is
		// per-conversation, the mapping per-message, and they can disagree.
		if let conversationID = conversationForMessage.removeValue(forKey: messageID),
		   !conversationForMessage.values.contains(conversationID) {
			generatingConversationIDs.remove(conversationID)
		}
	}

	// MARK: - Backends (private — nothing above this layer sees them)

	private var backends: [BackendID: any ChatBackend] = [:]
	private var modelBackend: [GenerativeChatModel.ID: BackendID] = [:]

	private var backendLogos: [BackendID: String] = [:]

	@ObservationIgnored
	nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

	@ObservationIgnored
	nonisolated(unsafe) private var networkObserver: UUID?

	// MARK: - Init

	init() {
		activationObserver = NotificationCenter.default.addObserver(
			forName: NSApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				await self?.refresh()
			}
		}

		NetworkMonitor.shared.start()
		networkObserver = NetworkMonitor.shared.addObserver { [weak self] online in
			Task { @MainActor in
				self?.networkPathChanged(online: online)
			}
		}
	}

	deinit {
		if let activationObserver {
			NotificationCenter.default.removeObserver(activationObserver)
		}
		if let networkObserver {
			NetworkMonitor.shared.removeObserver(networkObserver)
		}
	}

	// MARK: - Setup

	func register(_ backend: any ChatBackend) {
		backends[backend.id] = backend
		backendLogos[backend.id] = backend.logoName
		discoveryGeneration &+= 1
	}

	func unregister(_ id: BackendID) {
		backends.removeValue(forKey: id)
		chatModels.removeAll { model in
			modelBackend[model.id] == id
		}
		modelBackend = modelBackend.filter { $0.value != id }
		capabilities = capabilities.filter { key, _ in
			chatModels.contains { $0.id == key }
		}
		probeResults = probeResults.filter { key, _ in
			chatModels.contains { $0.id == key }
		}
		backendLogos.removeValue(forKey: id)
		// A vendor that's off has no failure to report — otherwise switching it
		// off would leave its error row on screen with no rows to explain.
		discoveryErrors.removeValue(forKey: id)
		catalogDidChange()
		discoveryGeneration &+= 1
	}

	// MARK: - Vendors

	/// Whether a vendor's switch in the Models pane is on. The default is
	/// registered in `Defaults`, so this reads the same value the pane binds to.
	nonisolated func isEnabled(_ vendor: ModelVendor) -> Bool {
		UserDefaults.standard.bool(forKey: vendor.defaultsKey)
	}

	/// Bring the registered backends in line with the vendor switches, then
	/// rediscover. Registration is the only gate that matters — an unregistered
	/// backend vends nothing, so a vendor that's off can't reach the picker.
	func applyVendorSettings() async {
		for vendor in ModelVendor.allCases {
			if isEnabled(vendor), let backend = vendor.backend() {
				register(backend)
			} else {
				unregister(vendor.backendID)
			}
		}
		await refresh()
	}

	func setVendor(_ vendor: ModelVendor, enabled: Bool) async {
		UserDefaults.standard.set(enabled, forKey: vendor.defaultsKey)
		await applyVendorSettings()
	}

	func models(from vendor: ModelVendor) -> [GenerativeChatModel] {
		let backendID = vendor.backendID
		return chatModels.filter { modelBackend[$0.id] == backendID }
	}

	// MARK: - Model switches

	/// The catalog minus the models switched off in the Models pane — what every
	/// picker offers. The Models pane itself reads `chatModels`, being the one
	/// place a switched-off model still has to be visible to be switched back on.
	var enabledChatModels: [GenerativeChatModel] {
		chatModels.filter { isEnabled($0) }
	}

	func isEnabled(_ model: GenerativeChatModel) -> Bool {
		isEnabled(model.id)
	}

	/// Whether a model is on offer.
	///
	/// Only the vendor says which models exist and which of them it has since
	/// replaced, so an untouched switch takes its position from that rather than
	/// from a list kept here: a model the vendor still serves but has superseded
	/// starts off, everything else starts on. Which way that falls can change
	/// under a model — the day a vendor ships the next Sonnet, the current one
	/// becomes an old one — and it should, for anyone who never took a view.
	/// Setting the switch is what pins it against the catalog moving.
	func isEnabled(_ id: GenerativeChatModel.ID) -> Bool {
		modelOverrides[id] ?? !supersededModelIDs.contains(id)
	}

	func setModel(_ model: GenerativeChatModel, enabled: Bool) {
		UserDefaults.standard.set(enabled, forKey: Defaults.Key.modelEnabled(model.id))
		modelOverrides[model.id] = enabled
	}

	/// Take the derived state that hangs off the catalog and recompute it from
	/// the catalog as it now stands. Called wherever `chatModels` is assigned.
	private func catalogDidChange() {
		supersededModelIDs = ModelRelease.supersededIDs(in: chatModels)
		modelOverrides = chatModels.reduce(into: [:]) { overrides, model in
			let key = Defaults.Key.modelEnabled(model.id)
			if let stored = UserDefaults.standard.object(forKey: key) as? Bool {
				overrides[model.id] = stored
			}
		}
	}

	// MARK: - Discovery

	/// The run currently discovering models, if any.
	///
	/// Discovery is a network round trip per backend now, not a return of
	/// constants, so two refreshes overlap easily — four call sites fire it,
	/// including every app activation. Two overlapping runs both commit, last
	/// writer wins, and the loser can be the newer one: a slow *failing* run
	/// would erase the catalog a fast successful one had just installed.
	@ObservationIgnored
	private var discoveryTask: Task<Void, Never>?

	/// Bumped whenever the set of registered backends changes. A run that
	/// started under a different set is answering a question nobody is asking
	/// any more, so it stamps itself at entry and drops its own result rather
	/// than committing it — the same discard-on-stale rule the probes use.
	@ObservationIgnored
	private var discoveryGeneration = 0

	/// The generation the in-flight run was started under.
	@ObservationIgnored
	private var discoveryTaskGeneration = 0

	func refresh(reprobing: Bool = false) async {
		// A plain refresh asks exactly the question a run in flight is already
		// answering, so it joins that one instead of racing it — but only if
		// that run is still answering the *current* question. A vendor toggled
		// on mid-flight bumps the generation, which means the run in flight is
		// already condemned to discard its result; joining it would return
		// having discovered nothing for the vendor just switched on.
		if !reprobing, let inFlight = discoveryTask, discoveryTaskGeneration == discoveryGeneration {
			await inFlight.value
			return
		}

		// A reprobing refresh has different preconditions — a key was just
		// added or removed — so it has to actually run. It still queues behind
		// whatever is in flight rather than interleaving with it.
		let previous = discoveryTask
		let task = Task { @MainActor [weak self] in
			await previous?.value
			await self?.performRefresh(reprobing: reprobing)
		}
		discoveryTask = task
		discoveryTaskGeneration = discoveryGeneration
		await task.value
		if discoveryTask == task { discoveryTask = nil }
	}

	private func performRefresh(reprobing: Bool) async {
		activeRefreshes += 1

		defer { activeRefreshes -= 1 }

		if reprobing { invalidateProbes() }

		let generation = discoveryGeneration

		var models: [GenerativeChatModel] = []
		var mapping: [GenerativeChatModel.ID: BackendID] = [:]
		var failures: [BackendID: String] = [:]

		await withTaskGroup(of: (BackendID, Result<[GenerativeChatModel], any Error>).self) { group in
			for (backendID, backend) in backends {
				group.addTask {
					do {
						return (backendID, .success(try await backend.availableModels()))
					} catch {
						return (backendID, .failure(error))
					}
				}
			}
			for await (backendID, outcome) in group {
				switch outcome {
				case .success(let vended):
					models.append(contentsOf: vended)
					for m in vended { mapping[m.id] = backendID }
				case .failure(let error):
					// "We couldn't ask" and "there's nothing to serve" produce
					// the same empty list, and only one of them is the user's
					// problem to act on. The rows still go, but the reason goes
					// on screen with them.
					failures[backendID] = Self.reason(for: error)
				}
			}
		}

		guard generation == discoveryGeneration else { return }

		chatModels = models
		modelBackend = mapping
		discoveryErrors = failures
		catalogDidChange()

		var newCaps: [GenerativeChatModel.ID: ModelCapabilities] = [:]
		await withTaskGroup(of: (GenerativeChatModel.ID, ModelCapabilities).self) { group in
			for model in models {
				if let backendID = mapping[model.id], let backend = backends[backendID] {
					group.addTask {
						let live = await backend.capabilities(of: model)
						let combined = ModelCapabilities(
							availabilityState: live.availabilityState,
							dataResidency: model.dataResidency,
							contextWindowTokens: model.contextWindowTokens,
							supportedLanguages: live.supportedLanguages,
							supportsImageInput: live.supportsImageInput
						)
						return (model.id, combined)
					}
				}
			}
			for await (id, caps) in group {
				newCaps[id] = caps
			}
		}

		let validIDs = Set(models.map { $0.id })
		var merged = newCaps.filter { validIDs.contains($0.key) }

		// Carry each model's last probe answer across the rebuild, but only
		// while it's still fresh. A live answer is the last thing anything
		// actually observed and dropping it would blink every light yellow on
		// every activation — an aged-out one is a claim nothing stands behind.
		//
		// Expiring one bumps the probe generation, and that bump is the only
		// thing that re-verifies a metered model at all. This runs on every
		// app activation while nothing else re-probes a vendor or Private
		// Cloud model, so without it a light that went green once stayed green
		// on a key revoked hours later, and one transient failure pinned a
		// light red for the rest of the session. The bump re-fires the
		// on-screen light's task, which re-probes exactly the model the user
		// is being shown a claim about — and no others.
		probeResults = probeResults.filter { validIDs.contains($0.key) }
		var expired = false
		for (id, result) in probeResults {
			guard let model = models.first(where: { $0.id == id }) else { continue }
			if isFresh(result, for: model) {
				merged[id]?.connection = result.state
			} else {
				probeResults.removeValue(forKey: id)
				expired = true
			}
		}
		guard generation == discoveryGeneration else { return }

		capabilities = merged
		if expired { probeGeneration &+= 1 }

		for model in models where model.dataResidency == .onDevice {
			Task { await probeConnection(for: model) }
		}
	}

	/// User-facing text for a discovery failure. Backends describe their own
	/// failures — the view layer shouldn't be assembling sentences out of
	/// status codes.
	private static func reason(for error: any Error) -> String {
		(error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
	}

	func discoveryError(for vendor: ModelVendor) -> String? {
		discoveryErrors[vendor.backendID]
	}

	// MARK: - Connection Probes

	private struct ProbeResult {
		var state: ConnectionState
		var at: Date
	}

	@ObservationIgnored
	private var probeResults: [GenerativeChatModel.ID: ProbeResult] = [:]

	/// An in-flight probe, stamped with the generation it was started under.
	///
	/// The stamp is what makes a verdict discardable. A probe answers "does
	/// this work?" for one specific set of preconditions — this key, this
	/// network path — and once those change, the answer coming back is about a
	/// world that no longer exists. Without the stamp, a probe issued against
	/// a key the user has since replaced commits its verdict as the current
	/// one and pins the light on it.
	private struct InFlightProbe {
		var task: Task<ConnectionState, Never>
		var generation: Int
	}

	@ObservationIgnored
	private var probesInFlight: [GenerativeChatModel.ID: InFlightProbe] = [:]

	private static func probeLifetime(for residency: DataResidency) -> TimeInterval {
		residency == .onDevice ? 5 * 60 : 30 * 60
	}

	private static let failedProbeLifetime: TimeInterval = 60

	private func isFresh(_ result: ProbeResult, for model: GenerativeChatModel) -> Bool {
		let lifetime = result.state == .verified
			? Self.probeLifetime(for: model.dataResidency)
			: Self.failedProbeLifetime
		return Date().timeIntervalSince(result.at) < lifetime
	}

	@discardableResult
	private func probeConnection(for model: GenerativeChatModel) async -> ConnectionState {
		guard let backendID = modelBackend[model.id], let backend = backends[backendID] else {
			return .unverified
		}

		guard capabilities(of: model).availabilityState == .available else {
			probeResults.removeValue(forKey: model.id)
			setConnection(.unverified, for: model.id)
			return .unverified
		}

		if let cached = probeResults[model.id], isFresh(cached, for: model) {
			setConnection(cached.state, for: model.id)
			return cached.state
		}

		// Only join a probe started under the preconditions still in force.
		// Joining an older one hands back an answer about the previous key or
		// the previous network path, and skips publishing `.checking` — so the
		// light reads "checking" while nothing is actually checking.
		if let running = probesInFlight[model.id], running.generation == probeGeneration {
			return await running.task.value
		}

		setConnection(.checking, for: model.id)

		let generation = probeGeneration
		let task = Task { await backend.verifyConnection(to: model) }
		probesInFlight[model.id] = InFlightProbe(task: task, generation: generation)
		let outcome = await task.value

		// Retire the entry whatever the verdict, but only *commit* one still
		// computed under the current preconditions. The identity check keeps a
		// late resumption from evicting a newer probe that has already taken
		// this slot.
		if probesInFlight[model.id]?.task == task {
			probesInFlight.removeValue(forKey: model.id)
		}
		guard generation == probeGeneration else { return outcome }

		probeResults[model.id] = ProbeResult(state: outcome, at: Date())
		setConnection(outcome, for: model.id)
		return outcome
	}

	/// Abandon every probe in flight.
	///
	/// Cancellation is the courtesy half — it releases a request that's about
	/// to stall out a URLSession timeout on a route that just disappeared.
	/// The correctness half is the generation bump each caller pairs this
	/// with: a backend that doesn't observe cancellation still returns, and
	/// what stops that answer from landing is the stamp, not the cancel.
	private func abandonProbesInFlight() {
		for probe in probesInFlight.values {
			probe.task.cancel()
		}
		probesInFlight.removeAll()
	}

	private func setConnection(_ state: ConnectionState, for id: GenerativeChatModel.ID) {
		guard var caps = capabilities[id], caps.connection != state else { return }
		caps.connection = state
		capabilities[id] = caps
	}

	/// A new chat was just opened on this model; make its first send cheap.
	///
	/// For a vendor model the useful warmth is all client-side — the vendor
	/// holds no connection and nothing server-side warms ahead of a real send —
	/// so this re-runs the free key check, which re-validates the key and
	/// leaves URLSession holding a warm TLS connection while the user types.
	/// The cached verdict is dropped first: warmth is the point, and a cached
	/// answer makes no request.
	///
	/// Anthropic only, for now: its probe is a free authenticated GET, while
	/// the OpenAI-compatible backends still verify with a billed inference —
	/// forcing one of those on every ⌘N would spend tokens on nothing.
	func prewarm(_ model: GenerativeChatModel) {
		guard modelBackend[model.id] == .anthropic else { return }
		probeResults.removeValue(forKey: model.id)
		Task { await probeConnection(for: model) }
	}

	func invalidateProbes() {
		// Bumped first, so anything already on the wire is stamped stale
		// before it can resume and commit.
		probeGeneration &+= 1
		abandonProbesInFlight()
		probeResults.removeAll()
		for id in capabilities.keys {
			setConnection(.unverified, for: id)
		}
	}

	private func networkPathChanged(online: Bool) {
		let networked = chatModels.filter { $0.dataResidency != .onDevice }
		guard !networked.isEmpty else { return }

		probeGeneration &+= 1
		// A probe caught mid-request by the path vanishing doesn't fail fast —
		// it stalls until the vendor's request timeout, then reports a failure
		// about a network that may well be back by then.
		abandonProbesInFlight()

		for model in networked {
			probeResults.removeValue(forKey: model.id)
			setConnection(online ? .unverified : .offline, for: model.id)
		}
	}

	// MARK: - Resolution (persistence → model)

	func model(withID id: GenerativeChatModel.ID?) -> GenerativeChatModel? {
		guard let id else { return nil }
		return chatModels.first { $0.id == id }
	}

	func logoName(for modelID: GenerativeChatModel.ID?) -> String? {
		guard let modelID, let backendID = modelBackend[modelID] else { return nil }
		return backendLogos[backendID]
	}

	/// Prefers what's on offer, but a catalog switched off entirely is still a
	/// catalog — returning nil there would say "no model exists" when what
	/// happened is that none of them are being offered.
	var fallbackModel: GenerativeChatModel? {
		let offered = enabledChatModels
		return offered.first { $0.dataResidency == .onDevice }
			?? offered.first
			?? chatModels.first { $0.dataResidency == .onDevice }
			?? chatModels.first
	}

	// MARK: - Capabilities

	func capabilities(of model: GenerativeChatModel) -> ModelCapabilities {
		capabilities[model.id] ?? .none
	}

	func refreshCapabilities(for model: GenerativeChatModel) async {
		guard let backendID = modelBackend[model.id], let backend = backends[backendID] else { return }
		let live = await backend.capabilities(of: model)
		capabilities[model.id] = ModelCapabilities(
			availabilityState: live.availabilityState,
			dataResidency: model.dataResidency,
			contextWindowTokens: model.contextWindowTokens,
			supportedLanguages: live.supportedLanguages,
			supportsImageInput: live.supportsImageInput,
			connection: capabilities[model.id]?.connection ?? .unverified
		)
		await probeConnection(for: model)
	}

	// MARK: - Chat (the one call the send button makes)

	func reply(
		to turns: [ChatTurn],
		using model: GenerativeChatModel,
		options: ChatOptions = .default
	) -> AsyncThrowingStream<ReplyEvent, Error> {
		guard let backendID = modelBackend[model.id], let backend = backends[backendID] else {
			let unknownID = modelBackend[model.id] ?? .none
			return AsyncThrowingStream { continuation in
				continuation.finish(throwing: ModelManagerError.unknownBackend(unknownID))
			}
		}
		if let cap = capabilities[model.id], cap.availabilityState != .available {
			return AsyncThrowingStream { continuation in
				continuation.finish(throwing: ModelManagerError.modelUnavailable(model.id))
			}
		}
		if let cap = capabilities[model.id], !cap.supportsImageInput,
		   turns.contains(where: { !$0.images.isEmpty }) {
			return AsyncThrowingStream { continuation in
				continuation.finish(
					throwing: ModelManagerError.imagesUnsupported(model.displayName)
				)
			}
		}
		return backend.reply(to: turns, model: model, options: options)
	}
}

// MARK: - Errors

enum ModelManagerError: Error {
	case unknownBackend(BackendID)
	case noModelSelected
	case modelUnavailable(GenerativeChatModel.ID)
	case imagesUnsupported(String)
}

extension ModelManagerError {

	/// A persisted id is the only handle left once a model leaves the catalog,
	/// and it's a namespaced key, not a name. Strip the namespace so an alert
	/// says "claude-opus-5" rather than "vendor.anthropic.claude-opus-5".
	static func readable(_ id: GenerativeChatModel.ID) -> String {
		// Vendor ids are all "vendor.<vendor>.<model>" — Anthropic's and the
		// OpenAI-dialect family's alike — so strip the two namespace segments
		// rather than checking each vendor's prefix.
		if id.hasPrefix("vendor."),
		   let modelStart = id.dropFirst("vendor.".count).firstIndex(of: ".") {
			return String(id[id.index(after: modelStart)...])
		}
		return id
	}
}

extension ModelManagerError: LocalizedError {
	var errorDescription: String? {
		switch self {
		case .unknownBackend(let id):
			"No backend registered for \"\(id.rawValue)\"."
		case .noModelSelected:
			"No model is available to reply."
		case .modelUnavailable(let id):
			"\(ModelManagerError.readable(id)) isn't available right now. "
				+ "Pick another model for this chat, or check Settings."
		case .imagesUnsupported(let name):
			"\(name) can't read images. Pick a model that can, then send again."
		}
	}
}
