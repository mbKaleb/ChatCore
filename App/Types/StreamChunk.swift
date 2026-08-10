//
//  StreamChunk.swift
//  ChatCore
//

enum StreamingMode: String, CaseIterable, Identifiable {
	case snapshot
	case token

	var id: String { rawValue }

	var displayName: String {
		switch self {
		case .snapshot: "Snapshot"
		case .token:    "Per token"
		}
	}

	var summary: String {
		switch self {
		case .snapshot: "Formatted while streaming. No arrival animation."
		case .token:    "New text fades in. Formatting applies when the reply finishes."
		}
	}
}

/// One paced piece of a reply in flight, and the moment it is due on screen.
struct StreamChunk: Identifiable, Equatable, Sendable {
	let id: Int
	let text: String

	/// Often a little ahead of the moment the piece was recorded: arrivals get
	/// re-spread so a decode batch reads as words rather than a block.
	///
	/// Monotonic on purpose. A `Date` is a wall clock and can step backwards
	/// under an NTP correction or a manual change, which turns `now - arrival`
	/// negative mid-fade and re-hides text that was already on screen. This is
	/// only ever subtracted from another instant, and `endGeneration` drops it
	/// with the rest of the live state, so nothing wants it to be a date.
	let arrival: ContinuousClock.Instant
}
