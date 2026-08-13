//
//  SimpleMessageRow.swift
//  ChatCore
//
//  One message in the `simple` transcript renderer, all SwiftUI: no hosted
//  NSTextView, no representable sizing, nothing that can disagree with the
//  scroll view about how tall a row is. Assistant markdown is drawn by the
//  same MarkdownUI path as the reference look, served from
//  `MarkdownContentCache`. The row reads `ModelManager.liveText` itself; a
//  row that only read `message.text` would never show a streamed reply.
//

import SwiftUI
import MarkdownUI

struct SimpleMessageRow: View {

	let message: Message

	@Environment(ModelManager.self) private var manager
	@Environment(ThemeManager.self) private var themes

	private var liveText: String? { manager.liveText[message.id] }
	private var displayText: String { liveText ?? message.text }
	private var isAssistant: Bool { message.role != "user" }

	/// Trimmed, like `MessageBubble.isEmpty`: a cancelled or failed turn can
	/// leave a whitespace-only message behind, and an untrimmed check renders
	/// it as an empty bubble.
	private var hasText: Bool {
		!displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	var body: some View {
		let t = themes.theme
		let a = themes.appearance

		if isAssistant, liveText != nil, !hasText {
			Text("Thinking…")
				.font(.callout)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
		} else if !hasText && message.attachments.isEmpty {
			// Nothing to show, so show nothing — not an empty bubble.
			EmptyView()
		} else {
			HStack(spacing: 0) {
				if isAssistant {
					column(t, a)
					Spacer(minLength: 12)
				} else {
					Spacer(minLength: 12)
					column(t, a)
				}
			}
		}
	}

	private func column(_ t: ChatTheme, _ a: ChatAppearance) -> some View {
		VStack(alignment: isAssistant ? .leading : .trailing, spacing: 8) {
			if !message.attachments.isEmpty {
				// Chips are fixed-width and an HStack draws past its edge rather
				// than wrap, so the row scrolls — same treatment MessageBubble
				// gives it, capped at its natural width.
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 8) {
						ForEach(message.attachments) { attachment in
							AttachmentChip(attachment: attachment)
						}
					}
				}
				.fixedSize(horizontal: false, vertical: true)
				.frame(
					maxWidth: AttachmentChip.rowWidth(for: message.attachments, spacing: 8),
					alignment: isAssistant ? .leading : .trailing
				)
			}

			if hasText {
				bubbleText(t, a)
					.padding(.horizontal, 15)
					.padding(.vertical, isAssistant ? 14 : 11)
					.background(isAssistant ? t.assistantBubble : t.userBubble)
					.foregroundStyle(isAssistant ? t.bodyText : t.userText)
					.clipShape(RoundedRectangle(cornerRadius: 20))
			}
		}
	}

	@ViewBuilder
	private func bubbleText(_ t: ChatTheme, _ a: ChatAppearance) -> some View {
		if isAssistant {
			Markdown(
				MarkdownContentCache.content(
					for: message,
					overrideText: liveText,
					rendersMath: a.rendersMath
				)
			)
			.chatMarkdownStyle(t, a)
		} else {
			Text(displayText)
				.font(a.bodyFont.font(size: a.fontSize))
				.lineSpacing(a.lineSpacing)
		}
	}
}
