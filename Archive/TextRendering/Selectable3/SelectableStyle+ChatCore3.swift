//
//  Selectable3Style+ChatCore.swift
//  ChatCore
//
//  Bridges the app's theme and appearance settings into the standalone
//  `Selectable3Style`.
//
//  The component itself stays ignorant of `ChatTheme`/`ChatAppearance` so it can
//  be evaluated and previewed on its own; this file is the only place the two
//  vocabularies meet. Every appearance slider has to land here, or the selectable
//  renderer quietly stops matching the other three.
//

import AppKit
import SwiftUI

// `ChatFont.nsFont(size:weight:)` is declared next to the original renderer in
// App/Selectable/SelectableStyle+ChatCore.swift; one copy serves both.

// MARK: - Style

extension Selectable3Style {

	init(theme t: ChatTheme, appearance a: ChatAppearance) {
		self.init()

		bodyFont = a.bodyFont.nsFont(size: a.fontSize)
		codeFont = a.codeFont.nsFont(size: a.codeFontSize)
		headingFont = a.headingFont.nsFont(size: a.fontSize, weight: .semibold)
		// Taken from the appearance rather than derived, so the heading-scale
		// slider drives this renderer the same way it drives MarkdownUI.
		headingPointSizes = (1...6).map { CGFloat(a.headingSize($0)) }

		bodyColor = NSColor(t.bodyText)
		strongColor = NSColor(t.strongText)
		emphasisColor = NSColor(t.emphasisText)
		headingColor = NSColor(t.headingText)
		secondaryColor = NSColor(t.bodyText).dimmed3(0.55)
		linkColor = NSColor(t.linkText)

		codeText = NSColor(t.inlineCodeText)
		codeCardFill = NSColor(t.codeCardBackground)
		codeCardStroke = NSColor(t.codeCardBorder)
		inlineCodeFill = NSColor(t.inlineCodeBackground)
		copyButtonFill = NSColor(t.codeCardCopyBackground)
		// The theme has one copy-button token, so the hover state is that colour
		// with more of it rather than a second token nobody would keep in sync.
		copyButtonHoverFill = NSColor(t.codeCardCopyBackground).moreOpaque3(1.9)
		copyButtonSymbolColor = NSColor(t.bodyText).dimmed3(0.75)
		quoteRule = NSColor(t.blockquoteRule)
		ruleColor = NSColor(t.codeCardBorder)
		// The theme has no table vocabulary yet, so the grid borrows the code
		// card's: its fill for the header band, its border for the rules.
		tableHeaderFill = NSColor(t.codeCardBackground)
		tableRule = NSColor(t.codeCardBorder)

		lineSpacing = CGFloat(a.lineSpacing)
		blockGap = CGFloat(ChatMarkdownMetrics.blockGap + a.lineSpacing)

		rendersMath = a.rendersMath
		equationFontSize = CGFloat(a.equationFontSize)
		// SwiftMath bakes the colour into the typeset display, so this has to be a
		// concrete colour rather than a dynamic one — a dynamic `NSColor` would
		// resolve against whatever appearance happened to be current at typeset
		// time and then stay that way through a theme switch.
		mathColor = NSColor(t.bodyText)
	}
}

private extension NSColor {

	/// `withAlphaComponent` traps on colours that have no alpha channel in their
	/// own space, and a `Color` bridged from SwiftUI can be one of those.
	func dimmed3(_ alpha: CGFloat) -> NSColor {
		usingColorSpace(.sRGB)?.withAlphaComponent(alpha) ?? self
	}

	/// The same colour with its alpha scaled, clamped to opaque.
	func moreOpaque3(_ factor: CGFloat) -> NSColor {
		guard let base = usingColorSpace(.sRGB) else { return self }
		return base.withAlphaComponent(min(1, base.alphaComponent * factor))
	}
}

// MARK: - Cache

/// One resolved style, reused until the theme or appearance changes.
///
/// Same reasoning as `ChatMarkdownTheme`: this is read inside `MessageBubble.body`,
/// which re-evaluates constantly as rows scroll, and building a style resolves
/// four fonts and fourteen colours.
@MainActor
enum Selectable3StyleCache {

	private static var cached: (theme: ChatTheme, appearance: ChatAppearance, value: Selectable3Style)?

	static func resolved(_ t: ChatTheme, _ a: ChatAppearance) -> Selectable3Style {
		if let cached, cached.theme == t, cached.appearance == a { return cached.value }
		let value = Selectable3Style(theme: t, appearance: a)
		cached = (t, a, value)
		return value
	}
}
