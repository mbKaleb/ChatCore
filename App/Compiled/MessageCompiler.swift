//
//  MessageCompiler.swift
//  ChatCore
//
//  Prototype renderer — see CompiledMessageList.swift.
//

import AppKit
import Markdown

// MARK: - Geometry shared with the row

/// Gap between a bubble and the edges of its row.
///
/// Deliberately the same numbers as `RowInsets` in `VirtualizedMessageList`, so
/// the two renderers place bubbles identically and switching between them doesn't
/// shift anything sideways.
enum CompiledRowInsets {
	static let leading: CGFloat = 16
	static let trailing: CGFloat = 26
	static let vertical: CGFloat = 6
}

enum CompiledMetrics {
	static let listIndent: CGFloat = 22
	static let markerGap: CGFloat = 6
	static let quoteIndent: CGFloat = 20
	static let quoteRuleWidth: CGFloat = 4
	static let codeCardPadding: CGFloat = 16
	static let codeCardCornerRadius: CGFloat = 12
	static let tableCellPaddingH: CGFloat = 12
	static let tableCellPaddingV: CGFloat = 7
	static let tableMargin: CGFloat = 8
	static let mathPaddingV: CGFloat = 10
	static let mathPaddingH: CGFloat = 4
	static let pillPadding: CGFloat = 2
}

// MARK: - Entry point

enum MessageCompiler {

	/// Lay out one message at `width`.
	///
	/// `MainActor` because typesetting math goes through `MTMathUILabel`, which is
	/// an `NSView`. The CoreText half would be happy on a background thread; if
	/// this ever needs to move off the main queue, math is the thing to hoist out.
	///
	/// Pass a `cache` carried over from the previous compile of the *same* message
	/// to make a streaming tick cost only the blocks that changed — see
	/// ``BlockLayoutCache``. Omitting it compiles everything from scratch, which is
	/// what a one-shot compile of a finished message wants.
	@MainActor
	static func compile(
		id: UUID,
		role: String,
		text: String,
		width: CGFloat,
		style: CompileStyle,
		cache: inout BlockLayoutCache
	) -> CompiledMessage {
		let isAssistant = role != "user"
		let usable = usableWidth(width, isAssistant: isAssistant)

		let blocks: [CompiledBlock]
		let contentSize: CGSize

		if isAssistant {
			let source = style.rendersMath ? MathMarkdown.preprocess(text) : text
			let document = Document(parsing: source)
			cache.begin(layoutKey: style.layoutKey)
			let compiler = BlockCompiler(
				width: usable,
				style: style,
				slicer: SourceSlicer(source),
				cache: cache
			)
			compiler.run(document.blockChildren, indent: 0, quoteDepth: 0)
			blocks = compiler.blocks
			contentSize = compiler.contentSize
			cache = compiler.cache
			cache.finish()
		} else {
			// A user bubble is plain text in the existing renderer too — no
			// markdown, no math.
			let attributed = NSAttributedString(
				string: text,
				attributes: CompiledAttributes.make(font: style.body(), color: style.userText)
			)
			let prepared = TextLayout.prepare(attributed)
			let (lines, size) = TextLayout.wrapped(
				prepared,
				width: usable,
				lineSpacing: style.lineSpacing
			)
			blocks = lines.isEmpty
				? []
				: [CompiledBlock(
					content: .text(lines),
					frame: CGRect(origin: .zero, size: size),
					reflow: CompiledBlock.Reflow(
						prepared: prepared,
						lineSpacing: style.lineSpacing,
						codeRanges: [],
						strikeRanges: []
					)
				)]
			contentSize = size
		}

		return assemble(
			id: id,
			isAssistant: isAssistant,
			blocks: blocks,
			contentSize: contentSize,
			width: width
		)
	}

	/// Compile without reusing anything — a message that isn't streaming.
	@MainActor
	static func compile(
		id: UUID,
		role: String,
		text: String,
		width: CGFloat,
		style: CompileStyle
	) -> CompiledMessage {
		var scratch = BlockLayoutCache()
		return compile(id: id, role: role, text: text, width: width, style: style, cache: &scratch)
	}

	/// Re-lay an already-compiled message at a new width.
	///
	/// The point of the compiled document: a resize does not have to parse markdown
	/// again, rebuild inline attributes, re-typeset a single equation or re-measure a
	/// single table cell. Only `.text` blocks are genuinely width-dependent — those
	/// are wrapped again from the attributed string the first compile kept. Every
	/// other block keeps its content verbatim and takes a new frame, and the stack is
	/// re-flowed by replaying each block's already-resolved `topGap`.
	@MainActor
	static func reflow(
		_ message: CompiledMessage,
		to width: CGFloat,
		style: CompileStyle
	) -> CompiledMessage {
		let usable = usableWidth(width, isAssistant: message.isAssistant)

		var blocks = message.blocks
		var y: CGFloat = 0
		var maxX: CGFloat = 0

		for index in blocks.indices {
			// `frame.minX` is the indent the compiler placed this block at — a
			// function of list and blockquote nesting, not of the column width.
			let indent = blocks[index].frame.minX
			let available = max(1, usable - indent)

			y += blocks[index].topGap
			var size = blocks[index].frame.size

			switch blocks[index].content {
			case .text:
				guard let reflow = blocks[index].reflow else { break }
				let (lines, wrapped) = TextLayout.wrapped(
					reflow.prepared,
					width: available,
					lineSpacing: reflow.lineSpacing
				)
				blocks[index].content = .text(lines)
				blocks[index].pills = reflow.codeRanges
					.flatMap { TextLayout.rects(for: $0, in: lines) }
					.map { $0.insetBy(dx: -CompiledMetrics.pillPadding, dy: 0) }
				blocks[index].strikes = reflow.strikeRanges
					.flatMap { TextLayout.rects(for: $0, in: lines) }
				size = wrapped

			case .table:
				size.width = min(blocks[index].naturalWidth, available)

			case .math(let entry):
				size.width = min(entry.size.width + 2 * CompiledMetrics.mathPaddingH, available)

			case .code, .rule:
				size.width = available
			}

			blocks[index].frame = CGRect(x: indent, y: y, width: size.width, height: size.height)
			y += size.height
			maxX = max(maxX, indent + size.width)
		}

		return assemble(
			id: message.id,
			isAssistant: message.isAssistant,
			blocks: blocks,
			contentSize: CGSize(width: maxX, height: y),
			width: width
		)
	}

	/// The column a bubble's content wraps into.
	private static func usableWidth(_ width: CGFloat, isAssistant: Bool) -> CGFloat {
		max(
			40,
			width
				- CompiledRowInsets.leading
				- CompiledRowInsets.trailing
				- 2 * ChatBubbleMetrics.horizontalPadding(assistant: isAssistant)
				- ChatBubbleMetrics.trailingGutter
		)
	}

	/// Wrap laid-out blocks in their bubble.
	///
	/// Shared by `compile` and `reflow` so the two can't disagree about where a
	/// bubble sits — a resize that placed bubbles even a point differently from a
	/// fresh compile would show up as a jump the first time a message streamed.
	private static func assemble(
		id: UUID,
		isAssistant: Bool,
		blocks: [CompiledBlock],
		contentSize: CGSize,
		width: CGFloat
	) -> CompiledMessage {
		let horizontalPadding = ChatBubbleMetrics.horizontalPadding(assistant: isAssistant)
		let verticalPadding = ChatBubbleMetrics.verticalPadding(assistant: isAssistant)
		let usable = usableWidth(width, isAssistant: isAssistant)

		// Assistant bubbles span the column; user bubbles hug their text.
		let contentWidth = isAssistant ? usable : min(usable, ceil(contentSize.width))
		let bubbleSize = CGSize(
			width: contentWidth + 2 * horizontalPadding,
			height: ceil(contentSize.height) + 2 * verticalPadding
		)

		let bubbleX = isAssistant
			? CompiledRowInsets.leading
			: max(CompiledRowInsets.leading, width - CompiledRowInsets.trailing - bubbleSize.width)
		let bubbleY = CompiledRowInsets.vertical
			+ (isAssistant ? ChatBubbleMetrics.assistantColumnPadding : 0)

		let height = bubbleY
			+ bubbleSize.height
			+ ChatBubbleMetrics.copyButtonHeight
			+ (isAssistant ? ChatBubbleMetrics.assistantColumnPadding : 0)
			+ CompiledRowInsets.vertical

		return CompiledMessage(
			id: id,
			isAssistant: isAssistant,
			blocks: blocks,
			bubbleRect: CGRect(origin: CGPoint(x: bubbleX, y: bubbleY), size: bubbleSize),
			contentOrigin: CGPoint(x: bubbleX + horizontalPadding, y: bubbleY + verticalPadding),
			height: height,
			compiledWidth: width
		)
	}
}

// MARK: - Source slicing

/// Maps a parsed block back to the markdown it was parsed from.
///
/// `BlockLayoutCache` needs a stable identity per block, and `Markup.format()`
/// gives one — but it re-serializes the node, which on a streaming tick means
/// walking and rebuilding the entire message just to compute cache keys. That's
/// the same linear cost the cache exists to avoid, and it measured as the larger
/// half of a tick.
///
/// cmark already records where every node came from, so slicing the source is
/// the same identity for a memcpy. Locations are 1-based, and `column` counts
/// UTF-8 bytes rather than characters — hence the byte array rather than
/// `String.Index` arithmetic, which would be both wrong and slower.
private struct SourceSlicer {

	private let bytes: [UInt8]
	/// Byte offset where each line starts, indexed by `line - 1`.
	private let lineStarts: [Int]

	init(_ source: String) {
		bytes = Array(source.utf8)
		var starts = [0]
		for (offset, byte) in bytes.enumerated() where byte == 0x0A { starts.append(offset + 1) }
		lineStarts = starts
	}

	/// Returns nil for a node cmark didn't locate, which the caller answers by
	/// falling back to `format()` rather than by skipping the cache.
	func slice(_ markup: some Markup) -> String? {
		guard let range = markup.range else { return nil }
		guard
			let lower = offset(of: range.lowerBound),
			let upper = offset(of: range.upperBound)
		else { return nil }
		// An upper bound past the end is normal mid-stream: the last line of a
		// partially received message hasn't arrived in full yet.
		let end = min(max(lower, upper), bytes.count)
		return String(decoding: bytes[lower ..< end], as: UTF8.self)
	}

	private func offset(of location: SourceLocation) -> Int? {
		let line = location.line - 1
		guard lineStarts.indices.contains(line) else { return nil }
		return lineStarts[line] + location.column - 1
	}
}

// MARK: - Attributes

enum CompiledAttributes {

	/// CoreText reads the foreground colour from `kCTForegroundColorAttributeName`
	/// as a `CGColor`; the AppKit `.foregroundColor` key it doesn't look at.
	static let foreground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

	static func make(font: CTFont, color: CGColor) -> [NSAttributedString.Key: Any] {
		[.font: font, foreground: color]
	}
}

// MARK: - Inline

/// Builds one attributed string out of a run of inline markup, recording the
/// ranges that need geometry rather than attributes.
@MainActor
private final class InlineBuilder {

	enum Role {
		case body
		case heading(Int)
		case table(header: Bool)
	}

	private let style: CompileStyle
	private let role: Role
	private let baseColor: CGColor

	let string = NSMutableAttributedString()
	private(set) var codeRanges: [NSRange] = []
	private(set) var strikeRanges: [NSRange] = []

	init(style: CompileStyle, role: Role, baseColor: CGColor) {
		self.style = style
		self.role = role
		self.baseColor = baseColor
	}

	func append(_ inlines: some Sequence<any InlineMarkup>) {
		for inline in inlines {
			append(inline, bold: false, italic: false, strike: false, color: baseColor)
		}
	}

	private func append(
		_ inline: any InlineMarkup,
		bold: Bool,
		italic: Bool,
		strike: Bool,
		color: CGColor
	) {
		switch inline {
		case let node as Markdown.Text:
			add(node.string, bold: bold, italic: italic, strike: strike, color: color)

		case let node as InlineCode:
			let start = string.length
			string.append(
				NSAttributedString(
					string: node.code,
					attributes: CompiledAttributes.make(font: style.code, color: style.inlineCodeText)
				)
			)
			codeRanges.append(NSRange(location: start, length: string.length - start))
			if strike { strikeRanges.append(NSRange(location: start, length: string.length - start)) }

		case is SoftBreak, is LineBreak:
			// Every source line gets a hard break, matching `SoftBreakMarkdown` in
			// the existing renderer — the model's line structure is meaningful.
			add("\n", bold: bold, italic: italic, strike: false, color: color)

		case let node as Emphasis:
			recurse(node, bold: bold, italic: true, strike: strike, color: style.emphasisText)

		case let node as Strong:
			recurse(node, bold: true, italic: italic, strike: strike, color: style.strongText)

		case let node as Strikethrough:
			recurse(node, bold: bold, italic: italic, strike: true, color: color)

		case let node as Markdown.Link:
			recurse(node, bold: bold, italic: italic, strike: strike, color: style.linkText)

		case let container as any InlineContainer:
			recurse(container, bold: bold, italic: italic, strike: strike, color: color)

		default:
			break
		}
	}

	private func recurse(
		_ container: any InlineContainer,
		bold: Bool,
		italic: Bool,
		strike: Bool,
		color: CGColor
	) {
		for child in container.inlineChildren {
			append(child, bold: bold, italic: italic, strike: strike, color: color)
		}
	}

	private func add(_ text: String, bold: Bool, italic: Bool, strike: Bool, color: CGColor) {
		guard !text.isEmpty else { return }
		let start = string.length
		string.append(
			NSAttributedString(
				string: text,
				attributes: CompiledAttributes.make(font: font(bold: bold, italic: italic), color: color)
			)
		)
		if strike { strikeRanges.append(NSRange(location: start, length: string.length - start)) }
	}

	private func font(bold: Bool, italic: Bool) -> CTFont {
		switch role {
		case .body:
			style.body(bold: bold, italic: italic)
		case .heading(let level):
			style.heading(level)
		case .table(let header):
			style.table(bold: header || bold)
		}
	}
}

// MARK: - Blocks

@MainActor
private final class BlockCompiler {

	private let width: CGFloat
	private let style: CompileStyle
	/// Turns a block back into the markdown it came from, for the cache key.
	private let slicer: SourceSlicer

	/// Layouts from the previous compile of this message, and the place this pass
	/// records what it used. Empty for a one-shot compile, in which case every
	/// lookup misses and the emitters behave exactly as they did before.
	private(set) var cache: BlockLayoutCache

	private(set) var blocks: [CompiledBlock] = []
	private var y: CGFloat = 0
	private var maxX: CGFloat = 0

	/// Block margins collapse the way CSS margins do — adjacent blocks are
	/// separated by the larger of the two, not their sum — and the last block emits
	/// no trailing margin at all.
	private var pendingMargin: CGFloat = 0
	private var hasEmitted = false

	var contentSize: CGSize { CGSize(width: maxX, height: y) }

	init(
		width: CGFloat,
		style: CompileStyle,
		slicer: SourceSlicer,
		cache: BlockLayoutCache = BlockLayoutCache()
	) {
		self.width = width
		self.style = style
		self.slicer = slicer
		self.cache = cache
	}

	/// A block's cache key. `format()` is the fallback for a node cmark gave no
	/// location for — slower, but never wrong, and it keeps a missing range from
	/// silently turning caching off.
	private func source(of markup: some Markup) -> String {
		slicer.slice(markup) ?? markup.format()
	}

	func run(_ children: some Sequence<any BlockMarkup>, indent: CGFloat, quoteDepth: Int) {
		for child in children {
			switch child {
			case let node as Paragraph:
				emitText(node.inlineChildren, source: source(of: node), role: .body, color: style.bodyText,
				         indent: indent, quoteDepth: quoteDepth, top: 0, bottom: style.blockGap)

			case let node as Heading:
				emitText(node.inlineChildren, source: source(of: node),
				         role: .heading(node.level), color: style.headingText,
				         indent: indent, quoteDepth: quoteDepth,
				         top: style.lineSpacing + 10, bottom: max(2, 10 - CGFloat(node.level)),
				         lineSpacing: 0)

			case let node as Markdown.CodeBlock:
				emitCodeOrMath(node, indent: indent, quoteDepth: quoteDepth)

			case let node as UnorderedList:
				emitList(node.listItems, indent: indent, quoteDepth: quoteDepth) { _ in "•" }

			case let node as OrderedList:
				let start = Int(node.startIndex)
				emitList(node.listItems, indent: indent, quoteDepth: quoteDepth) { "\(start + $0)." }

			case let node as BlockQuote:
				run(node.blockChildren,
				    indent: indent + CompiledMetrics.quoteIndent,
				    quoteDepth: quoteDepth + 1)

			case is ThematicBreak:
				emit(.rule,
				     size: CGSize(width: width - indent, height: 1),
				     x: indent, top: style.blockGap, bottom: style.blockGap, quoteDepth: quoteDepth)

			case let node as Markdown.Table:
				emitTable(node, indent: indent, quoteDepth: quoteDepth)

			case let container as any BlockContainer:
				run(container.blockChildren, indent: indent, quoteDepth: quoteDepth)

			default:
				break
			}
		}
	}

	// MARK: Emitters

	private func emitText(
		_ inlines: some Sequence<any InlineMarkup>,
		source: String,
		role: InlineBuilder.Role,
		color: CGColor,
		indent: CGFloat,
		quoteDepth: Int,
		top: CGFloat,
		bottom: CGFloat,
		lineSpacing: CGFloat? = nil
	) {
		let resolvedSpacing = lineSpacing ?? style.lineSpacing
		let available = max(1, width - indent)

		// The cache key carries the column rather than the indent, because two
		// blocks nested differently but wrapping into the same width really do lay
		// out identically. Line spacing isn't in it: it's a function of the role,
		// which is.
		let kind: BlockLayoutCache.Kind = switch role {
		case .heading(let level): .heading(level)
		default: .body
		}

		let laid = cache.text(source: source, kind: kind, width: available) {
			let builder = InlineBuilder(style: style, role: role, baseColor: color)
			builder.append(inlines)
			guard builder.string.length > 0 else { return nil }

			let prepared = TextLayout.prepare(builder.string)
			let (lines, size) = TextLayout.wrapped(
				prepared,
				width: available,
				lineSpacing: resolvedSpacing
			)
			guard !lines.isEmpty else { return nil }

			return BlockLayoutCache.TextLayoutResult(
				lines: lines,
				size: size,
				pills: builder.codeRanges
					.flatMap { TextLayout.rects(for: $0, in: lines) }
					.map { $0.insetBy(dx: -CompiledMetrics.pillPadding, dy: 0) },
				strikes: builder.strikeRanges.flatMap { TextLayout.rects(for: $0, in: lines) },
				reflow: CompiledBlock.Reflow(
					prepared: prepared,
					lineSpacing: resolvedSpacing,
					codeRanges: builder.codeRanges,
					strikeRanges: builder.strikeRanges
				)
			)
		}
		guard let laid else { return }

		emit(.text(laid.lines), size: laid.size, x: indent, top: top, bottom: bottom,
		     quoteDepth: quoteDepth, pills: laid.pills, strikes: laid.strikes,
		     reflow: laid.reflow)
	}

	private func emitCodeOrMath(_ node: Markdown.CodeBlock, indent: CGFloat, quoteDepth: Int) {
		let body = node.code.trimmingCharacters(in: .newlines)

		if style.rendersMath, node.language == MathMarkdown.language {
			let prepared = LatexCompat.prepare(body)
			if let entry = MathCache.entry(
				latex: prepared.latex,
				fontSize: style.equationFontSize,
				color: style.mathColor
			) {
				let size = CGSize(
					width: min(entry.size.width + 2 * CompiledMetrics.mathPaddingH, width - indent),
					height: entry.size.height + 2 * CompiledMetrics.mathPaddingV
				)
				emit(.math(entry), size: size, x: indent,
				     top: style.blockGap, bottom: style.blockGap, quoteDepth: quoteDepth)
				return
			}
			// LaTeX that doesn't parse falls through and shows its source, which
			// beats a blank hole where the equation was.
		}

		// Keyed on the code alone — the card's height comes from unwrapped lines, so
		// nothing about this layout moves with the column.
		let laid = cache.code(source: body) {
			let attributed = NSAttributedString(
				string: body,
				attributes: CompiledAttributes.make(font: style.code, color: style.bodyText)
			)
			let (lines, natural) = TextLayout.unwrapped(attributed)
			guard !lines.isEmpty else { return nil }
			return BlockLayoutCache.CodeLayoutResult(lines: lines, size: natural)
		}
		guard let laid else { return }

		let size = CGSize(
			width: width - indent,
			height: laid.size.height + 2 * CompiledMetrics.codeCardPadding
		)
		emit(.code(laid.lines), size: size, x: indent,
		     top: style.blockGap, bottom: style.blockGap, quoteDepth: quoteDepth)
	}

	private func emitList(
		_ items: some Sequence<ListItem>,
		indent: CGFloat,
		quoteDepth: Int,
		marker: (Int) -> String
	) {
		for (offset, item) in items.enumerated() {
			let first = blocks.count
			run(item.blockChildren,
			    indent: indent + CompiledMetrics.listIndent,
			    quoteDepth: quoteDepth)
			guard blocks.count > first else { continue }

			// The marker rides on the item's first block so it moves with it, and
			// so an item whose first block is a code fence still gets a bullet.
			blocks[first].marker = markerLine(marker(offset), indent: indent)

			// Items stack on the same rhythm as wrapped lines; only leaving the
			// list starts a new block.
			pendingMargin = style.lineSpacing
		}
		pendingMargin = style.blockGap
	}

	private func markerLine(_ text: String, indent: CGFloat) -> CompiledLine? {
		let attributed = NSAttributedString(
			string: text,
			attributes: CompiledAttributes.make(font: style.body(), color: style.bodyText)
		)
		let (lines, _) = TextLayout.unwrapped(attributed)
		guard var line = lines.first else { return nil }
		// Right-aligned into the gutter the list indent opened up.
		let x = CompiledMetrics.listIndent - CompiledMetrics.markerGap - line.width
		line = CompiledLine(
			line: line.line,
			origin: CGPoint(x: max(0, x), y: line.origin.y),
			ascent: line.ascent,
			descent: line.descent,
			width: line.width
		)
		return line
	}

	private func cellText(_ cell: Markdown.Table.Cell, header: Bool) -> NSAttributedString {
		let builder = InlineBuilder(style: style, role: .table(header: header), baseColor: style.bodyText)
		builder.append(cell.inlineChildren)
		return builder.string
	}

	private func emitTable(_ node: Markdown.Table, indent: CGFloat, quoteDepth: Int) {
		// Column widths, row heights and cell frames are all measured from unwrapped
		// cells, so the whole table is width-invariant and its cache key doesn't need
		// the column. A streaming table that gains a row misses once for the table as
		// a whole — the coarsest reuse here, and the reason a very long table is the
		// remaining worst case for an incremental compile.
		let laid = cache.table(source: source(of: node)) { self.layOutTable(node) }
		guard let laid else { return }

		emit(.table(laid.table),
		     size: CGSize(width: min(laid.size.width, width - indent), height: laid.size.height),
		     x: indent,
		     top: CompiledMetrics.tableMargin, bottom: CompiledMetrics.tableMargin,
		     quoteDepth: quoteDepth,
		     naturalWidth: laid.size.width)
	}

	private func layOutTable(_ node: Markdown.Table) -> BlockLayoutCache.TableLayoutResult? {
		var rows: [[NSAttributedString]] = []

		var headerCells: [NSAttributedString] = []
		for cell in node.head.cells {
			headerCells.append(cellText(cell, header: true))
		}
		if !headerCells.isEmpty { rows.append(headerCells) }

		for row in node.body.rows {
			var cells: [NSAttributedString] = []
			for cell in row.cells {
				cells.append(cellText(cell, header: false))
			}
			rows.append(cells)
		}

		guard !rows.isEmpty else { return nil }
		let columns = max(node.maxColumnCount, rows.map(\.count).max() ?? 0)
		guard columns > 0 else { return nil }

		// Cells never wrap, so a wide table overflows horizontally rather than
		// squeezing — the same behaviour `HorizontalScrollBox` gives today, and
		// the reason a table's height doesn't depend on the window width.
		var laid: [[(lines: [CompiledLine], size: CGSize)]] = []
		var columnWidths = [CGFloat](repeating: 0, count: columns)
		var rowHeights = [CGFloat](repeating: 0, count: rows.count)

		for (r, row) in rows.enumerated() {
			var laidRow: [(lines: [CompiledLine], size: CGSize)] = []
			for c in 0 ..< columns {
				let cell = c < row.count ? row[c] : NSAttributedString(string: "")
				let result = TextLayout.unwrapped(cell)
				columnWidths[c] = max(columnWidths[c], result.size.width + 2 * CompiledMetrics.tableCellPaddingH)
				rowHeights[r] = max(rowHeights[r], result.size.height + 2 * CompiledMetrics.tableCellPaddingV)
				laidRow.append(result)
			}
			laid.append(laidRow)
		}

		var columnEdges: [CGFloat] = [0]
		for w in columnWidths { columnEdges.append(columnEdges[columnEdges.count - 1] + w) }
		var rowEdges: [CGFloat] = [0]
		for h in rowHeights { rowEdges.append(rowEdges[rowEdges.count - 1] + h) }

		var cells: [CompiledTable.Cell] = []
		for (r, laidRow) in laid.enumerated() {
			for (c, cell) in laidRow.enumerated() {
				let frame = CGRect(
					x: columnEdges[c] + CompiledMetrics.tableCellPaddingH,
					y: rowEdges[r] + CompiledMetrics.tableCellPaddingV,
					width: columnWidths[c] - 2 * CompiledMetrics.tableCellPaddingH,
					height: rowHeights[r] - 2 * CompiledMetrics.tableCellPaddingV
				)
				cells.append(CompiledTable.Cell(lines: cell.lines, frame: frame, isHeader: r == 0))
			}
		}

		return BlockLayoutCache.TableLayoutResult(
			table: CompiledTable(cells: cells, columnEdges: columnEdges, rowEdges: rowEdges),
			size: CGSize(
				width: columnEdges[columnEdges.count - 1],
				height: rowEdges[rowEdges.count - 1]
			)
		)
	}

	private func emit(
		_ content: CompiledBlock.Content,
		size: CGSize,
		x: CGFloat,
		top: CGFloat,
		bottom: CGFloat,
		quoteDepth: Int,
		pills: [CGRect] = [],
		strikes: [CGRect] = [],
		reflow: CompiledBlock.Reflow? = nil,
		naturalWidth: CGFloat = 0
	) {
		// Kept on the block: a reflow replays this number rather than re-deriving it
		// from the margin rules, which live partly in `emitList` rather than here.
		let gap = hasEmitted ? max(pendingMargin, top) : 0
		y += gap
		let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
		blocks.append(
			CompiledBlock(
				content: content,
				frame: frame,
				quoteDepth: quoteDepth,
				pills: pills,
				strikes: strikes,
				topGap: gap,
				naturalWidth: naturalWidth,
				reflow: reflow
			)
		)
		y += size.height
		maxX = max(maxX, frame.maxX)
		pendingMargin = bottom
		hasEmitted = true
	}
}
