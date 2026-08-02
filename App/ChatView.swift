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
	@State private var input: String = ""
	@State private var pastedAttachments: [MessageAttachment] = []
	@State private var showFileImporter = false
	@State private var isDropTargeted = false
	@State private var scrollToBottomToken = 0
	@State private var composeHeight: CGFloat = 0
	@State private var errorMessage: String?
	@State private var errorSuggestsSettings = false
	@FocusState private var inputFocused: Bool

	@State private var sortedMessagesCache: [Message] = []

	private var sortedMessages: [Message] { sortedMessagesCache }

	private var isResponding: Bool {
		guard let last = sortedMessages.last else { return false }
		return manager.generatingMessageID == last.id
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

			GlassEffectContainer(spacing: 8) {
				VStack(alignment: .leading, spacing: 8) {
					if !pastedAttachments.isEmpty || isDropTargeted {
						attachmentsTray
					}

					HStack(spacing: 8) {
						Button { showFileImporter = true } label: {
							Image(systemName: "plus")
								.font(.title3)
								.frame(width: 34, height: 34)
								.contentShape(Circle())
						}
						.buttonStyle(.plain)
						.glassEffect(.clear, in: .rect(cornerRadius: 20))
						.help("Attach a file")

						HStack(alignment: .center, spacing: 8) {
							TextField("Message", text: $input, axis: .vertical)
								.textFieldStyle(.plain)
								.scrollContentBackground(.hidden)
								.focused($inputFocused)
								.onSubmit {
									guard !isResponding else { return }
									Task { await send() }
								}
								.onKeyPress(.return, phases: .down) { press in
									guard press.modifiers.contains(.shift) else { return .ignored }
									input.insert(contentsOf: "\n", at: input.endIndex)
									return .handled
								}
								.onKeyPress(.escape) {
									guard isResponding else { return .ignored }
									stopResponding()
									return .handled
								}
								.onChange(of: input) { oldValue, newValue in
									guard let pasted = pastedChunk(from: oldValue, to: newValue) else { return }
									input = oldValue
									addAttachment(MessageAttachment(text: pasted))
								}

							Button {
								if isResponding { stopResponding() } else { Task { await send() } }
							} label: {
								Image(systemName: isResponding ? "stop.circle.fill" : "arrow.up.circle.fill")
									.font(.system(size: 25))
									.contentTransition(.symbolEffect(.replace))
									.frame(width: 30, height: 30)
									.contentShape(Circle())
							}
							.buttonStyle(.plain)
							.disabled(!isResponding && input.isEmpty && pastedAttachments.isEmpty)
							.help(isResponding ? "Stop generating (Esc)" : "Send")
						}
						.padding(.leading, 13)
						.padding(.trailing, 4)
						.padding(.vertical, 4)
						.frame(maxWidth: .infinity)
						.glassEffect(.clear, in: .rect(cornerRadius: 19))
					}
				}
			}
			.padding()
			.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composeHeight = $0 }
		}
		.background {
			BackendWatermark(
				logoName: manager.logoName(for: conversation.modelID),
				isEmpty: sortedMessagesCache.isEmpty
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
			if sortedMessagesCache.isEmpty {
				sortedMessagesCache = conversation.messages.sorted { $0.timestamp < $1.timestamp }
			}
			claimPendingFocus()
		}
		.onChange(of: conversation.id) {
			input = ""
			errorMessage = nil
			errorSuggestsSettings = false
			sortedMessagesCache = conversation.messages.sorted { $0.timestamp < $1.timestamp }
			claimPendingFocus()
		}
		.onChange(of: app.sidebarOpen) {
			if !app.sidebarOpen { inputFocused = true }
		}
		.alert(
			"Oops!",
			isPresented: Binding(
				get: { errorMessage != nil },
				set: { if !$0 { errorMessage = nil } }
			)
		) {
			if errorSuggestsSettings {
				Button("Open System Settings") {
					if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
						NSWorkspace.shared.open(url)
					}
				}
			}
			Button("OK", role: .cancel) { errorSuggestsSettings = false }
		} message: {
			Text(errorMessage ?? "Something went wrong.")
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

	private func pastedChunk(from oldValue: String, to newValue: String) -> String? {
		guard newValue.count > oldValue.count else { return nil }

		let old = Array(oldValue)
		let new = Array(newValue)

		var prefix = 0
		while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
			prefix += 1
		}

		var suffix = 0
		let maxSuffix = min(old.count - prefix, new.count - prefix)
		while suffix < maxSuffix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
			suffix += 1
		}

		let insertedRange = prefix..<(new.count - suffix)
		guard insertedRange.count > 32 else { return nil }
		return String(new[insertedRange])
	}

	private func importFile(_ result: Result<[URL], Error>) {
		guard case .success(let urls) = result else { return }
		importFiles(urls)
	}

	private static let dropTypes: [UTType] =
		[.fileURL] + AttachmentImage.readableTypes + [.image]

	private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
		var handled = false

		for provider in providers {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				handled = true
				_ = provider.loadObject(ofClass: URL.self) { url, _ in
					guard let url else { return }
					Task { @MainActor in importFiles([url]) }
				}
				continue
			}

			let name = provider.suggestedName

			if let identifier = imageTypeIdentifier(for: provider) {
				handled = true
				provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
					Task { @MainActor in stageDroppedImage(data, name: name) }
				}
				continue
			}

			guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
			handled = true
			provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
				let data = url.flatMap { try? Data(contentsOf: $0) }
				Task { @MainActor in stageDroppedImage(data, name: name ?? url?.lastPathComponent) }
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
	private func stageDroppedImage(_ data: Data?, name: String?) {
		guard
			let data,
			let attachment = MessageAttachment(imageData: data, title: name ?? "Dropped Image")
		else {
			errorMessage = "Couldn't read that image."
			return
		}
		addAttachment(attachment)
	}

	@discardableResult
	private func importFiles(_ urls: [URL]) -> Bool {
		var unreadable: [String] = []

		for url in urls {
			guard url.isFileURL else {
				unreadable.append(url.lastPathComponent)
				continue
			}

			let didAccess = url.startAccessingSecurityScopedResource()
			defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

			if AttachmentImage.isReadable(AttachmentImage.type(of: url)) {
				guard
					let data = try? Data(contentsOf: url),
					let attachment = MessageAttachment(imageData: data, title: url.lastPathComponent)
				else {
					unreadable.append(url.lastPathComponent)
					continue
				}
				addAttachment(attachment)
				continue
			}

			guard let text = try? String(contentsOf: url, encoding: .utf8) else {
				unreadable.append(url.lastPathComponent)
				continue
			}
			addAttachment(MessageAttachment(title: url.lastPathComponent, text: text))
		}

		switch unreadable.count {
		case 0: break
		case 1: errorMessage = "Couldn't read \u{201C}\(unreadable[0])\u{201D}."
		default: errorMessage = "Couldn't read \(unreadable.count) of those files."
		}

		return unreadable.count < urls.count
	}

	@MainActor
	private func acceptImages(from pasteboard: NSPasteboard) -> Bool {
		guard pasteboard.containsImages else { return false }

		let attachments = pasteboard.imageAttachments()
		guard !attachments.isEmpty else {
			errorMessage = "Couldn't read that image."
			return true
		}
		for attachment in attachments {
			addAttachment(attachment)
		}
		return true
	}

	@MainActor
	private func addAttachment(_ attachment: MessageAttachment) {
		withAnimation(.smooth(duration: 0.34)) {
			pastedAttachments.append(attachment)
		}
	}

	@MainActor
	private func removeAttachment(_ attachment: MessageAttachment) {
		withAnimation(.smooth(duration: 0.28)) {
			pastedAttachments.removeAll { $0.id == attachment.id }
		}
	}

	// MARK: - Attachments tray

	private var attachmentsTray: some View {
		Group {
			if isDropTargeted {
				HStack(spacing: 8) {
					Image(systemName: "arrow.down.doc")
					Text("Drop here")
				}
				.font(.callout)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity)
				.frame(height: 48)
			} else {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 8) {
						ForEach(pastedAttachments) { attachment in
							AttachmentChip(attachment: attachment) {
								removeAttachment(attachment)
							}
							.transition(Self.chipTransition)
						}
					}
					.padding(6)
				}
				.fixedSize(horizontal: false, vertical: true)
			}
		}
		.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 18))
		.overlay {
			if isDropTargeted {
				RoundedRectangle(cornerRadius: 18)
					.strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
			}
		}
		.transition(Self.trayTransition)
	}

	private static let chipTransition: AnyTransition = .asymmetric(
		insertion: .scale(scale: 0.72)
			.combined(with: .opacity)
			.animation(.bouncy(duration: 0.38, extraBounce: 0.22)),
		removal: .opacity.animation(.easeOut(duration: 0.22))
	)

	private static let trayTransition: AnyTransition = .asymmetric(
		insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
		removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
	)

	@MainActor
	private func stopResponding() {
		guard let last = sortedMessages.last, manager.isGenerating(last.id) else { return }
		manager.cancelGeneration(for: last.id)
	}

	@MainActor
	func send() async {
		let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		let attachments = pastedAttachments
		let prompt = attachments.composedPrompt(with: typed)
		guard !prompt.isEmpty || !attachments.images.isEmpty else { return }
		input = ""
		pastedAttachments = []

		let sentConversationID = conversation.id

		let userMsg = Message(role: "user", text: typed, attachments: attachments)
		conversation.messages.append(userMsg)
		sortedMessagesCache.append(userMsg)

		let assistantMsg = Message(role: "assistant", text: "")
		conversation.messages.append(assistantMsg)
		sortedMessagesCache.append(assistantMsg)

		scrollToBottomToken += 1

		let history = turns(upTo: sortedMessages.count - 1)

		manager.beginGeneration(for: assistantMsg.id)

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

				for try await snapshot in stream {
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
				return latest
			}
			manager.registerCancellation(for: assistantMsg.id) { streaming.cancel() }

			assistantMsg.text = try await streaming.value
		} catch {
			let latest = manager.liveText[assistantMsg.id] ?? assistantMsg.text
			assistantMsg.text = latest
			if assistantMsg.text.isEmpty {
				conversation.messages.removeAll { $0.id == assistantMsg.id || $0.id == userMsg.id }
				sortedMessagesCache.removeAll { $0.id == assistantMsg.id || $0.id == userMsg.id }
				if conversation.id == sentConversationID {
					input = typed
					pastedAttachments = attachments
				}
			}
			if conversation.id == sentConversationID {
				if isCloudUnavailable(error) {
					errorSuggestsSettings = true
					errorMessage = "Private Cloud isn't available right now. Make sure you're signed in to your Apple Account and Apple Intelligence is enabled."
				} else {
					errorMessage = error.localizedDescription
				}
			}
		}

		if assistantMsg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			conversation.messages.removeAll { $0.id == assistantMsg.id }
			sortedMessagesCache.removeAll { $0.id == assistantMsg.id }
		}

		manager.endGeneration(for: assistantMsg.id)

		if conversation.title == "New Chat" && conversation.messages.count == 2 {
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
			for try await snapshot in stream { title = snapshot }
		} catch {
			return
		}
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		if !trimmed.isEmpty { conversation.title = trimmed }
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
