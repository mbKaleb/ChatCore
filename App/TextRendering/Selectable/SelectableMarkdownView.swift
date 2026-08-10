//
//  SelectableMarkdownView.swift
//  ChatCore
//
//  Prototype: rendered markdown inside a single TextKit 2 text container.
//
//  One container means one selection domain, which is what buys flowing selection
//  across headings, paragraphs, lists, quotes and code — plus shift-click, ⌘A,
//  double/triple-click, autoscroll, Find and Services for free.
//

import AppKit
import SwiftUI

// MARK: - Text view

final class SelectableTextView: NSTextView {

	/// Set by the coordinator so ⌘C can prefer the original markdown.
	var emitsMarkdownOnCopy = true

	override var acceptsFirstResponder: Bool { true }

	/// `NSTextView.textStorage` is nil when the view is driven by TextKit 2, so
	/// anything reaching for the backing store has to go through the content
	/// storage instead. Getting this wrong fails silently — copy just falls back to
	/// rendered text.
	var storage: NSTextStorage? {
		textContentStorage?.textStorage ?? textStorage
	}

	// Without this the view swallows scroll events meant for the enclosing SwiftUI
	// ScrollView, because a non-scrolling NSTextView still claims them.
	override func scrollWheel(with event: NSEvent) {
		nextResponder?.scrollWheel(with: event)
	}

	// ⌘C on rendered text normally yields the *rendered* string, with the markdown
	// stripped. The `.markdownSource` attribute written by the compiler lets a
	// selection that fully covers a block round-trip back to its source.
	override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
		guard emitsMarkdownOnCopy, let storage else {
			return super.writeSelection(to: pboard, types: types)
		}

		var out = ""
		for value in selectedRanges {
			out += copyText(for: value.rangeValue, in: storage)
		}
		let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return super.writeSelection(to: pboard, types: types) }

		pboard.clearContents()
		pboard.declareTypes([.string], owner: nil)
		pboard.setString(trimmed, forType: .string)
		return true
	}

	private func copyText(for selection: NSRange, in storage: NSTextStorage) -> String {
		let whole = NSRange(location: 0, length: storage.length)
		var out = ""

		storage.enumerateAttribute(.blockID, in: selection) { value, range, _ in
			guard value != nil else {
				out += plain(storage.attributedSubstring(from: range).string)
				return
			}

			var block = NSRange()
			_ = storage.attribute(.blockID, at: range.location, longestEffectiveRange: &block, in: whole)

			// The block's range includes its terminating newline; a selection that
			// stops just short of it still counts as covering the whole block.
			let visible = NSRange(location: block.location, length: max(0, block.length - 1))
			let covered = visible.length > 0
				&& NSIntersectionRange(selection, visible).length >= visible.length

			if covered,
			   let source = storage.attribute(.markdownSource, at: range.location, effectiveRange: nil) as? String {
				out += source + "\n\n"
			} else {
				out += plain(storage.attributedSubstring(from: range).string)
			}
		}
		return out
	}

	/// U+2028 keeps multi-line blocks inside one layout fragment, but it should
	/// leave the app as an ordinary newline.
	private func plain(_ string: String) -> String {
		string.replacingOccurrences(of: "\u{2028}", with: "\n")
	}
}

// MARK: - SwiftUI wrapper

struct SelectableMarkdownView: NSViewRepresentable {

	let markdown: String
	var style = SelectableStyle()
	var onOpenURL: ((URL) -> Void)?

	func makeCoordinator() -> Coordinator {
		Coordinator(style: style, onOpenURL: onOpenURL)
	}

	func makeNSView(context: Context) -> SelectableTextView {
		let contentStorage = NSTextContentStorage()
		let layoutManager = NSTextLayoutManager()
		let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
		container.lineFragmentPadding = 0
		container.widthTracksTextView = true
		layoutManager.textContainer = container
		contentStorage.addTextLayoutManager(layoutManager)
		layoutManager.delegate = context.coordinator

		let textView = SelectableTextView(frame: .zero, textContainer: container)
		textView.isEditable = false
		textView.isSelectable = true
		textView.drawsBackground = false
		textView.textContainerInset = .zero
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.autoresizingMask = [.width]
		textView.delegate = context.coordinator
		textView.linkTextAttributes = [
			.foregroundColor: style.linkColor,
			.underlineStyle: NSUnderlineStyle.single.rawValue,
			.cursor: NSCursor.pointingHand,
		]
		textView.selectedTextAttributes = [.backgroundColor: style.selectionColor]

		context.coordinator.contentStorage = contentStorage
		context.coordinator.apply(markdown: markdown, style: style, to: textView)
		return textView
	}

	func updateNSView(_ nsView: SelectableTextView, context: Context) {
		context.coordinator.onOpenURL = onOpenURL
		context.coordinator.apply(markdown: markdown, style: style, to: nsView)
	}

	// The single most common failure mode for a text view inside SwiftUI is
	// collapsing to zero height or growing without bound. Measuring here, against
	// the width SwiftUI actually proposes, avoids the intrinsic-size dance.
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextView, context: Context) -> CGSize? {
		guard let width = proposal.width, width > 0, width.isFinite else { return nil }
		guard let layoutManager = nsView.textLayoutManager else { return nil }

		if abs(nsView.frame.width - width) > 0.5 {
			nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height))
		}
		layoutManager.ensureLayout(for: layoutManager.documentRange)
		let height = layoutManager.usageBoundsForTextContainer.height
		return CGSize(width: width, height: ceil(height) + nsView.textContainerInset.height * 2)
	}

	// MARK: - Coordinator

	@MainActor
	final class Coordinator: NSObject, NSTextLayoutManagerDelegate, NSTextViewDelegate {

		var style: SelectableStyle
		var onOpenURL: ((URL) -> Void)?
		var contentStorage: NSTextContentStorage?

		private var decoration: FragmentDecoration
		private var renderedMarkdown: String?
		private var renderedFontSize: CGFloat?

		init(style: SelectableStyle, onOpenURL: ((URL) -> Void)?) {
			self.style = style
			self.onOpenURL = onOpenURL
			self.decoration = FragmentDecoration(style: style)
		}

		func apply(markdown: String, style: SelectableStyle, to textView: SelectableTextView) {
			guard renderedMarkdown != markdown || renderedFontSize != style.bodyFont.pointSize else { return }
			self.style = style
			self.decoration = FragmentDecoration(style: style)
			renderedMarkdown = markdown
			renderedFontSize = style.bodyFont.pointSize

			guard let contentStorage else { return }
			let built = MarkdownAttributedBuilder(style: style).build(markdown)

			// Streaming appends land after any existing selection, so restoring it
			// verbatim keeps the user's selection alive across token updates.
			let previous = textView.selectedRanges.map(\.rangeValue)
			contentStorage.performEditingTransaction {
				// Assigning `attributedString` leaves `contentStorage.textStorage` nil,
				// which silently breaks anything that walks the backing store — copy
				// fidelity included. Installing a real NSTextStorage also gives the
				// streaming path something to splice into.
				if let storage = contentStorage.textStorage {
					storage.setAttributedString(built)
				} else {
					contentStorage.textStorage = NSTextStorage(attributedString: built)
				}
			}
			let clamped = previous
				.map { NSIntersectionRange($0, NSRange(location: 0, length: built.length)) }
				.filter { $0.length > 0 }
			if !clamped.isEmpty {
				textView.selectedRanges = clamped.map { NSValue(range: $0) }
			}
		}

		// Every paragraph gets the custom fragment: block kinds decide what is drawn
		// behind the text, and even a plain paragraph may need inline-code pills.
		func textLayoutManager(
			_ textLayoutManager: NSTextLayoutManager,
			textLayoutFragmentFor location: NSTextLocation,
			in textElement: NSTextElement
		) -> NSTextLayoutFragment {
			let fragment = SelectableLayoutFragment(textElement: textElement, range: textElement.elementRange)
			fragment.decoration = decoration
			if let paragraph = textElement as? NSTextParagraph,
			   paragraph.attributedString.length > 0,
			   let box = paragraph.attributedString.attribute(.blockKind, at: 0, effectiveRange: nil) as? BlockKindBox {
				fragment.kind = box.kind
			}
			return fragment
		}

		func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
			let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
			guard let url else { return false }
			if let onOpenURL {
				onOpenURL(url)
			} else {
				NSWorkspace.shared.open(url)
			}
			return true
		}
	}
}
