import SwiftUI
import AppKit
import MarkdownUI

struct MessageBubble: View {
	let message: Message

	@Environment(ModelManager.self) private var manager
	@Environment(ThemeManager.self) private var themes
	@AppStorage(Defaults.Key.streamingMode) private var streamingModeRaw = StreamingMode.token.rawValue
	@State private var isHovering = false
	@State private var didCopy = false

	private var liveText: String? {
		manager.liveText[message.id]
	}

	private var streamingMode: StreamingMode {
		StreamingMode(rawValue: streamingModeRaw) ?? .token
	}

	private var streamingChunks: [StreamChunk]? {
		guard streamingMode == .token, liveText != nil else { return nil }
		let chunks = manager.liveChunks[message.id] ?? []
		return chunks.isEmpty ? nil : chunks
	}

	private var displayText: String {
		liveText ?? message.text
	}

	private var isAssistant: Bool { message.role != "user" }

	private var isEmpty: Bool {
		message.attachments.isEmpty
			&& displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	var body: some View {
		let _ = Self.printChanges()

		if isEmpty {
			Color.clear.frame(height: 0)
		} else {
			HStack(spacing: 0) {
				if message.role == "user" {
					Spacer(minLength: 5)
					VStack(alignment: .trailing, spacing: 0) {
						bubble
						copyButton.opacity(isHovering ? 1 : 0)
					}
				} else {
					VStack(alignment: .leading, spacing: 0) {
						bubble
						copyButton.opacity(isHovering ? 1 : 0)
					}
					.padding(.vertical, 4)
					Spacer(minLength: 5)
				}
			}
			.onHover { hovering in
				isHovering = hovering
			}
			.animation(.easeInOut(duration: 0.12), value: isHovering)
		}
	}

	private var bubble: some View {
		let t = themes.theme
		let a = themes.appearance
		return VStack(alignment: isAssistant ? .leading : .trailing, spacing: 8) {
			if !message.attachments.isEmpty {
				HStack(spacing: 8) {
					ForEach(message.attachments) { attachment in
						AttachmentChip(attachment: attachment)
					}
				}
			}

			if !displayText.isEmpty {
				textContainer(t, a)
			}
		}
	}

	@ViewBuilder
	private func textContainer(_ t: ChatTheme, _ a: ChatAppearance) -> some View {
		Group {
			if message.role == "user" {
				Text(displayText)
					.font(a.bodyFont.font(size: a.fontSize))
					.lineSpacing(a.lineSpacing)
			} else if let streamingChunks {
				StreamingTextView(
					chunks: streamingChunks,
					font: a.bodyFont,
					fontSize: a.fontSize,
					lineSpacing: a.lineSpacing,
					color: t.bodyText
				)
			} else {
				Markdown(
					MarkdownContentCache.content(
						for: message,
						overrideText: liveText,
						rendersMath: a.rendersMath
					)
				)
				.chatMarkdownStyle(t, a)
			}
		}
		.padding(.horizontal, isAssistant ? 18 : 15)
		.padding(.vertical, isAssistant ? 14 : 11)
		.background(isAssistant ? t.assistantBubble : t.userBubble)
		.foregroundStyle(isAssistant ? t.bodyText : t.userText)
		.clipShape(RoundedRectangle(cornerRadius: 12))
	}

	private var copyButton: some View {
		Button(action: copy) {
			Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(width: 16, height: 16)
				.padding(15)
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.help("Copy message")
		.disabled(didCopy)
	}

	private func copy() {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()

		var items: [NSPasteboardWriting] = []
		let text = message.attachments.composedPrompt(with: displayText)
		if !text.isEmpty {
			items.append(text as NSString)
		}

		for attachment in message.attachments.images {
			guard let data = attachment.imageData, let type = attachment.imageType else { continue }
			let item = NSPasteboardItem()
			item.setData(data, forType: NSPasteboard.PasteboardType(type))
			items.append(item)
		}

		guard !items.isEmpty else { return }
		pasteboard.writeObjects(items)

		didCopy = true

		Task {
			try? await Task.sleep(for: .seconds(1.2))
			didCopy = false
		}
	}
}
