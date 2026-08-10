//
//  ZoomProbe.swift
//  ChatCore
//

#if DEBUG

import AppKit

/// Reproduces the toolbar double-click headlessly: a double-click on the
/// titlebar/toolbar runs `zoom(_:)` (with the system's "double-click a
/// window's title bar to Zoom" setting), so this calls the same thing and
/// then watches the frame. One clean animation to the screen edge is zoom
/// working; an excursion to full size that comes back is something restoring
/// the old frame after AppKit already committed the new one.
///
/// `-zoomProbe` arms it. Runs from a terminal and terminates itself.
@MainActor
enum ZoomProbe {

	static var isRequested: Bool {
		ProcessInfo.processInfo.arguments.contains("-zoomProbe")
	}

	static func armIfRequested() {
		guard isRequested else { return }
		waitForWindow(attemptsLeft: 50)
	}

	private static func waitForWindow(attemptsLeft: Int) {
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
			guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else {
				if attemptsLeft > 0 {
					waitForWindow(attemptsLeft: attemptsLeft - 1)
				} else {
					emit("no visible window appeared; giving up")
					NSApp.terminate(nil)
				}
				return
			}

			for extra in NSApp.windows where extra !== window && extra.isVisible && !(extra is NSPanel) {
				extra.close()
			}

			NSApp.activate(ignoringOtherApps: true)
			window.makeKeyAndOrderFront(nil)

			// Start from a known, un-zoomed frame whatever the last run left.
			window.setFrame(NSRect(x: 200, y: 120, width: 900, height: 700), display: true)

			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
				let screen = window.screen ?? NSScreen.main
				emit("screen.visibleFrame=\(screen?.visibleFrame ?? .zero)")
				emit("window.frame(before)=\(window.frame)")
				emit("delegate=\(window.delegate.map { String(describing: type(of: $0)) } ?? "nil")")
				emit("isZoomed(before)=\(window.isZoomed)")

				// What AppKit will actually target: the delegate's answer to the
				// standard frame, if it has one.
				if let delegate = window.delegate, let screen,
				   delegate.responds(to: #selector(NSWindowDelegate.windowWillUseStandardFrame(_:defaultFrame:))) {
					let standard = delegate.windowWillUseStandardFrame!(window, defaultFrame: screen.visibleFrame)
					emit("delegate windowWillUseStandardFrame=\(standard)")
				} else {
					emit("delegate does not implement windowWillUseStandardFrame")
				}
				emit("contentMinSize=\(window.contentMinSize) contentMaxSize=\(window.contentMaxSize)")
				emit("minSize=\(window.minSize) maxSize=\(window.maxSize)")

				// Double-click on the titlebar/toolbar runs the system's
				// AppleActionOnDoubleClick — which defaults to Fill (window
				// tiling) since Sequoia, not Zoom. `zoom(nil)` held when tried
				// here, so drive the real path: a synthetic double-click routed
				// through `sendEvent` at a point in the toolbar strip.
				// Find a spot in the titlebar strip that isn't a toolbar item —
				// items swallow the double-click, the background forwards it.
				let y = window.frame.height - 14
				var chosen = NSPoint(x: window.frame.width * 0.6, y: y)
				if let frameView = window.contentView?.superview {
					for x in stride(from: CGFloat(80), to: window.frame.width - 80, by: 20) {
						let candidate = NSPoint(x: x, y: y)
						guard let hit = frameView.hitTest(candidate) else { continue }
						let name = NSStringFromClass(type(of: hit))
						if !name.contains("Item") && !name.contains("Button") {
							chosen = candidate
							emit("background point at x=\(x): \(name)")
							break
						}
					}
				}
				emit("double-clicking at window-relative \(chosen)")
				sendDoubleClick(to: window, at: chosen)
				emit("window.frame(immediately after)=\(window.frame) isZoomed=\(window.isZoomed)")

				sample(window, ticks: 120, every: 0.05)
			}
		}
	}

	/// Prints every distinct frame for 3 seconds, then a verdict.
	private static func sample(_ window: NSWindow, ticks: Int, every: Double) {
		var seen: [String] = []
		var frames: [NSRect] = []

		func tick(_ remaining: Int) {
			let elapsed = Double(ticks - remaining) * every
			let line = "frame=\(window.frame) isZoomed=\(window.isZoomed)"
			if seen.last != line {
				seen.append(line)
				frames.append(window.frame)
				emit("t=\(String(format: "%.2f", elapsed))s \(line)")
			}
			guard remaining > 0 else {
				let peak = frames.map(\.width).max() ?? 0
				let final = frames.last?.width ?? 0
				let bounced = peak > final + 1
				emit("verdict: distinct=\(seen.count) peakWidth=\(peak) finalWidth=\(final) \(bounced ? "BOUNCED BACK" : "held")")
				NSApp.terminate(nil)
				return
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + every) { tick(remaining - 1) }
		}
		tick(ticks)
	}

	private static func sendDoubleClick(to window: NSWindow, at point: NSPoint) {
		var eventNumber = 9000
		func mouse(_ type: NSEvent.EventType, clickCount: Int) -> NSEvent? {
			eventNumber += 1
			return NSEvent.mouseEvent(
				with: type, location: point, modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber, context: nil,
				eventNumber: eventNumber, clickCount: clickCount, pressure: 1
			)
		}
		if let view = window.contentView?.superview?.hitTest(point) {
			emit("hitTest at click point: \(type(of: view))")
		} else {
			emit("hitTest at click point: nil")
		}
		for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1),
		                      (.leftMouseDown, 2), (.leftMouseUp, 2)] {
			guard let event = mouse(type, clickCount: count) else { continue }
			window.sendEvent(event)
		}
	}

	private static func emit(_ message: String) {
		print("[ZoomProbe] \(message)")
	}
}

#endif
