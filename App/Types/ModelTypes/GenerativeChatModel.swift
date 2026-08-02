//
//  GenerativeChatModel.swift
//  ChatCore
//

import Foundation
import SwiftUI

// MARK: - Model Descriptor

nonisolated struct GenerativeChatModel: Codable, Hashable, Identifiable, Sendable {

	var id: String

	var displayName: String
	var icon: ModelIcon

	var weights: ModelWeights

	var dataResidency: DataResidency
	var contextWindowTokens: Int?

}

// MARK: - Model Icon

/// How a model draws itself. Vendors that ship their own mark get an asset;
/// only Apple's models have an SF Symbol that actually means something, so a
/// bare symbol name is no longer the shape a backend can hand back.
nonisolated enum ModelIcon: Codable, Hashable, Sendable {
	case symbol(String)
	case asset(String)
}

struct ModelIconView: View {
	var icon: ModelIcon
	var size: CGFloat = 16

	var body: some View {
		switch icon {
		case .symbol(let name):
			Image(systemName: name)
				.font(.system(size: size))
				.frame(width: size, height: size)
		case .asset(let name):
			assetImage(name)
				.resizable()
				.scaledToFit()
				.frame(width: size, height: size)
		}
	}

	/// Asset icons have to carry their size in the image itself, not just in a
	/// `.frame`. A `Picker` row that becomes the collapsed menu label is handed
	/// to AppKit, which takes the `NSImage` and draws it at its natural size —
	/// the SwiftUI sizing modifiers around it are gone by then, so a full-size
	/// vendor mark renders enormous. Stamping the size onto the `NSImage`
	/// survives that trip; elsewhere the modifiers above still do the work.
	private func assetImage(_ name: String) -> Image {
		#if os(macOS)
		if let image = NSImage(named: name) {
			let sized = image.copy() as! NSImage
			sized.size = NSSize(width: size, height: size)
			return Image(nsImage: sized)
		}
		#endif
		return Image(name)
	}
}

// MARK: - Backend Identity

nonisolated struct BackendID: RawRepresentable, Codable, Hashable, Sendable {
	var rawValue: String

	static let apple     = BackendID(rawValue: "apple")
	static let anthropic = BackendID(rawValue: "anthropic")
	static let none      = BackendID(rawValue: "")
}

// MARK: - Well-Known Models

nonisolated extension GenerativeChatModel {

	static let onDevice = GenerativeChatModel(
		id: "apple.on-device",
		displayName: "On Device",
		icon: .symbol("apple.intelligence"),
		weights: .unknown,
		dataResidency: .onDevice,
		contextWindowTokens: 4_096
	)

	static let privateCloud = GenerativeChatModel(
		id: "apple.private-cloud",
		displayName: "Private Cloud",
		icon: .symbol("apple.intelligence"),
		weights: .closed,
		dataResidency: .privateCloud,
		contextWindowTokens: 32_768
	)

	static let none = GenerativeChatModel(
		id: "none",
		displayName: " ",
		icon: .symbol("questionmark.circle"),
		weights: .unknown,
		dataResidency: .unknown,
		contextWindowTokens: nil
	)

	var isAnthropicModel: Bool { id.hasPrefix("vendor.anthropic.") }

}

// MARK: - Supporting Enums

nonisolated enum ModelWeights: String, Codable, Sendable {
	case open
	case closed
	case mutable
	case unknown

	var display: String {
		switch self {
		case .open:         "Open"
		case .closed:       "Closed"
		case .mutable:		"Mutable"
		case .unknown:      "Unknown"
		}
	}
}

nonisolated enum DataResidency: String, Codable, Sendable {
	case onDevice
	case privateCloud
	case cloud
	case unknown

	var display: String {
			switch self {
			case .onDevice:     "On-Device"
			case .privateCloud: "Private Cloud"
			case .cloud:        "Cloud"
			case .unknown:      "Unknown"
			}
		}
}

nonisolated enum ConnectionState: String, Codable, Sendable {

	case unverified

	case checking

	case verified

	case offline

	case unauthorized

	case failed

	var isPending: Bool { self == .unverified || self == .checking }
}

nonisolated extension ConnectionState {

	static func diagnosing(_ error: any Error) -> ConnectionState {
		guard let urlError = error as? URLError else { return .failed }
		switch urlError.code {
		case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
			 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
			 .internationalRoamingOff:
			return .offline
		case .userAuthenticationRequired:
			return .unauthorized
		default:
			return .failed
		}
	}
}

nonisolated enum AvailabilityState: String, Codable, Equatable, Sendable {
	case available
	case downloading
	case disabled
	case deviceNotEligible
	case quotaExceeded
	case unknown

	var display: String {
			switch self {
			case .available:          "Available"
			case .downloading:        "Downloading"
			case .disabled:           "Disabled"
			case .deviceNotEligible:  "Device Not Eligible"
			case .quotaExceeded:      "Usage Limit Reached"
			case .unknown:            "Unknown"
			}
		}
}

// MARK: - Capabilities

nonisolated struct ModelCapabilities: Codable, Sendable {
	var availabilityState: AvailabilityState
	var dataResidency: DataResidency
	var contextWindowTokens: Int?
	var supportedLanguages: Int?
	var supportsImageInput: Bool = true
	var connection: ConnectionState = .unverified
}

nonisolated extension ModelCapabilities {

	static let none = ModelCapabilities(
		availabilityState: .unknown,
		dataResidency: .unknown,
		contextWindowTokens: nil,
		supportedLanguages: nil
	)

	var statusLevel: StatusLevel {
		switch availabilityState {
		case .disabled, .deviceNotEligible, .quotaExceeded, .unknown:
			return .failed
		case .downloading:
			return .trying
		case .available:
			break
		}

		switch connection {
		case .unverified, .checking:
			return .trying
		case .offline, .unauthorized, .failed:
			return .failed
		case .verified:
			switch dataResidency {
			case .onDevice, .privateCloud: return .secure
			case .cloud:                   return .cloud
			case .unknown:                 return .failed
			}
		}
	}
}

// MARK: - Status Level

nonisolated enum StatusLevel: Int, Sendable {
	case failed = 0
	case trying = 1
	case secure = 2
	case cloud = 3

	var color: Color {
		switch self {
		case .failed: .red
		case .trying: .yellow
		case .secure: .blue
		case .cloud:  Color(red: 0, green: 0.8, blue: 0.15)
		}
	}

	var isLive: Bool { self == .secure || self == .cloud }
}
