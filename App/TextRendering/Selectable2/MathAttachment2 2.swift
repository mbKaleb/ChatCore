//
//  MathAttachment2.swift
//  ChatCore
//
//  An equation that reserves space in the text stream and draws nothing.
//
//  It replaces `selectable`'s `BlockViewAttachment`, which hosted an
//  `NSHostingView` per equation and built it during layout. Here the attachment
//  is a hole: it occupies one character (U+FFFC), reports geometry that was
//  measured once by `MathCache`, and leaves the painting to
//  `SelectableLayoutFragment2` — the same place code cards and inline-code pills
//  are painted. Nothing about a visible frame typesets, measures or instantiates
//  anything.
//
//  The one character also keeps selection sweeping *through* the equation rather
//  than stopping at it, which is the property the whole renderer exists for.
//

import AppKit
import SwiftMath

nonisolated final class MathAttachment2: NSTextAttachment {

	/// The source, kept for copy fidelity and for the parse-failure fallback.
	let latex: String

	/// `nil` when the LaTeX didn't parse. The builder emits source text instead of
	/// an attachment in that case, so a live attachment always has an entry — this
	/// stays optional only so `attachmentBounds` can't trap.
	let entry: MathCache.Entry?

	/// Inline math sits on the surrounding baseline and is typeset in text mode;
	/// block math owns its paragraph.
	let isInline: Bool

	/// Padding around block math, so an equation isn't flush against the prose
	/// above and below it. Inline math gets none — it has to keep the line's
	/// rhythm.
	let padding: CGSize

	/// Written by `attachmentBounds` when a wide equation has to be shrunk to fit
	/// the column, and read back by the fragment at draw time.
	///
	/// Mutable state on an attachment is a smell, but the alternative is worse:
	/// the scale depends on the container width, which is not known when the
	/// string is built, and the *reserved* height has to already account for it or
	/// the equation overlaps its neighbours. TextKit lays out on one thread and
	/// always calls `attachmentBounds` before drawing the fragment that contains
	/// it, so the ordering holds.
	private(set) var scale: CGFloat = 1

	init(latex: String, entry: MathCache.Entry?, isInline: Bool, padding: CGSize) {
		self.latex = latex
		self.entry = entry
		self.isInline = isInline
		self.padding = padding
		super.init(data: nil, ofType: nil)
		// No `allowsTextAttachmentView`, and no `viewProvider` override: there is no
		// view. An attachment with no image and no cell still draws the generic
		// document icon, so an empty image stands in for "draws nothing".
		image = NSImage(size: NSSize(width: 1, height: 1))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func attachmentBounds(
		for attributes: [NSAttributedString.Key: Any],
		location: NSTextLocation,
		textContainer: NSTextContainer?,
		proposedLineFragment: CGRect,
		position: CGPoint
	) -> CGRect {
		guard let entry else {
			// Reserve one line so a failed parse leaves a gap the size of the text
			// that would have been there.
			let font = (attributes[.font] as? NSFont) ?? .systemFont(ofSize: 14)
			return CGRect(x: 0, y: 0, width: 0, height: font.ascender - font.descender)
		}

		// This is the hottest function in the math path — TextKit calls it for
		// every attachment on every layout pass — so it stays arithmetic over
		// values that were measured once.
		let available = proposedLineFragment.width
		let natural = entry.size.width + 2 * padding.width
		scale = available > 0 && natural > available ? available / natural : 1

		return CGRect(origin: CGPoint(x: 0, y: -below), size: size)
	}

	// MARK: - Geometry

	/// The reserved box, scaled to whatever fit the column.
	var size: CGSize {
		guard let entry else { return .zero }
		return CGSize(
			width: (entry.size.width + 2 * padding.width) * scale,
			height: (entry.size.height + 2 * padding.height) * scale
		)
	}

	/// How far the box hangs below the baseline.
	///
	/// Block math hangs by its full height, so its line box is exactly the
	/// equation. Inline math hangs by its own descent, which is what puts it on
	/// the same baseline as the words around it instead of sitting on top of them.
	private var below: CGFloat {
		guard let entry else { return 0 }
		return isInline ? (entry.descent + padding.height) * scale : size.height
	}

	/// The reserved box in view coordinates, given where the line put it.
	///
	/// `x` is the left edge of the attachment character and `baseline` the line's
	/// baseline, both already in the coordinate space being drawn into. Flipped
	/// coordinates, so hanging below the baseline means a larger `y`.
	func box(x: CGFloat, baseline: CGFloat) -> CGRect {
		let size = size
		return CGRect(
			x: x,
			y: baseline + below - size.height,
			width: size.width,
			height: size.height
		)
	}

	/// Where the display itself goes inside that box.
	///
	/// The padding is inside the reserved box and shrinks with it, so this can't
	/// drift from what `attachmentBounds` promised.
	func displayRect(in box: CGRect) -> CGRect {
		guard let entry else { return .null }
		return CGRect(
			x: box.minX + padding.width * scale,
			y: box.minY + padding.height * scale,
			width: entry.size.width * scale,
			height: entry.size.height * scale
		)
	}
}
