//
//  SelectableMarkdownView2.swift
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

final class SelectableTextView2: NSTextView {

	/// Set by the coordinator so ⌘C can prefer the original markdown.
	var emitsMarkdownOnCopy = true

	/// Styling for the copy buttons; refreshed by the coordinator alongside the
	/// fragments' decoration so the two can't drift.
	var buttonDecoration = FragmentDecoration2()

	/// One real `NSButton` per code card, keyed by `blockID2` and repositioned
	/// whenever layout runs. Earlier iterations painted the button in the layout
	/// fragment and re-implemented hover, cursor and click against its geometry —
	/// none of which survived SwiftUI hosting, where the window withholds
	/// mouse-moved events and the List's gesture plumbing sits in front of a
	/// hand-rolled `mouseDown`. A control gets all of that from AppKit directly,
	/// and floating over the text it leaves the selection story untouched.
	private var copyButtons: [Int: CodeCopyButton2] = [:]

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

	// MARK: - Copy buttons

	override func layout() {
		super.layout()
		syncCopyButtons()
	}

	// `layout()` only runs when something marks the view as needing it, and a
	// width change re-wraps every code card.
	override func setFrameSize(_ newSize: NSSize) {
		super.setFrameSize(newSize)
		needsLayout = true
	}

	/// One pass that makes the subviews match the code cards: create what's
	/// missing, move what shifted, drop what's gone. Keyed by `blockID2`, which is
	/// stable across a streaming rebuild for every block before the append point —
	/// so a card's button (and its mid-flight checkmark) survives retokenizing.
	func syncCopyButtons() {
		guard let textLayoutManager else { return }
		let origin = textContainerOrigin
		var seen = Set<Int>()

		textLayoutManager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
			guard
				let fragment = fragment as? SelectableLayoutFragment2,
				let blockID = fragment.blockID,
				let code = fragment.codeSource,
				let frame = fragment.copyButtonFrame()?.offsetBy(dx: origin.x, dy: origin.y)
			else { return true }

			seen.insert(blockID)
			let button: CodeCopyButton2
			if let existing = self.copyButtons[blockID] {
				button = existing
			} else {
				button = CodeCopyButton2()
				self.addSubview(button)
				self.copyButtons[blockID] = button
			}
			button.decoration = self.buttonDecoration
			button.code = code
			if button.frame != frame {
				button.frame = frame
			}
			return true
		}

		for (blockID, button) in copyButtons where !seen.contains(blockID) {
			button.removeFromSuperview()
			copyButtons[blockID] = nil
		}
	}

	// ⌘C on rendered text normally yields the *rendered* string, with the markdown
	// stripped. The `.markdownSource2` attribute written by the compiler lets a
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

		storage.enumerateAttribute(.blockID2, in: selection) { value, range, _ in
			guard value != nil else {
				out += plain(storage.attributedSubstring(from: range))
				return
			}

			var block = NSRange()
			_ = storage.attribute(.blockID2, at: range.location, longestEffectiveRange: &block, in: whole)

			// The block's range includes its terminating newline; a selection that
			// stops just short of it still counts as covering the whole block.
			let visible = NSRange(location: block.location, length: max(0, block.length - 1))
			let covered = visible.length > 0
				&& NSIntersectionRange(selection, visible).length >= visible.length

			if covered,
			   let source = storage.attribute(.markdownSource2, at: range.location, effectiveRange: nil) as? String {
				out += source + "\n\n"
			} else {
				out += plain(storage.attributedSubstring(from: range))
			}
		}
		return out
	}

	/// The rendered text as it should leave the app.
	///
	/// Two substitutions: U+2028 keeps multi-line blocks inside one layout
	/// fragment but should copy as an ordinary newline, and an equation is a
	/// single U+FFFC that would otherwise paste as a blank box — it copies as its
	/// LaTeX instead. Whole-block selections don't come through here at all;
	/// `.markdownSource2` already round-trips those.
	private func plain(_ attributed: NSAttributedString) -> String {
		var out = ""
		let whole = NSRange(location: 0, length: attributed.length)

		attributed.enumerateAttribute(.attachment, in: whole) { value, range, _ in
			guard let math = value as? MathAttachment2 else {
				out += attributed.attributedSubstring(from: range).string
				return
			}
			out += math.isInline ? "$\(math.latex)$" : "\n```math\n\(math.latex)\n```\n"
		}
		return out.replacingOccurrences(of: "\u{2028}", with: "\n")
	}
}

// MARK: - Copy button

/// The copy button floating over one code card.
///
/// A real control on purpose: hover highlight, pointer cursor, pressed state and
/// click delivery are all AppKit's problem, which matters inside SwiftUI hosting
/// where synthesizing them by hand demonstrably fails. The visuals are drawn
/// flat — capsule fill plus SF symbol — to match what the fragment used to paint.
final class CodeCopyButton2: NSButton {

	var decoration = FragmentDecoration2()
	/// The card's code exactly as authored — what a click puts on the pasteboard.
	var code = ""

	private var isHovered = false
	private var showsCheckmark = false
	private var revertTask: Task<Void, Never>?
	private var hoverArea: NSTrackingArea?

	init() {
		super.init(frame: .zero)
		title = ""
		isBordered = false
		setButtonType(.momentaryChange)
		target = self
		action = #selector(copyCode)
		toolTip = "Copy code"
		setAccessibilityLabel("Copy code")
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}

	// A click while the window isn't key should copy, not just activate the app
	// and then need a second click.
	override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	// An I-beam here would read as "this is selectable text"; it isn't. The text
	// view owns the I-beam through its own cursor rects, and this rect — being the
	// deeper view — wins over it.
	override func resetCursorRects() {
		addCursorRect(bounds, cursor: .pointingHand)
	}

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		if let hoverArea { removeTrackingArea(hoverArea) }
		let area = NSTrackingArea(
			rect: .zero,
			options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
			owner: self
		)
		addTrackingArea(area)
		hoverArea = area
	}

	override func mouseEntered(with event: NSEvent) {
		isHovered = true
		needsDisplay = true
	}

	override func mouseExited(with event: NSEvent) {
		isHovered = false
		needsDisplay = true
	}

	override func draw(_ dirtyRect: NSRect) {
		// `isHighlighted` is the momentary press — the immediate "it reacted",
		// before the checkmark lands.
		let fill = isHighlighted || isHovered
			? decoration.copyButtonHoverFill
			: decoration.copyButtonFill
		if let fill {
			fill.setFill()
			NSBezierPath(
				roundedRect: bounds,
				xRadius: decoration.copyButtonCornerRadius,
				yRadius: decoration.copyButtonCornerRadius
			).fill()
		}

		guard let symbol = symbolImage() else { return }
		let size = symbol.size
		symbol.draw(
			in: CGRect(
				x: bounds.midX - size.width / 2,
				y: bounds.midY - size.height / 2,
				width: size.width,
				height: size.height
			)
		)
	}

	private func symbolImage() -> NSImage? {
		guard let image = NSImage(
			systemSymbolName: showsCheckmark ? "checkmark" : "doc.on.doc",
			accessibilityDescription: showsCheckmark ? "Copied" : "Copy code"
		) else { return nil }

		var configuration = NSImage.SymbolConfiguration(
			pointSize: decoration.copyButtonSymbolSize,
			weight: .medium
		)
		if let color = decoration.copyButtonSymbol {
			configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
		}
		return image.withSymbolConfiguration(configuration)
	}

	@objc private func copyCode() {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(code, forType: .string)

		showsCheckmark = true
		needsDisplay = true

		revertTask?.cancel()
		revertTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(1.2))
			guard let self, !Task.isCancelled else { return }
			showsCheckmark = false
			needsDisplay = true
		}
	}
}

// MARK: - SwiftUI wrapper

struct SelectableMarkdownView2: NSViewRepresentable {

	let markdown: String
	var style = Selectable2Style()
	var onOpenURL: ((URL) -> Void)?

	func makeCoordinator() -> Coordinator {
		Coordinator(style: style, onOpenURL: onOpenURL)
	}

	func makeNSView(context: Context) -> SelectableTextView2 {
		let contentStorage = NSTextContentStorage()
		let layoutManager = NSTextLayoutManager()
		let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
		container.lineFragmentPadding = 0
		container.widthTracksTextView = true
		layoutManager.textContainer = container
		contentStorage.addTextLayoutManager(layoutManager)
		layoutManager.delegate = context.coordinator

		let textView = SelectableTextView2(frame: .zero, textContainer: container)
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

	func updateNSView(_ nsView: SelectableTextView2, context: Context) {
		context.coordinator.onOpenURL = onOpenURL
		context.coordinator.apply(markdown: markdown, style: style, to: nsView)
	}

	// The single most common failure mode for a text view inside SwiftUI is
	// collapsing to zero height or growing without bound. Measuring here, against
	// the width SwiftUI actually proposes, avoids the intrinsic-size dance.
	func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelectableTextView2, context: Context) -> CGSize? {
		// A nil or zero width is one of SwiftUI's probing passes. Returning nil
		// there hands sizing to AppKit's stale intrinsic frame — which is where
		// ghost-height bubbles and phantom bottom gaps come from. Answer with
		// the last real measurement instead; there is always one by the time
		// the probe matters, because the definite-width pass comes first.
		guard let width = proposal.width, width > 0, width.isFinite else {
			return context.coordinator.measuredSize
		}
		guard let layoutManager = nsView.textLayoutManager else { return nil }

		// Full-document layout is too expensive to run once per layout pass per
		// message; the measurement is a pure function of (content, width), so
		// cache it on exactly that key.
		if let cached = context.coordinator.measuredSize,
		   abs(cached.width - width) < 0.5,
		   context.coordinator.measuredVersion == context.coordinator.contentVersion {
			return cached
		}

		if abs(nsView.frame.width - width) > 0.5 {
			nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height))
		}
		layoutManager.ensureLayout(for: layoutManager.documentRange)
		let height = layoutManager.usageBoundsForTextContainer.height
		let size = CGSize(width: width, height: ceil(height) + nsView.textContainerInset.height * 2)
		context.coordinator.measuredSize = size
		context.coordinator.measuredVersion = context.coordinator.contentVersion
		return size
	}

	// MARK: - Coordinator

	@MainActor
	final class Coordinator: NSObject, NSTextLayoutManagerDelegate, NSTextViewDelegate {

		var style: Selectable2Style
		var onOpenURL: ((URL) -> Void)?
		var contentStorage: NSTextContentStorage?

		/// The `sizeThatFits` cache: the last measured size, and which content
		/// version it measured. `apply` bumps `contentVersion` on every real
		/// rebuild, so a stale height can never outlive the text it measured.
		var measuredSize: CGSize?
		var measuredVersion = -1
		private(set) var contentVersion = 0

		private var decoration: FragmentDecoration2
		private var renderedMarkdown: String?
		private var renderedFontSize: CGFloat?
		/// Math is typeset against a resolved colour, so a light/dark switch has to
		/// rebuild the string even when nothing else about it changed.
		private var renderedMathToken: String?

		init(style: Selectable2Style, onOpenURL: ((URL) -> Void)?) {
			self.style = style
			self.onOpenURL = onOpenURL
			self.decoration = FragmentDecoration2(style: style)
		}

		func apply(markdown: String, style: Selectable2Style, to textView: SelectableTextView2) {
			var style = style
			// SwiftMath bakes the colour into the typeset display, so a dynamic
			// `NSColor` would be resolved at typeset time against whatever appearance
			// happened to be current — and then keep that colour through a theme
			// switch. Resolving it here, against this view's appearance, makes the
			// resolved value part of the cache key instead.
			style.mathColor = textView.effectiveAppearance.resolve(style.mathColor)
			let mathToken = "\(style.equationFontSize)|\(style.mathColor)|\(style.rendersMath)"

			guard renderedMarkdown != markdown
				|| renderedFontSize != style.bodyFont.pointSize
				|| renderedMathToken != mathToken
			else { return }
			contentVersion += 1
			self.style = style
			self.decoration = FragmentDecoration2(style: style)
			renderedMarkdown = markdown
			renderedFontSize = style.bodyFont.pointSize
			renderedMathToken = mathToken

			guard let contentStorage else { return }
			var builder = MarkdownAttributedBuilder2(style: style)
			let built = builder.build(markdown)

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

			// Every copy button just moved (or appeared). Layout first — the new
			// content hasn't been laid out yet, and a fragment without line
			// fragments reports no button frame at all. The work isn't wasted:
			// `sizeThatFits` needs the same layout a moment later.
			textView.buttonDecoration = decoration
			if let layoutManager = textView.textLayoutManager {
				layoutManager.ensureLayout(for: layoutManager.documentRange)
			}
			textView.syncCopyButtons()
		}

		// Every paragraph gets the custom fragment: block kinds decide what is drawn
		// behind the text, and even a plain paragraph may need inline-code pills.
		func textLayoutManager(
			_ textLayoutManager: NSTextLayoutManager,
			textLayoutFragmentFor location: NSTextLocation,
			in textElement: NSTextElement
		) -> NSTextLayoutFragment {
			let fragment = SelectableLayoutFragment2(textElement: textElement, range: textElement.elementRange)
			fragment.decoration = decoration
			if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 {
				// One lookup for all three: fragments are re-vended constantly while
				// a reply streams in.
				let attributes = paragraph.attributedString.attributes(at: 0, effectiveRange: nil)
				if let box = attributes[.blockKind2] as? BlockKindBox2 {
					fragment.kind = box.kind
				}
				fragment.blockID = attributes[.blockID2] as? Int
				fragment.codeSource = attributes[.codeSource2] as? String
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
