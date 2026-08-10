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

	/// The chat pinned in the second pane, when the window is split.
	///
	/// Independent of the sidebar's selection on purpose: selection keeps
	/// driving the primary pane exactly as before, and this one only ever
	/// changes by an explicit drop or close. Resolved the same way
	/// `selectedConversation` is — a held model object, not a query — for the
	/// same streaming-write reason.
	var secondaryConversation: Conversation?

	var sidebarOpen: Bool { columnVisibility != .detailOnly }

	// MARK: - Drafts

	/// Unsent compose-bar contents, one per conversation.
	///
	/// Held here rather than as `ChatView` state so that switching chats
	/// neither destroys the typed text nor leaks staged attachments into the
	/// next chat. Bookkeeping the way `lastSidebarToggle` is: read and written
	/// only from event handlers, never rendered, so observing it would
	/// invalidate a body for nothing.
	@ObservationIgnored private var drafts: [UUID: ChatDraft] = [:]

	/// The compose surfaces currently on screen, keyed by the chat each is
	/// editing.
	///
	/// Registered by `ChatView` on appear and cleared on disappear, so a task
	/// that outlives its view — a failing send, a slow file read — can land
	/// its result in the *live* draft. The view that started such a task can
	/// be torn down and rebuilt (deselect, multi-select) while it runs, and
	/// the copy the task captured would otherwise write into `@State` storage
	/// nothing renders any more.
	///
	/// A dictionary rather than the single slot it used to be: the split view
	/// puts two composers on screen at once, and whichever registered last
	/// would otherwise shadow the other — an attachment ingested for the left
	/// chat has to find the left chat's compose bar.
	@ObservationIgnored private var activeComposers: [UUID: WeakComposer] = [:]

	private struct WeakComposer { weak var ref: ComposerState? }

	func registerComposer(_ composer: ComposerState, for conversationID: UUID) {
		// One entry per composer: `ChatView` re-registers on a conversation
		// swap without unregistering first, and the stale key would otherwise
		// keep routing that chat's async results to a bar now editing another.
		activeComposers = activeComposers.filter { $0.value.ref !== composer && $0.value.ref != nil }
		activeComposers[conversationID] = WeakComposer(ref: composer)
	}

	func unregisterComposer(_ composer: ComposerState) {
		activeComposers = activeComposers.filter { $0.value.ref !== composer && $0.value.ref != nil }
	}

	private func liveComposer(for conversationID: UUID) -> ComposerState? {
		activeComposers[conversationID]?.ref
	}

	func stashDraft(_ draft: ChatDraft, for id: UUID) {
		if draft.isEmpty {
			drafts.removeValue(forKey: id)
		} else {
			drafts[id] = draft
		}
	}

	/// The stashed draft, removed on the way out — once loaded, the compose
	/// bar owns it again.
	func takeDraft(for id: UUID) -> ChatDraft {
		drafts.removeValue(forKey: id) ?? ChatDraft()
	}

	/// Stage an ingested attachment into the chat it was started for,
	/// wherever that chat's draft lives *now*: the on-screen composer when
	/// it's up, the stash otherwise. Every attachment write from an async
	/// completion funnels through here.
	func stageAttachment(_ attachment: MessageAttachment, for conversationID: UUID) {
		if let composer = liveComposer(for: conversationID) {
			composer.add(attachment)
		} else {
			var draft = takeDraft(for: conversationID)
			draft.attachments.append(attachment)
			stashDraft(draft, for: conversationID)
		}
	}

	/// Put a failed send's prompt back where the user can retry it — same
	/// routing as `stageAttachment`, merged ahead of whatever is already
	/// drafted rather than overwriting it.
	func restoreDraft(text: String, attachments: [MessageAttachment], for conversationID: UUID) {
		if let composer = liveComposer(for: conversationID) {
			var draft = ChatDraft(text: composer.text, attachments: composer.attachments)
			draft.prepend(text: text, attachments: attachments)
			composer.setText(draft.text)
			composer.attachments = draft.attachments
		} else {
			var draft = takeDraft(for: conversationID)
			draft.prepend(text: text, attachments: attachments)
			stashDraft(draft, for: conversationID)
		}
	}

	// MARK: - Chat errors

	/// Errors waiting to be shown, one per conversation.
	///
	/// Keyed so a failure reported by an outlived task lands on the chat it
	/// belongs to, not on whichever chat is up when it fires: `ChatView`
	/// presents its own conversation's entry — immediately when that chat is
	/// on screen, on return when it isn't. Observed, unlike the drafts: the
	/// alert renders from this.
	var chatErrors: [UUID: ChatError] = [:]

	func reportChatError(_ error: ChatError, for conversationID: UUID) {
		chatErrors[conversationID] = error
	}

	func clearChatError(for conversationID: UUID) {
		chatErrors.removeValue(forKey: conversationID)
	}

	// MARK: - Sidebar

	/// The last toggle's timestamp, for the cooldown below.
	///
	/// Bookkeeping, never drawn. Observed, it would invalidate a body on every
	/// toggle for a value nothing renders — which is most of what this type
	/// exists to stop.
	@ObservationIgnored private var lastSidebarToggle: ContinuousClock.Instant?

	private static let sidebarToggleCooldown: Duration = .milliseconds(150)

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
		defer {
			// Selecting the chat that's pinned on the side folds the split back
			// together — the alternative is the same transcript twice, with two
			// composers fighting over one draft.
			if let selected = selectedConversation, secondaryConversation?.id == selected.id {
				secondaryConversation = nil
			}
		}
		if selectedConversation?.id == id { return }
		var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
		descriptor.fetchLimit = 1
		selectedConversation = try? context.fetch(descriptor).first
	}

	// MARK: - Split view

	/// Open a dropped chat in the second pane.
	///
	/// Dropping the chat that's already up moves it there instead — the pane
	/// reads as "pin this to the side", and duplicating a transcript across
	/// both panes is the one arrangement this feature refuses to build.
	@discardableResult
	func openSecondary(id: UUID, in context: ModelContext) -> Bool {
		if secondaryConversation?.id == id { return true }
		if selectedIDs == [id], let current = selectedConversation {
			secondaryConversation = current
			selectedConversation = nil
			selectedIDs = []
			return true
		}
		var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
		descriptor.fetchLimit = 1
		guard let convo = try? context.fetch(descriptor).first else { return false }
		secondaryConversation = convo
		return true
	}

	func closeSecondary() {
		secondaryConversation = nil
	}

	/// Called ahead of a sidebar delete so the pane doesn't keep rendering a
	/// model object the context is about to tear down.
	func conversationsWillBeDeleted(_ ids: some Collection<UUID>) {
		if let secondary = secondaryConversation, ids.contains(secondary.id) {
			secondaryConversation = nil
		}
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

/// A compose bar's unsent contents.
struct ChatDraft {
	var text = ""
	var attachments: [MessageAttachment] = []

	var isEmpty: Bool { text.isEmpty && attachments.isEmpty }

	/// An older prompt merged in ahead of what's already here — restoring a
	/// failed send must not overwrite a draft typed since.
	mutating func prepend(text failed: String, attachments failedAttachments: [MessageAttachment]) {
		if !failed.isEmpty {
			text = text.isEmpty ? failed : failed + "\n" + text
		}
		attachments = failedAttachments + attachments
	}
}

/// A failure one chat needs to show, when it's next on screen.
struct ChatError {
	var message: String
	var suggestsSettings = false
}
