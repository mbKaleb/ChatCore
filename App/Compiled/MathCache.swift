//
//  MathCache.swift
//  ChatCore
//
//  Prototype renderer — see CompiledMessageList.swift.
//

import AppKit
import SwiftMath

/// Typeset math, kept as a vector display rather than a rasterized image.
///
/// The height of an equation is a pure function of `(latex, fontSize)`, so these
/// are shared across every message and every conversation in the process — the
/// same equation typeset in twenty replies costs one typeset. That also means the
/// estimator guesswork the old list needed for math (`mathDisplayRatio`) has no
/// counterpart here: `size` is exact from the first frame.
///
/// Colour is baked in by `MTMathUILabel` during layout and `MTDisplay.textColor`
/// isn't public, so a theme change re-typesets rather than re-colouring. That's
/// the one avoidable cost in here; the fix is a `textColor` accessor upstream.
@MainActor
enum MathCache {

	/// `nonisolated` and `@unchecked Sendable` so the TextKit renderers can read
	/// geometry and paint from their own nonisolated layout classes. Every field is
	/// a `let` written once during `entry(latex:fontSize:color:mode:)`, and
	/// `MTMathListDisplay` is only ever read after that — drawing it doesn't mutate
	/// it. Nothing here is main-actor state; only the cache around it is.
	nonisolated struct Entry: @unchecked Sendable {
		let display: MTMathListDisplay
		/// Exact box the display paints into.
		let size: CGSize
		/// How far the display reaches below its baseline. Block math ignores this;
		/// inline math needs it to sit on the surrounding text's baseline instead
		/// of on the bottom of its own box.
		let descent: CGFloat
	}

	private struct Key: Hashable {
		let latex: String
		let fontSize: CGFloat
		let color: String
		let inline: Bool
	}

	private static var storage: [Key: Entry] = [:]

	/// Keys oldest-used first. Promotion happens on every hit, so what falls off the
	/// front is the equation nobody has laid out in the longest time — not merely the
	/// one compiled earliest. Insertion order was the wrong rule here: a transcript
	/// full of one recurring equation would evict it in favour of one-offs scrolled
	/// past once.
	private static var order: [Key] = []
	private static let capacity = 512

	/// Reused across every typeset — `MTMathUILabel` is an `NSView`, and building
	/// one per equation was most of the cost.
	private static let label: MTMathUILabel = {
		let label = MTMathUILabel()
		label.labelMode = .display
		label.textAlignment = .left
		label.contentInsets = MTEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
		label.displayErrorInline = false
		return label
	}()

	/// Returns `nil` when the LaTeX doesn't parse, so the caller can fall back to
	/// showing the source rather than a blank hole.
	///
	/// `inline` is a real cache dimension, not a scale factor applied afterwards:
	/// text mode sets fractions, limits and operators at different sizes from
	/// display mode, so the same latex has two different typesettings.
	static func entry(
		latex: String,
		fontSize: CGFloat,
		color: NSColor,
		inline: Bool = false
	) -> Entry? {
		let key = Key(latex: latex, fontSize: fontSize, color: colorToken(color), inline: inline)
		if let hit = storage[key] {
			promote(key)
			return hit
		}

		// Set every time rather than once at construction: the label is shared, so
		// whatever the last caller wanted is what it still holds.
		label.labelMode = inline ? .text : .display
		label.fontSize = fontSize
		label.textColor = color
		label.latex = latex
		guard label.mathList != nil else { return nil }

		// `_layoutSubviews` positions the display relative to the label's bounds,
		// so the bounds have to be right *before* the layout that produces the
		// display we keep. With zero insets and a box of exactly this height the
		// display lands at (0, descent), which is what `draw(_:in:)` assumes.
		let fitting = label.fittingSize
		let boxHeight = max(fitting.height, fontSize / 2)
		label.frame = CGRect(x: 0, y: 0, width: fitting.width, height: boxHeight)
		label.layout()

		guard let display = label.displayList else { return nil }
		let entry = Entry(
			display: display,
			size: CGSize(width: fitting.width, height: boxHeight),
			descent: display.descent
		)

		storage[key] = entry
		order.append(key)
		evictOverflow()
		return entry
	}

	/// Paint an entry into `rect`, which must have been sized from `entry.size`.
	///
	/// `MTMathListDisplay` draws in y-up space; the document view is flipped, so
	/// the context is flipped back around the box for the duration of the draw.
	///
	/// Must be called with `NSGraphicsContext.current` set to this same context.
	/// SwiftMath draws fraction bars and radical vinculums with `NSBezierPath`,
	/// which paints into the *current* graphics context rather than the one it was
	/// handed — so off the `NSView.draw(_:)` path (rendering to a bitmap, say)
	/// those strokes vanish silently and everything else looks right.
	///
	/// `nonisolated` because it is a pure function of its arguments — it touches
	/// neither the storage nor the shared label — and the TextKit layout classes
	/// that paint math are themselves nonisolated.
	nonisolated static func draw(_ entry: Entry, in rect: CGRect, context: CGContext) {
		// The text matrix is NOT part of the graphics state — `saveGState` won't
		// bring it back. Restoring it by hand is the whole reason this isn't a
		// plain save/restore pair: leaving the identity matrix behind rendered
		// every glyph after the first equation upside down, with its baseline
		// still in the right place.
		let restoreTextMatrix = context.textMatrix

		context.saveGState()
		context.translateBy(x: rect.minX, y: rect.minY + rect.height)
		context.scaleBy(x: 1, y: -1)
		// The display assumes the identity text matrix the way `MTMathUILabel`
		// leaves it; with the CTM flipped back to y-up here, that draws upright.
		context.textMatrix = .identity
		entry.display.draw(context)
		context.restoreGState()

		context.textMatrix = restoreTextMatrix
	}

	/// Move `key` to the most-recently-used end.
	///
	/// A linear search over at most `capacity` keys, and only on a compile — nothing
	/// on the scroll or draw path reaches this, because a laid-out equation is held
	/// by the block that draws it rather than looked up again.
	private static func promote(_ key: Key) {
		guard let index = order.firstIndex(of: key), index != order.count - 1 else { return }
		order.remove(at: index)
		order.append(key)
	}

	private static func evictOverflow() {
		let overflow = order.count - capacity
		guard overflow > 0 else { return }
		for key in order.prefix(overflow) { storage.removeValue(forKey: key) }
		order.removeFirst(overflow)
	}

	private static func colorToken(_ color: NSColor) -> String {
		guard let rgb = color.usingColorSpace(.sRGB) else { return color.description }
		return String(
			format: "%.3f,%.3f,%.3f,%.3f",
			rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent
		)
	}
}
