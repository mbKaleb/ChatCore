//
//  SelectableMarkdownDemo3.swift
//  ChatCore
//
//  Prototype harness. Open the previews, or drop `SelectableMarkdownDemo3()` into
//  a window, and try to drag-select from the first heading down through the code
//  block — inside a message the selection flows; between messages it does not.
//

import SwiftUI

let selectableKitchenSink3 = """
	# Flowing selection

	Everything in this message lives in **one** `NSTextContainer`, so a drag that \
	starts here keeps going through the list, the quote and the fenced code below \
	without ever restarting. Try ⌘A, or triple-click a paragraph, or shift-click \
	further down — it all behaves like [a real text view](https://example.com).

	## What stays real text

	- Headings, paragraphs and *emphasis*
	- Lists, including `inline code` inside them
	  - Nested one level, to check the hanging indent
	- ~~Strikethrough~~ and links

	1. Ordered items work the same way
	2. Wrapped list text should align under the text, not under the marker, which \
	needs enough words to actually wrap

	> Blockquotes draw their rule in the layout fragment.
	> A second line, to confirm the rule stays continuous.

	```swift
	// The card behind this is painted by SelectableLayoutFragment3,
	// not by a sibling SwiftUI view — so this text is still selectable
	// and still part of the same selection as the prose above it.
	func greet(_ name: String) -> String {
	    "Hello, \\(name)"
	}
	```

	---

	Math is the exception: it becomes an attachment, so selection sweeps *through* \
	it as a single character rather than stopping at it. Inline math like \
	$e^{i\\pi} + 1 = 0$ sits on this line's baseline, while a price like $5 stays \
	ordinary text.

	```math
	\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}
	```

	Every equation was typeset once, when this string was built — scrolling past \
	one paints a cached display and measures nothing.

	```math
	\\frac{\\partial u}{\\partial t} = \\alpha \\nabla^2 u
	```

	The paragraph after the attachment proves the selection kept going.

	## The rest of markdown

	Tables are real, selectable text — each row is one paragraph, the columns are \
	tab stops, and the grid behind them is painted by the fragment:

	| Renderer | Selection | Math | Tables |
	|:---------|:---------:|:----:|-------:|
	| MarkdownUI | per block | yes | yes |
	| Selectable 2 | flows | yes | source |
	| **Selectable 3** | flows | yes | *rendered* |

	Task lists keep their checkboxes instead of degrading to plain bullets:

	- [x] Tables as columns, with GFM alignment
	- [x] Checkboxes, still ordinary text
	- [ ] Cell wrapping — one line per row for now

	An image loads once, process-wide, and is painted from cache like an \
	equation; until it arrives it reads as its alt text:

	![A sample photo](https://picsum.photos/420/240)

	Selecting from the table straight through the image and into this sentence \
	stays one continuous sweep, and ⌘C gives back the markdown.
	"""

private let shortReply3 = """
	This is a second message. Selection **stops** at the boundary between messages \
	— that is the Tier 3 problem, and it needs a coordinator across text views.
	"""

// MARK: - Demo

struct SelectableMarkdownDemo3: View {

	@State private var fontSize: Double = 14
	@State private var showsSecondMessage = true

	private var style: Selectable3Style {
		var style = Selectable3Style()
		style.bodyFont = .systemFont(ofSize: fontSize)
		style.codeFont = .monospacedSystemFont(ofSize: fontSize - 1.5, weight: .regular)
		style.headingFont = .systemFont(ofSize: fontSize, weight: .semibold)
		return style
	}

	var body: some View {
		VStack(spacing: 0) {
			controls
			Divider()
			ScrollView {
				VStack(alignment: .leading, spacing: 20) {
					message(selectableKitchenSink3)
					if showsSecondMessage {
						message(shortReply3)
					}
				}
				.padding(20)
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
	}

	private func message(_ markdown: String) -> some View {
		SelectableMarkdownView3(markdown: markdown, style: style)
			.padding(14)
			.background {
				RoundedRectangle(cornerRadius: 12)
					.fill(.quaternary.opacity(0.4))
			}
	}

	private var controls: some View {
		HStack(spacing: 16) {
			Text("Body size")
				.foregroundStyle(.secondary)
			Slider(value: $fontSize, in: 11...24, step: 0.5)
				.frame(width: 180)
			Text(fontSize, format: .number.precision(.fractionLength(1)))
				.monospacedDigit()
				.foregroundStyle(.secondary)
			Toggle("Second message", isOn: $showsSecondMessage)
				.toggleStyle(.switch)
			Spacer()
		}
		.font(.callout)
		.padding(.horizontal, 20)
		.padding(.vertical, 10)
	}
}

#Preview("Selectable markdown") {
	SelectableMarkdownDemo3()
		.frame(width: 620, height: 780)
}

#Preview("Single message, dark") {
	ScrollView {
		SelectableMarkdownView3(markdown: selectableKitchenSink3)
			.padding(20)
	}
	.frame(width: 560, height: 760)
	.preferredColorScheme(.dark)
}
