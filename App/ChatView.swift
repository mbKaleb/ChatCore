import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

import MarkdownUI

struct ChatView: View {
	@Environment(ModelManager.self) private var manager
	/// The sidebar state and the pending-focus flag are read here rather than
	/// handed down: routing them through `ConversationDetail` made that view —
	/// and the toolbar it declares — re-render on every sidebar toggle, for a
	/// value only this one reacts to.
	@Environment(AppModel.self) private var app
	@Bindable var conversation: Conversation
	/// How the transcript is drawn. Passed in rather than read from settings
	/// here, so this view has no opinion about which renderers exist.
	var renderer: TranscriptRenderer
	@State private var composer = ComposerState()
	@State private var showFileImporter = false
	@State private var isDropTargeted = false
	@State private var scrollToBottomToken = 0
	@State private var composeHeight: CGFloat = 0
	@FocusState private var inputFocused: Bool

	@State private var sortedMessagesCache: [Message] = []

	/// Which conversation `sortedMessagesCache` was built from.
	@State private var cachedConversationID: UUID?

	/// The transcript, oldest first. Served from the cache except on the one
	/// frame where the conversation has changed under the view but `onChange`
	/// hasn't caught the cache up yet — sorting fresh there keeps that frame
	/// from handing the new renderer the *previous* chat's messages to build,
	/// measure, and throw away.
	private var sortedMessages: [Message] {
		cachedConversationID == conversation.id
			? sortedMessagesCache
			: Self.sortedByTimestamp(conversation.messages)
	}

	/// Ties broken by id: `sorted` isn't stable, so two messages minted in the
	/// same instant could swap order between rebuilds.
	private static func sortedByTimestamp(_ messages: [Message]) -> [Message] {
		messages.sorted {
			$0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.id < $1.id
		}
	}

	private func rebuildCache() {
		sortedMessagesCache = Self.sortedByTimestamp(conversation.messages)
		cachedConversationID = conversation.id
	}

	private var isResponding: Bool {
		guard let last = sortedMessages.last else { return false }
		return manager.generatingMessageIDs.contains(last.id)
	}

	private var isSelectingText: Bool {
		guard let event = NSApp.currentEvent else { return false }
		switch event.type {
		case .leftMouseDown, .leftMouseUp,
			 .rightMouseDown, .rightMouseUp,
			 .otherMouseDown, .otherMouseUp:
			return event.clickCount > 1
		default:
			return false
		}
	}

	var body: some View {
		let _ = Self.printChanges()
		ZStack(alignment: .bottom) {
			renderer.transcript(
				TranscriptContext(
					conversationID: conversation.id,
					messages: sortedMessages,
					scrollOffsetFromBottom: $conversation.scrollOffsetFromBottom,
					scrollToBottomToken: scrollToBottomToken,
					bottomInset: composeHeight
				)
			)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.id(conversation.id)

			Composer(
				state: composer,
				isResponding: isResponding,
				isDropTargeted: isDropTargeted,
				focus: $inputFocused,
				height: $composeHeight,
				onSend: { Task { await send() } },
				onStop: stopResponding,
				onAttach: { showFileImporter = true }
			)
		}
		.background {
			BackendWatermark(
				logoName: manager.logoName(for: conversation.modelID),
				isEmpty: sortedMessages.isEmpty
			)
		}
		.background { PasteImageCatcher(onPaste: acceptImages(from:)) }
		.contentShape(Rectangle())
		.onDrop(of: Self.dropTypes, isTargeted: $isDropTargeted) { providers in
			acceptDrop(providers)
		}
		.animation(.easeInOut(duration: 0.15), value: isDropTargeted)
		.onKeyPress(.escape) {
			guard isResponding else { return .ignored }
			stopResponding()
			return .handled
		}
		.simultaneousGesture(TapGesture().onEnded {
			guard !isSelectingText else { return }
			inputFocused = true
		})
		.fileImporter(
			isPresented: $showFileImporter,
			allowedContentTypes:
				[.plainText, .text, .sourceCode, .json, .commaSeparatedText]
				+ AttachmentImage.readableTypes,
			allowsMultipleSelection: false
		) { result in
			importFile(result)
		}
		.onAppear {
			if cachedConversationID != conversation.id { rebuildCache() }
			app.registerComposer(composer, for: conversation.id)
			loadDraft()
			claimPendingFocus()
		}
		// Multi-select or an emptied selection replaces this view with a
		// placeholder; whatever was mid-composition waits in the store.
		.onDisappear {
			stashDraft(for: conversation.id)
			app.unregisterComposer(composer)
		}
		.onChange(of: conversation.id) { oldID, newID in
			stashDraft(for: oldID)
			app.registerComposer(composer, for: newID)
			loadDraft()
			rebuildCache()
			claimPendingFocus()
		}
		// The cache mirrors the store, and the store has writers this view
		// never sees run: a `send` captured by an instance that has since been
		// torn down and rebuilt still removes its failed exchange from
		// `conversation.messages`. Membership is all they change from outside,
		// so the count is the resync signal.
		.onChange(of: conversation.messages.count) {
			guard cachedConversationID == conversation.id,
			      sortedMessagesCache.count != conversation.messages.count else { return }
			rebuildCache()
		}
		.onChange(of: app.sidebarOpen) {
			if !app.sidebarOpen { inputFocused = true }
		}
		// Presented from the model's per-chat store rather than local state:
		// the reporter may be a task whose view is long gone, and an error
		// for another chat should wait for that chat, not pop over this one.
		// Clearing on dismissal drops the whole entry — including the
		// suggests-settings flag that used to survive into the next,
		// unrelated error's alert.
		.alert(
			"Oops!",
			isPresented: Binding(
				get: { app.chatErrors[conversation.id] != nil },
				set: { presented in
					if !presented { app.clearChatError(for: conversation.id) }
				}
			)
		) {
			if app.chatErrors[conversation.id]?.suggestsSettings == true {
				Button("Open System Settings") {
					if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
						NSWorkspace.shared.open(url)
					}
				}
			}
			Button("OK", role: .cancel) { }
		} message: {
			Text(app.chatErrors[conversation.id]?.message ?? "Something went wrong.")
		}
	}

	/// Take the focus a freshly created chat was promised, once.
	///
	/// The flag is cleared on the way through: `newConversation` sets it and
	/// whichever of appear-or-id-change happens first honours it.
	private func claimPendingFocus() {
		guard app.focusInputOnNextChat else { return }
		app.focusInputOnNextChat = false
		inputFocused = true
	}

	// MARK: - Drafts

	/// Swap this chat's stashed draft into the compose bar.
	private func loadDraft() {
		let draft = app.takeDraft(for: conversation.id)
		composer.setText(draft.text)
		composer.attachments = draft.attachments
	}

	private func stashDraft(for id: UUID) {
		app.stashDraft(
			ChatDraft(text: composer.text, attachments: composer.attachments),
			for: id
		)
	}

	/// The conversation's own model, or nothing.
	///
	/// There is deliberately no substitute here. The pinned model can vanish —
	/// a failed catalog fetch, a removed key, a model the vendor retired — and
	/// falling back to whatever else is loaded silently answers on a different
	/// vendor's model than the one the user chose, on-device instead of cloud,
	/// with nothing on screen to say so.
	private var resolvedModel: GenerativeChatModel? {
		manager.model(withID: conversation.modelID)
	}

	private func isCloudUnavailable(_ error: Error) -> Bool {
		let cloudID = GenerativeChatModel.privateCloud.id
		if case ModelManagerError.modelUnavailable(let id) = error { return id == cloudID }
		if case ChatBackendError.modelUnavailable(let id) = error { return id == cloudID }
		return false
	}

	private func turns(upTo lastCount: Int) -> [ChatTurn] {
		var imageIndex = 0
		return sortedMessages.prefix(lastCount).map { message in
			let images = message.attachments.compactMap { attachment -> ChatImage? in
				guard let data = attachment.imageData else { return nil }
				imageIndex += 1
				return ChatImage(
					data: data,
					label: "image-\(imageIndex)",
					title: attachment.title
				)
			}
			return ChatTurn(
				role: ChatTurn.Role(rawValue: message.role) ?? .user,
				content: message.attachments.composedPrompt(with: message.text),
				images: images
			)
		}
	}

	private func importFile(_ result: Result<[URL], Error>) {
		guard case .success(let urls) = result else { return }
		importFiles(urls, for: conversation.id)
	}

	private static let dropTypes: [UTType] =
		[.fileURL] + AttachmentImage.readableTypes + [.image, .plainText]

	private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
		var handled = false

		// Stamped now, delivered later: providers complete whenever their app
		// materializes the data — seconds, for a file promise — and by then
		// the user may be composing in a different chat. Everything below
		// stages for the chat the drop landed on, wherever its draft is then.
		let targetID = conversation.id

		for provider in providers {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				handled = true
				_ = provider.loadObject(ofClass: URL.self) { url, _ in
					guard let url else { return }
					Task { @MainActor in importFiles([url], for: targetID) }
				}
				continue
			}

			let name = provider.suggestedName

			if let identifier = imageTypeIdentifier(for: provider) {
				handled = true
				provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
					Task { @MainActor in stageDroppedImage(data, name: name, for: targetID) }
				}
				continue
			}

			if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
				handled = true
				provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
					let data = url.flatMap { try? Data(contentsOf: $0) }
					Task { @MainActor in
						stageDroppedImage(data, name: name ?? url?.lastPathComponent, for: targetID)
					}
				}
				continue
			}

			// A run of selected text dragged straight from another app — no
			// file behind it, so none of the branches above claim it.
			guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { continue }
			handled = true
			_ = provider.loadObject(ofClass: String.self) { text, _ in
				guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
				Task { @MainActor in
					app.stageAttachment(MessageAttachment(title: "Dropped Text", text: text), for: targetID)
				}
			}
		}

		return handled
	}

	private func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
		AttachmentImage.readableTypes
			.map(\.identifier)
			.first { provider.hasItemConformingToTypeIdentifier($0) }
	}

	@MainActor
	private func stageDroppedImage(_ data: Data?, name: String?, for targetID: UUID) {
		guard
			let data,
			let attachment = MessageAttachment(imageData: data, title: name ?? "Dropped Image")
		else {
			app.reportChatError(ChatError(message: "Couldn't read that image."), for: targetID)
			return
		}
		app.stageAttachment(attachment, for: targetID)
	}

	/// Reads and image decodes happen off the main thread — done inline, a
	/// dropped gigabyte of log beachballed the app for the whole read.
	private func importFiles(_ urls: [URL], for targetID: UUID) {
		Task {
			let outcomes = await Task.detached(priority: .userInitiated) {
				urls.map(AttachmentImport.load)
			}.value
			stageImports(outcomes, for: targetID)
		}
	}

	@MainActor
	private func stageImports(_ outcomes: [AttachmentImport.Outcome], for targetID: UUID) {
		var unreadable: [String] = []
		var tooLarge: [String] = []
		for outcome in outcomes {
			switch outcome {
			case .attachment(let attachment): app.stageAttachment(attachment, for: targetID)
			case .unreadable(let name): unreadable.append(name)
			case .tooLarge(let name): tooLarge.append(name)
			}
		}
		if let failure = AttachmentImport.failureMessage(unreadable: unreadable, tooLarge: tooLarge) {
			app.reportChatError(ChatError(message: failure), for: targetID)
		}
	}

	@MainActor
	private func acceptImages(from pasteboard: NSPasteboard) -> Bool {
		guard pasteboard.containsImages else { return false }

		let attachments = pasteboard.imageAttachments()
		guard !attachments.isEmpty else {
			app.reportChatError(ChatError(message: "Couldn't read that image."), for: conversation.id)
			return true
		}
		for attachment in attachments {
			composer.add(attachment)
		}
		return true
	}

	@MainActor
	private func stopResponding() {
		guard let last = sortedMessages.last, manager.isGenerating(last.id) else { return }
		manager.cancelGeneration(for: last.id)
	}

	@MainActor
	func send() async {
		let typed = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
		let attachments = composer.attachments
		let prompt = attachments.composedPrompt(with: typed)
		guard !prompt.isEmpty || !attachments.images.isEmpty else { return }
		composer.setText("")
		composer.attachments = []

		let sentConversationID = conversation.id

		let userMsg = Message(role: "user", text: typed, attachments: attachments)
		conversation.messages.append(userMsg)
		sortedMessagesCache.append(userMsg)

		let assistantMsg = Message(role: "assistant", text: "")
		conversation.messages.append(assistantMsg)
		sortedMessagesCache.append(assistantMsg)

		scrollToBottomToken += 1

		let history = turns(upTo: sortedMessages.count - 1)

		manager.beginGeneration(for: assistantMsg.id, in: sentConversationID)

		do {
			guard let model = resolvedModel else {
				throw ModelManagerError.modelUnavailable(conversation.modelID)
			}
			let stream = manager.reply(to: history, using: model, options: conversation.options)

			let streaming = Task { @MainActor () throws -> String in
				var latest = ""
				var lastVisualFlush = Date.distantPast
				let minVisualFlushInterval: TimeInterval = 1.0 / 20
				var lastPersistFlush = Date.distantPast
				let minPersistFlushInterval: TimeInterval = 1.0

				// Both throttles below skip everything that lands inside their last
				// interval, so the tail has to be pushed once the stream is done.
				// A `defer` rather than a line after the loop: cancelling mid-turn
				// throws out of the loop, and that partial text is still kept.
				defer {
					manager.updateGeneration(assistantMsg.id, text: latest)
					manager.recordChunk(latest, for: assistantMsg.id)
					assistantMsg.text = latest
				}

				for try await event in stream {
					switch event {
					case .thinking(let thinking):
						// Already paced by the backend's transcript poll, so no
						// throttle of its own.
						manager.updateThinking(assistantMsg.id, text: thinking)
					case .content(let snapshot):
						latest = snapshot
						let now = Date()
						if now.timeIntervalSince(lastVisualFlush) >= minVisualFlushInterval {
							manager.updateGeneration(assistantMsg.id, text: latest)
							manager.recordChunk(latest, for: assistantMsg.id)
							lastVisualFlush = now
						}
						if now.timeIntervalSince(lastPersistFlush) >= minPersistFlushInterval {
							assistantMsg.text = latest
							lastPersistFlush = now
						}
					}
				}
				return latest
			}
			manager.registerCancellation(for: assistantMsg.id) { streaming.cancel() }

			assistantMsg.text = try await streaming.value
		} catch {
			let latest = manager.liveText[assistantMsg.id] ?? assistantMsg.text
			assistantMsg.text = latest

			// A deliberate stop isn't a failure: the prompt was answered as far
			// as the user wanted. Backends that end the stream quietly on cancel
			// never reach this catch; this evens out the ones that throw.
			let cancelled = error is CancellationError

			// Everything user-facing below goes through the model, keyed by the
			// sent chat, never through this view's own state: this method runs
			// on a copy captured at send time, and by now the sent chat may be
			// showing through a rebuilt view — or not at all. The model knows
			// where that chat's draft lives and holds its error until it's on
			// screen; a copy of dead `@State` can't reach either. The cache
			// writes are safe on any copy — removing ids that aren't there is a
			// no-op, and a live view that missed them resyncs off the store's
			// message count.
			if assistantMsg.text.isEmpty, !cancelled {
				conversation.messages.removeAll { $0.id == assistantMsg.id || $0.id == userMsg.id }
				sortedMessagesCache.removeAll { $0.id == assistantMsg.id || $0.id == userMsg.id }
				app.restoreDraft(text: typed, attachments: attachments, for: sentConversationID)
			}
			if !cancelled {
				let failure = isCloudUnavailable(error)
					? ChatError(
						message: "Private Cloud isn't available right now. Make sure you're signed in to your Apple Account and Apple Intelligence is enabled.",
						suggestsSettings: true
					)
					: ChatError(message: error.localizedDescription)
				app.reportChatError(failure, for: sentConversationID)
			}
		}

		if assistantMsg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			conversation.messages.removeAll { $0.id == assistantMsg.id }
			sortedMessagesCache.removeAll { $0.id == assistantMsg.id }
		}

		manager.endGeneration(for: assistantMsg.id)

		// "First completed exchange", not "exactly two messages": a stop
		// before the first token leaves an odd count behind, and an exact
		// count would then never title the chat at all.
		if conversation.title == Conversation.untitledTitle,
		   conversation.messages.contains(where: { $0.role == "assistant" }) {
			await generateTitle(from: prompt, images: history.last?.images ?? [])
		}
	}

	@MainActor
	private func generateTitle(from prompt: String, images: [ChatImage] = []) async {
		guard let model = resolvedModel else { return }
		let subject = prompt.isEmpty
			? "an image the user sent with no message"
			: "the user saying: \"\(prompt)\""
		let titlePrompt = "Give a 3-word title for a conversation that starts with \(subject). Reply with only the title, no punctuation."
		var title = ""
		do {
			let stream = manager.reply(
				to: [ChatTurn(role: .user, content: titlePrompt, images: images)],
				using: model
			)
			for try await event in stream {
				if case .content(let snapshot) = event { title = snapshot }
			}
		} catch {
			return
		}
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		if !trimmed.isEmpty { conversation.title = trimmed }
	}
}

// MARK: - File import

/// The file-to-attachment pipeline, deliberately off the main actor: reads,
/// text decoding, and image normalization all run wherever the caller puts
/// them — `importFiles` puts them on a detached task.
private nonisolated enum AttachmentImport {

	/// Past this, a file isn't a chat attachment — it's a context window all
	/// by itself — and reading it in would stall even the background hop.
	static let maxFileBytes = 20 << 20

	enum Outcome {
		case attachment(MessageAttachment)
		case unreadable(String)
		case tooLarge(String)
	}

	static func load(_ url: URL) -> Outcome {
		let name = url.lastPathComponent
		guard url.isFileURL else { return .unreadable(name) }

		let didAccess = url.startAccessingSecurityScopedResource()
		defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

		if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
		   size > maxFileBytes {
			return .tooLarge(name)
		}

		if AttachmentImage.isReadable(AttachmentImage.type(of: url)) {
			guard
				let data = try? Data(contentsOf: url),
				let attachment = MessageAttachment(imageData: data, title: name)
			else { return .unreadable(name) }
			return .attachment(attachment)
		}

		guard let text = decodeText(url) else { return .unreadable(name) }
		return .attachment(MessageAttachment(title: name, text: text))
	}

	/// UTF-8 first, since that's what nearly everything is; then whatever the
	/// file declares for itself; then Latin-1, which maps every byte rather
	/// than rejecting a readable file outright.
	private static func decodeText(_ url: URL) -> String? {
		if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
		var detected = String.Encoding.utf8
		if let text = try? String(contentsOf: url, usedEncoding: &detected) { return text }
		guard let data = try? Data(contentsOf: url) else { return nil }
		return String(data: data, encoding: .isoLatin1)
	}

	static func failureMessage(unreadable: [String], tooLarge: [String]) -> String? {
		switch (unreadable.count, tooLarge.count) {
		case (0, 0): return nil
		case (1, 0): return "Couldn't read \u{201C}\(unreadable[0])\u{201D}."
		case (0, 1): return "\u{201C}\(tooLarge[0])\u{201D} is too large to attach."
		case (_, 0): return "Couldn't read \(unreadable.count) of those files."
		case (0, _): return "Those files are too large to attach."
		default: return "Couldn't attach \(unreadable.count + tooLarge.count) of those files."
		}
	}
}

private struct BackendWatermark: View {
	var logoName: String?
	var isEmpty: Bool

	var body: some View {
		let _ = Self.printChanges()
		Group {
			if isEmpty {
				watermarkImage
					.opacity(0.08)
					.transition(.opacity)
			}
		}
		.animation(.easeOut(duration: 0.5), value: isEmpty)
	}

	@ViewBuilder
	private var watermarkImage: some View {
		let name = logoName ?? "apple.intelligence"
		if name == "ClaudeLogo" {
			Image("ClaudeIcon")
				.resizable()
				.scaledToFit()
				.frame(width: 120, height: 120)
		} else {
			Image(systemName: name)
				.font(.system(size: 120))
				.foregroundStyle(.secondary)
		}
	}
}

#Preview {
	struct PreviewContainer: View {
		@State private var app = AppModel()
		@State private var renderer = TranscriptRenderer.default

		private let conversation: Conversation = {
			var config = Chat.default
			config.modelID = GenerativeChatModel.privateCloud.id
			return Conversation(config: config)
		}()

		var body: some View {
			ChatView(
				conversation: conversation,
				renderer: renderer
			)
			.environment(app)
			.environment(ModelManager())
			.environment(ThemeManager())
			// Its own control rather than the stored preference: the preview is
			// where two renderers get held against each other, and switching
			// here doesn't disturb what the running app is set to.
			.overlay(alignment: .topTrailing) {
				Picker("Renderer", selection: $renderer) {
					ForEach(TranscriptRenderer.allCases) { renderer in
						Text(renderer.displayName).tag(renderer)
					}
				}
				.pickerStyle(.menu)
				.labelsHidden()
				.fixedSize()
				.padding(8)
			}
		}
	}

	return PreviewContainer()
}
