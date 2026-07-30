//
//  StreamChunk.swift
//  ChatCore
//

import Foundation

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

struct StreamChunk: Identifiable, Equatable, Sendable {
	let id: Int
	let text: String
	let arrival: Date
}
