//
//  TabActivity.swift
//  ChatCore
//

import SwiftUI
import AppKit

/// A spinner on the right side of the window's native tab while its chat is
/// thinking or streaming.
///
/// The slot is `NSWindowTab.accessoryView` — the same one Safari's tab
/// spinners live in, trailing the tab title. AppKit owns the placement; all
/// this decides is when the view is there at all. Setting it on a window with
/// no tab bar up is harmless: the accessory only renders inside a tab.
///
/// "Busy" is per *window*, not per app: this window's tab should spin for the
/// chats this window is showing — the selected one and the pinned secondary —
/// and stay still while some other tab's chat streams. Kept out of `AppView`'s
/// body for the usual reason: the reads here change on every send and selection
/// change, and this view is the only thing that should re-run for them.
struct TabActivity: View {

	@Environment(ModelManager.self) private var manager
	@Environment(AppModel.self) private var app

	var body: some View {
		TabAccessorySpinner(isSpinning: isBusy)
			.frame(width: 0, height: 0)
			.accessibilityHidden(true)
	}

	private var isBusy: Bool {
		let generating = manager.generatingConversationIDs
		guard !generating.isEmpty else { return false }
		if let id = app.selectedConversation?.id, generating.contains(id) { return true }
		if let id = app.secondaryConversation?.id, generating.contains(id) { return true }
		return false
	}
}

private struct TabAccessorySpinner: NSViewRepresentable {

	var isSpinning: Bool

	func makeNSView(context: Context) -> Probe { Probe() }
	func updateNSView(_ view: Probe, context: Context) { view.isSpinning = isSpinning }

	final class Probe: NSView {

		var isSpinning = false {
			didSet { if isSpinning != oldValue { apply() } }
		}

		/// Lazily built and reused: the accessory slot is swapped, not the
		/// spinner, so a busy → idle → busy chat doesn't mint indicators.
		private var spinner: NSProgressIndicator?

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			// `updateNSView` can run before the window exists; this is the pass
			// that has one.
			apply()
		}

		private func apply() {
			guard let window else { return }
			if isSpinning {
				let spinner = spinner ?? makeSpinner()
				if window.tab.accessoryView !== spinner {
					window.tab.accessoryView = spinner
				}
				spinner.startAnimation(nil)
			} else {
				spinner?.stopAnimation(nil)
				// Only take back a slot we filled — don't clobber someone
				// else's accessory if one ever appears.
				if let spinner, window.tab.accessoryView === spinner {
					window.tab.accessoryView = nil
				}
			}
		}

		private func makeSpinner() -> NSProgressIndicator {
			let indicator = NSProgressIndicator()
			indicator.style = .spinning
			indicator.controlSize = .small
			indicator.isIndeterminate = true
			indicator.isDisplayedWhenStopped = false
			indicator.sizeToFit()
			spinner = indicator
			return indicator
		}
	}
}
