//
//  BlockLayoutCache.swift
//  ChatCore
//
//  Prototype renderer — see CompiledMessageList.swift.
//

import AppKit

/// Laid-out blocks from the previous compile of one message, keyed by the
/// markdown they came from.
///
/// The streaming problem this solves: a reply arrives a few tokens at a time, and
/// every tick re-runs `MessageCompiler.compile` over the *whole* message so far.
/// Parsing that again is cheap; re-shaping every glyph in it is not, so a long
/// answer gets quadratically more expensive to receive the longer it gets.
///
/// Reusing the tail is not a matter of appending to the last block, because
/// markdown has no such guarantee: a newly arrived ``` turns the paragraph above
/// it into a code fence, a `|` row extends a table, a blank line closes a list.
/// What *is* stable is the mapping from a block's source text to its layout — so
/// this keys on the markdown a block was parsed from (see `SourceSlicer`) and
/// lets the parser decide which blocks are still the same. A tick where only the
/// final paragraph grew misses once and hits on
/// everything above it; a tick where a fence retroactively swallowed three
/// paragraphs misses on all of them, correctly, because their source is now part
/// of a different block.
///
/// Entries are only kept for one generation: `begin`/`finish` rotate the map, so
/// a block that stopped appearing falls out on the next compile rather than
/// accumulating. Even so this holds a second reference to every `CTLine` in the
/// message it caches, which is why the controller keeps exactly one — the message
/// being streamed. See `CompiledListViewController.compiled(_:)`.
struct BlockLayoutCache {

	// MARK: Results

	/// Everything about a wrapped text block that costs more than arithmetic.
	/// Frames and margins aren't in here: `BlockCompiler.emit` recomputes those
	/// each pass, and they're a handful of additions.
	struct TextLayoutResult {
		var lines: [CompiledLine]
		var size: CGSize
		var pills: [CGRect]
		var strikes: [CGRect]
		var reflow: CompiledBlock.Reflow
	}

	/// A code card's lines, laid out unwrapped. `size` is the natural text box —
	/// the card's own frame is derived from the column width by the caller.
	struct CodeLayoutResult {
		var lines: [CompiledLine]
		var size: CGSize
	}

	/// A table's cells and its *unclipped* size. Both are width-invariant; only
	/// how much of it shows depends on the column.
	struct TableLayoutResult {
		var table: CompiledTable
		var size: CGSize
	}

	// MARK: Key

	/// What makes two blocks interchangeable, beyond their source text.
	///
	/// Role is in here because the same words typeset differently as a heading, and
	/// the font and colour a role resolves to are pinned by the style's layout key,
	/// checked once in `begin`.
	enum Kind: Hashable {
		case body
		case heading(Int)
		case code
		case table
	}

	private struct Key: Hashable {
		let source: String
		let kind: Kind
		/// The column the block wrapped into, or 0 for content that never wraps.
		let width: CGFloat
	}

	private enum Value {
		case text(TextLayoutResult)
		case code(CodeLayoutResult)
		case table(TableLayoutResult)
	}

	/// Last compile's blocks — the only thing a lookup reads.
	private var previous: [Key: Value] = [:]
	/// This compile's blocks, hit or miss, so `finish` can drop what went away.
	private var current: [Key: Value] = [:]
	/// What `previous` was laid out against. A style change that moves fonts or
	/// colours invalidates every line in here at once.
	private var layoutKey: CompileStyle.LayoutKey?

	/// Blocks the last pass reused and blocks it had to lay out.
	///
	/// Worth having beyond curiosity: a key that stops matching doesn't break
	/// anything, it just quietly stops saving anything, and hit rate is the only
	/// symptom. `-renderDebug` prints it.
	private(set) var hits = 0
	private(set) var misses = 0

	// MARK: Generations

	/// Open a compile pass, discarding everything if the style no longer matches.
	mutating func begin(layoutKey new: CompileStyle.LayoutKey) {
		if layoutKey != new {
			previous.removeAll(keepingCapacity: true)
			layoutKey = new
		}
		current.removeAll(keepingCapacity: true)
		hits = 0
		misses = 0
	}

	/// Close a compile pass. Only blocks this pass actually used survive into the
	/// next one, so an edit that shortens a message releases the rest immediately.
	mutating func finish() {
		previous = current
		current.removeAll(keepingCapacity: true)
	}

	// MARK: Lookup
	//
	// `make` returns nil for a block that compiled to nothing (an empty paragraph,
	// say); those aren't cached, since not emitting is cheaper than a lookup.

	mutating func text(
		source: String,
		kind: Kind,
		width: CGFloat,
		make: () -> TextLayoutResult?
	) -> TextLayoutResult? {
		let key = Key(source: source, kind: kind, width: width)
		if case .text(let hit)? = previous[key] {
			hits += 1
			current[key] = .text(hit)
			return hit
		}
		misses += 1
		guard let made = make() else { return nil }
		current[key] = .text(made)
		return made
	}

	mutating func code(source: String, make: () -> CodeLayoutResult?) -> CodeLayoutResult? {
		let key = Key(source: source, kind: .code, width: 0)
		if case .code(let hit)? = previous[key] {
			hits += 1
			current[key] = .code(hit)
			return hit
		}
		misses += 1
		guard let made = make() else { return nil }
		current[key] = .code(made)
		return made
	}

	mutating func table(source: String, make: () -> TableLayoutResult?) -> TableLayoutResult? {
		let key = Key(source: source, kind: .table, width: 0)
		if case .table(let hit)? = previous[key] {
			hits += 1
			current[key] = .table(hit)
			return hit
		}
		misses += 1
		guard let made = make() else { return nil }
		current[key] = .table(made)
		return made
	}
}
