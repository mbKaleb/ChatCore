//
//  LazyScroller.swift
//  ChatCore
//

import AppKit

/// A scroller that paints nothing until it's been asked for.
///
/// Hiding the view isn't enough on its own: AppKit owns the scroller's
/// visibility while it autohides and flashes it, and unhides it whenever it
/// decides the content moved. Quiet is a property of the scroller rather than
/// something done to it from outside, so nothing AppKit does to `isHidden` or
/// `alphaValue` puts it back on screen early.
final class QuietScroller: NSScroller {

	var isQuiet = true {
		didSet {
			guard isQuiet != oldValue else { return }
			needsDisplay = true
		}
	}

	override func draw(_ dirtyRect: NSRect) {
		guard !isQuiet else { return }
		super.draw(dirtyRect)
	}

	override func drawKnob() {
		guard !isQuiet else { return }
		super.drawKnob()
	}

	override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
		guard !isQuiet else { return }
		super.drawKnobSlot(in: slotRect, highlight: flag)
	}
}

/// A scroll view whose scrollers float over the content, whatever the system
/// preference says.
///
/// "Show scroll bars: Always" is a legacy scroller, and a legacy scroller takes
/// its width out of the content rather than floating above it. Both AppKit
/// transcript renderers lay out against `contentSize.width`, so that width
/// arrives 13pt short the moment the scroller tiles — after the transcript has
/// already been compiled at the full column. Every message then reflows to
/// acknowledge a scrollbar, which is the shift.
///
/// Assigning `scrollerStyle` doesn't hold: AppKit re-reads the preference on
/// every tile and puts it back. Owning the getter is what makes it stick.
final class OverlayScrollView: NSScrollView {

	override var scrollerStyle: NSScroller.Style {
		get { .overlay }
		set { super.scrollerStyle = .overlay }
	}
}

// A scroll view SwiftUI declares — `List`'s — can't be given this override.
// Assigning `scrollerStyle` doesn't survive the next tile, and swapping the
// instance onto a runtime subclass, the way KVO does, trips an AppKit responder
// assertion and takes the app down. So the list renderers keep the system's
// scroller style, and stay shift-free by leaving its width alone instead.

/// Holds a transcript's vertical scroller back until someone actually scrolls it.
///
/// AppKit flashes an overlay scroller whenever the content offset jumps, and
/// opening a chat jumps before anyone has touched anything: the transcript is
/// placed at the offset it was left at, or stuck to the bottom, as its first act.
/// The scroller that flashes over that is answering a scroll nobody performed.
///
/// There is no way to tell AppKit that a particular move wasn't the user's, so
/// the scroller stays quiet until a live scroll proves otherwise — the one event
/// only a real gesture posts. Every programmatic placement, opening a chat or
/// sticking to the bottom mid-stream, is silent for as long as that holds.
@MainActor
final class LazyScroller {

	private var revealed = false

	nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

	deinit {
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
	}

	/// Give `scrollView` the transcript's scroller, quiet until earned.
	///
	/// Safe to call again, and meant to be: SwiftUI rebuilds its `List` scroll
	/// view's scroller out from under this, so re-attaching on every update is
	/// what keeps a replacement quiet too.
	func attach(to scrollView: NSScrollView) {
		scrollView.autohidesScrollers = true

		// Mounted once and left mounted. Both AppKit transcript renderers lay out
		// against `contentSize.width`, so a scroller that comes and goes is a
		// column that comes and goes with it — every message reflowing to
		// acknowledge a scrollbar.
		scrollView.hasVerticalScroller = true

		if !(scrollView.verticalScroller is QuietScroller) {
			let quiet = QuietScroller()
			// An overlay scroller floats, so its size is a look and `.small` is
			// the transcript's. A legacy one is a column the content doesn't
			// get, and re-sizing it hands those points back mid-layout with
			// every message reflowing into them — the shift, wearing a different
			// hat. So the thin look is taken only where it's free.
			quiet.controlSize = scrollView.scrollerStyle == .overlay
				? .small
				: scrollView.verticalScroller?.controlSize ?? .small
			scrollView.verticalScroller = quiet
		}

		(scrollView.verticalScroller as? QuietScroller)?.isQuiet = !revealed

		guard !revealed, observers.isEmpty else { return }

		observers.append(
			NotificationCenter.default.addObserver(
				forName: NSScrollView.willStartLiveScrollNotification,
				object: scrollView,
				queue: .main
			) { [weak self, weak scrollView] _ in
				MainActor.assumeIsolated {
					guard let self, let scrollView else { return }
					self.reveal(in: scrollView)
				}
			}
		)

	}

	/// Hand the scroller over, from the start of the gesture that asked for it.
	private func reveal(in scrollView: NSScrollView) {
		revealed = true
		(scrollView.verticalScroller as? QuietScroller)?.isQuiet = false
	}
}
