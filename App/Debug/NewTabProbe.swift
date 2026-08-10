//
//  NewTabProbe.swift
//  ChatCore
//

#if DEBUG

import AppKit

/// Handles the scene lends the probe for commands with no AppKit equivalent.
@MainActor
enum WindowProbeHooks {
	static var openNewWindow: (() -> Void)?
}

/// Answers the one thing `-tabBarProbe` can't: does ⌘T produce a *tab*?
///
/// `TabBarProbe` reaches for `addTabbedWindow` directly, which forces a tab by
/// construction — useful for styling the bar, useless for telling whether the
/// menu item does the same. This one runs the New Tab button's body verbatim
/// (a plain `sendAction`, not a SwiftUI command, so it is dispatchable from
/// here) and then reports what the window server actually did with it: how many
/// windows are up, how many of them share a tab group, and what each tab is
/// titled.
///
/// `-newTabProbe` arms it. Runs from a terminal and terminates itself.
@MainActor
enum NewTabProbe {

	static var isRequested: Bool {
		ProcessInfo.processInfo.arguments.contains("-newTabProbe")
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

			// AppKit restores the window layout of the previous launch, tab
			// grouping included — so an earlier probe run's leftovers would be
			// the starting state and "did a tab appear" stops being answerable.
			// One window in, one merge to look for.
			for extra in NSApp.windows where extra !== window && extra.isVisible && !(extra is NSPanel) {
				extra.close()
			}

			// `sendAction(to: nil)` walks the *key* window's responder chain, and
			// an app launched from a terminal may never have been activated — so
			// a dead ⌘T and an unfocused probe look identical unless the window
			// is made key first. This is the control, not decoration.
			NSApp.activate(ignoringOtherApps: true)
			window.makeKeyAndOrderFront(nil)

			DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
				report("before", window)
				emit("activated: isActive=\(NSApp.isActive) keyWindow=\(describe(NSApp.keyWindow)) mainWindow=\(describe(NSApp.mainWindow))")
				emit("responder chain answers newWindowForTab: = \(NSApp.target(forAction: #selector(NSWindow.newWindowForTab(_:))) != nil)")

				// The shipping command itself, not a copy of it — a paraphrase
				// here is how the last run came back green on a path nothing
				// ships.
				let delivered = NewTabIntent.open()
				emit("NewTabIntent.open() delivered=\(delivered)")

				// Watch the window the tab bar lands on, not the tab: a
				// transition and a fight both move, and the only thing that
				// tells them apart is whether the motion stops.
				sample(window, label: "geometry", ticks: 30, every: 0.1) {
					report("after ⌘T", NSApp.keyWindow ?? window)

					// The other half of the claim. Preferring tabs is a property
					// of the window, not of the command that opened it, so New
					// Window is the case that says whether ⌘⇧N got swallowed
					// along with it.
					emit("pressing New Window (hook=\(WindowProbeHooks.openNewWindow != nil))")
					WindowProbeHooks.openNewWindow?()

					DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
						report("after ⌘⇧N", NSApp.keyWindow ?? window)
						NSApp.terminate(nil)
					}
				}
			}
		}
	}

	private static func report(_ label: String, _ window: NSWindow) {
		let onscreen = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
		let group = window.tabGroup?.windows
		emit("\(label): visibleWindows=\(onscreen.count) tabGroupWindows=\(group?.count ?? 0) tabBarVisible=\(window.tabGroup?.isTabBarVisible ?? false)")
		emit("\(label): AppleWindowTabbingMode=\(UserDefaults.standard.string(forKey: "AppleWindowTabbingMode") ?? "unset (system default)")")
		emit("\(label): TabBarChrome stripChrome=\(TabBarChrome.Probe.updateCount) fullWalks=\(TabBarChrome.Probe.walkCount) stretches=\(TabBarChrome.Probe.stretchCount)")
		for (index, member) in onscreen.enumerated() {
			let title = member.title.isEmpty ? "(empty)" : member.title
			let inGroup = group?.contains(member) ?? false
			emit("\(label):   [\(index)] \(type(of: member)) title=\"\(title)\" tabbingMode=\(name(of: member.tabbingMode)) id=\"\(member.tabbingIdentifier)\" inGroup=\(inGroup)")
		}
	}

	/// Records the window's geometry on a timer and prints it when it changes.
	///
	/// The tab bar appearing moves the content — that much is native and
	/// expected. What matters is the shape of the motion afterwards: a handful
	/// of distinct geometries that stop is a transition, a stream that keeps
	/// coming is something being fought over every layout pass.
	private static func sample(
		_ window: NSWindow,
		label: String,
		ticks: Int,
		every: Double,
		then finish: @escaping () -> Void
	) {
		var seen: [String] = []
		var changesAfterFirstSecond = 0

		func tick(_ remaining: Int) {
			let elapsed = Double(ticks - remaining) * every
			let line = "content=\(window.contentLayoutRect) size=\(window.frame.size) tabBar=\(window.tabGroup?.isTabBarVisible ?? false)"
			if seen.last != line {
				seen.append(line)
				if elapsed > 1.0 { changesAfterFirstSecond += 1 }
				emit("\(label) t=\(String(format: "%.1f", elapsed))s \(line)")
			}
			guard remaining > 0 else {
				emit("\(label): distinct=\(seen.count) changesAfter1s=\(changesAfterFirstSecond) verdict=\(changesAfterFirstSecond == 0 ? "settled (transition)" : "STILL MOVING (fight)")")
				finish()
				return
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + every) { tick(remaining - 1) }
		}
		tick(ticks)
	}

	private static func describe(_ window: NSWindow?) -> String {
		guard let window else { return "nil" }
		return "\(type(of: window))(\"\(window.title)\")"
	}

	private static func name(of mode: NSWindow.TabbingMode) -> String {
		switch mode {
		case .automatic: "automatic"
		case .preferred: "preferred"
		case .disallowed: "disallowed"
		@unknown default: "unknown(\(mode.rawValue))"
		}
	}

	private static func emit(_ message: String) {
		print("[NewTabProbe] \(message)")
	}
}

#endif
