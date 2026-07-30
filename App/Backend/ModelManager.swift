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

	private(set) var capabilities: [GenerativeChatModel.ID: ModelCapabilities] = [:]

	private(set) var isRefreshing = false

	private(set) var probeGeneration = 0

	private(set) var liveText: [Message.ID: String] = [:]

	@ObservationIgnored
	private var cancelHandlers: [Message.ID: @MainActor () -> Void] = [:]

	private(set) var liveChunks: [Message.ID: [StreamChunk]] = [:]

	private struct ChunkCursor { var text: String; var byteCount: Int }
	@ObservationIgnored
	private var chunkCursor: [Message.ID: ChunkCursor] = [:]

	func beginGeneration(for messageID: Message.ID) {
		liveText[messageID] = ""
		liveChunks[messageID] = []
		chunkCursor[messageID] = ChunkCursor(text: "", byteCount: 0)
	}

	func registerCancellation(for messageID: Message.ID, _ cancel: @escaping @MainActor () -> Void) {
		cancelHandlers[messageID] = cancel
	}

	func updateGeneration(_ messageID: Message.ID, text: String) {
		liveText[messageID] = text
	}

	func recordChunk(_ full: String, for messageID: Message.ID) {
		let cursor = chunkCursor[messageID] ?? ChunkCursor(text: "", byteCount: 0)
		guard full != cursor.text else { return }

		guard full.utf8.starts(with: cursor.text.utf8) else {
			chunkCursor[messageID] = ChunkCursor(text: full, byteCount: full.utf8.count)
			liveChunks[messageID] = [StreamChunk(id: 0, text: full, arrival: Date())]
			return
		}

		let delta = String(decoding: full.utf8.dropFirst(cursor.byteCount), as: UTF8.self)
		guard !delta.isEmpty else { return }
		chunkCursor[messageID] = ChunkCursor(text: full, byteCount: full.utf8.count)

		var chunks = liveChunks[messageID] ?? []
		chunks.append(StreamChunk(id: chunks.count, text: delta, arrival: Date()))
		liveChunks[messageID] = chunks
	}

	func cancelGeneration(for messageID: Message.ID) {
		cancelHandlers[messageID]?()
	}

	func isGenerating(_ messageID: Message.ID) -> Bool {
		liveText[messageID] != nil
	}

	func endGeneration(for messageID: Message.ID) {
		liveText.removeValue(forKey: messageID)
		liveChunks.removeValue(forKey: messageID)
		chunkCursor.removeValue(forKey: messageID)
		cancelHandlers.removeValue(forKey: messageID)
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

	// MARK: - Discovery

	func refresh(reprobing: Bool = false) async {
		isRefreshing = true

		defer { isRefreshing = false }

		if reprobing { invalidateProbes() }

		var models: [GenerativeChatModel] = []
		var mapping: [GenerativeChatModel.ID: BackendID] = [:]

		await withTaskGroup(of: (BackendID, [GenerativeChatModel]?).self) { group in
			for (backendID, backend) in backends {
				group.addTask {
					let vended = try? await backend.availableModels()
					return (backendID, vended)
				}
			}
			for await (backendID, vended) in group {
				if let vended {
					models.append(contentsOf: vended)
					for m in vended { mapping[m.id] = backendID }
				}
			}
		}

		chatModels = models
		modelBackend = mapping

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
		capabilities = merged
		if expired { probeGeneration &+= 1 }

		for model in models where model.dataResidency == .onDevice {
			Task { await probeConnection(for: model) }
		}
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

	var fallbackModel: GenerativeChatModel? {
		chatModels.first { $0.dataResidency == .onDevice } ?? chatModels.first
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
	) -> AsyncThrowingStream<String, Error> {
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

extension ModelManagerError: LocalizedError {
	var errorDescription: String? {
		switch self {
		case .unknownBackend(let id):
			"No backend registered for \"\(id.rawValue)\"."
		case .noModelSelected:
			"No model is available to reply."
		case .modelUnavailable(let id):
			"The model \"\(id)\" is not available right now."
		case .imagesUnsupported(let name):
			"\(name) can't read images. Pick a model that can, then send again."
		}
	}
}
