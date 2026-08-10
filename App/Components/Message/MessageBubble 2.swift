import SwiftUI
import AppKit
import MarkdownUI

/// Geometry a bubble commits to, shared with the list's height estimator.
///
/// The estimator has to predict this layout before SwiftUI has built it. Any
/// number in here that only one of the two knows about is a number the rows
/// visibly settle onto after they appear, so both sides read them from here.
enum ChatBubbleMetrics {

	static let assistantHorizontalPadding: CGFloat = 18
	static let assistantVerticalPadding: CGFloat = 14

	static let userHorizontalPadding: CGFloat = 15
	static let userVerticalPadding: CGFloat = 11

	/// Breathing room above and below an assistant column.
	static let assistantColumnPadding: CGFloat = 4

	/// The gutter the bubble can never grow into, opposite its own edge.
	static let trailingGutter: CGFloat = 12

	/// Vertical gap between the attachment chips and the text.
	static let attachmentSpacing: CGFloat = 8

	static let copyButtonGlyph: CGFloat = 16
	static let copyButtonPadding: CGFloat = 15

	/// Reserved under every bubble whether or not the button is faded in —
	/// `opacity` hides a view, it doesn't give back its space.
	static var copyButtonHeight: CGFloat { copyButtonGlyph + 2 * copyButtonPadding }

	static func horizontalPadding(assistant: Bool) -> CGFloat {
		assistant ? assistantHorizontalPadding : userHorizontalPadding
	}

	static func verticalPadding(assistant: Bool) -> CGFloat {
		assistant ? assistantVerticalPadding : userVerticalPadding
	}
}

/// Which component draws assistant markdown inside a bubble.
///
/// The TextKit 2 paths make selection flow across the whole message; MarkdownUI
/// is the reference look. `selectable2` is a fork of `selectable` that carries
/// experiments — currently fast LaTeX — without destabilising it.
enum AssistantTextEngine {
	case markdownUI
	case selectable
	case selectable2
}

struct MessageBubble: View {
	let message: Message

	/// Which text container draws assistant markdown. Only the `selectable`
	/// transcript renderers move this off `markdownUI`.
	var assistantText: AssistantTextEngine = .markdownUI

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
					Spacer(minLength: ChatBubbleMetrics.trailingGutter)
					VStack(alignment: .trailing, spacing: 0) {
						bubble
						copyButton.opacity(isHovering ? 1 : 0)
					}
				} else {
					VStack(alignment: .leading, spacing: 0) {
						bubble
						copyButton.opacity(isHovering ? 1 : 0)
					}
					.padding(.vertical, ChatBubbleMetrics.assistantColumnPadding)
					Spacer(minLength: ChatBubbleMetrics.trailingGutter)
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
		return VStack(
			alignment: isAssistant ? .leading : .trailing,
			spacing: ChatBubbleMetrics.attachmentSpacing
		) {
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
			} else if assistantText == .selectable {
				// Same preprocessing MarkdownContentCache applies, so the two
				// renderers are being handed identical source.
				SelectableMarkdownView(
					markdown: SoftBreakMarkdown.preserveLineBreaks(
						a.rendersMath ? MathMarkdown.preprocess(displayText) : displayText
					),
					style: SelectableStyleCache.resolved(t, a)
				)
			} else if assistantText == .selectable2 {
				// `inlineMath` is the one preprocessing difference from the other
				// renderers: this is the only one that draws `$…$`.
				SelectableMarkdownView2(
					markdown: SoftBreakMarkdown.preserveLineBreaks(
						a.rendersMath
							? MathMarkdown.preprocess(displayText, inlineMath: true)
							: displayText
					),
					style: Selectable2StyleCache.resolved(t, a)
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
		.padding(.horizontal, ChatBubbleMetrics.horizontalPadding(assistant: isAssistant))
		.padding(.vertical, ChatBubbleMetrics.verticalPadding(assistant: isAssistant))
		.background(isAssistant ? t.assistantBubble : t.userBubble)
		.foregroundStyle(isAssistant ? t.bodyText : t.userText)
		.clipShape(RoundedRectangle(cornerRadius: 12))
	}

	private var copyButton: some View {
		Button(action: copy) {
			Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
				.font(.caption)
				.foregroundStyle(.secondary)
				.frame(
					width: ChatBubbleMetrics.copyButtonGlyph,
					height: ChatBubbleMetrics.copyButtonGlyph
				)
				.padding(ChatBubbleMetrics.copyButtonPadding)
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
