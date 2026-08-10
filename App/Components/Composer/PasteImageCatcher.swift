//
//  PasteImageCatcher.swift
//  ChatCore
//

import AppKit
import SwiftUI

struct PasteImageCatcher: NSViewRepresentable {

	var onPaste: (NSPasteboard) -> Bool

	func makeNSView(context: Context) -> MonitorView {
		let view = MonitorView()
		view.onPaste = onPaste
		return view
	}

	func updateNSView(_ nsView: MonitorView, context: Context) {
		nsView.onPaste = onPaste
	}

	static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
		nsView.stopMonitoring()
	}

	final class MonitorView: NSView {
		var onPaste: ((NSPasteboard) -> Bool)?
		private var monitor: Any?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window == nil { stopMonitoring() } else { startMonitoring() }
		}

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		private func startMonitoring() {
			guard monitor == nil else { return }
			monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				guard let self, self.shouldHandle(event) else { return event }
				return self.onPaste?(.general) == true ? nil : event
			}
		}

		func stopMonitoring() {
			guard let monitor else { return }
			NSEvent.removeMonitor(monitor)
			self.monitor = nil
		}

		private func shouldHandle(_ event: NSEvent) -> Bool {
			let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			guard modifiers == .command,
				  event.charactersIgnoringModifiers?.lowercased() == "v"
			else { return false }
			guard let window, event.window === window else { return false }
			return true
		}
	}
}
