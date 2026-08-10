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

	/// Overlay compatibility is opt-in for a subclass that draws. Without this,
	/// asking the scroll view for `.overlay` while this scroller is installed
	/// is asking for a style AppKit considers unsafe with it, and the answer
	/// is legacy — which is why assigning the style looked like it "didn't
	/// stick": the scroller was vetoing it.
	override class var isCompatibleWithOverlayScrollers: Bool { true }

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

/// The transcript scroll views' own subclass, for the renderers that build
/// theirs by hand. Owning the getter is the strongest pin there is — AppKit
/// can re-read the system preference as often as it likes and always hear
/// overlay — but it's only available to a class we get to declare.
final class OverlayScrollView: NSScrollView {

	override var scrollerStyle: NSScroller.Style {
		get { .overlay }
		set { super.scrollerStyle = .overlay }
	}
}

/// Gives a transcript scroll view the scroller it should have had: overlay,
/// thin, and silent until the user actually scrolls.
///
/// Overlay because the alternative is structural. A legacy scroller — what
/// "Show scroll bars: Always" installs — takes its width out of
/// `contentSize`, the number every transcript renderer lays out against, so
/// its arrival reflows every message on screen. An overlay scroller floats,
/// and its width is only a look.
///
/// Quiet because AppKit flashes overlay scrollers at every content jump, and
/// opening a chat jumps before anyone has touched anything: the transcript is
/// placed at the offset it was left at, or stuck to the bottom, as its first
/// act. The scroller stays unpainted until a live scroll — the one event only
/// a real gesture posts — and behaves normally from then on.
///
/// One instance runs per scroll view and is held by the scroll view itself,
/// so the per-row probes in the SwiftUI list all land on the same controller
/// instead of stacking one observer per visible row.
@MainActor
final class LazyScroller: NSObject {

	static func install(on scrollView: NSScrollView) {
		if let installed = objc_getAssociatedObject(scrollView, &installedKey) as? LazyScroller {
			installed.pin()
			return
		}
		let controller = LazyScroller(scrollView)
		objc_setAssociatedObject(scrollView, &installedKey, controller, .OBJC_ASSOCIATION_RETAIN)
		controller.pin()
	}

	private nonisolated(unsafe) static var installedKey: UInt8 = 0

	private weak var scrollView: NSScrollView?
	private var revealed = false
	nonisolated(unsafe) private var revealWatch: NSObjectProtocol?

	private init(_ scrollView: NSScrollView) {
		self.scrollView = scrollView
		super.init()

		revealWatch = NotificationCenter.default.addObserver(
			forName: NSScrollView.willStartLiveScrollNotification,
			object: scrollView,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.reveal() }
		}
	}

	deinit {
		if let revealWatch { NotificationCenter.default.removeObserver(revealWatch) }
	}

	/// Everything this controller asserts, re-assertable in one move: overlay
	/// style, autohide, and a quiet small scroller. Called on install, on every
	/// style change AppKit makes, and whenever a probe re-runs.
	func pin() {
		guard let scrollView else { return }

		if scrollView.scrollerStyle != .overlay {
			scrollView.scrollerStyle = .overlay
		}
		scrollView.autohidesScrollers = true
		scrollView.hasVerticalScroller = true

		if !(scrollView.verticalScroller is QuietScroller) {
			let quiet = QuietScroller()
			quiet.controlSize = .small
			quiet.isQuiet = !revealed
			scrollView.verticalScroller = quiet
		}
	}

	/// Hand the scroller over, from the start of the gesture that asked for it.
	///
	private func reveal() {
		revealed = true
		(scrollView?.verticalScroller as? QuietScroller)?.isQuiet = false
	}
}
