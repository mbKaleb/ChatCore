//
//  AppView.swift
//  ChatCore
//

import SwiftUI
import SwiftData

// MARK: - Focused Menu Actions

/// Focused values must be `Equatable` or every body re-run of the publishing
/// view counts as a new value — and a body that runs twice in one frame (a
/// delete touches selection, the query, and focus in the same event) then trips
/// "FocusedValue update tried to update multiple times per frame". Two of these
/// always compare equal: the closure is re-created each body run but reads live
/// state through its captured property wrappers, so a new instance is never a
/// semantic change.
/// ⌘T: a tab, and an empty one.
///
/// Nothing here starts a chat — the tab comes up on "Select or start a
/// conversation", the same as a new window does. Whether the window lands in the
/// tab group isn't decided here either; that is `TabbingPolicy`'s business,
/// settled by the window's own `tabbingMode` before AppKit orders it in.
@MainActor
enum NewTabIntent {

	/// Kept as a function rather than spelled out in the menu item so
	/// `-newTabProbe` exercises this exact path instead of a copy that can fall
	/// behind.
	@discardableResult
	static func open() -> Bool {
		NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
	}
}

/// ⌘⇧N: a window, not a tab, and an empty one.
@MainActor
enum NewWindowIntent {

	/// `TabbingPolicy` marks windows `.preferred`, which is a property of the
	/// window and not of the command that opened it — so AppKit can't tell New
	/// Window from New Tab by itself, and left alone it files both into the
	/// group. Automatic tabbing goes off for exactly as long as the window takes
	/// to appear, which SwiftUI builds synchronously inside `openWindow`, so the
	/// suppression spans this one statement and can't leak to anything else.
	static func open(_ openWindow: OpenWindowAction) {
		let wasAllowed = NSWindow.allowsAutomaticWindowTabbing
		NSWindow.allowsAutomaticWindowTabbing = false
		defer { NSWindow.allowsAutomaticWindowTabbing = wasAllowed }
		openWindow(id: "main")
	}
}

struct FocusedAction: Equatable {
	var perform: () -> Void

	init(_ perform: @escaping () -> Void) { self.perform = perform }

	static func == (lhs: Self, rhs: Self) -> Bool { true }
}

struct DeleteConversationsAction: Equatable {
	var isEnabled: Bool
	var perform: () -> Void

	// `isEnabled` is the only part the menu renders; see `FocusedAction` for
	// why the closure doesn't participate.
	static func == (lhs: Self, rhs: Self) -> Bool { lhs.isEnabled == rhs.isEnabled }
}

private struct NewChatKey: FocusedValueKey { typealias Value = FocusedAction }
private struct ToggleSidebarKey: FocusedValueKey { typealias Value = FocusedAction }
private struct FindChatKey: FocusedValueKey { typealias Value = FocusedAction }
private struct DeleteConversationsKey: FocusedValueKey { typealias Value = DeleteConversationsAction }
private struct RefreshViewKey: FocusedValueKey { typealias Value = FocusedAction }

extension FocusedValues {
	var newChat: FocusedAction? {
		get { self[NewChatKey.self] }
		set { self[NewChatKey.self] = newValue }
	}
	var refreshView: FocusedAction? {
		get { self[RefreshViewKey.self] }
		set { self[RefreshViewKey.self] = newValue }
	}
	var toggleSidebar: FocusedAction? {
		get { self[ToggleSidebarKey.self] }
		set { self[ToggleSidebarKey.self] = newValue }
	}
	var findChat: FocusedAction? {
		get { self[FindChatKey.self] }
		set { self[FindChatKey.self] = newValue }
	}
	var deleteConversations: DeleteConversationsAction? {
		get { self[DeleteConversationsKey.self] }
		set { self[DeleteConversationsKey.self] = newValue }
	}
}

/// The window.
///
/// Holds the model and hands it to the two columns through the environment,
/// reading none of it itself. That is the point: a `$model.x` binding doesn't
/// read `x`, so a write to `selectedIDs` or `focusInputOnNextChat` no longer
/// re-runs this body and, with it, both toolbars. The bindings still deliver —
/// `NavigationSplitView` tracks `columnVisibility` through the binding alone,
/// verified by toggling with no read of it anywhere in this body.
struct AppView: View {

	@Environment(\.modelContext) private var modelContext
	@Environment(ModelManager.self) private var manager
	@AppStorage(Defaults.Key.defaultModelID) private var defaultModelID = GenerativeChatModel.onDevice.id

	#if DEBUG
	@Environment(\.openWindow) private var openWindow
	#endif

	@State private var model = AppModel()

	/// Bumped by ⌘R. The only value this body reads that changes at runtime —
	/// which is the point: a refresh *is* a rebuild of everything below, and
	/// nothing else should be able to cause one.
	@State private var refreshToken = 0

	var body: some View {
		let _ = Self.printChanges()
		@Bindable var model = model
		NavigationSplitView(columnVisibility: $model.columnVisibility) {
			ConversationSidebar(onNewConversation: newConversation)
				.id(refreshToken)
		} detail: {
			ConversationDetail()
				.scrollEdgeEffectHidden(true, for: .top)
				.id(refreshToken)
		}
		.task {
			#if DEBUG
			// Lets `-newTabProbe` press New Window too. `openWindow` is a
			// SwiftUI environment action with no AppKit equivalent to send, so
			// the probe can only reach ⌘⇧N through a handle the scene hands it.
			WindowProbeHooks.openNewWindow = { NewWindowIntent.open(openWindow) }
			#endif
			if FileManager.default.ubiquityIdentityToken == nil {
				model.promptICloudSignIn = true
			}
		}
		.alert("Sign in to iCloud", isPresented: $model.promptICloudSignIn) {
			Button("Open System Settings") {
				if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
					NSWorkspace.shared.open(url)
				}
			}
			Button("Not Now", role: .cancel) {}
		} message: {
			Text("Private Cloud needs your Apple Account. On-device chat works either way.")
		}
		.focusedSceneValue(\.newChat, FocusedAction(newConversation))
		.focusedSceneValue(\.toggleSidebar, FocusedAction(model.toggleSidebar))
		.focusedSceneValue(\.refreshView, FocusedAction(refresh))
		.background {
			TextSizeShortcuts()
			TabShortcuts()
			TabbingPolicy()
			if !ProcessInfo.processInfo.arguments.contains("-noTabBarChrome") {
				TabBarChrome()
			}
			if !ProcessInfo.processInfo.arguments.contains("-noTabActivity") {
				TabActivity()
			}
		}
		.environment(model)
	}

	private func newConversation() {
		model.newConversation(in: modelContext, defaultModelID: defaultModelID)
		if let chatModel = manager.model(withID: defaultModelID) {
			manager.prewarm(chatModel)
		}
	}

	/// Rebuild both columns from scratch, keeping everything that isn't a view.
	///
	/// Deliberately the *view* only. A turn in flight is an unstructured task
	/// that writes through `ModelManager` and the `Conversation` object, neither
	/// of which lives in the view tree, so tearing the tree down doesn't
	/// interrupt it — the rebuilt transcript picks the stream back up from
	/// `liveText` on its first frame. `AppModel` survives for the same reason:
	/// selection, drafts and the split pane are state, not rendering. The
	/// compose bar's contents make the round trip through the draft stash, which
	/// `ChatView` already does on every appear and disappear.
	///
	/// The caches go with it. They exist to make a *destroyed* view cheap to
	/// rebuild — restoring a compiled document or a parsed markdown tree is
	/// exactly what a refresh is asking not to happen, since the reason to press
	/// ⌘R is that what's on screen is wrong.
	private func refresh() {
		MarkdownContentCache.removeAll()
		MathCache.removeAll()
		refreshToken &+= 1
	}
}

/// The unshifted half of ⌘+ / ⌘−.
///
/// The View menu carries the real items; their ⌘+ only matches the shifted key,
/// which is what "+" is on most layouts. These invisible twins catch ⌘= and the
/// numeric-keypad ⌘− so either press does the same thing, the way a browser
/// behaves. Kept in its own view so the read of `fontSize` — which changes on
/// every press — doesn't land in `AppView`'s body and rebuild the window.
private struct TextSizeShortcuts: View {

	@Environment(ThemeManager.self) private var themes

	var body: some View {
		ZStack {
			Button("Increase Text Size") { themes.fontSize += 1 }
				.keyboardShortcut("=", modifiers: .command)
				.disabled(themes.fontSize >= ChatAppearance.fontSizeRange.upperBound)

			Button("Decrease Text Size") { themes.fontSize -= 1 }
				.keyboardShortcut("_", modifiers: .command)
				.disabled(themes.fontSize <= ChatAppearance.fontSizeRange.lowerBound)
		}
		.opacity(0)
		.accessibilityHidden(true)
	}
}

// MARK: - Conversation Sidebar

private struct ConversationSidebar: View {
	@Environment(AppModel.self) private var model
	var onNewConversation: () -> Void

	@State private var searchText = ""
	@State private var debouncedSearch = ""

	@FocusState private var focus: SidebarFocus?

	private static let searchDebounce: Duration = .milliseconds(200)

	var body: some View {
		let _ = Self.printChanges()
		@Bindable var model = model
		ConversationList(
			search: debouncedSearch,
			selectedIDs: $model.selectedIDs,
			focus: $focus,
			onNewConversation: onNewConversation
		)
		.safeAreaInset(edge: .top) {
			SidebarSearchField(text: $searchText, focus: $focus)
		}
		.task(id: searchText) {
			let pending = searchText
			if pending.isEmpty {
				debouncedSearch = ""
				return
			}
			try? await Task.sleep(for: Self.searchDebounce)
			guard !Task.isCancelled else { return }
			debouncedSearch = pending
		}
		.navigationSplitViewColumnWidth(min: 235, ideal: 260, max: 320)
		.focusedSceneValue(\.findChat, FocusedAction { focus = .search })
	}
}

private struct ConversationList: View {
	@Environment(\.modelContext) private var modelContext
	@Environment(AppModel.self) private var model
	@Query private var conversations: [Conversation]

	private let search: String

	@Binding var selectedIDs: Set<UUID>
	@FocusState.Binding var focus: SidebarFocus?
	var onNewConversation: () -> Void

	@State private var snippets: [UUID: AttributedString] = [:]

	@State private var renamingID: UUID?
	@State private var renameDraft: String = ""
	@FocusState private var renameFieldFocused: Bool

	init(
		search: String,
		selectedIDs: Binding<Set<UUID>>,
		focus: FocusState<SidebarFocus?>.Binding,
		onNewConversation: @escaping () -> Void
	) {
		self.search = search
		self._selectedIDs = selectedIDs
		self._focus = focus
		self.onNewConversation = onNewConversation

		let term = search
		let predicate: Predicate<Conversation>? = term.isEmpty ? nil : #Predicate<Conversation> { convo in
			convo.title.localizedStandardContains(term)
				|| convo.messages.contains(where: { $0.text.localizedStandardContains(term) })
		}
		self._conversations = Query(filter: predicate, sort: \Conversation.createdAt, order: .reverse)
	}

	private var renameTarget: Conversation? {
		guard selectedIDs.count == 1 else { return nil }
		return conversations.first { selectedIDs.contains($0.id) }
	}

	private var visibleSelection: [Conversation] {
		conversations.filter { selectedIDs.contains($0.id) }
	}

	var body: some View {
		let _ = Self.printChanges()
		List(conversations, selection: $selectedIDs) { convo in
			Group {
				if renamingID == convo.id {
					TextField("Name", text: $renameDraft)
						.textFieldStyle(.plain)
						.focused($renameFieldFocused)
						.onSubmit(commitRename)
						.onExitCommand(perform: cancelRename)
				} else {
					VStack(alignment: .leading, spacing: 2) {
						Text(convo.title)
							.lineLimit(1)

						if let snippet = snippets[convo.id] {
							Text(snippet)
								.font(.caption)
								.foregroundStyle(.secondary)
								.lineLimit(2)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(RowDoubleClickHandler(onDoubleClick: beginRename(rowIndex:)))
					.draggable(ConversationDragItem(id: convo.id))
				}
			}
			.tag(convo.id)
		}
		.focused($focus, equals: .list)
		.overlay {
			if conversations.isEmpty && !search.isEmpty {
				ContentUnavailableView.search(text: search)
			}
		}
		.task(id: search) { await rebuildSnippets(for: search) }
		.onChange(of: focus) { _, focus in
			guard focus == .list, !search.isEmpty, selectedIDs.isEmpty else { return }
			guard let first = conversations.first else { return }
			selectedIDs = [first.id]
		}
		.onKeyPress(.return) {
			guard focus == .list, renamingID == nil, let target = renameTarget else { return .ignored }
			beginRename(target)
			return .handled
		}
		.onChange(of: selectedIDs) {
			if let id = renamingID, !selectedIDs.contains(id) { cancelRename() }
		}
		.focusedSceneValue(
			\.deleteConversations,
			DeleteConversationsAction(
				isEnabled: focus == .list && renamingID == nil && !visibleSelection.isEmpty,
				perform: deleteSelected
			)
		)
		.background {
			Button(action: clearSelectionIfFocused) { }
				.keyboardShortcut(.escape, modifiers: [])
				.disabled(focus != .list)
				.opacity(0)
		}
		.toolbar {
			ToolbarItem {
				GlassEffectContainer(spacing: 12) {
					HStack {
						Button(action: onNewConversation) {
							Label("New Conversation", systemImage: "square.and.pencil")
						}
						.glassEffect(.regular.interactive())

						Button(role: .destructive, action: deleteSelected) {
							Label("Delete", systemImage: "trash")
						}
						.disabled(visibleSelection.isEmpty)
						.glassEffect(.regular.interactive())
					}
				}
			}
			.sharedBackgroundVisibility(.hidden)
		}
	}

	private func rebuildSnippets(for term: String) async {
		guard !term.isEmpty else {
			if !snippets.isEmpty { snippets = [:] }
			return
		}

		var built: [UUID: AttributedString] = [:]
		for convo in conversations.prefix(SidebarSearchSnippet.resultLimit) {
			if Task.isCancelled { return }
			if let snippet = SidebarSearchSnippet.excerpt(for: convo, matching: term) {
				built[convo.id] = snippet
			}
			await Task.yield()
		}

		guard !Task.isCancelled else { return }
		snippets = built
	}

	private func clearSelectionIfFocused() {
		guard focus == .list, renamingID == nil else { return }
		selectedIDs = []
	}

	private func beginRename(rowIndex: Int) {
		guard conversations.indices.contains(rowIndex) else { return }
		let convo = conversations[rowIndex]
		selectedIDs = [convo.id]
		beginRename(convo)
	}

	private func beginRename(_ convo: Conversation) {
		renameDraft = convo.title
		renamingID = convo.id
		renameFieldFocused = true
	}

	private func commitRename() {
		defer { finishRename() }
		guard let id = renamingID, let convo = conversations.first(where: { $0.id == id }) else { return }
		let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		convo.title = trimmed
	}

	private func cancelRename() { finishRename() }

	private func finishRename() {
		renamingID = nil
		renameDraft = ""
		renameFieldFocused = false
		focus = .list
	}

	private func deleteSelected() {
		let doomed = visibleSelection
		model.conversationsWillBeDeleted(doomed.map(\.id))
		selectedIDs.subtract(doomed.map(\.id))
		for convo in doomed { modelContext.delete(convo) }
	}
}

// MARK: - Row Double-Click

private struct RowDoubleClickHandler: NSViewRepresentable {
	var onDoubleClick: (Int) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(onDoubleClick: onDoubleClick) }

	func makeNSView(context: Context) -> NSView {
		let probe = NSView(frame: .zero)
		attach(probe, coordinator: context.coordinator, attemptsLeft: 8)
		return probe
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		context.coordinator.onDoubleClick = onDoubleClick
		attach(nsView, coordinator: context.coordinator, attemptsLeft: 1)
	}

	private func attach(_ probe: NSView, coordinator: Coordinator, attemptsLeft: Int) {
		guard attemptsLeft > 0 else { return }
		DispatchQueue.main.async {
			guard let table = probe.enclosingScrollView?.documentView as? NSTableView else {
				attach(probe, coordinator: coordinator, attemptsLeft: attemptsLeft - 1)
				return
			}
			if table.target !== coordinator {
				// Every row installs a handler on the same table, so the
				// displaced target may be a sibling Coordinator. Inherit the
				// real target it saved instead of chaining coordinators —
				// two of them forwarding to each other recurses forever in
				// `responds(to:)`.
				if let peer = table.target as? Coordinator {
					coordinator.originalTarget = peer.originalTarget
				} else {
					coordinator.originalTarget = table.target as AnyObject?
				}
				table.target = coordinator
			}
			table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
		}
	}

	@MainActor final class Coordinator: NSObject {
		var onDoubleClick: (Int) -> Void

		/// SwiftUI's own table target, displaced when we install ourselves.
		/// The table has a single `target` shared by `action` and
		/// `doubleAction`, so its single-click action (`onAction:`) lands here;
		/// anything we don't handle is forwarded back to keep List selection
		/// working.
		nonisolated(unsafe) weak var originalTarget: AnyObject?

		init(onDoubleClick: @escaping (Int) -> Void) {
			self.onDoubleClick = onDoubleClick
		}

		nonisolated override func responds(to aSelector: Selector!) -> Bool {
			super.responds(to: aSelector) || (originalTarget?.responds(to: aSelector) ?? false)
		}

		nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
			if let originalTarget, originalTarget.responds(to: aSelector) {
				return originalTarget
			}
			return super.forwardingTarget(for: aSelector)
		}

		// Isolated as a whole rather than hopping inside: AppKit fires
		// target-actions on the main thread, and the annotation is what lets
		// the compiler see that instead of taking `self` across a boundary.
		@objc @MainActor func handleDoubleClick(_ sender: NSTableView) {
			let row = sender.clickedRow
			guard row >= 0 else { return }
			onDoubleClick(row)
		}
	}
}

// MARK: - Conversation Detail
/// The detail column and the toolbar over it.
///
/// Reads `selectedIDs` and `selectedConversation` and nothing else. In
/// particular it does *not* read `sidebarOpen`: that used to arrive as a stored
/// property, so every sidebar toggle re-ran this body and rebuilt the `.toolbar`
/// below it — SwiftUI re-issues an `NSToolbarItem` when its content changes
/// identity, which is a visible swap. `ChatView` reads the sidebar state itself
/// now, being the only thing that reacts to it.
private struct ConversationDetail: View {
	@Environment(AppModel.self) private var model
	@Environment(\.modelContext) private var modelContext

	@State private var splitDropTargeted = false

	/// Two fifths of the screen: the floor under the primary chat pane, and —
	/// the window being `.contentMinSize` — under the window itself, plus the
	/// sidebar's 235pt while it's open. Read once per launch, so a window
	/// dragged to another display keeps the floor of the screen it started on.
	private static let chatPaneMinWidth: CGFloat =
		((NSScreen.main?.frame.width ?? 1280) * 0.4).rounded()

	/// The secondary pane's floor, shared with the outer frame below so the
	/// window's minimum grows by exactly this much while a split is open.
	private static let secondaryPaneMinWidth: CGFloat = 320

	var body: some View {
		let _ = Self.printChanges()
		HSplitView {
			primaryPane
				.frame(minWidth: Self.chatPaneMinWidth, maxWidth: .infinity, maxHeight: .infinity)
				.layoutPriority(1)

			if let secondary = model.secondaryConversation {
				SecondaryChatPane(conversation: secondary)
				.frame(minWidth: Self.secondaryPaneMinWidth, maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		// The sum of the panes' floors, so this frame — the window being
		// `.contentMinSize` — never declares less width than the split's
		// children demand: a floor below theirs lets the window shrink until
		// the secondary pane clips off the right edge. The secondary's 320pt
		// only counts while it exists; a single-pane window keeps the smaller
		// floor rather than pinning a split-sized one the sidebar then adds
		// 235pt to.
		.frame(
			minWidth: Self.chatPaneMinWidth
				+ (model.secondaryConversation != nil ? Self.secondaryPaneMinWidth : 0),
			minHeight: 360
		)
		// On the whole column rather than a right-edge strip: the payload type
		// is what routes the drop, not where it lands. Files and text keep
		// falling through to `ChatView`'s own drop handling — nothing there
		// accepts a conversation, and nothing here accepts anything else.
		.dropDestination(for: ConversationDragItem.self) { items, _ in
			guard let item = items.first else { return false }
			return model.openSecondary(id: item.id, in: modelContext)
		} isTargeted: { splitDropTargeted = $0 }
		.overlay {
			if splitDropTargeted { SplitDropHint() }
		}
		.animation(.easeInOut(duration: 0.15), value: splitDropTargeted)
		// Resolved here rather than one level up: this is the view that renders
		// the result, so the read of `selectedIDs` it costs is one this body
		// already owes. On `AppView` it was a dependency bought for nothing.
		.onChange(of: model.selectedIDs, initial: true) {
			model.resolveSelection(in: modelContext)
		}
		.toolbar {
			ToolbarItem(placement: .principal) {
				ModelBadge(conversation: model.selectedConversation)
			}

			ToolbarItem(placement: .primaryAction) {
				StatusIndicatorItem(conversation: model.selectedConversation)
			}
		}
	}

	private var primaryPane: some View {
		ZStack {
			if model.selectedIDs.count > 1 {
				Text("\(model.selectedIDs.count) conversations selected")
					.foregroundStyle(.secondary)
			} else if let conversation = model.selectedConversation {
				ChatView(conversation: conversation)
			} else {
				Text("Select or start a conversation")
					.foregroundStyle(.secondary)
			}
		}
	}
}

/// The pinned half of the split: a full `ChatView` under a slim header naming
/// the chat, with the one control the pane needs — closing it. The sidebar's
/// selection never points here; the header is what says which chat this is.
private struct SecondaryChatPane: View {
	@Environment(AppModel.self) private var model
	var conversation: Conversation

	var body: some View {
		ChatView(conversation: conversation)
			.safeAreaInset(edge: .top, spacing: 0) { header }
	}

	private var header: some View {
		HStack(spacing: 8) {
			// Reads the live title, so a rename or auto-title lands here too.
			Text(conversation.title)
				.font(.callout.weight(.medium))
				.lineLimit(1)

			Spacer(minLength: 8)

			Button {
				model.closeSecondary()
			} label: {
				Image(systemName: "xmark")
					.font(.caption.weight(.semibold))
					.frame(width: 20, height: 20)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.help("Close Split View")
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.background(.bar)
		.overlay(alignment: .bottom) { Divider() }
	}
}

/// What a sidebar drag sees while it hovers: the right half lights up as the
/// pane the drop will fill. Purely indicative — the drop itself is accepted by
/// the column underneath, wherever it lands.
private struct SplitDropHint: View {
	var body: some View {
		HStack(spacing: 0) {
			Color.clear

			ZStack {
				RoundedRectangle(cornerRadius: 16)
					.fill(Color.accentColor.opacity(0.1))
				RoundedRectangle(cornerRadius: 16)
					.strokeBorder(
						Color.accentColor.opacity(0.5),
						style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
					)
				Label("Open Side by Side", systemImage: "rectangle.split.2x1")
					.font(.headline)
					.foregroundStyle(Color.accentColor)
			}
			.padding(10)
		}
		.allowsHitTesting(false)
		.transition(.opacity)
	}
}

/// Resolves the model itself so the `chatModels` lookup doesn't make the
/// enclosing detail body depend on `ModelManager.chatModels`, and reads the
/// stored default for the same reason — `@AppStorage` is a view onto
/// `UserDefaults`, not a value that has to be threaded down from the window.
private struct StatusIndicatorItem: View {
	@Environment(ModelManager.self) private var manager
	@AppStorage(Defaults.Key.defaultModelID) private var defaultModelID = GenerativeChatModel.onDevice.id
	var conversation: Conversation?

	private var modelID: GenerativeChatModel.ID { conversation?.modelID ?? defaultModelID }

	var body: some View {
		if let model = manager.model(withID: modelID) {
			StatusIndicator(model: model)
		} else {
			MissingModelIndicator(modelID: modelID)
		}
	}
}

// MARK: - Model Badge

private struct ModelBadge: View {

	@Environment(ModelManager.self) private var manager
	@AppStorage(Defaults.Key.defaultModelID) private var defaultModelID = GenerativeChatModel.onDevice.id
	var conversation: Conversation?

	@State private var showPicker = false

	private var appleModels: [GenerativeChatModel] {
		manager.enabledChatModels.filter { $0.dataResidency != .cloud }
	}

	private var cloudModels: [GenerativeChatModel] {
		manager.enabledChatModels.filter { $0.dataResidency == .cloud }
	}

	/// The same split the Settings picker makes: a vendor serves its whole back
	/// catalog, and all of it arriving in one list buries what it ships today.
	/// Which half a model falls in comes from the manager, computed over the
	/// whole catalog — asked of this already-filtered list, the answer would be
	/// about the list rather than about what the vendor ships.
	private var currentModels: [GenerativeChatModel] {
		cloudModels.filter { !manager.supersededModelIDs.contains($0.id) }
	}

	/// Newest first, so the version a user is coming back from leads.
	private var olderModels: [GenerativeChatModel] {
		cloudModels
			.filter { manager.supersededModelIDs.contains($0.id) }
			.sorted { lhs, rhs in
				guard let left = lhs.release, let right = rhs.release else { return false }
				return right < left
			}
	}

	private var displayedModelID: GenerativeChatModel.ID {
		conversation?.modelID ?? defaultModelID
	}

	/// The id is a namespaced key, not a name — it doesn't fit the badge and
	/// doesn't read as one. When the model is gone, say that instead.
	private var badgeModelName: String {
		manager.model(withID: displayedModelID)?.displayName ?? "Unavailable"
	}

	private var isDefaultForNewChats: Binding<Bool> {
		Binding(
			get: { displayedModelID == defaultModelID },
			set: { isOn in
				if isOn { defaultModelID = displayedModelID }
			}
		)
	}

	private func select(_ model: GenerativeChatModel) {
		if let conversation {
			conversation.modelID = model.id
		} else {
			defaultModelID = model.id
		}
		showPicker = false
	}

	var body: some View {
		let _ = Self.printChanges()
		Button {
			showPicker = true
		} label: {
			ZStack {
				HStack(spacing: 2) {
					Text(badgeModelName)
				}
				.padding()
			}
			.lineLimit(2)
			.frame(width: 160, height: 36)
			.clipped()
			// A plain button only hit-tests the glyphs it draws, so without this
			// the empty space around a short model name swallows the click.
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.fixedSize()
		.popover(isPresented: $showPicker, arrowEdge: .bottom) {
			ModelPickerPopover(
				appleModels: appleModels,
				currentModels: currentModels,
				olderModels: olderModels,
				displayedModelID: displayedModelID,
				showsDefaultToggle: conversation != nil,
				isDefaultForNewChats: isDefaultForNewChats,
				capabilities: { manager.capabilities(of: $0) },
				onSelect: select
			)
		}
	}
}

private struct ModelPickerPopover: View {
	var appleModels: [GenerativeChatModel]
	var currentModels: [GenerativeChatModel]
	var olderModels: [GenerativeChatModel]
	var displayedModelID: GenerativeChatModel.ID
	var showsDefaultToggle: Bool
	var isDefaultForNewChats: Binding<Bool>
	var capabilities: (GenerativeChatModel) -> ModelCapabilities
	var onSelect: (GenerativeChatModel) -> Void

	/// Collapsed unless the chat is already on one of them — a popover is a
	/// pick-and-go, and the back catalog is longer than the part anyone reads.
	/// Nothing persists it: the next one opens on what's current again.
	@State private var showsOlder = false

	private let horizontalPadding: CGFloat = 14
	private let rowIndent: CGFloat = 14 + 16 + 6

	var body: some View {
		let _ = Self.printChanges()
		VStack(alignment: .leading, spacing: 0) {
			section(icon: Image(systemName: "apple.intelligence"), title: "Apple", models: appleModels)

			if !currentModels.isEmpty || !olderModels.isEmpty {
				Divider().padding(.vertical, 4)
				section(icon: Image("ClaudeIcon").resizable().scaledToFit(), title: "Claude", models: currentModels)
			}

			if !olderModels.isEmpty {
				olderHeader

				if showsOlder {
					ForEach(olderModels, content: row)
				}
			}

			if showsDefaultToggle {
				Divider().padding(.vertical, 4)
				Toggle("Use for New Chats", isOn: isDefaultForNewChats)
					.padding(.horizontal, horizontalPadding)
					.padding(.vertical, 6)
			}
		}
		.padding(.vertical, 8)
		.frame(width: 240)
		.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
		.presentationBackground(.clear)
		// A chat left on a retired version has to be able to see itself, and the
		// group it lives in is closed by default.
		.onAppear {
			showsOlder = olderModels.contains { $0.id == displayedModelID }
		}
	}

	/// The one header in the popover that's also a control — the group under it
	/// is the only one that opens.
	private var olderHeader: some View {
		Button {
			withAnimation(.snappy(duration: 0.15)) { showsOlder.toggle() }
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "chevron.right")
					.font(.caption2)
					.rotationEffect(.degrees(showsOlder ? 90 : 0))
					.frame(width: 16, height: 16)
				Text("Other Models")
					.font(.caption)
					.fontWeight(.medium)
				Spacer(minLength: 0)
			}
			.foregroundStyle(.secondary)
			.padding(.horizontal, horizontalPadding)
			.padding(.top, 6)
			.padding(.bottom, 2)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	@ViewBuilder
	private func section<Icon: View>(icon: Icon, title: String, models: [GenerativeChatModel]) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 6) {
				icon.frame(width: 16, height: 16)
				Text(title)
					.font(.caption)
					.fontWeight(.medium)
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, horizontalPadding)
			.padding(.top, 6)
			.padding(.bottom, 2)

			ForEach(models, content: row)
		}
	}

	@ViewBuilder
	private func row(_ model: GenerativeChatModel) -> some View {
		let isPrivateCloud = model.id == GenerativeChatModel.privateCloud.id
		let isAvailable = isPrivateCloud || capabilities(model).availabilityState == .available
		let isSelected = model.id == displayedModelID

		Button {
			onSelect(model)
		} label: {
			HStack {
				Text(model.displayName)
				Spacer()
				if isSelected {
					Image(systemName: "checkmark")
						.fontWeight(.semibold)
				}
			}
			.foregroundStyle(isAvailable ? .primary : .secondary)
			.padding(.leading, rowIndent)
			.padding(.trailing, horizontalPadding)
			.padding(.vertical, 6)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!isAvailable)
	}
}
