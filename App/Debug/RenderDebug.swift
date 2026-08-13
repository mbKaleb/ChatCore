//
//  RenderDebug.swift
//  ChatCore
//

import SwiftUI
import Foundation

enum RenderDebug {
	static let enabled = ProcessInfo.processInfo.arguments.contains("-renderDebug")
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
