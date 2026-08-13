import SwiftUI
import AppKit
import MarkdownUI

/// Geometry a bubble commits to, shared with the list's height estimator.
///
/// The estimator has to predict this layout before SwiftUI has built it. Any
/// number in here that only one of the two knows about is a number the rows
/// visibly settle onto after they appear, so both sides read them from here.
enum ChatBubbleMetrics {

	static let assistantHorizontalPadding: CGFloat = 15
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
/// `selectable2` — one TextKit 2 container per message — is the app's
/// renderer; `markdownUI` is the reference look it is judged against. The
/// other engines this enum once named live in Archive/TextRendering.
enum AssistantTextEngine {
	case markdownUI
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

	/// A turn in flight with nothing to show yet — the model is reasoning, or
	/// the request is still on the wire. Either way the honest state is
	/// "working", not the zero-height row an empty message normally collapses
	/// to. The first answer token flips this off and the bubble takes over.
	private var isAwaitingAnswer: Bool {
		isAssistant && liveText != nil && isEmpty
	}

	/// The tail of the reasoning streamed so far, sized for a glance. The tail
	/// rather than the head: the head goes stale the moment the model moves on,
	/// while the tail is what it's thinking about now.
	private var thinkingTail: String? {
		guard let thinking = manager.liveThinking[message.id], !thinking.isEmpty else {
			return nil
		}
		let tail = thinking.suffix(360)
		guard tail.count < thinking.count else { return String(tail) }
		return "…" + tail.drop(while: { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
	}

	var body: some View {
		if isAwaitingAnswer {
			thinkingIndicator
		} else if isEmpty {
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

	/// What an assistant row shows while the model works: a shimmering label,
	/// with the live tail of its reasoning beneath once there is one. Quiet on
	/// purpose — no bubble background, secondary colors — so the eventual
	/// answer, not the wait, is the loudest thing in the transcript.
	private var thinkingIndicator: some View {
		HStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 6) {
				ThinkingShimmerLabel()
				if let thinkingTail {
					Text(thinkingTail)
						.font(.callout)
						.foregroundStyle(.tertiary)
						.lineLimit(6)
						.frame(maxWidth: 520, alignment: .leading)
				}
			}
			.padding(.horizontal, 4)
			.padding(.vertical, ChatBubbleMetrics.assistantColumnPadding + 6)
			Spacer(minLength: ChatBubbleMetrics.trailingGutter)
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
				attachmentRow
			}

			if !displayText.isEmpty {
				textContainer(t, a)
			}
		}
	}

	/// The chips above a message's text.
	///
	/// Chips are fixed-width, so two of them already want more room than a
	/// bubble has in a narrow pane, and an `HStack` would simply draw past its
	/// edge. Scrolling is how the rest of the transcript handles content that
	/// can't wrap — code blocks, tables, the composer's own tray — so the row
	/// does the same, capped at its natural width so a single chip still lets
	/// a user bubble hug its text instead of stretching to the full column.
	private var attachmentRow: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: ChatBubbleMetrics.attachmentSpacing) {
				ForEach(message.attachments) { attachment in
					AttachmentChip(attachment: attachment)
				}
			}
		}
		.fixedSize(horizontal: false, vertical: true)
		.frame(
			maxWidth: AttachmentChip.rowWidth(
				for: message.attachments,
				spacing: ChatBubbleMetrics.attachmentSpacing
			),
			alignment: isAssistant ? .leading : .trailing
		)
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
			} else if assistantText == .selectable2 {
				// `inlineMath` is the one preprocessing difference from the
				// reference path: this engine is the only one that draws `$…$`.
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
		.clipShape(RoundedRectangle(cornerRadius: 20))
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
		.pointerStyle(.link)
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

/// "Thinking…" with a highlight sweeping through it.
///
/// The sweep is a gradient band masked to the glyphs, driven by a `TimelineView`
/// the same way `GlowDot` animates — no repeating SwiftUI animation left running
/// on a row that is about to be torn down when the answer arrives.
private struct ThinkingShimmerLabel: View {

	private static let text = "Thinking…"
	private static let font = Font.callout.weight(.medium)
	private static let sweepPeriod: TimeInterval = 1.8

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
			let phase = timeline.date.timeIntervalSinceReferenceDate
				.truncatingRemainder(dividingBy: Self.sweepPeriod) / Self.sweepPeriod

			Text(Self.text)
				.font(Self.font)
				.foregroundStyle(.secondary)
				.overlay {
					GeometryReader { geo in
						let band = geo.size.width * 0.6
						LinearGradient(
							colors: [.clear, .primary.opacity(0.85), .clear],
							startPoint: .leading,
							endPoint: .trailing
						)
						.frame(width: band)
						.offset(x: (geo.size.width + band) * phase - band)
					}
					.mask(Text(Self.text).font(Self.font))
				}
		}
	}
}
