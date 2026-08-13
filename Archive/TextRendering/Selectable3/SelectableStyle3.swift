//
//  Selectable3Style.swift
//  ChatCore
//
//  Styling inputs for the `selectable3` renderer.
//
//  A fork of Selectable2's style, kept separate so `selectable3` can grow the
//  rest of markdown — tables, task lists, images — without disturbing the
//  renderer people are already comparing against. Everything is suffixed `3`
//  because all three forks live in the same module.
//

import AppKit

// MARK: - Custom attributes

/// Semantics the compiler writes into the text storage so the *layout* layer can
/// decorate without re-parsing. `blockKind3` drives which fragment subclass gets
/// vended; `inlineCode3` drives pill drawing; `markdownSource3` backs copy fidelity.
// The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, but TextKit's
// layout classes are nonisolated — so everything the layout layer touches has to
// opt out explicitly, or the overrides below cannot match their superclasses.
nonisolated extension NSAttributedString.Key {

	static let blockKind3 = NSAttributedString.Key("cc3.blockKind")
	static let inlineCode3 = NSAttributedString.Key("cc3.inlineCode")
	static let markdownSource3 = NSAttributedString.Key("cc3.markdownSource")
	static let blockID3 = NSAttributedString.Key("cc3.blockID")
	/// A code card's code exactly as authored — what its copy button puts on the
	/// pasteboard. The rendered text carries U+2028 line separators and
	/// `markdownSource3` carries the fence, so neither of those can stand in.
	static let codeSource3 = NSAttributedString.Key("cc3.codeSource")
}

nonisolated enum BlockKind3: Equatable {

	case paragraph
	case heading(level: Int)
	case quote(depth: Int)
	case codeBlock(language: String?)
	case listItem(depth: Int)
	case rule
	case attachment
	/// One row of a rendered table. `row` is its index counting the header as 0,
	/// `rows` the table's total, and `width` the laid-out width of the whole grid
	/// — every row carries the full geometry because each row is its own layout
	/// fragment, and the fragment painting a separator can't see its siblings.
	case tableRow(row: Int, rows: Int, width: CGFloat)

	/// Whether this block wants a drawn card behind it.
	var isCard: Bool {
		if case .codeBlock = self { return true }
		return false
	}

	/// Whether this block wants a leading accent rule drawn beside it.
	var quoteDepth: Int? {
		if case .quote(let d) = self { return d }
		return nil
	}
}

// MARK: - Theme

/// Deliberately standalone rather than wired to `ChatTheme`/`ChatAppearance`, so
/// the prototype compiles and renders on its own while we decide whether the
/// approach is worth adopting.
/// `@unchecked Sendable` because `NSFont` and `NSColor` are reference types the
/// SDK does not mark as `Sendable`, but both are immutable once created and this
/// struct is only ever read — including from the nonisolated layout layer.
nonisolated struct Selectable3Style: @unchecked Sendable {

	var bodyFont: NSFont = .systemFont(ofSize: 14)
	var codeFont: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
	var headingFont: NSFont = .systemFont(ofSize: 14, weight: .semibold)

	var bodyColor: NSColor = .labelColor
	var headingColor: NSColor = .labelColor
	var secondaryColor: NSColor = .secondaryLabelColor
	var linkColor: NSColor = .linkColor
	/// Nil falls back to `bodyColor`, matching a theme that doesn't tint emphasis.
	var strongColor: NSColor?
	var emphasisColor: NSColor?

	var codeText: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 0.92, alpha: 1) : .init(white: 0.15, alpha: 1) }
	var codeCardFill: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.055) : .init(white: 0, alpha: 0.04) }
	var codeCardStroke: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.09) : .init(white: 0, alpha: 0.08) }
	var inlineCodeFill: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.10) : .init(white: 0, alpha: 0.06) }
	var quoteRule: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.22) : .init(white: 0, alpha: 0.18) }
	var ruleColor: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.14) : .init(white: 0, alpha: 0.12) }

	var selectionColor: NSColor = .selectedTextBackgroundColor

	/// Extra leading between lines, expressed the way the SwiftUI side does it.
	var lineSpacing: CGFloat = 3
	/// Vertical gap between sibling blocks.
	var blockGap: CGFloat = 9
	var cardCornerRadius: CGFloat = 8
	var cardPadding: NSEdgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
	var inlineCodePadding: CGFloat = 3
	var inlineCodeCornerRadius: CGFloat = 4

	/// Copy button painted in a code card's top-trailing corner.
	var copyButtonSize: CGFloat = 22
	/// Distance from the button to the card's top and trailing edges.
	var copyButtonInset: CGFloat = 8
	var copyButtonCornerRadius: CGFloat = 6
	var copyButtonSymbolSize: CGFloat = 11
	var copyButtonFill: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.10) : .init(white: 0, alpha: 0.07) }
	/// Fill while the pointer is over the button itself rather than just the card.
	var copyButtonHoverFill: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.18) : .init(white: 0, alpha: 0.12) }
	var copyButtonSymbolColor: NSColor = .secondaryLabelColor

	/// Width kept clear at the trailing edge of every code line so the button
	/// never sits on top of code. The button is *painted over* the text rather
	/// than laid out beside it, so the room has to come out of the line width —
	/// the same trade `CodeBlockCard` makes with its trailing padding.
	var copyButtonGutter: CGFloat { copyButtonSize + copyButtonInset }
	/// Horizontal distance from the quote rule to the quoted text.
	var quoteIndent: CGFloat = 18
	/// Indent applied per level of list nesting.
	var listIndent: CGFloat = 22

	/// Six explicit point sizes, h1…h6. Empty means "derive from `bodyFont`" — the
	/// app supplies its own ramp so the heading scale slider keeps working.
	var headingPointSizes: [CGFloat] = []

	// MARK: Math

	/// Off means `$…$` and ```` ```math ```` are left as their source text, the
	/// same way the other renderers read the appearance switch.
	var rendersMath = true
	var equationFontSize: CGFloat = 17
	/// Baked into the typeset display, so this is a cache dimension rather than a
	/// draw-time colour. Resolve it against the current appearance before handing
	/// it over — see `Coordinator.apply`.
	var mathColor: NSColor = .labelColor
	/// Breathing room around a display equation, inside its reserved box.
	var mathBlockPadding = CGSize(width: 4, height: 8)

	// MARK: Tables

	var tableHeaderFill: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.055) : .init(white: 0, alpha: 0.04) }
	var tableRule: NSColor = NSColor(name: nil) { $0.isDark ? .init(white: 1, alpha: 0.12) : .init(white: 0, alpha: 0.10) }
	/// Horizontal distance between the end of one column's widest cell and the
	/// start of the next.
	var tableColumnGap: CGFloat = 26
	/// Vertical breathing room above and below each row's text; the row rule is
	/// drawn in the middle of two adjacent rows' padding.
	var tableRowPadding: CGFloat = 6
	/// How far the header fill and the rules extend past the cell text on each
	/// side, so the grid reads as slightly wider than its content.
	var tableEdgeInset: CGFloat = 8
	/// A column is as wide as its widest cell up to this; a longer cell overruns
	/// its stop and that row's later cells land on the next stop past the text.
	/// Real column wrapping can't happen inside a single paragraph, so the cap
	/// trades misalignment in pathological rows for alignment in the common case.
	var tableMaxColumnWidth: CGFloat = 300

	// MARK: Images

	/// Off leaves images as their alt-text placeholder without ever fetching.
	var rendersImages = true
	/// A tall image scales down to this; width is capped by the column at layout
	/// time, the same way a wide equation is.
	var imageMaxHeight: CGFloat = 320
	var imageCornerRadius: CGFloat = 8

	func headingSize(_ level: Int) -> CGFloat {
		let index = max(0, min(5, level - 1))
		if headingPointSizes.count == 6 { return headingPointSizes[index] }
		let scale: [CGFloat] = [1.6, 1.4, 1.22, 1.1, 1.0, 0.94]
		return (bodyFont.pointSize * scale[index]).rounded()
	}

	func heading(_ level: Int) -> NSFont {
		let size = headingSize(level)
		let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
		guard let descriptor = headingFont.fontDescriptor
			.withSymbolicTraits(level <= 2 ? .bold : []) as NSFontDescriptor?,
			let font = NSFont(descriptor: descriptor, size: size)
		else { return .systemFont(ofSize: size, weight: weight) }
		return font
	}
}

// MARK: - Drawing config handed to the layout fragment

/// A flat snapshot of everything `SelectableLayoutFragment3` needs at draw time.
///
/// The colours stay as `NSColor` rather than `CGColor` on purpose: dynamic system
/// colours resolve against `NSAppearance.currentDrawingAppearance` when `.cgColor`
/// is read, so converting lazily inside `draw(at:in:)` makes the decoration follow
/// light/dark without rebuilding any fragments.
nonisolated struct FragmentDecoration3 {

	var cardFill: NSColor?
	var cardStroke: NSColor?
	var cardCornerRadius: CGFloat = 8
	var quoteRule: NSColor?
	var quoteIndent: CGFloat = 18
	var horizontalRule: NSColor?
	var inlineCodeFill: NSColor?
	var inlineCodePadding: CGFloat = 3
	var inlineCodeCornerRadius: CGFloat = 4
	var padding: NSEdgeInsets = NSEdgeInsets()

	var copyButtonSize: CGFloat = 0
	var copyButtonInset: CGFloat = 8
	var copyButtonCornerRadius: CGFloat = 6
	var copyButtonSymbolSize: CGFloat = 11
	var copyButtonFill: NSColor?
	var copyButtonHoverFill: NSColor?
	var copyButtonSymbol: NSColor?

	var tableHeaderFill: NSColor?
	var tableRule: NSColor?
	var tableRowPadding: CGFloat = 6
	var tableEdgeInset: CGFloat = 8
	var imageCornerRadius: CGFloat = 8

	init(style: Selectable3Style) {
		cardFill = style.codeCardFill
		cardStroke = style.codeCardStroke
		cardCornerRadius = style.cardCornerRadius
		quoteRule = style.quoteRule
		quoteIndent = style.quoteIndent
		horizontalRule = style.ruleColor
		inlineCodeFill = style.inlineCodeFill
		inlineCodePadding = style.inlineCodePadding
		inlineCodeCornerRadius = style.inlineCodeCornerRadius
		padding = style.cardPadding
		copyButtonSize = style.copyButtonSize
		copyButtonInset = style.copyButtonInset
		copyButtonCornerRadius = style.copyButtonCornerRadius
		copyButtonSymbolSize = style.copyButtonSymbolSize
		copyButtonFill = style.copyButtonFill
		copyButtonHoverFill = style.copyButtonHoverFill
		copyButtonSymbol = style.copyButtonSymbolColor
		tableHeaderFill = style.tableHeaderFill
		tableRule = style.tableRule
		tableRowPadding = style.tableRowPadding
		tableEdgeInset = style.tableEdgeInset
		imageCornerRadius = style.imageCornerRadius
	}

	init() {}
}

// `NSAppearance.isDark` lives next to the original renderer in
// App/Selectable/SelectableStyle.swift and `NSAppearance.resolve(_:)` next to
// Selectable2 in SelectableStyle2.swift; one copy of each serves all forks.
