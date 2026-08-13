//
//  SelectableLayoutFragment3.swift
//  ChatCore
//
//  Prototype: block decoration that stays inside the text container.
//
//  Code cards, quote rules, inline-code pills, table grids and images are
//  *painted*, not built out of sibling views. That is the whole trick — the
//  text never leaves the single NSTextContainer, so selection keeps flowing
//  across it.
//

import AppKit

nonisolated final class SelectableLayoutFragment3: NSTextLayoutFragment {

	var kind: BlockKind3 = .paragraph
	var decoration = FragmentDecoration3()

	/// Identity for the copy button that floats over this card, from `.blockID3`.
	var blockID: Int?
	/// The card's code as authored, from `.codeSource3`. Nil on everything that
	/// isn't a code card.
	var codeSource: String?

	/// Whether the text view should keep a copy button positioned over this card.
	///
	/// The button is a real `NSButton` owned by the text view, not something this
	/// fragment paints. Painting one and hand-rolling its mouse handling was the
	/// first attempt, and inside SwiftUI hosting the events never arrived — the
	/// hosting window doesn't deliver mouse-moved events, and the List's gesture
	/// plumbing sits between the window and a hand-rolled `mouseDown`. A real
	/// control gets AppKit's routing, cursor rects and pressed state for free.
	var hasCopyButton: Bool {
		kind.isCard && codeSource != nil && decoration.copyButtonSize > 0
	}

	// MARK: - Reserved space

	// TextKit 2 keeps this space clear around the line fragments, which is where
	// the card is drawn. Doing it here rather than with paragraph spacing means the
	// card's own geometry and the reserved space can never drift apart.
	override var topMargin: CGFloat { kind.isCard ? decoration.padding.top : 0 }
	override var bottomMargin: CGFloat { kind.isCard ? decoration.padding.bottom : 0 }

	override var renderingSurfaceBounds: CGRect {
		guard let extra = decorationRect() else { return super.renderingSurfaceBounds }
		return super.renderingSurfaceBounds.union(extra.insetBy(dx: -1, dy: -1))
	}

	// MARK: - Drawing

	override func draw(at point: CGPoint, in context: CGContext) {
		context.saveGState()
		drawBlockDecoration(at: point, in: context)
		drawInlineCodePills(at: point, in: context)
		context.restoreGState()

		super.draw(at: point, in: context)

		// After `super`, so an equation or image paints over the (empty)
		// attachment glyph rather than under it.
		drawMath(at: point, in: context)
		drawImages(at: point, in: context)
	}

	private func drawBlockDecoration(at point: CGPoint, in context: CGContext) {
		guard let local = decorationRect() else { return }
		let rect = local.offsetBy(dx: point.x, dy: point.y)

		switch kind {
		case .codeBlock:
			let path = CGPath(
				roundedRect: rect,
				cornerWidth: decoration.cardCornerRadius,
				cornerHeight: decoration.cardCornerRadius,
				transform: nil
			)
			if let fill = decoration.cardFill {
				context.setFillColor(fill.cgColor)
				context.addPath(path)
				context.fillPath()
			}
			if let stroke = decoration.cardStroke {
				context.setStrokeColor(stroke.cgColor)
				context.setLineWidth(1)
				context.addPath(path)
				context.strokePath()
			}

		case .quote:
			guard let color = decoration.quoteRule else { return }
			context.setFillColor(color.cgColor)
			context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
			context.fillPath()

		case .rule:
			guard let color = decoration.horizontalRule else { return }
			context.setFillColor(color.cgColor)
			context.fill(rect)

		case .tableRow(let row, _, _):
			// `rect` spans this row including its vertical padding. The header
			// gets a fill; every row closes itself with a hairline at its bottom
			// edge, which lands in the padding shared with the next row — so the
			// rules read as one grid without any fragment seeing its siblings.
			// No vertical lines on purpose; the column gap does that work.
			if row == 0, let fill = decoration.tableHeaderFill {
				context.setFillColor(fill.cgColor)
				context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
				context.fillPath()
			}
			if let rule = decoration.tableRule {
				context.setFillColor(rule.cgColor)
				context.fill(CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
			}

		default:
			break
		}
	}

	/// The decoration rect in fragment-local coordinates, or nil when this block
	/// draws nothing behind its text.
	///
	/// `layoutFragmentFrame.origin.x` already carries the paragraph's head indent,
	/// and `draw(at:in:)` is handed that same origin — so the text container's left
	/// edge sits at `-indent` here, not at zero. Treating local x as container x
	/// shifts every decoration right by its own block's indent.
	private func decorationRect() -> CGRect? {
		let bounds = lineBounds()
		guard !bounds.isNull else { return nil }

		let indent = paragraphIndent()
		let containerWidth = contentWidth()

		switch kind {
		case .codeBlock:
			// The text is inset from the card by the padding, so the card's left edge
			// is exactly that padding to the left of where the text starts.
			return CGRect(
				x: -decoration.padding.left,
				y: bounds.minY - decoration.padding.top,
				width: max(0, containerWidth - indent + decoration.padding.left),
				height: bounds.height + decoration.padding.top + decoration.padding.bottom
			)

		case .quote(let depth):
			// Spans the full fragment height, including margins, so a quote made of
			// several paragraphs still reads as one continuous rule.
			return CGRect(
				x: CGFloat(depth - 1) * decoration.quoteIndent - indent,
				y: 0,
				width: 3,
				height: layoutFragmentFrame.height
			)

		case .rule:
			return CGRect(x: -indent, y: bounds.midY - 0.5, width: containerWidth, height: 1)

		case .tableRow(_, _, let width):
			// The grid extends a little past the cell text on both sides, capped
			// at the container so a too-wide table's decoration clips with its
			// clipped text rather than painting past the bubble.
			let inset = decoration.tableEdgeInset
			return CGRect(
				x: -inset,
				y: bounds.minY - decoration.tableRowPadding,
				width: min(width + 2 * inset, containerWidth - indent + inset),
				height: bounds.height + 2 * decoration.tableRowPadding
			)

		default:
			return nil
		}
	}

	// MARK: - Copy button

	/// Where the text view should place this card's copy button, in
	/// text-container coordinates.
	///
	/// The rect from `decorationRect()` is fragment-local, and a fragment's local
	/// origin is its `layoutFragmentFrame` origin — the same point
	/// `draw(at:in:)` is handed.
	func copyButtonFrame() -> CGRect? {
		guard hasCopyButton, let card = decorationRect() else { return nil }
		let size = decoration.copyButtonSize
		return CGRect(
			x: card.maxX - decoration.copyButtonInset - size,
			y: card.minY + decoration.copyButtonInset,
			width: size,
			height: size
		)
		.offsetBy(dx: layoutFragmentFrame.minX, dy: layoutFragmentFrame.minY)
	}

	// MARK: - Inline code pills

	// NSAttributedString's .backgroundColor gives an unpadded, square rectangle that
	// reads as a bug next to rounded UI. Drawing it here lets the pill have padding
	// and a corner radius while the code itself stays ordinary selectable text.
	private func drawInlineCodePills(at point: CGPoint, in context: CGContext) {
		guard let fill = decoration.inlineCodeFill else { return }

		var pills: [CGRect] = []
		for line in textLineFragments {
			let string = line.attributedString
			let range = NSIntersectionRange(line.characterRange, NSRange(location: 0, length: string.length))
			guard range.length > 0 else { continue }

			string.enumerateAttribute(.inlineCode3, in: range) { value, subrange, _ in
				guard value != nil, subrange.length > 0 else { return }
				let start = line.locationForCharacter(at: subrange.location).x
				let end = line.locationForCharacter(at: subrange.location + subrange.length).x
				guard end > start else { return }

				let bounds = line.typographicBounds
				pills.append(
					CGRect(
						x: bounds.minX + start,
						y: bounds.minY + 1,
						width: end - start,
						height: bounds.height - 2
					)
					.insetBy(dx: -decoration.inlineCodePadding, dy: 0)
					.offsetBy(dx: point.x, dy: point.y)
				)
			}
		}

		guard !pills.isEmpty else { return }
		context.setFillColor(fill.cgColor)
		for pill in pills {
			context.addPath(
				CGPath(
					roundedRect: pill,
					cornerWidth: decoration.inlineCodeCornerRadius,
					cornerHeight: decoration.inlineCodeCornerRadius,
					transform: nil
				)
			)
		}
		context.fillPath()
	}

	// MARK: - Math

	// The equation was typeset when the string was built, so this is a blit: find
	// where TextKit put the attachment character, and paint the cached display
	// there. Nothing here parses, measures or allocates a view, which is the whole
	// reason math lives in the fragment instead of in an `NSHostingView`.
	private func drawMath(at point: CGPoint, in context: CGContext) {
		for line in textLineFragments {
			let string = line.attributedString
			let range = NSIntersectionRange(line.characterRange, NSRange(location: 0, length: string.length))
			guard range.length > 0, string.containsAttachments(in: range) else { continue }

			string.enumerateAttribute(.attachment, in: range) { value, subrange, _ in
				guard
					let attachment = value as? MathAttachment3,
					let entry = attachment.entry
				else { return }

				// `attachmentBounds` is stated relative to the baseline, so the box
				// has to be placed from the baseline rather than from the top of the
				// line: `glyphOrigin` is the baseline origin within
				// `typographicBounds`.
				let bounds = line.typographicBounds
				let box = attachment.box(
					x: point.x + bounds.minX + line.locationForCharacter(at: subrange.location).x,
					baseline: point.y + bounds.minY + line.glyphOrigin.y
				)

				context.saveGState()
				// SwiftMath strokes fraction bars and radical vinculums through
				// `NSBezierPath`, which paints into `NSGraphicsContext.current`
				// rather than into the context it was handed. On the text view's
				// draw path that is already this context; off it — rendering to a
				// bitmap for a test — it is not, and those strokes vanish silently
				// while every glyph still looks right.
				let previous = NSGraphicsContext.current
				NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
				MathCache.draw(entry, in: attachment.displayRect(in: box), context: context)
				NSGraphicsContext.current = previous
				context.restoreGState()
			}
		}
	}

	// MARK: - Images

	// Same contract as math: the bitmap was loaded when the string was built, so
	// a visible frame only blits. `NSImage.draw` goes through the current
	// NSGraphicsContext, hence the same explicit push `drawMath` needs.
	private func drawImages(at point: CGPoint, in context: CGContext) {
		for line in textLineFragments {
			let string = line.attributedString
			let range = NSIntersectionRange(line.characterRange, NSRange(location: 0, length: string.length))
			guard range.length > 0, string.containsAttachments(in: range) else { continue }

			string.enumerateAttribute(.attachment, in: range) { value, subrange, _ in
				guard
					let attachment = value as? ImageAttachment3,
					let display = attachment.display
				else { return }

				let bounds = line.typographicBounds
				let box = attachment.box(
					x: point.x + bounds.minX + line.locationForCharacter(at: subrange.location).x,
					baseline: point.y + bounds.minY + line.glyphOrigin.y
				)
				guard !box.isEmpty else { return }

				context.saveGState()
				let radius = min(decoration.imageCornerRadius, box.width / 2, box.height / 2)
				context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
				context.clip()
				let previous = NSGraphicsContext.current
				NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
				display.draw(
					in: box,
					from: .zero,
					operation: .sourceOver,
					fraction: 1,
					respectFlipped: true,
					hints: [.interpolation: NSImageInterpolation.high.rawValue]
				)
				NSGraphicsContext.current = previous
				context.restoreGState()
			}
		}
	}

	// MARK: - Geometry helpers

	private func lineBounds() -> CGRect {
		textLineFragments.reduce(CGRect.null) { $0.union($1.typographicBounds) }
	}

	private func contentWidth() -> CGFloat {
		if let width = textLayoutManager?.textContainer?.size.width, width > 0, width < .greatestFiniteMagnitude {
			return width
		}
		return layoutFragmentFrame.width
	}

	/// The paragraph's head indent, which is also this fragment's x origin.
	private func paragraphIndent() -> CGFloat {
		guard
			let paragraph = textElement as? NSTextParagraph,
			paragraph.attributedString.length > 0,
			let style = paragraph.attributedString.attribute(
				.paragraphStyle, at: 0, effectiveRange: nil
			) as? NSParagraphStyle
		else { return 0 }
		return style.firstLineHeadIndent
	}
}
