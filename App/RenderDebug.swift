//
//  RenderDebug.swift
//  ChatCore
//

import SwiftUI
import Foundation

enum RenderDebug {
	static let enabled = false

	static let listMetrics = ProcessInfo.processInfo.arguments.contains("-listMetrics")
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
