//
//  CompiledDocumentView.swift
//  ChatCore
//
//  Prototype renderer — see CompiledMessageList.swift.
//

import AppKit
import CoreText

/// The whole transcript as one view.
///
/// There is no cell reuse, no hosting view and no height cache here — a scroll is
/// a binary search into a prefix-sum array followed by `CTLineDraw` on the lines
/// the dirty rect actually touches. Lazy *layout* is what the compiled document
/// replaces; lazy *drawing* stays, and is the reason a 5,000-line transcript costs
/// the same to scroll as a 50-line one.
final class CompiledDocumentView: NSView {

	var document = CompiledDocument() {
		didSet { needsDisplay = true }
	}

	var style: CompileStyle? {
		didSet { needsDisplay = true }
	}

	/// Rows are laid out top-down, matching document order.
	override var isFlipped: Bool { true }

	/// Deliberately not layer-backed: the document view is as tall as the whole
	/// transcript, and a layer's backing store can't cover that. AppKit's
	/// responsive scrolling draws ahead of the viewport instead.
	override var wantsUpdateLayer: Bool { false }

	override var isOpaque: Bool { false }

	/// Draw a screen either side of the viewport so a flick has content ready
	/// before it arrives — the same trick `BufferedTableView` uses.
	override func prepareContent(in rect: NSRect) {
		let buffer = (enclosingScrollView?.contentView.bounds.height ?? bounds.height)
		guard buffer > 0 else { return super.prepareContent(in: rect) }
		super.prepareContent(in: rect.insetBy(dx: 0, dy: -buffer).intersection(bounds))
	}

	override func draw(_ dirtyRect: NSRect) {
		guard
			let context = NSGraphicsContext.current?.cgContext,
			let style
		else { return }

		// Established here for the pass, and re-established by `TextLayout.draw`
		// before every block — the text matrix survives neither `saveGState` nor a
		// neighbouring `MTMathListDisplay`, so it can't be set once and trusted.
		context.textMatrix = TextLayout.flippedTextMatrix

		for index in document.indexes(in: dirtyRect) {
			draw(document[index], atY: document.top(of: index), in: context, dirty: dirtyRect, style: style)
		}
	}

	// MARK: - Message

	private func draw(
		_ message: CompiledMessage,
		atY rowY: CGFloat,
		in context: CGContext,
		dirty: CGRect,
		style: CompileStyle
	) {
		let bubble = message.bubbleRect.offsetBy(dx: 0, dy: rowY)
		if bubble.maxY >= dirty.minY, bubble.minY <= dirty.maxY {
			context.setFillColor(message.isAssistant ? style.assistantBubble : style.userBubble)
			context.addPath(
				CGPath(roundedRect: bubble, cornerWidth: 12, cornerHeight: 12, transform: nil)
			)
			context.fillPath()
		}

		let origin = CGPoint(
			x: message.contentOrigin.x,
			y: rowY + message.contentOrigin.y
		)

		for block in message.blocks {
			let frame = block.frame.offsetBy(dx: origin.x, dy: origin.y)
			guard frame.maxY >= dirty.minY else { continue }
			guard frame.minY <= dirty.maxY else { break }
			draw(block, at: frame, in: context, dirty: dirty, style: style)
		}
	}

	// MARK: - Block

	private func draw(
		_ block: CompiledBlock,
		at frame: CGRect,
		in context: CGContext,
		dirty: CGRect,
		style: CompileStyle
	) {
		drawQuoteRules(block, at: frame, in: context, style: style)

		if let marker = block.marker {
			TextLayout.draw(marker, at: frame.origin, in: context)
		}

		switch block.content {
		case .text(let lines):
			drawPills(block.pills, at: frame, in: context, style: style)
			TextLayout.draw(lines, at: frame.origin, in: context, dirty: dirty)
			drawStrikes(block.strikes, at: frame, in: context, style: style)

		case .code(let lines):
			drawCodeCard(lines, at: frame, in: context, dirty: dirty, style: style)

		case .math(let entry):
			context.saveGState()
			context.clip(to: frame)
			MathCache.draw(
				entry,
				in: CGRect(
					x: frame.minX + CompiledMetrics.mathPaddingH,
					y: frame.minY + CompiledMetrics.mathPaddingV,
					width: entry.size.width,
					height: entry.size.height
				),
				context: context
			)
			context.restoreGState()

		case .table(let table):
			drawTable(table, at: frame, in: context, dirty: dirty, style: style)

		case .rule:
			context.setFillColor(style.codeCardBorder)
			context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1))
		}
	}

	private func drawQuoteRules(
		_ block: CompiledBlock,
		at frame: CGRect,
		in context: CGContext,
		style: CompileStyle
	) {
		guard block.quoteDepth > 0 else { return }
		context.setFillColor(style.blockquoteRule)
		for level in 0 ..< block.quoteDepth {
			let x = frame.minX - CGFloat(block.quoteDepth - level) * CompiledMetrics.quoteIndent
			context.addPath(
				CGPath(
					roundedRect: CGRect(
						x: x,
						y: frame.minY,
						width: CompiledMetrics.quoteRuleWidth,
						height: frame.height
					),
					cornerWidth: 2,
					cornerHeight: 2,
					transform: nil
				)
			)
		}
		context.fillPath()
	}

	private func drawPills(
		_ pills: [CGRect],
		at frame: CGRect,
		in context: CGContext,
		style: CompileStyle
	) {
		guard !pills.isEmpty else { return }
		context.setFillColor(style.inlineCodeBackground)
		for pill in pills {
			context.addPath(
				CGPath(
					roundedRect: pill.offsetBy(dx: frame.minX, dy: frame.minY),
					cornerWidth: 3,
					cornerHeight: 3,
					transform: nil
				)
			)
		}
		context.fillPath()
	}

	private func drawStrikes(
		_ strikes: [CGRect],
		at frame: CGRect,
		in context: CGContext,
		style: CompileStyle
	) {
		guard !strikes.isEmpty else { return }
		context.setFillColor(style.bodyText)
		for strike in strikes {
			let box = strike.offsetBy(dx: frame.minX, dy: frame.minY)
			context.fill(
				CGRect(x: box.minX, y: box.midY - 0.5, width: box.width, height: 1)
			)
		}
	}

	private func drawCodeCard(
		_ lines: [CompiledLine],
		at frame: CGRect,
		in context: CGContext,
		dirty: CGRect,
		style: CompileStyle
	) {
		let card = CGPath(
			roundedRect: frame,
			cornerWidth: CompiledMetrics.codeCardCornerRadius,
			cornerHeight: CompiledMetrics.codeCardCornerRadius,
			transform: nil
		)
		context.setFillColor(style.codeCardBackground)
		context.addPath(card)
		context.fillPath()

		context.setStrokeColor(style.codeCardBorder)
		context.setLineWidth(1)
		context.addPath(card)
		context.strokePath()

		// Long source lines overflow rather than wrap, which is what makes a code
		// block's height width-invariant. Clipping is what stands in for the
		// horizontal scroller the prototype doesn't have yet.
		context.saveGState()
		context.clip(to: frame.insetBy(dx: 1, dy: 1))
		TextLayout.draw(
			lines,
			at: CGPoint(
				x: frame.minX + CompiledMetrics.codeCardPadding,
				y: frame.minY + CompiledMetrics.codeCardPadding
			),
			in: context,
			dirty: dirty
		)
		context.restoreGState()
	}

	private func drawTable(
		_ table: CompiledTable,
		at frame: CGRect,
		in context: CGContext,
		dirty: CGRect,
		style: CompileStyle
	) {
		context.saveGState()
		context.clip(to: frame)

		if style.stripedTables {
			context.setFillColor(style.tableStripe)
			for row in 0 ..< max(0, table.rowEdges.count - 1) where row.isMultiple(of: 2) {
				context.fill(
					CGRect(
						x: frame.minX,
						y: frame.minY + table.rowEdges[row],
						width: table.columnEdges[table.columnEdges.count - 1],
						height: table.rowEdges[row + 1] - table.rowEdges[row]
					)
				)
			}
		}

		context.setStrokeColor(style.codeCardBorder)
		context.setLineWidth(1)
		let width = table.columnEdges[table.columnEdges.count - 1]
		let height = table.rowEdges[table.rowEdges.count - 1]
		for x in table.columnEdges {
			context.move(to: CGPoint(x: frame.minX + x, y: frame.minY))
			context.addLine(to: CGPoint(x: frame.minX + x, y: frame.minY + height))
		}
		for y in table.rowEdges {
			context.move(to: CGPoint(x: frame.minX, y: frame.minY + y))
			context.addLine(to: CGPoint(x: frame.minX + width, y: frame.minY + y))
		}
		context.strokePath()

		for cell in table.cells {
			let origin = CGPoint(x: frame.minX + cell.frame.minX, y: frame.minY + cell.frame.minY)
			TextLayout.draw(cell.lines, at: origin, in: context, dirty: dirty)
		}

		context.restoreGState()
	}
}
