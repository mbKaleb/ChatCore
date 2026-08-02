//
//  MDTheme.swift
//  ChatCore
//

import SwiftUI
import MarkdownUI

enum ChatMarkdownMetrics {

	static let blockGap: Double = 6
}

extension Theme {

	static func chatCore(_ t: ChatTheme, _ a: ChatAppearance) -> Theme {
		Theme()
			.text {
				ForegroundColor(t.bodyText)
				a.bodyFont.markdownFamily
				FontSize(a.fontSize)
			}
			.strong {
				ForegroundColor(t.strongText)
			}
			.emphasis {
				ForegroundColor(t.emphasisText)
			}
			.link {
				ForegroundColor(t.linkText)
			}
			.heading1 { ChatHeading(configuration: $0, level: 1, t: t, a: a) }
			.heading2 { ChatHeading(configuration: $0, level: 2, t: t, a: a) }
			.heading3 { ChatHeading(configuration: $0, level: 3, t: t, a: a) }
			.heading4 { ChatHeading(configuration: $0, level: 4, t: t, a: a) }
			.heading5 { ChatHeading(configuration: $0, level: 5, t: t, a: a) }
			.heading6 { ChatHeading(configuration: $0, level: 6, t: t, a: a) }
			.paragraph { configuration in
				configuration.label
					.markdownMargin(top: 0, bottom: CGFloat(ChatMarkdownMetrics.blockGap + a.lineSpacing))
					.fixedSize(horizontal: false, vertical: true)
			}
			.thematicBreak {
				Divider()
					.overlay(t.codeCardBorder)
					.markdownMargin(
						top: CGFloat(ChatMarkdownMetrics.blockGap + a.lineSpacing),
						bottom: CGFloat(ChatMarkdownMetrics.blockGap + a.lineSpacing)
					)
			}
			.code {
				a.codeFont.markdownFamily
				FontSize(a.codeFontSize)
				BackgroundColor(t.inlineCodeBackground)
				ForegroundColor(t.inlineCodeText)
			}
			.listItem { configuration in
				configuration.label
					.markdownMargin(top: 0, bottom: CGFloat(a.lineSpacing))
			}
			.table { configuration in
				configuration.label
					.fixedSize(horizontal: false, vertical: true)
					.markdownTableBorderStyle(.init(color: t.codeCardBorder))
					.markdownTableBackgroundStyle(
						a.stripedTables
							? .alternatingRows(t.assistantBubble, t.inlineCodeBackground)
							: .clear
					)
					.frame(maxWidth: .infinity, alignment: .center)
					.markdownMargin(top: 8, bottom: 8)
			}
			.tableCell { configuration in
				configuration.label
					.markdownTextStyle {
						if configuration.row == 0 {
							FontWeight(.semibold)
						}
						a.tableFont.markdownFamily
						FontSize(a.tableFontSize)
						BackgroundColor(nil)
					}
					.fixedSize(horizontal: false, vertical: true)
					.padding(.vertical, 7)
					.padding(.horizontal, 12)
			}
			.codeBlock { configuration in
				Group {
					if configuration.language == MathMarkdown.language {
						MathBlockView(latex: configuration.content.trimmingCharacters(in: .whitespacesAndNewlines))
					} else {
						CodeBlockCard(configuration: configuration)
					}
				}
				.markdownMargin(
					top: CGFloat(ChatMarkdownMetrics.blockGap + a.lineSpacing),
					bottom: CGFloat(ChatMarkdownMetrics.blockGap + a.lineSpacing)
				)
			}
			.blockquote { configuration in
				let inset = CGFloat(ChatMarkdownMetrics.blockGap + a.lineSpacing)
				configuration.label
					.padding(.top, inset)
					.padding(.leading, 16)
					.overlay(alignment: .leading) {
						RoundedRectangle(cornerRadius: 2)
							.fill(t.blockquoteRule)
							.frame(width: 4)
					}
					.padding(.leading, 4)
				.markdownMargin(top: inset, bottom: inset)
			}
	}
}

// MARK: - Applying the theme

/// The last `Theme` built, reused until one of its inputs changes.
///
/// `Theme.chatCore` allocates roughly twenty escaping closures, and
/// `chatMarkdownStyle` is applied inside `MessageBubble.body` — so every row was
/// building a fresh one on every body evaluation, and rows re-evaluate
/// constantly as they scroll in and out. The inputs only change when the user
/// touches the appearance settings, so a single slot is enough.
private enum ChatMarkdownTheme {

	private static var cached: (theme: ChatTheme, appearance: ChatAppearance, value: Theme)?

	static func resolved(_ t: ChatTheme, _ a: ChatAppearance) -> Theme {
		if let cached, cached.theme == t, cached.appearance == a { return cached.value }
		let value = Theme.chatCore(t, a)
		cached = (t, a, value)
		return value
	}
}

extension View {

	func chatMarkdownStyle(_ t: ChatTheme, _ a: ChatAppearance) -> some View {
		self
			.markdownTheme(ChatMarkdownTheme.resolved(t, a))
			.lineSpacing(a.lineSpacing)
	}
}

// MARK: - Headings

private struct ChatHeading: View {
	let configuration: BlockConfiguration
	let level: Int
	let t: ChatTheme
	let a: ChatAppearance

	var body: some View {
		configuration.label
			.markdownTextStyle {
				a.headingFont.markdownFamily
				FontSize(a.headingSize(level))
				FontWeight(level <= 2 ? .bold : .semibold)
				ForegroundColor(t.headingText)
			}
			.fixedSize(horizontal: false, vertical: true)
			.lineSpacing(0)
			.markdownMargin(
				top: CGFloat(a.lineSpacing) + 10,
				bottom: CGFloat(max(2, 10 - level))
			)
	}
}

// MARK: - Previews

private let kitchenSink = """
	# Heading 1
	Body text under h1.
	## Heading 2
	Body text under h2.
	### Heading 3
	Body text under h3.
	#### Heading 4
	Body text under h4.
	##### Heading 5
	Body text under h5.
	###### Heading 6
	Body text under h6.

	A paragraph with **bold**, *italic*, `inline code`, a
	[link](https://example.com) and ~~strikethrough~~, long enough to wrap so
	line spacing has somewhere to show itself.

	- Bulleted item
	- Another, with `code` in it
	  - Nested one level

	1. Numbered item
	2. Second

	> A blockquote, which styles its rule but not yet its text.

	```swift
	let greeting = "Hello"
	print(greeting)
	```

	$$e^{i\\pi} + 1 = 0$$

	| Control | Affects | Unit |
	| --- | --- | --- |
	| Text size | Body, headings | pt |
	| Code size | Inline and fenced | pt |
	"""

@MainActor
private func kitchenSinkPreview(_ t: ChatTheme, _ a: ChatAppearance) -> some View {
	ScrollView {
		Markdown(MathMarkdown.preprocess(kitchenSink))
			.chatMarkdownStyle(t, a)
			.padding(18)
	}
	.background(Color.black)
	.environment(ThemeManager())
	.frame(width: 520, height: 700)
}

#Preview("Markdown — default") {
	kitchenSinkPreview(.midnight, .default)
}

#Preview("Markdown — every slider maxed") {
	kitchenSinkPreview(
		.graphite,
		ChatAppearance(
			bodyFont: ChatFont.resolve("charter", in: ChatFont.prose, fallback: .system),
			fontSize: 24,
			lineSpacing: 12,
			headingFont: ChatFont.resolve("rounded", in: ChatFont.prose, fallback: .system),
			headingScale: 1.3,
			codeFont: ChatFont.resolve("menlo", in: ChatFont.monospaced, fallback: .systemMono),
			codeFontSize: 20,
			rendersMath: true,
			equationScale: 1.6,
			tableFont: .system,
			tableFontSize: 20,
			stripedTables: true
		)
	)
}

#Preview("Markdown — every slider minimed") {
	kitchenSinkPreview(
		.midnight,
		ChatAppearance(
			bodyFont: .system,
			fontSize: 11,
			lineSpacing: 0,
			headingFont: .system,
			headingScale: 0.8,
			codeFont: .systemMono,
			codeFontSize: 9,
			rendersMath: true,
			equationScale: 0.9,
			tableFont: .system,
			tableFontSize: 9,
			stripedTables: false
		)
	)
}
