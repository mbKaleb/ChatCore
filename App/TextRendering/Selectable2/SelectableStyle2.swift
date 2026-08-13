//
//  Selectable2Style.swift
//  ChatCore
//
//  Styling inputs for the `selectable2` renderer.
//
//  A verbatim fork of App/Selectable/SelectableStyle.swift, kept separate so
//  `selectable2` can change layout and drawing without disturbing the renderer
//  people are already comparing against. Everything is suffixed `2` because both
//  forks live in the same module.
//

import AppKit

// MARK: - Custom attributes

/// Semantics the compiler writes into the text storage so the *layout* layer can
/// decorate without re-parsing. `blockKind2` drives which fragment subclass gets
/// vended; `inlineCode2` drives pill drawing; `markdownSource2` backs copy fidelity.
// The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, but TextKit's
// layout classes are nonisolated — so everything the layout layer touches has to
// opt out explicitly, or the overrides below cannot match their superclasses.
nonisolated extension NSAttributedString.Key {

	static let blockKind2 = NSAttributedString.Key("cc2.blockKind")
	static let inlineCode2 = NSAttributedString.Key("cc2.inlineCode")
	static let markdownSource2 = NSAttributedString.Key("cc2.markdownSource")
	static let blockID2 = NSAttributedString.Key("cc2.blockID")
	/// A code card's code exactly as authored — what its copy button puts on the
	/// pasteboard. The rendered text carries U+2028 line separators and
	/// `markdownSource2` carries the fence, so neither of those can stand in.
	static let codeSource2 = NSAttributedString.Key("cc2.codeSource")
}

nonisolated enum BlockKind2: Equatable {

	case paragraph
	case heading(level: Int)
	case quote(depth: Int)
	case codeBlock(language: String?)
	case listItem(depth: Int)
	case rule
	case attachment

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
nonisolated struct Selectable2Style: @unchecked Sendable {

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

/// A flat snapshot of everything `SelectableLayoutFragment2` needs at draw time.
///
/// The colours stay as `NSColor` rather than `CGColor` on purpose: dynamic system
/// colours resolve against `NSAppearance.currentDrawingAppearance` when `.cgColor`
/// is read, so converting lazily inside `draw(at:in:)` makes the decoration follow
/// light/dark without rebuilding any fragments.
nonisolated struct FragmentDecoration2 {

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

	init(style: Selectable2Style) {
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
	}

	init() {}
}

nonisolated extension NSAppearance {

	var isDark: Bool {
		bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
	}
}

nonisolated extension NSAppearance {

	/// A concrete colour for a possibly-dynamic one, resolved against this
	/// appearance. Anything that bakes a colour in — a typeset equation, a cache
	/// key — needs the resolved value rather than the dynamic wrapper, or it keeps
	/// whatever appearance happened to be current when it was first read.
	func resolve(_ color: NSColor) -> NSColor {
		var resolved = color
		performAsCurrentDrawingAppearance {
			resolved = color.usingColorSpace(.sRGB) ?? color
		}
		return resolved
	}
}
