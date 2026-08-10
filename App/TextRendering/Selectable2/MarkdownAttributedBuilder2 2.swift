//
//  MarkdownAttributedBuilder2.swift
//  ChatCore
//
//  swift-markdown AST -> a single NSAttributedString per message.
//
//  Everything that can stay real text stays real text, so selection flows through
//  it. Only content that genuinely isn't text (math, images) becomes an
//  NSTextAttachment, which costs one character of selection granularity.
//
//  Math is typeset *here*, at build time, and the resulting `MathCache.Entry` is
//  carried by the attachment. That is the whole performance story: layout reads
//  a measured size, drawing paints a laid-out display, and neither of them ever
//  parses LaTeX.
//

import AppKit
import Markdown

@MainActor
struct MarkdownAttributedBuilder2 {

	var style: Selectable2Style

	/// Macro definitions gathered from the whole message, so an equation can use a
	/// `\newcommand` written in a different block. Set once per `build`.
	private var mathPreamble = ""

	/// Fenced languages that render as a typeset equation rather than as code.
	static let attachmentLanguages: Set<String> = ["math", "latex", "katex"]

	mutating func build(_ source: String) -> NSAttributedString {
		mathPreamble = style.rendersMath ? LatexCompat.documentPreamble(in: source) : ""
		let document = Document(parsing: source)
		let out = NSMutableAttributedString()
		var counter = 0
		for child in document.children {
			emit(child, into: out, listDepth: 0, quoteDepth: 0, blockID: &counter)
		}
		// A document that ends in a newline gets an empty trailing paragraph, which
		// lays out as a stray blank line under the last block.
		if out.string.hasSuffix("\n") {
			out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
		}
		return out
	}

	// MARK: - Blocks

	private func emit(
		_ markup: Markup,
		into out: NSMutableAttributedString,
		listDepth: Int,
		quoteDepth: Int,
		blockID: inout Int
	) {
		switch markup {

		case let heading as Heading:
			let font = style.heading(heading.level)
			let paragraph = paragraphStyle(
				indent: indent(listDepth, quoteDepth),
				before: blockID == 0 ? 0 : style.blockGap + 6,
				after: max(2, 8 - CGFloat(heading.level)),
				lineSpacing: 1
			)
			let body = inlines(heading, base: [
				.font: font,
				.foregroundColor: style.headingColor,
				.paragraphStyle: paragraph,
			])
			push(body, kind: .heading(level: heading.level), source: heading, into: out, blockID: &blockID)

		case let paragraph as Paragraph:
			let style = paragraphStyle(
				indent: indent(listDepth, quoteDepth),
				before: blockID == 0 ? 0 : self.style.blockGap,
				after: 0,
				lineSpacing: self.style.lineSpacing
			)
			let body = inlines(paragraph, base: baseAttributes(paragraph: style))
			push(
				body,
				kind: quoteDepth > 0 ? .quote(depth: quoteDepth) : .paragraph,
				source: paragraph,
				into: out,
				blockID: &blockID
			)

		case let code as CodeBlock:
			emitCodeBlock(code, into: out, listDepth: listDepth, quoteDepth: quoteDepth, blockID: &blockID)

		case let quote as BlockQuote:
			for child in quote.children {
				emit(child, into: out, listDepth: listDepth, quoteDepth: quoteDepth + 1, blockID: &blockID)
			}

		case let list as UnorderedList:
			emitList(list, ordered: false, start: 1, into: out, listDepth: listDepth, quoteDepth: quoteDepth, blockID: &blockID)

		case let list as OrderedList:
			emitList(list, ordered: true, start: Int(list.startIndex), into: out, listDepth: listDepth, quoteDepth: quoteDepth, blockID: &blockID)

		case is ThematicBreak:
			let paragraph = paragraphStyle(
				indent: 0,
				before: style.blockGap + 4,
				after: style.blockGap + 4,
				lineSpacing: 0
			)
			// The glyph is a space; the rule itself is drawn by the fragment.
			let body = NSAttributedString(string: " ", attributes: [
				.font: NSFont.systemFont(ofSize: 4),
				.foregroundColor: NSColor.clear,
				.paragraphStyle: paragraph,
			])
			push(body, kind: .rule, source: markup, into: out, blockID: &blockID)

		default:
			// Tables and anything else not yet handled fall back to their source
			// text so nothing silently disappears from the transcript.
			guard !markup.isEmpty else { break }
			let paragraph = paragraphStyle(
				indent: indent(listDepth, quoteDepth),
				before: style.blockGap,
				after: 0,
				lineSpacing: style.lineSpacing
			)
			let body = NSAttributedString(
				string: markup.format().trimmingCharacters(in: .newlines).replacingOccurrences(of: "\n", with: "\u{2028}"),
				attributes: [
					.font: style.codeFont,
					.foregroundColor: style.secondaryColor,
					.paragraphStyle: paragraph,
				]
			)
			push(body, kind: .paragraph, source: markup, into: out, blockID: &blockID)
		}
	}

	private func emitCodeBlock(
		_ code: CodeBlock,
		into out: NSMutableAttributedString,
		listDepth: Int,
		quoteDepth: Int,
		blockID: inout Int
	) {
		let language = code.language?.lowercased()

		// LaTeX that doesn't typeset falls through to the ordinary code card, so a
		// parse failure shows its source rather than leaving a hole.
		if style.rendersMath, let language, Self.attachmentLanguages.contains(language),
		   let attachment = mathAttachment(
			   code.code.trimmingCharacters(in: .whitespacesAndNewlines),
			   isInline: false
		   ) {
			emitMath(attachment, source: code, into: out, blockID: &blockID)
			return
		}

		let inset = indent(listDepth, quoteDepth)
		let paragraph = paragraphStyle(
			indent: inset + style.cardPadding.left,
			before: style.blockGap,
			after: 0,
			lineSpacing: 2
		)
		paragraph.tailIndent = -style.cardPadding.right
		paragraph.lineBreakMode = .byCharWrapping

		// U+2028 keeps the whole fence inside ONE NSTextParagraph, so it lays out as
		// a single layout fragment and gets a single continuous card behind it.
		// Splitting on \n would give one card per line.
		let text = code.code
			.trimmingCharacters(in: .newlines)
			.replacingOccurrences(of: "\n", with: "\u{2028}")

		let body = NSAttributedString(string: text, attributes: [
			.font: style.codeFont,
			.foregroundColor: style.codeText,
			.paragraphStyle: paragraph,
		])
		push(body, kind: .codeBlock(language: code.language), source: code, into: out, blockID: &blockID)
	}

	// MARK: - Math

	/// Typesets once, here, and hands the result to the attachment.
	///
	/// `MathCache` is keyed on `(latex, fontSize, colour, inline)` and shared
	/// process-wide, so the same equation in twenty replies costs one typeset —
	/// and a streamed rebuild of this string is a dictionary hit per equation, not
	/// a re-typeset. Returns `nil` when the LaTeX doesn't parse.
	/// - Parameter pointSize: What the surrounding run is set in. Inline math has
	///   to match the text it sits in, and that text is not always body text — an
	///   equation in a heading set at body size reads as a footnote next to the
	///   words around it. Display math ignores this and takes the equation scale.
	private func mathAttachment(
		_ latex: String,
		isInline: Bool,
		pointSize: CGFloat? = nil
	) -> MathAttachment2? {
		let prepared = LatexCompat.prepare(latex, preamble: mathPreamble)
		guard let entry = MathCache.entry(
			latex: prepared.latex,
			fontSize: isInline
				? (pointSize ?? style.bodyFont.pointSize)
				: style.equationFontSize,
			color: style.mathColor,
			inline: isInline
		) else { return nil }

		return MathAttachment2(
			latex: latex,
			entry: entry,
			isInline: isInline,
			padding: isInline ? .zero : style.mathBlockPadding
		)
	}

	private func emitMath(
		_ attachment: MathAttachment2,
		source: Markup,
		into out: NSMutableAttributedString,
		blockID: inout Int
	) {
		let paragraph = paragraphStyle(indent: 0, before: style.blockGap, after: 0, lineSpacing: 0)
		let body = NSMutableAttributedString(attachment: attachment)
		body.addAttributes([.paragraphStyle: paragraph], range: NSRange(location: 0, length: body.length))
		push(body, kind: .attachment, source: source, into: out, blockID: &blockID)
	}

	private func emitList(
		_ list: ListItemContainer,
		ordered: Bool,
		start: Int,
		into out: NSMutableAttributedString,
		listDepth: Int,
		quoteDepth: Int,
		blockID: inout Int
	) {
		var number = start
		for item in list.listItems {
			var isFirstParagraph = true
			for child in item.children {
				switch child {
				case let paragraph as Paragraph:
					let marker = ordered ? "\(number).\t" : "\(bullet(listDepth))\t"
					emitListParagraph(
						paragraph,
						marker: isFirstParagraph ? marker : "\t",
						into: out,
						listDepth: listDepth,
						quoteDepth: quoteDepth,
						blockID: &blockID
					)
					isFirstParagraph = false

				case let nested as UnorderedList:
					emitList(nested, ordered: false, start: 1, into: out, listDepth: listDepth + 1, quoteDepth: quoteDepth, blockID: &blockID)

				case let nested as OrderedList:
					emitList(nested, ordered: true, start: Int(nested.startIndex), into: out, listDepth: listDepth + 1, quoteDepth: quoteDepth, blockID: &blockID)

				default:
					emit(child, into: out, listDepth: listDepth + 1, quoteDepth: quoteDepth, blockID: &blockID)
				}
			}
			number += 1
		}
	}

	private func emitListParagraph(
		_ paragraph: Paragraph,
		marker: String,
		into out: NSMutableAttributedString,
		listDepth: Int,
		quoteDepth: Int,
		blockID: inout Int
	) {
		// `indent(_:_:)` already accounts for list depth — adding it again here is
		// what made nested items sit two levels deep.
		let head = indent(listDepth, quoteDepth)
		let hanging = head + style.listIndent

		let paragraphStyle = paragraphStyle(
			indent: head,
			before: blockID == 0 ? 0 : style.lineSpacing + 2,
			after: 0,
			lineSpacing: style.lineSpacing
		)
		// Wrapped lines align under the text, not under the marker.
		paragraphStyle.headIndent = hanging
		paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: hanging)]
		paragraphStyle.defaultTabInterval = style.listIndent

		let body = NSMutableAttributedString(string: marker, attributes: [
			.font: style.bodyFont,
			.foregroundColor: style.secondaryColor,
			.paragraphStyle: paragraphStyle,
		])
		body.append(inlines(paragraph, base: baseAttributes(paragraph: paragraphStyle)))
		push(body, kind: .listItem(depth: listDepth), source: paragraph, into: out, blockID: &blockID)
	}

	// MARK: - Inlines

	private func inlines(_ container: Markup, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
		let out = NSMutableAttributedString()
		for child in container.children {
			out.append(inline(child, base: base))
		}
		return out
	}

	private func inline(_ markup: Markup, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
		var attributes = base
		let font = (base[.font] as? NSFont) ?? style.bodyFont

		switch markup {

		case let text as Markdown.Text:
			guard style.rendersMath, text.string.contains("$") else {
				return NSAttributedString(string: text.string, attributes: base)
			}
			return inlineMath(text.string, base: base, pointSize: font.pointSize)

		case is SoftBreak:
			return NSAttributedString(string: " ", attributes: base)

		case is LineBreak:
			// U+2028 breaks the line without starting a new paragraph element, so the
			// block keeps its single-fragment decoration.
			return NSAttributedString(string: "\u{2028}", attributes: base)

		case let code as InlineCode:
			attributes[.font] = style.codeFont
			attributes[.foregroundColor] = style.codeText
			attributes[.inlineCode2] = true
			return NSAttributedString(string: code.code, attributes: attributes)

		case is Emphasis:
			attributes[.font] = applying(.italic, to: font)
			if let color = style.emphasisColor { attributes[.foregroundColor] = color }
			return inlines(markup, base: attributes)

		case is Strong:
			attributes[.font] = applying(.bold, to: font)
			if let color = style.strongColor { attributes[.foregroundColor] = color }
			return inlines(markup, base: attributes)

		case is Strikethrough:
			attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
			attributes[.strikethroughColor] = style.secondaryColor
			return inlines(markup, base: attributes)

		case let link as Link:
			if let destination = link.destination, let url = URL(string: destination) {
				attributes[.link] = url
			}
			attributes[.foregroundColor] = style.linkColor
			return inlines(markup, base: attributes)

		case let image as Markdown.Image:
			let alt = image.plainText.isEmpty ? (image.source ?? "image") : image.plainText
			attributes[.foregroundColor] = style.secondaryColor
			return NSAttributedString(string: "🖼 \(alt)", attributes: attributes)

		case let html as InlineHTML:
			return NSAttributedString(string: html.rawHTML, attributes: base)

		default:
			guard markup.childCount > 0 else {
				return NSAttributedString(string: markup.format(), attributes: base)
			}
			return inlines(markup, base: base)
		}
	}

	// MARK: - Inline math

	/// Splits a run of text on `$…$` and typesets each hit.
	///
	/// Only `$…$` reaches here. `\(…\)` cannot: CommonMark treats a backslash
	/// before ASCII punctuation as an escape, so by the time a `Text` node arrives
	/// the delimiters have been eaten and it reads as `(x)`. That form is rewritten
	/// to `$…$` by `MathMarkdown.preprocess(_:inlineMath:)`, which runs on the raw
	/// source before parsing — the same place block math is fenced.
	private func inlineMath(
		_ string: String,
		base: [NSAttributedString.Key: Any],
		pointSize: CGFloat
	) -> NSAttributedString {
		let out = NSMutableAttributedString()
		var literal = ""
		var i = string.startIndex

		func flush() {
			guard !literal.isEmpty else { return }
			out.append(NSAttributedString(string: literal, attributes: base))
			literal = ""
		}

		while i < string.endIndex {
			guard string[i] == "$", let close = closingDollar(in: string, after: i) else {
				literal.append(string[i])
				i = string.index(after: i)
				continue
			}

			let body = String(string[string.index(after: i)..<close])
			guard let attachment = mathAttachment(body, isInline: true, pointSize: pointSize) else {
				// Unparseable: keep the delimiters and the source, so it reads as
				// the author typed it.
				literal += string[i...close]
				i = string.index(after: close)
				continue
			}

			flush()
			let math = NSMutableAttributedString(attachment: attachment)
			// The attachment character inherits the run's attributes so the line's
			// paragraph style and leading are unchanged by it.
			math.addAttributes(base, range: NSRange(location: 0, length: math.length))
			out.append(math)
			i = string.index(after: close)
		}

		flush()
		return out
	}

	/// The closing `$` for an opener at `open`, or nil if this `$` isn't math.
	///
	/// Lives in `InlineMathDelimiter` so the rule can be tested on its own: it is
	/// pure string reasoning, and its failure mode is a sentence quietly typeset
	/// as an equation rather than anything that looks like an error.
	private func closingDollar(in string: String, after open: String.Index) -> String.Index? {
		InlineMathDelimiter.closingDollar(in: string, after: open)
	}

	// MARK: - Helpers

	private func push(
		_ body: NSAttributedString,
		kind: BlockKind2,
		source: Markup,
		into out: NSMutableAttributedString,
		blockID: inout Int
	) {
		let block = NSMutableAttributedString(attributedString: body)

		// A block can legitimately be empty while streaming — "## " arrives before
		// its text does — so the trailing newline has to source its attributes
		// defensively rather than reading index -1.
		let tail: [NSAttributedString.Key: Any] = block.length > 0
			? block.attributes(at: block.length - 1, effectiveRange: nil)
			: [.font: style.bodyFont, .foregroundColor: style.bodyColor]

		// The trailing newline is what makes TextKit 2 treat this as its own
		// NSTextParagraph, and therefore its own layout fragment.
		block.append(NSAttributedString(string: "\n", attributes: tail))
		block.addAttributes([
			.blockKind2: BlockKindBox2(kind),
			.blockID2: blockID,
			.markdownSource2: source.format().trimmingCharacters(in: .newlines),
		], range: NSRange(location: 0, length: block.length))
		out.append(block)
		blockID += 1
	}

	private func baseAttributes(paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
		[
			.font: style.bodyFont,
			.foregroundColor: style.bodyColor,
			.paragraphStyle: paragraph,
		]
	}

	private func paragraphStyle(
		indent: CGFloat,
		before: CGFloat,
		after: CGFloat,
		lineSpacing: CGFloat
	) -> NSMutableParagraphStyle {
		let paragraph = NSMutableParagraphStyle()
		paragraph.firstLineHeadIndent = indent
		paragraph.headIndent = indent
		paragraph.paragraphSpacingBefore = before
		paragraph.paragraphSpacing = after
		paragraph.lineSpacing = lineSpacing
		return paragraph
	}

	private func indent(_ listDepth: Int, _ quoteDepth: Int) -> CGFloat {
		CGFloat(quoteDepth) * style.quoteIndent + CGFloat(listDepth) * style.listIndent
	}

	private func bullet(_ depth: Int) -> String {
		["•", "◦", "▪"][depth % 3]
	}

	private func applying(_ trait: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
		let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
		return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
	}
}

/// `BlockKind2` is an enum with associated values, which `NSAttributedString`
/// cannot store directly — attribute values must be objects.
nonisolated final class BlockKindBox2: NSObject {

	let kind: BlockKind2

	init(_ kind: BlockKind2) {
		self.kind = kind
	}

	override func isEqual(_ object: Any?) -> Bool {
		(object as? BlockKindBox2)?.kind == kind
	}

	override var hash: Int {
		String(describing: kind).hashValue
	}
}
