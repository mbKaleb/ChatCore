//
//  AppView.swift
//  ChatCore
//

import SwiftUI
import SwiftData

// MARK: - Focused Menu Actions

struct DeleteConversationsAction {
	var isEnabled: Bool
	var perform: () -> Void
}

private struct NewChatKey: FocusedValueKey { typealias Value = () -> Void }
private struct ToggleSidebarKey: FocusedValueKey { typealias Value = () -> Void }
private struct FindChatKey: FocusedValueKey { typealias Value = () -> Void }
private struct DeleteConversationsKey: FocusedValueKey { typealias Value = DeleteConversationsAction }

extension FocusedValues {
	var newChat: (() -> Void)? {
		get { self[NewChatKey.self] }
		set { self[NewChatKey.self] = newValue }
	}
	var toggleSidebar: (() -> Void)? {
		get { self[ToggleSidebarKey.self] }
		set { self[ToggleSidebarKey.self] = newValue }
	}
	var findChat: (() -> Void)? {
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
	@AppStorage(Defaults.Key.defaultModelID) private var defaultModelID = GenerativeChatModel.onDevice.id

	@State private var model = AppModel()

	var body: some View {
		let _ = Self.printChanges()
		@Bindable var model = model
		NavigationSplitView(columnVisibility: $model.columnVisibility) {
			ConversationSidebar(onNewConversation: newConversation)
		} detail: {
			ConversationDetail()
				.scrollEdgeEffectHidden(true, for: .top)
		}
		.environment(model)
		.task {
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
		.focusedSceneValue(\.newChat, newConversation)
		.focusedSceneValue(\.toggleSidebar, model.toggleSidebar)
		.background { TextSizeShortcuts() }
	}

	private func newConversation() {
		model.newConversation(in: modelContext, defaultModelID: defaultModelID)
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
		.focusedSceneValue(\.findChat) { focus = .search }
	}
}

private struct ConversationList: View {
	@Environment(\.modelContext) private var modelContext
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
			table.target = coordinator
			table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
		}
	}

	final class Coordinator: NSObject {
		var onDoubleClick: (Int) -> Void

		init(onDoubleClick: @escaping (Int) -> Void) {
			self.onDoubleClick = onDoubleClick
		}

		@objc func handleDoubleClick(_ sender: NSTableView) {
			let row = sender.clickedRow
			guard row >= 0 else { return }
			MainActor.assumeIsolated { onDoubleClick(row) }
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

	/// Read here rather than inside `ChatView`, which takes the renderer it is
	/// told to use and leaves where that came from to its caller.
	@AppStorage(Defaults.Key.transcriptRenderer) private var rendererID = TranscriptRenderer.default.rawValue

	var body: some View {
		let _ = Self.printChanges()
		ZStack {
			if model.selectedIDs.count > 1 {
				Text("\(model.selectedIDs.count) conversations selected")
					.foregroundStyle(.secondary)
			} else if let conversation = model.selectedConversation {
				ChatView(
					conversation: conversation,
					renderer: TranscriptRenderer(storedID: rendererID)
				)
			} else {
				Text("Select or start a conversation")
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.frame(minWidth: 480, minHeight: 360)
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
