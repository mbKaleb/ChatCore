//
//  SelectableLayoutFragment.swift
//  ChatCore
//
//  Prototype: block decoration that stays inside the text container.
//
//  Code cards, quote rules and inline-code pills are *painted*, not built out of
//  sibling views. That is the whole trick — the text never leaves the single
//  NSTextContainer, so selection keeps flowing across it.
//

import AppKit

nonisolated final class SelectableLayoutFragment: NSTextLayoutFragment {

	var kind: BlockKind = .paragraph
	var decoration = FragmentDecoration()

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

		default:
			return nil
		}
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

			string.enumerateAttribute(.inlineCode, in: range) { value, subrange, _ in
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
