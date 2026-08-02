//
//  CompileStyle.swift
//  ChatCore
//
//  Prototype renderer — see CompiledMessageList.swift.
//

import AppKit
import SwiftUI

/// Everything the compiler needs from the theme and appearance, resolved once.
///
/// `ThemeManager.theme` and `.appearance` are computed properties that rescan the
/// font catalog on every read, so they're pulled through here exactly once per
/// compile pass rather than once per block.
struct CompileStyle: Equatable {

	// MARK: Metrics

	let fontSize: CGFloat
	let lineSpacing: CGFloat
	let codeFontSize: CGFloat
	let tableFontSize: CGFloat
	let equationFontSize: CGFloat
	let rendersMath: Bool
	let stripedTables: Bool

	/// Matches `ChatMarkdownMetrics.blockGap + lineSpacing`, which is what
	/// `MDTheme` uses for paragraph margins — the two renderers have to agree or
	/// toggling between them visibly reflows.
	var blockGap: CGFloat { CGFloat(ChatMarkdownMetrics.blockGap) + lineSpacing }

	// MARK: Fonts

	private let bodyFont: ChatFont
	private let headingFont: ChatFont
	private let codeChatFont: ChatFont
	private let tableChatFont: ChatFont
	private let headingSizes: [CGFloat]

	// MARK: Colours

	let bodyText: CGColor
	let strongText: CGColor
	let emphasisText: CGColor
	let headingText: CGColor
	let linkText: CGColor
	let inlineCodeText: CGColor
	let userText: CGColor

	let inlineCodeBackground: CGColor
	let codeCardBackground: CGColor
	let codeCardBorder: CGColor
	let blockquoteRule: CGColor
	let assistantBubble: CGColor
	let userBubble: CGColor
	let tableStripe: CGColor

	/// Math colour has to be an `NSColor` — `MTMathUILabel` bakes it in during
	/// typesetting rather than taking it from the context at draw time.
	let mathColor: NSColor

	// MARK: Layout identity

	/// The part of a style that is *baked into* a compiled document.
	///
	/// Fonts, sizes and text colours all end up inside `CompiledLine`'s attributed
	/// runs or inside a typeset `MathCache.Entry`, so changing one of them means the
	/// lines on hand are wrong and the transcript has to be compiled again. Every
	/// other colour here is chrome the document view looks up at draw time —
	/// bubbles, card fills, rules, table stripes — and changing one of those only
	/// needs a redraw.
	///
	/// Anything added to `CompileStyle` belongs on exactly one side of this line:
	/// in here if a `CompiledBlock` captures it, left out if `CompiledDocumentView`
	/// reads it while painting.
	var layoutKey: LayoutKey {
		LayoutKey(
			fontSize: fontSize,
			lineSpacing: lineSpacing,
			codeFontSize: codeFontSize,
			tableFontSize: tableFontSize,
			equationFontSize: equationFontSize,
			rendersMath: rendersMath,
			bodyFont: bodyFont,
			headingFont: headingFont,
			codeChatFont: codeChatFont,
			tableChatFont: tableChatFont,
			headingSizes: headingSizes,
			bodyText: bodyText,
			strongText: strongText,
			emphasisText: emphasisText,
			headingText: headingText,
			linkText: linkText,
			inlineCodeText: inlineCodeText,
			userText: userText,
			mathColor: mathColor
		)
	}

	struct LayoutKey: Equatable {
		let fontSize: CGFloat
		let lineSpacing: CGFloat
		let codeFontSize: CGFloat
		let tableFontSize: CGFloat
		let equationFontSize: CGFloat
		let rendersMath: Bool
		let bodyFont: ChatFont
		let headingFont: ChatFont
		let codeChatFont: ChatFont
		let tableChatFont: ChatFont
		let headingSizes: [CGFloat]
		let bodyText: CGColor
		let strongText: CGColor
		let emphasisText: CGColor
		let headingText: CGColor
		let linkText: CGColor
		let inlineCodeText: CGColor
		let userText: CGColor
		let mathColor: NSColor
	}

	init(theme: ChatTheme, appearance: ChatAppearance) {
		fontSize = CGFloat(appearance.fontSize)
		lineSpacing = CGFloat(appearance.lineSpacing)
		codeFontSize = CGFloat(appearance.codeFontSize)
		tableFontSize = CGFloat(appearance.tableFontSize)
		equationFontSize = CGFloat(appearance.equationFontSize)
		rendersMath = appearance.rendersMath
		stripedTables = appearance.stripedTables

		bodyFont = appearance.bodyFont
		headingFont = appearance.headingFont
		codeChatFont = appearance.codeFont
		tableChatFont = appearance.tableFont
		headingSizes = (1 ... 6).map { CGFloat(appearance.headingSize($0)) }

		bodyText = NSColor(theme.bodyText).cgColor
		strongText = NSColor(theme.strongText).cgColor
		emphasisText = NSColor(theme.emphasisText).cgColor
		headingText = NSColor(theme.headingText).cgColor
		linkText = NSColor(theme.linkText).cgColor
		inlineCodeText = NSColor(theme.inlineCodeText).cgColor
		userText = NSColor(theme.userText).cgColor

		inlineCodeBackground = NSColor(theme.inlineCodeBackground).cgColor
		codeCardBackground = NSColor(theme.codeCardBackground).cgColor
		codeCardBorder = NSColor(theme.codeCardBorder).cgColor
		blockquoteRule = NSColor(theme.blockquoteRule).cgColor
		assistantBubble = NSColor(theme.assistantBubble).cgColor
		userBubble = NSColor(theme.userBubble).cgColor
		tableStripe = NSColor(theme.inlineCodeBackground).cgColor

		mathColor = NSColor(theme.bodyText)
	}

	// MARK: Resolution

	func body(bold: Bool = false, italic: Bool = false) -> CTFont {
		CompiledFonts.font(bodyFont, size: fontSize, bold: bold, italic: italic)
	}

	func heading(_ level: Int) -> CTFont {
		let index = min(max(level, 1), 6) - 1
		return CompiledFonts.font(headingFont, size: headingSizes[index], bold: level <= 2)
	}

	func headingSize(_ level: Int) -> CGFloat {
		headingSizes[min(max(level, 1), 6) - 1]
	}

	var code: CTFont { CompiledFonts.font(codeChatFont, size: codeFontSize) }

	func table(bold: Bool) -> CTFont {
		CompiledFonts.font(tableChatFont, size: tableFontSize, bold: bold)
	}
}
