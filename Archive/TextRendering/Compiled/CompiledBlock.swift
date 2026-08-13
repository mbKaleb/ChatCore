//
//  CompiledBlock.swift
//  ChatCore
//
//  Prototype renderer — see CompiledMessageList.swift.
//

import AppKit

// MARK: - Block

/// One markdown block, laid out and ready to paint.
///
/// The block is the unit rather than the message because it's the smallest thing
/// whose rendering is context-free — a *line* isn't, since whether it's code, a
/// table cell or a list continuation depends on the block enclosing it. Block
/// granularity is also what makes the width-invariance below exploitable.
struct CompiledBlock {

	enum Content {
		case text([CompiledLine])
		/// Draws a card behind itself. Never wraps, so its height is
		/// width-invariant and a resize can keep it.
		case code([CompiledLine])
		/// Also width-invariant.
		case math(MathCache.Entry)
		case table(CompiledTable)
		case rule
	}

	var content: Content

	/// Content-box relative, flipped (y down).
	var frame: CGRect

	/// Blockquote nesting. Each level paints a rule at its leading edge.
	var quoteDepth: Int = 0

	/// Bullet or list number, positioned in block space.
	var marker: CompiledLine?

	/// Inline-code backgrounds, block-relative.
	var pills: [CGRect] = []

	/// Strikethrough rules, block-relative.
	///
	/// CoreText draws underlines but has no strikethrough attribute — unlike
	/// `NSLayoutManager`, which is why this is geometry rather than an attribute.
	var strikes: [CGRect] = []

	/// The vertical space that was inserted above this block, already resolved.
	///
	/// The compiler collapses adjacent margins the way CSS does — `max(bottom, top)`
	/// rather than their sum — and a list overrides the gap between its items. All
	/// of those inputs are style constants, none of them depend on width, so a
	/// reflow replays the resolved number instead of re-deriving it. Storing the
	/// answer rather than the algebra is also what keeps `MessageCompiler.reflow`
	/// from having to know the list rules a second time.
	var topGap: CGFloat = 0

	/// A table's unclipped width, kept so a resize can re-clamp `frame` without
	/// re-measuring a single cell.
	///
	/// Cells are laid out unwrapped, so a table's column widths, row heights and
	/// cell frames are all width-invariant; the only thing a resize changes is how
	/// much of it is visible.
	var naturalWidth: CGFloat = 0

	/// What a `.text` block needs to wrap itself again at a new width.
	///
	/// Only text blocks carry one — they're the only content whose *height* moves
	/// with the column. Everything width-independent about the wrap is already done
	/// and held in `prepared`, so a resize is a run of
	/// `CTTypesetterSuggestLineBreak` calls and nothing else: no markdown parse, no
	/// inline-attribute pass, no glyph shaping.
	var reflow: Reflow?

	struct Reflow {
		var prepared: TextLayout.Prepared
		var lineSpacing: CGFloat
		/// Inline-code and strikethrough runs, as ranges into the source string. The
		/// pill and strike *rects* are geometry over wrapped lines, so they have to
		/// be rebuilt after every re-wrap; the ranges they come from don't move.
		var codeRanges: [NSRange]
		var strikeRanges: [NSRange]
	}
}

// MARK: - Table

struct CompiledTable {

	struct Cell {
		var lines: [CompiledLine]
		/// Block-relative.
		var frame: CGRect
		var isHeader: Bool
	}

	var cells: [Cell]
	/// Column boundaries, block-relative, `columns + 1` entries.
	var columnEdges: [CGFloat]
	/// Row boundaries, block-relative, `rows + 1` entries.
	var rowEdges: [CGFloat]
}

// MARK: - Message

/// A compiled message: its blocks, plus the bubble geometry they sit inside.
///
/// Block frames are relative to `contentOrigin`, which is relative to the row.
/// Nothing in here is absolute, so a message can be moved in the document by
/// changing one prefix sum rather than touching any geometry.
struct CompiledMessage {
	let id: UUID
	let isAssistant: Bool
	var blocks: [CompiledBlock]
	/// Row-relative.
	var bubbleRect: CGRect
	/// Row-relative origin that block frames are measured from.
	var contentOrigin: CGPoint
	var height: CGFloat
	/// The width this was compiled at, so a resize knows what to discard.
	var compiledWidth: CGFloat
}

// MARK: - Document

/// The whole transcript, compiled.
///
/// `offsets` is a prefix sum over row heights, so mapping a scroll position to a
/// message is a binary search and nothing else. There is no height cache, no
/// estimator and no correction pass — heights here are measurements, because the
/// thing that produced them is the same thing that will paint them.
struct CompiledDocument {

	private(set) var messages: [CompiledMessage] = []
	/// `messages.count + 1` entries; `offsets[i]` is the top of message `i`.
	private(set) var offsets: [CGFloat] = [0]
	private(set) var width: CGFloat = 0

	var totalHeight: CGFloat { offsets.last ?? 0 }
	var isEmpty: Bool { messages.isEmpty }
	var count: Int { messages.count }

	init(width: CGFloat = 0) {
		self.width = width
	}

	subscript(index: Int) -> CompiledMessage { messages[index] }

	func top(of index: Int) -> CGFloat { offsets[index] }

	mutating func append(_ message: CompiledMessage) {
		messages.append(message)
		offsets.append(totalHeight + message.height)
	}

	/// Swap a message in place, re-flowing everything below it.
	///
	/// The streaming case: only the last message changes, so this is O(1)
	/// amortised for the shape that actually happens.
	mutating func replace(at index: Int, with message: CompiledMessage) {
		guard messages.indices.contains(index) else { return }
		messages[index] = message
		rebuildOffsets(from: index)
	}

	mutating func removeAll(keepingWidth: Bool = true) {
		messages.removeAll()
		offsets = [0]
		if !keepingWidth { width = 0 }
	}

	mutating func setWidth(_ new: CGFloat) { width = new }

	private mutating func rebuildOffsets(from index: Int) {
		for i in index ..< messages.count {
			offsets[i + 1] = offsets[i] + messages[i].height
		}
	}

	/// Index of the first message whose bottom edge is at or below `y`.
	///
	/// Binary search over the prefix sums — the whole reason the document is a
	/// flat array of heights rather than a view hierarchy.
	func firstIndex(endingAtOrAfter y: CGFloat) -> Int {
		var low = 0
		var high = messages.count
		while low < high {
			let mid = (low + high) / 2
			if offsets[mid + 1] <= y { low = mid + 1 } else { high = mid }
		}
		return low
	}

	/// The messages `rect` touches.
	func indexes(in rect: CGRect) -> Range<Int> {
		guard !messages.isEmpty else { return 0 ..< 0 }
		let first = firstIndex(endingAtOrAfter: rect.minY)
		guard first < messages.count else { return 0 ..< 0 }
		var last = first
		while last < messages.count, offsets[last] < rect.maxY { last += 1 }
		return first ..< last
	}
}
