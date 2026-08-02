//
//  AppModel.swift
//  ChatCore
//
//  The window's state, held apart from the view that used to own it.
//
//  As `@State` on `AppView`, each of these invalidated the whole split view on
//  every write — both columns and both toolbars — whether or not `body` had any
//  use for the value. `@State` has no way to say "this write changes nothing on
//  screen": it invalidates the owning view unconditionally. `@Observable` scopes
//  that to the views whose last `body` actually read the property, so a write
//  reaches exactly the columns that render it, and `@ObservationIgnored` takes
//  the bookkeeping out of the graph entirely.
//
//  This is the general form of the trick already spelled out on
//  `selectedConversation`, which was resolved by hand for the same reason.
//

import SwiftUI
import SwiftData

@Observable
@MainActor
final class AppModel {

	var selectedIDs: Set<UUID> = []
	var columnVisibility: NavigationSplitViewVisibility = .all
	var focusInputOnNextChat = false
	var promptICloudSignIn = false

	/// Resolved once per selection change rather than derived from a `@Query`,
	/// so writes to any conversation's `title` or `messages` — e.g. the
	/// once-a-second persist flush while streaming — don't touch this.
	var selectedConversation: Conversation?

	var sidebarOpen: Bool { columnVisibility != .detailOnly }

	// MARK: - Sidebar

	/// The last toggle's timestamp, for the cooldown below.
	///
	/// Bookkeeping, never drawn. Observed, it would invalidate a body on every
	/// toggle for a value nothing renders — which is most of what this type
	/// exists to stop.
	@ObservationIgnored private var lastSidebarToggle: ContinuousClock.Instant?

	private static let sidebarToggleCooldown: Duration = .milliseconds(400)

	func toggleSidebar() {
		let now = ContinuousClock.now
		if let last = lastSidebarToggle, now - last < Self.sidebarToggleCooldown { return }
		lastSidebarToggle = now
		columnVisibility = sidebarOpen ? .detailOnly : .all
	}

	// MARK: - Selection

	/// The context is passed in rather than stored: it belongs to the
	/// environment, and holding one past the view that vended it outlives the
	/// only guarantee there is about its lifetime.
	func resolveSelection(in context: ModelContext) {
		guard selectedIDs.count == 1, let id = selectedIDs.first else {
			selectedConversation = nil
			return
		}
		if selectedConversation?.id == id { return }
		var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
		descriptor.fetchLimit = 1
		selectedConversation = try? context.fetch(descriptor).first
	}

	func newConversation(in context: ModelContext, defaultModelID: String) {
		var config = Chat.default
		config.modelID = defaultModelID
		let convo = Conversation(config: config)
		context.insert(convo)
		focusInputOnNextChat = true
		// Set before the id changes: a freshly inserted, unsaved model may not
		// come back from a fetch yet, and `resolveSelection` short-circuits
		// when the resolved conversation already matches.
		selectedConversation = convo
		selectedIDs = [convo.id]
	}
}
