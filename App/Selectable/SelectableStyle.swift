//
//  SelectableStyle.swift
//  ChatCore
//
//  Prototype: styling inputs for the TextKit 2 selectable-markdown component.
//

import AppKit

// MARK: - Custom attributes

/// Semantics the compiler writes into the text storage so the *layout* layer can
/// decorate without re-parsing. `blockKind` drives which fragment subclass gets
/// vended; `inlineCode` drives pill drawing; `markdownSource` backs copy fidelity.
// The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, but TextKit's
// layout classes are nonisolated — so everything the layout layer touches has to
// opt out explicitly, or the overrides below cannot match their superclasses.
nonisolated extension NSAttributedString.Key {

	static let blockKind = NSAttributedString.Key("cc.blockKind")
	static let inlineCode = NSAttributedString.Key("cc.inlineCode")
	static let markdownSource = NSAttributedString.Key("cc.markdownSource")
	static let blockID = NSAttributedString.Key("cc.blockID")
}

nonisolated enum BlockKind: Equatable {

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
nonisolated struct SelectableStyle: @unchecked Sendable {

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
	/// Horizontal distance from the quote rule to the quoted text.
	var quoteIndent: CGFloat = 18
	/// Indent applied per level of list nesting.
	var listIndent: CGFloat = 22

	/// Six explicit point sizes, h1…h6. Empty means "derive from `bodyFont`" — the
	/// app supplies its own ramp so the heading scale slider keeps working.
	var headingPointSizes: [CGFloat] = []

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

/// A flat snapshot of everything `SelectableLayoutFragment` needs at draw time.
///
/// The colours stay as `NSColor` rather than `CGColor` on purpose: dynamic system
/// colours resolve against `NSAppearance.currentDrawingAppearance` when `.cgColor`
/// is read, so converting lazily inside `draw(at:in:)` makes the decoration follow
/// light/dark without rebuilding any fragments.
nonisolated struct FragmentDecoration {

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

	init(style: SelectableStyle) {
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
	}

	init() {}
}

nonisolated extension NSAppearance {

	var isDark: Bool {
		bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
	}
}
