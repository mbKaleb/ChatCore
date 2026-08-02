//
//  RenderDebug.swift
//  ChatCore
//

import SwiftUI
import Foundation

enum RenderDebug {
	static let enabled = ProcessInfo.processInfo.arguments.contains("-renderDebug")

	static let listMetrics = ProcessInfo.processInfo.arguments.contains("-listMetrics")

	/// Seeds the `transcriptRenderer` default.
	///
	/// The compiled transcript is the default path; `-renderer <id>` starts on
	/// another one without going through Settings, which is what you want when
	/// comparing two of them or when one is the suspect. `-legacyRenderer` is the
	/// older spelling of `-renderer virtualized`.
	///
	/// This only seeds the registration domain, so a renderer picked in Settings
	/// still wins. To override one that was picked, name the key itself —
	/// `-transcriptRenderer list` — which lands in the argument domain and beats
	/// everything.
	static let defaultRenderer: TranscriptRenderer = {
		let arguments = ProcessInfo.processInfo.arguments
		if
			let flag = arguments.firstIndex(of: "-renderer"),
			let named = arguments.indices.contains(flag + 1)
				? TranscriptRenderer(rawValue: arguments[flag + 1])
				: nil
		{
			return named
		}
		if arguments.contains("-legacyRenderer") { return .virtualized }
		return .default
	}()
}

extension View {
	@inline(__always)
	static func printChanges() {
		#if DEBUG
		if RenderDebug.enabled {
			Self._printChanges()
		}
		#endif
	}
}
