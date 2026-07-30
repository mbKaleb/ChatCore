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

struct AppView: View {

	@Environment(\.modelContext) private var modelContext
	@Environment(ModelManager.self) private var manager
	@Query(sort: \Conversation.createdAt, order: .reverse) var conversations: [Conversation]

	@State private var selectedIDs: Set<UUID> = []
	@State private var columnVisibility: NavigationSplitViewVisibility = .all

	@State private var focusInputOnNextChat = false

	@AppStorage(Defaults.Key.defaultModelID) private var defaultModelID = GenerativeChatModel.onDevice.id

	@State private var promptICloudSignIn = false

	@State private var lastSidebarToggle: ContinuousClock.Instant?

	private static let sidebarToggleCooldown: Duration = .milliseconds(400)

	private var sidebarOpen: Bool { columnVisibility != .detailOnly }

	private var conversation: Conversation? {
		guard selectedIDs.count == 1 else { return nil }
		return conversations.first { selectedIDs.contains($0.id) }
	}

	private var displayedModelID: GenerativeChatModel.ID {
		conversation?.modelID ?? defaultModelID
	}

	var body: some View {
		let _ = Self.printChanges()
		NavigationSplitView(columnVisibility: $columnVisibility) {
			ConversationSidebar(selectedIDs: $selectedIDs, onNewConversation: newConversation)
		} detail: {
			ConversationDetail(
				selectedIDs: selectedIDs,
				conversation: conversation,
				sidebarOpen: sidebarOpen,
				focusInputOnAppear: $focusInputOnNextChat
			)
				.scrollEdgeEffectHidden(true, for: .top)
				.toolbar {
					ToolbarItem(placement: .principal) {
						ModelBadge(conversation: conversation, defaultModelID: $defaultModelID)
					}

					ToolbarItem(placement: .primaryAction) {
						StatusIndicator(model: manager.model(withID: displayedModelID) ?? .onDevice)
					}
				}
		}
		.task {
			if FileManager.default.ubiquityIdentityToken == nil {
				promptICloudSignIn = true
			}
		}
		.alert("Sign in to iCloud", isPresented: $promptICloudSignIn) {
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
		.focusedSceneValue(\.toggleSidebar, toggleSidebar)
	}

	func toggleSidebar() {
		let now = ContinuousClock.now
		if let last = lastSidebarToggle, now - last < Self.sidebarToggleCooldown { return }
		lastSidebarToggle = now
		columnVisibility = sidebarOpen ? .detailOnly : .all
	}

	func newConversation() {
		var config = Chat.default
		config.modelID = defaultModelID
		let convo = Conversation(config: config)
		modelContext.insert(convo)
		focusInputOnNextChat = true
		selectedIDs = [convo.id]
	}
}

// MARK: - Conversation Sidebar

private struct ConversationSidebar: View {
	@Binding var selectedIDs: Set<UUID>
	var onNewConversation: () -> Void

	@State private var searchText = ""
	@State private var debouncedSearch = ""

	@FocusState private var focus: SidebarFocus?

	private static let searchDebounce: Duration = .milliseconds(200)

	var body: some View {
		let _ = Self.printChanges()
		ConversationList(
			search: debouncedSearch,
			selectedIDs: $selectedIDs,
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
private struct ConversationDetail: View {
	var selectedIDs: Set<UUID>
	var conversation: Conversation?
	var sidebarOpen: Bool
	@Binding var focusInputOnAppear: Bool

	var body: some View {
		let _ = Self.printChanges()
		ZStack {
			if selectedIDs.count > 1 {
				Text("\(selectedIDs.count) conversations selected")
					.foregroundStyle(.secondary)
			} else if let conversation {
				ChatView(conversation: conversation, sidebarOpen: sidebarOpen, focusInputOnAppear: $focusInputOnAppear)
			} else {
				Text("Select or start a conversation")
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.frame(minWidth: 480, minHeight: 360)
	}
}

// MARK: - Model Badge

private struct ModelBadge: View {

	@Environment(ModelManager.self) private var manager
	var conversation: Conversation?
	@Binding var defaultModelID: String

	@State private var showPicker = false

	private var appleModels: [GenerativeChatModel] {
		manager.chatModels.filter { $0.dataResidency != .cloud }
	}

	private var otherModels: [GenerativeChatModel] {
		manager.chatModels.filter { $0.dataResidency == .cloud }
	}

	private var displayedModelID: GenerativeChatModel.ID {
		conversation?.modelID ?? defaultModelID
	}

	private var badgeModelName: String {
		manager.model(withID: displayedModelID)?.displayName ?? displayedModelID
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
		}
		.buttonStyle(.plain)
		.fixedSize()
		.popover(isPresented: $showPicker, arrowEdge: .bottom) {
			ModelPickerPopover(
				appleModels: appleModels,
				otherModels: otherModels,
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
	var otherModels: [GenerativeChatModel]
	var displayedModelID: GenerativeChatModel.ID
	var showsDefaultToggle: Bool
	var isDefaultForNewChats: Binding<Bool>
	var capabilities: (GenerativeChatModel) -> ModelCapabilities
	var onSelect: (GenerativeChatModel) -> Void

	private let horizontalPadding: CGFloat = 14
	private let rowIndent: CGFloat = 14 + 16 + 6

	var body: some View {
		let _ = Self.printChanges()
		VStack(alignment: .leading, spacing: 0) {
			section(icon: Image(systemName: "apple.intelligence"), title: "Apple", models: appleModels)

			if !otherModels.isEmpty {
				Divider().padding(.vertical, 4)
				section(icon: Image("ClaudeIcon").resizable().scaledToFit(), title: "Claude", models: otherModels)
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
