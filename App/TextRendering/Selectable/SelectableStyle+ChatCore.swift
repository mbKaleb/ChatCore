//
//  SelectableStyle+ChatCore.swift
//  ChatCore
//
//  Bridges the app's theme and appearance settings into the standalone
//  `SelectableStyle`.
//
//  The component itself stays ignorant of `ChatTheme`/`ChatAppearance` so it can
//  be evaluated and previewed on its own; this file is the only place the two
//  vocabularies meet. Every appearance slider has to land here, or the selectable
//  renderer quietly stops matching the other three.
//

import AppKit
import SwiftUI

// MARK: - Fonts

extension ChatFont {

	/// The AppKit twin of `font(size:weight:)`. TextKit needs a concrete `NSFont`
	/// in the attributed string; SwiftUI's `Font` cannot be unwrapped into one.
	func nsFont(size: Double, weight: NSFont.Weight = .regular) -> NSFont {
		switch kind {
		case .system(let design):
			let base: NSFont = design == .monospaced
				? .monospacedSystemFont(ofSize: size, weight: weight)
				: .systemFont(ofSize: size, weight: weight)

			let systemDesign: NSFontDescriptor.SystemDesign? = switch design {
			case .rounded: .rounded
			case .serif: .serif
			default: nil
			}
			guard
				let systemDesign,
				let descriptor = base.fontDescriptor.withDesign(systemDesign),
				let font = NSFont(descriptor: descriptor, size: size)
			else { return base }
			return font

		case .family(let name):
			let base = NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
			guard weight.rawValue >= NSFont.Weight.semibold.rawValue else { return base }
			let descriptor = base.fontDescriptor
				.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.bold))
			return NSFont(descriptor: descriptor, size: size) ?? base
		}
	}
}

// MARK: - Style

extension SelectableStyle {

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
		secondaryColor = NSColor(t.bodyText).dimmed(0.55)
		linkColor = NSColor(t.linkText)

		codeText = NSColor(t.inlineCodeText)
		codeCardFill = NSColor(t.codeCardBackground)
		codeCardStroke = NSColor(t.codeCardBorder)
		inlineCodeFill = NSColor(t.inlineCodeBackground)
		quoteRule = NSColor(t.blockquoteRule)
		ruleColor = NSColor(t.codeCardBorder)

		lineSpacing = CGFloat(a.lineSpacing)
		blockGap = CGFloat(ChatMarkdownMetrics.blockGap + a.lineSpacing)
	}
}

private extension NSColor {

	/// `withAlphaComponent` traps on colours that have no alpha channel in their
	/// own space, and a `Color` bridged from SwiftUI can be one of those.
	func dimmed(_ alpha: CGFloat) -> NSColor {
		usingColorSpace(.sRGB)?.withAlphaComponent(alpha) ?? self
	}
}

// MARK: - Cache

/// One resolved style, reused until the theme or appearance changes.
///
/// Same reasoning as `ChatMarkdownTheme`: this is read inside `MessageBubble.body`,
/// which re-evaluates constantly as rows scroll, and building a style resolves
/// four fonts and fourteen colours.
@MainActor
enum SelectableStyleCache {

	private static var cached: (theme: ChatTheme, appearance: ChatAppearance, value: SelectableStyle)?

	static func resolved(_ t: ChatTheme, _ a: ChatAppearance) -> SelectableStyle {
		if let cached, cached.theme == t, cached.appearance == a { return cached.value }
		let value = SelectableStyle(theme: t, appearance: a)
		cached = (t, a, value)
		return value
	}
}
