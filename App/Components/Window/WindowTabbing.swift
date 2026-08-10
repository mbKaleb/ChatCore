//
//  WindowTabbing.swift
//  ChatCore
//

import SwiftUI
import AppKit

/// Safari's tab keys, for native window tabs.
///
/// ⌘1–⌘8 jump straight to that tab, ⌘9 to the last one whatever the count,
/// and ⌘⇧[ / ⌘⇧] step sideways — all on top of the ⌃Tab pair AppKit already
/// keeps in the Window menu. Safari shows none of these as menu items either,
/// so they live as hidden buttons in the window, the same trick as
/// `TextSizeShortcuts`.
struct TabShortcuts: View {

	var body: some View {
		ZStack {
			ForEach(1..<10) { slot in
				Button("Tab \(slot)") { Self.selectTab(slot) }
					.keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .command)
			}

			Button("Show Previous Tab") {
				NSApp.sendAction(#selector(NSWindow.selectPreviousTab(_:)), to: nil, from: nil)
			}
			.keyboardShortcut("[", modifiers: [.command, .shift])

			Button("Show Next Tab") {
				NSApp.sendAction(#selector(NSWindow.selectNextTab(_:)), to: nil, from: nil)
			}
			.keyboardShortcut("]", modifiers: [.command, .shift])
		}
		.opacity(0)
		.accessibilityHidden(true)
	}

	/// ⌘9 means "last tab" regardless of how many there are; ⌘1–⌘8 only
	/// fire when that many tabs exist.
	private static func selectTab(_ slot: Int) {
		guard let windows = NSApp.keyWindow?.tabGroup?.windows, windows.count > 1 else { return }
		let target = slot == 9 ? windows.last : (slot <= windows.count ? windows[slot - 1] : nil)
		target?.makeKeyAndOrderFront(nil)
	}
}

/// Says this window would rather be a tab.
///
/// A native tab *is* an `NSWindow` — `NSWindowTabGroup` groups windows, and
/// Safari's tabs are windows too — so opening one is never anything but opening
/// a window. The only question is whether AppKit files it into the existing
/// group or leaves it standing on its own, and that is `tabbingMode`.
///
/// It ships as `.automatic`, which defers to "Prefer tabs when opening
/// documents" — *in full screen only* by default. That is why ⌘T delivered its
/// action and produced a second window: verified with `-newTabProbe` as
/// `delivered=true`, two windows, the original reporting `inGroup=false`.
/// `.preferred` overrides the system setting for this app alone, and AppKit
/// does the grouping itself at order-in.
///
/// The window is reached in `viewDidMoveToWindow`, which SwiftUI runs while
/// building the new window's tree — before it is ordered in, which is the pass
/// that has to see the flag.
struct TabbingPolicy: NSViewRepresentable {

	func makeNSView(context: Context) -> Policy { Policy() }
	func updateNSView(_ view: Policy, context: Context) {}

	final class Policy: NSView {

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard let window else { return }

			guard NSWindow.allowsAutomaticWindowTabbing else {
				// Opened by New Window, which switches automatic tabbing off for
				// the length of the call precisely so this window stays out of
				// the group forming around it. Reading the switch rather than a
				// flag of our own keeps the two commands' difference in one
				// place — `NewWindowIntent`.
				//
				// Restored a tick later, once ordering-in is past and can't
				// retroactively merge it: a window that opted out of joining a
				// group still has to offer tabs of its own, or ⌘T from here
				// would open a window instead.
				DispatchQueue.main.async { window.tabbingMode = .preferred }
				return
			}
			window.tabbingMode = .preferred
		}
	}
}

/// Takes the chrome out from behind the native tab bar, and hides its "+".
///
/// The tab bar is a bottom titlebar accessory — it already sits *under* the
/// toolbar rather than inside it, in a plain `NSView` of its own. What made it
/// read as part of the toolbar is the `NSSubduedGlassEffectView` behind it: a
/// full-width tinted track drawn under the tabs. It can't simply be hidden —
/// the tabs are *inside* it, so that would take them along. It holds three
/// subviews — a backdrop, the one carrying the tab strip, and an overlay — and
/// only the middle one has children of its own, which is what tells them apart.
///
/// `NSTitlebarView`'s own opaque material stays: `titlebarAppearsTransparent`
/// is left false (and forced back down if something flips it), so the toolbar
/// keeps its background and the transcript doesn't show through it.
///
/// The selected tab's own `NSGlassEffectView` is left alone. It's a separate
/// view from the track, and once the track is gone it's the only thing marking
/// which tab is active.
///
/// AppKit shows the "+" whenever something in the responder chain answers
/// `newWindowForTab:` — which SwiftUI's `WindowGroup` always does — and there
/// is no public switch for it, so it's hidden by hand here too: it's the only
/// `NSButton` in the titlebar wired to that action.
///
/// Hiding the "+" doesn't give its space back, though. `NSTabBar` fills the
/// detail column already — it's the `NSTabBarTrackView` inside it that AppKit
/// insets by 8pt on the left and 40pt on the right, the latter being the room
/// the button was standing in. The tabs live in that track, so widening it to
/// the bar's own bounds is what makes them run the full width of the chat.
///
/// The search walks only the titlebar side of the frame view, never the content
/// view, so the SwiftUI hierarchy is never touched. `didUpdateNotification`
/// fires once per event pass; the memoized early-out keeps the common case to a
/// couple of pointer checks, and the full walk only runs while there is
/// something fresh to find — the tab bar just appeared, or was toggled back on
/// via View ▸ Show Tab Bar.
struct TabBarChrome: NSViewRepresentable {

	func makeNSView(context: Context) -> Probe { Probe() }
	func updateNSView(_ view: Probe, context: Context) {}

	final class Probe: NSView {

		private weak var hiddenButton: NSButton?
		private weak var track: NSView?

		/// Titlebar subview + accessory counts at the last search, and the
		/// searches still allowed on this shape.
		private var lastTitlebarShape = -1
		private var searchesLeft = 0

		/// Searches allowed per titlebar shape — a couple of event passes' worth,
		/// enough for an accessory that lays out late, far short of a loop.
		private static let searchBudget = 12

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			// Selector-based on purpose: these unregister themselves on
			// dealloc, which keeps `deinit` out of the main-actor's way.
			NotificationCenter.default.removeObserver(self)
			guard let window else { return }
			NotificationCenter.default.addObserver(
				self, selector: #selector(windowDidUpdate),
				name: NSWindow.didUpdateNotification, object: window
			)
			stripChrome()
		}

		@objc private func windowDidUpdate(_ note: Notification) {
			stripChrome()
		}

		#if DEBUG
		/// How hard this is working, for `-newTabProbe`. A hidden view makes
		/// AppKit relayout and a relayout posts another update, so "runs a lot"
		/// and "runs forever" look the same from outside — these tell them apart.
		nonisolated(unsafe) static var updateCount = 0
		nonisolated(unsafe) static var walkCount = 0
		/// Times `stretchTrack` got past its guard and forced a layout. A forced
		/// layout invalidates, an invalidation posts the update this runs on, so
		/// this is the count that says whether the widening is self-feeding.
		nonisolated(unsafe) static var stretchCount = 0
		#endif

		private func stripChrome() {
			guard let window else { return }
			#if DEBUG
			Self.updateCount += 1
			#endif
			// The titlebar keeps its own opaque material — only the tab bar's
			// own track comes out below.
			if window.titlebarAppearsTransparent {
				window.titlebarAppearsTransparent = false
			}

			// Re-assert rather than return: AppKit flips these back when the tab
			// bar relays out, and doing it from the stored references costs no
			// search — which is also what retries a `hideBackdrops` that came too
			// early to apply.
			//
			// Only ever *change* things, though. Hiding an already-hidden view
			// still invalidates it, and this runs on `didUpdateNotification`,
			// which the invalidation then posts again: a write every pass becomes
			// ~150 window updates a second with the geometry never moving, which
			// is the tab bar flickering in place. Read first, write only on a
			// difference, and the steady state costs nothing.
			if let hiddenButton, hiddenButton.window === window, !hiddenButton.isHidden {
				hiddenButton.isHidden = true
			}
			if let track, track.window === window {
				hideBackdrops(of: track)
				stretchTrack(of: track)
				// Both in hand: nothing a fresh search could add.
				if hiddenButton?.window === window { return }
			}

			guard let content = window.contentView, let frame = content.superview else { return }

			// A budget, not a latch.
			//
			// Only the window hosting the tab bar has a track to find; its
			// siblings in the group have none, so they never fill the references
			// above, never take the early return, and re-walk their whole
			// titlebar on every event pass for as long as they stay open —
			// measured with `-newTabProbe` at ~76 walks a second, climbing with
			// the tab count. Latching on the titlebar's shape alone stopped that
			// but could also stop it too early: a track that lands a frame after
			// the shape settles would never be searched for again.
			//
			// So each shape gets a run of searches rather than one. Late arrivals
			// are still caught, a window with nothing to find goes quiet, and the
			// bar appearing or leaving moves one of the two counts and buys a
			// fresh run.
			let shape = frame.subviews.count &* 31 &+ window.titlebarAccessoryViewControllers.count
			if shape != lastTitlebarShape {
				lastTitlebarShape = shape
				searchesLeft = Self.searchBudget
			}
			guard searchesLeft > 0 else { return }
			searchesLeft -= 1

			#if DEBUG
			Self.walkCount += 1
			#endif
			for sibling in frame.subviews where sibling !== content {
				if hiddenButton?.window !== window, let button = Self.newTabButton(in: sibling) {
					hiddenButton = button
				}
				if track?.window !== window, let found = Self.trackGlass(in: sibling) {
					track = found
				}
			}
			hiddenButton?.isHidden = true
			if let track {
				hideBackdrops(of: track)
				stretchTrack(of: track)
			}
		}

		/// Widens the track holding the tabs to the whole tab bar.
		///
		/// `track` is the glass view; the view AppKit insets is its superview,
		/// the `NSTabBarTrackView`, and it does it in Auto Layout — writing the
		/// frame is undone by the next layout pass. `NSTabBar` holds the
		/// constraints, four of them horizontal:
		///
		///     H:|-(8)-[track]
		///     H:[track]-(8@700)-|
		///     H:[track]-(4)-[newTabButton]
		///     H:[newTabButton]-(8)-|
		///
		/// The trailing inset is only *nominally* 8 — that constraint is
		/// optional, and the required button chain is what actually pins the
		/// track 40pt short. The button is collapsed rather than unhooked:
		/// deactivating its two left the track 4pt wide, because `NSTabBar`
		/// measures the track against where the button landed and Auto Layout,
		/// with nothing left to hold it, dropped the button at the origin.
		///
		/// The constants aren't all zeroed, though — the track keeps `inset` at
		/// each end of the bar so the tabs don't run into the window's edges.
		/// Only the constraints that reach the bar itself carry it; the one
		/// spanning track to button is interior and goes to zero, or the
		/// trailing margin would come out doubled.
		///
		/// Constants stay put unless AppKit rebuilds the bar, and the frame
		/// check up front makes the settled case a single comparison.
		private static let inset: CGFloat = 8

		private func stretchTrack(of track: NSView) {
			guard let trackView = track.superview, let bar = trackView.superview else { return }
			let wanted = bar.bounds.insetBy(dx: Self.inset, dy: 0)
			guard trackView.frame != wanted else { return }
			#if DEBUG
			Self.stretchCount += 1
			#endif

			for constraint in bar.constraints {
				let items = [constraint.firstItem as? NSView, constraint.secondItem as? NSView]
				guard items.contains(where: { $0 === trackView }) || items.contains(where: { $0 === hiddenButton })
				else { continue }
				guard Self.isHorizontalEdge(constraint) else { continue }

				// Sign depends on which side of the relation AppKit put the bar
				// on, but the magnitude is the same either way: the edges that
				// meet the bar get the margin, the interior gap gets nothing.
				let touchesBar = items.contains { $0 === bar || $0 == nil }
				let wanted = touchesBar
					? (constraint.constant < 0 ? -Self.inset : Self.inset)
					: 0
				if constraint.constant != wanted { constraint.constant = wanted }
			}
			if let button = hiddenButton { Self.collapse(button) }
			bar.layoutSubtreeIfNeeded()
		}

		/// Takes the width out of the hidden "+".
		///
		/// Its constraints stay active on purpose: `NSTabBar` re-derives the
		/// track from where the button ends up, so cutting the chain leaves the
		/// track measured against a button standing wherever Auto Layout
		/// dropped it. A zero width keeps the chain intact and empty, which is
		/// the same 40pt back without the arithmetic depending on us.
		private static let zeroWidth = "ChatCore.newTabButtonZeroWidth"

		private static func collapse(_ button: NSButton) {
			guard !button.constraints.contains(where: { $0.identifier == zeroWidth }) else { return }
			let width = button.widthAnchor.constraint(equalToConstant: 0)
			width.identifier = zeroWidth
			width.isActive = true
		}

		private static func isHorizontalEdge(_ constraint: NSLayoutConstraint) -> Bool {
			let horizontal: Set<NSLayoutConstraint.Attribute> = [.leading, .trailing, .left, .right, .width]
			return horizontal.contains(constraint.firstAttribute)
				|| horizontal.contains(constraint.secondAttribute)
		}

		/// Hides the childless siblings flanking the tab strip.
		///
		/// The guard is the safety catch: before the accessory has laid out,
		/// *nothing* has children yet, and hiding on that frame would blank the
		/// tab bar. Leaving the stock chrome up for a frame is the better miss.
		private func hideBackdrops(of track: NSView) {
			let layers = track.subviews
			guard layers.contains(where: { !$0.subviews.isEmpty }) else { return }
			for layer in layers where layer.subviews.isEmpty && !layer.isHidden {
				layer.isHidden = true
			}
		}

		private static func trackGlass(in view: NSView) -> NSView? {
			if NSStringFromClass(type(of: view)).contains("SubduedGlassEffectView") { return view }
			for sub in view.subviews {
				if let found = trackGlass(in: sub) { return found }
			}
			return nil
		}

		private static func newTabButton(in view: NSView) -> NSButton? {
			if let button = view as? NSButton,
			   button.action == #selector(NSWindow.newWindowForTab(_:))
				|| NSStringFromClass(type(of: button)).contains("NewTab") {
				return button
			}
			for sub in view.subviews {
				if let found = newTabButton(in: sub) { return found }
			}
			return nil
		}
	}
}
