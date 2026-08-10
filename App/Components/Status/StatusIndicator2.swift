//
//  StatusIndicator2.swift
//  ChatCore
//

import SwiftUI

/// A 20×20 status light: a small dot that breathes while the model is live.
///
/// Everything is in the one view — no popover, no hover state, no animatable
/// color shim. The tooltip carries the detail the popover used to.
@available(macOS 27.0, *)
struct StatusIndicator2: View {
	@Environment(ModelManager.self) private var manager

	let model: GenerativeChatModel

	private var capabilities: ModelCapabilities {
		manager.capabilities(of: model)
	}

	private var status: StatusLevel {
		capabilities.availabilityState == .unknown && manager.isRefreshing
			? .trying
			: capabilities.statusLevel
	}

	var body: some View {
		Dot(color: status.color, alive: status.isLive)
			.frame(width: 20, height: 20)
			.help(tooltip)
			.task(id: model.id, priority: .background) {
				await manager.refreshCapabilities(for: model)
			}
	}

	private var tooltip: String {
		switch capabilities.availabilityState {
		case .available:
			switch capabilities.connection {
			case .unverified, .checking:
				capabilities.dataResidency == .onDevice ? "Warming up the model…" : "Verifying access…"
			case .verified:
				// A vendor light can't claim a live connection — the API is
				// stateless HTTPS and connects per send. Green means the key
				// and route checked out recently.
				status == .cloud ? "Ready (access verified)" : "Model ready (secure)"
			case .offline:      "No internet connection"
			case .unauthorized: "API key was rejected"
			case .failed:
				capabilities.dataResidency == .onDevice
					? "The model didn't respond"
					: "Couldn't reach the model"
			}
		case .deviceNotEligible: "Device not eligible for Apple Intelligence"
		case .disabled:
			capabilities.dataResidency == .cloud
				? "No API key configured"
				: "Apple Intelligence not enabled in System Settings"
		case .downloading:    "Loading / connecting…"
		case .quotaExceeded:  "Daily usage limit reached"
		case .unknown:        "Model unavailable"
		}
	}
}

/// A 4pt dot with a halo that pulses when `alive`.
@available(macOS 27.0, *)
private struct Dot: View {
	let color: Color
	let alive: Bool

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 5.0, paused: !alive)) { tl in
			let phase = alive
				? 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 1.8)
				: 0.0
			Circle()
				.fill(color)
				.frame(width: 4, height: 4)
				.shadow(color: color.opacity(0.75 + phase * 0.4), radius: 4 + phase * 9)
				.shadow(color: color.opacity(0.45 + phase * 0.4), radius: (4 + phase * 9) * 2)
		}
		.animation(.easeInOut(duration: 0.35), value: color)
		.animation(.easeInOut(duration: 0.35), value: alive)
	}
}

/// The light for a model that isn't in the catalog.
///
/// The alternative — substituting some other loaded model's descriptor — makes
/// the light publish a verified, on-device, secure claim about a model that
/// isn't there, which is the one thing this control must never do.
@available(macOS 27.0, *)
struct MissingModelIndicator2: View {
	let modelID: GenerativeChatModel.ID

	var body: some View {
		Dot(color: StatusLevel.failed.color, alive: false)
			.frame(width: 20, height: 20)
			.help("\(ModelManagerError.readable(modelID)) isn't available right now.")
	}
}
