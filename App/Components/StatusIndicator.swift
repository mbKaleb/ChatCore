//
//  ModelStatusLight.swift
//  ChatCore
//
//	Created by Kaleb Franken on 6/15/26.
//

import SwiftUI
import AppKit

@available(macOS 27.0, *)
struct StatusIndicator: View {
	@Environment(ModelManager.self) private var manager
	@State private var showInfo = false
	@State private var dismissTask: Task<Void, Never>?

	let model: GenerativeChatModel

	private var capabilities: ModelCapabilities {
		manager.capabilities(of: model)
	}

	private struct RefreshKey: Equatable {
		var modelID: GenerativeChatModel.ID
		var generation: Int
	}

	private var status: StatusLevel {
		if capabilities.availabilityState == .unknown && manager.isRefreshing {
			return .trying
		}
		return capabilities.statusLevel
	}

	private var label: String {
		switch capabilities.availabilityState {
		case .available:
			switch capabilities.connection {
			case .unverified, .checking:
				return capabilities.dataResidency == .onDevice
					? "Warming up the model…"
					: "Checking the connection…"
			case .verified:
				return status == .cloud ? "Connected (public cloud)" : "Model ready (secure)"
			case .offline:
				return "No internet connection"
			case .unauthorized:
				return "API key was rejected"
			case .failed:
				return capabilities.dataResidency == .onDevice
					? "The model didn't respond"
					: "Couldn't reach the model"
			}
		case .deviceNotEligible:
			return "Device not eligible for Apple Intelligence"
		case .disabled:
			return capabilities.dataResidency == .cloud
				? "No API key configured"
				: "Apple Intelligence not enabled in System Settings"
		case .downloading:
			return "Loading / connecting…"
		case .quotaExceeded:
			return "Daily usage limit reached"
		case .unknown:
			return "Model unavailable"
		}
	}

	var body: some View {
		let _ = Self.printChanges()
		GlowDot(color: status.color, alive: status.isLive)
			.frame(width: 24, height: 24)
			.padding(6)
			.help(label)
			.onHover { hovering in
				dismissTask?.cancel()
				if hovering {
					showInfo = true
				} else {
					dismissTask = Task {
						try? await Task.sleep(for: .milliseconds(150))
						if !Task.isCancelled { showInfo = false }
					}
				}
			}
			.popover(isPresented: $showInfo, arrowEdge: .bottom) {
				ModelInfoView(model: model, capabilities: capabilities)
					.padding(14)
					.frame(width: 230)
			}
			.onTapGesture {}
			.task(id: RefreshKey(modelID: model.id, generation: manager.probeGeneration),
				  priority: .background) {
				await manager.refreshCapabilities(for: model)
			}
	}
}

@available(macOS 26.0, *)
private struct ModelInfoView: View {
	let model: GenerativeChatModel
	let capabilities: ModelCapabilities

	private var statusText: String {
		switch capabilities.availabilityState {
		case .available:
			switch capabilities.connection {
			case .unverified, .checking:
				return capabilities.dataResidency == .onDevice ? "Warming up…" : "Checking…"
			case .verified:     return "Ready"
			case .offline:      return "Offline"
			case .unauthorized: return "Key rejected"
			case .failed:       return "Unreachable"
			}
		case .downloading: return "Downloading…"
		case .disabled: return capabilities.dataResidency == .cloud ? "No API key" : "Disabled in Settings"
		case .deviceNotEligible: return "Not supported"
		case .quotaExceeded: return "Limit reached"
		case .unknown: return "Unavailable"
		}
	}

	private var usageText: String {
		switch capabilities.dataResidency {
		case .onDevice:     "Unlimited"
		case .privateCloud: "Daily limit (iCloud)"
		case .cloud:        "Provider-metered"
		case .unknown:      "—"
		}
	}

	var body: some View {
		let _ = Self.printChanges()
		VStack(alignment: .leading, spacing: 8) {
			Text("MODEL")
				.font(.caption2)
				.foregroundStyle(.secondary)

			HStack(spacing: 6) {
				ModelIconView(icon: model.icon)
				Text(model.displayName)
					.fontWeight(.semibold)
			}

			Divider()

			LabeledContent("Status", value: statusText)
			LabeledContent("Data residency", value: capabilities.dataResidency.display)
			LabeledContent("Usage", value: usageText)
			LabeledContent("Weights", value: model.weights.display)
			if let contextWindow = capabilities.contextWindowTokens {
				LabeledContent("Context", value: "\(contextWindow.formatted()) tokens")
			}
			if let languages = capabilities.supportedLanguages {
				LabeledContent("Languages", value: "\(languages)")
			}

			Divider()

			Text(model.id)
				.font(.caption2)
				.foregroundStyle(.tertiary)
				.textSelection(.enabled)
		}
		.font(.callout)
	}
}

private struct GlowDot: View, Animatable {
	var color: Color
	let alive: Bool

	var animatableData: RGBAComponents {
		get { RGBAComponents(color) }
		set { color = newValue.color }
	}

	var body: some View {
		let _ = Self.printChanges()
		TimelineView(.animation(minimumInterval: 1.0 / 5.0, paused: !alive)) { tl in
			let phase = alive ? 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 1.8) : 0
			orb(phase: phase)
		}
		.animation(.easeInOut(duration: 0.35), value: color)
		.animation(.easeInOut(duration: 0.35), value: alive)
	}

	private func orb(phase: Double) -> some View {
		let glow = 4 + phase * 9
		let haloOpacity = 0.45 + phase * 0.40

		return Circle()
			.fill(
				RadialGradient(
					colors: [color.opacity(0.95), color],
					center: .center,
					startRadius: 0,
					endRadius: 5
				)
			)
			.frame(width: 4, height: 4)
			.overlay(
				Circle()
					.fill(.white.opacity(0.1))
					.frame(width: 2.5, height: 2.5)
					.offset(x: -1.5, y: -1.5)
					.blur(radius: 0.5)
			)
			.shadow(color: color.opacity(haloOpacity + 0.3), radius: glow)
			.shadow(color: color.opacity(haloOpacity), radius: glow * 2)
			.drawingGroup()
	}
}

private struct RGBAComponents: Equatable, VectorArithmetic {
	var r, g, b, a: Double

	init(_ color: Color) {
		let resolved = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
		r = Double(resolved.redComponent)
		g = Double(resolved.greenComponent)
		b = Double(resolved.blueComponent)
		a = Double(resolved.alphaComponent)
	}

	private init(r: Double, g: Double, b: Double, a: Double) {
		self.r = r; self.g = g; self.b = b; self.a = a
	}

	var color: Color { Color(red: r, green: g, blue: b, opacity: a) }

	static var zero: RGBAComponents { RGBAComponents(r: 0, g: 0, b: 0, a: 0) }

	static func + (lhs: RGBAComponents, rhs: RGBAComponents) -> RGBAComponents {
		RGBAComponents(r: lhs.r + rhs.r, g: lhs.g + rhs.g, b: lhs.b + rhs.b, a: lhs.a + rhs.a)
	}

	static func - (lhs: RGBAComponents, rhs: RGBAComponents) -> RGBAComponents {
		RGBAComponents(r: lhs.r - rhs.r, g: lhs.g - rhs.g, b: lhs.b - rhs.b, a: lhs.a - rhs.a)
	}

	mutating func scale(by rhs: Double) {
		r *= rhs; g *= rhs; b *= rhs; a *= rhs
	}

	var magnitudeSquared: Double { r * r + g * g + b * b + a * a }
}
