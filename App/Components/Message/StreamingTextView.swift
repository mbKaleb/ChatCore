//
//  StreamingTextView.swift
//  ChatCore
//

import SwiftUI
import AppKit

/// Marks a span of the reply with the instant it is due on screen.
///
/// A `TextRenderer` is handed glyph runs and nothing else — no text, no source
/// range — so an attribute is the only handle it has on "which piece is this".
/// Carrying the arrival itself rather than an index into a side table also buys
/// the coalescing: Core Text merges adjacent runs whose attributes compare
/// *equal*, so pieces sharing an arrival (a delta too large for the pacer to
/// spread gets zero spacing) collapse into one run and one opacity, while
/// pieces on their own schedule stay apart. An id-per-piece tag would have
/// forced them apart for no visible difference.
///
/// `nonisolated` because the renderer's `draw` reads it and `draw` is
/// nonisolated; a main actor-isolated conformance cannot be used from there.
private nonisolated struct StreamPiece: TextAttribute {
	let arrival: ContinuousClock.Instant
}

/// Draws one already-laid-out `Text`, varying only the opacity of the pieces
/// still arriving.
///
/// The split between this and the view above is the whole point of the design:
/// layout is the expensive half and it does not depend on time, so it happens
/// once per arrival while only the opacity pass repeats at 60Hz. The old
/// renderer rebuilt a nested `Text` per segment on every frame instead, and
/// re-walked every character of the reply on every flush on top of that.
private nonisolated struct StreamFadeRenderer: TextRenderer {

	/// The instant this frame is drawn for, on the clock the arrivals were
	/// scheduled against.
	var now: ContinuousClock.Instant

	var fadeDuration: Duration

	var initialOpacity: Double

	func draw(layout: Text.Layout, in context: inout GraphicsContext) {
		for line in layout {
			for run in line {
				guard let piece = run[StreamPiece.self] else {
					// Untagged: the settled body. It shares one attribute set,
					// so however long the reply grows it arrives here as a
					// single run per line.
					context.draw(run)
					continue
				}
				let alpha = opacity(since: piece.arrival)
				if alpha >= 1 {
					context.draw(run)
				} else if alpha > 0 {
					var faded = context
					faded.opacity = alpha
					faded.draw(run)
				}
				// Zero means a piece scheduled ahead of this frame. Skipping the
				// draw is the same picture as drawing it transparent and
				// cheaper — and it was still laid out, so the space it will
				// take is already reserved and nothing reflows when it lands.
			}
		}
	}

	/// Ease-out cubic from `initialOpacity` to 1, and nothing at all before a
	/// piece is due.
	private func opacity(since arrival: ContinuousClock.Instant) -> Double {
		let elapsed = now - arrival
		// Pieces can be scheduled slightly ahead of now (paced reveal); they
		// hold invisible until their turn.
		guard elapsed >= .zero else { return 0 }
		guard elapsed < fadeDuration else { return 1 }
		let t = elapsed / fadeDuration
		let eased = 1 - pow(1 - t, 3)
		return initialOpacity + (1 - initialOpacity) * eased
	}
}

/// Plain text that fades in a piece at a time as the model streams it.
struct StreamingTextView: View {

	let chunks: [StreamChunk]
	var font: ChatFont = .system
	let fontSize: Double
	let lineSpacing: Double
	let color: Color
	var blockGap: Double = ChatMarkdownMetrics.blockGap

	/// How long one piece takes to reach full strength.
	private static let fadeDuration: Duration = .milliseconds(400)

	/// Where a piece starts. Not zero: a word appearing out of nothing reads as
	/// a flicker, one that starts faint reads as ink soaking in.
	private static let initialOpacity: Double = 0.12

	/// The settle deadline a timer has actually slept past.
	///
	/// An instant rather than a flag, so a chunk landing after a lull un-pauses
	/// the timeline in the same body evaluation that first sees it: the
	/// deadline moves, the comparison below stops matching, and no write from
	/// the restarted task is needed to get the next frame drawn.
	@State private var settledThrough: ContinuousClock.Instant?

	/// Segmentation and the folded-down settled prefix, carried across the body
	/// evaluations one stream causes.
	///
	/// A reference in `@State`, observed by nothing — mutating it cannot
	/// invalidate anything, which is what makes it safe to fill in from `body`.
	@State private var cache = StreamTextCache()

	var body: some View {
		// Only decides which pieces are old enough to fold into the untagged
		// prefix, which is a cost decision rather than a visual one: a piece
		// left tagged past its fade draws at full strength anyway. This sample
		// is taken before the renderer's and the renderer's is what the fade is
		// measured against, so a piece can never be folded ahead of finishing.
		let settledBefore = ContinuousClock.now - Self.fadeDuration
		let text = cache.text(
			for: chunks,
			gapLineHeight: gapLineHeight,
			settledBefore: settledBefore
		)

		return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isSettled)) { _ in
			// The schedule's context carries a wall-clock `Date` and no
			// monotonic instant, so the frame's time is sampled here instead.
			// Against a 400ms fade the gap between "this closure ran" and "the
			// frame was presented" is under one frame, and staying on a single
			// clock is what makes the arithmetic against `StreamChunk.arrival`
			// mean anything at all.
			text
				.textRenderer(
					StreamFadeRenderer(
						now: ContinuousClock.now,
						fadeDuration: Self.fadeDuration,
						initialOpacity: Self.initialOpacity
					)
				)
				.font(font.font(size: fontSize))
				.lineSpacing(lineSpacing)
				.foregroundStyle(color)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		}
		.task(id: settleDeadline) {
			guard let deadline = settleDeadline, settledThrough != deadline else { return }
			// Slept on the clock the arrivals were scheduled on, so the wake
			// lands when the last piece actually finishes rather than a
			// wall-clock step away from it. The tolerance is a frame: this only
			// has to beat the next tick, and a loose timer is a coalesced one.
			try? await Task.sleep(
				until: deadline, tolerance: .milliseconds(16), clock: .continuous
			)
			guard !Task.isCancelled else { return }
			settledThrough = deadline
		}
	}

	/// When the last piece on screen finishes fading — the moment there is
	/// nothing left to animate.
	private var settleDeadline: ContinuousClock.Instant? {
		chunks.last.map { $0.arrival + Self.fadeDuration }
	}

	/// Whether the 60Hz timeline can stop.
	///
	/// Derived from state a sleeping task writes, rather than from a `Date()`
	/// sampled inside `body`. The old form could never be true: `recordChunk`
	/// schedules arrivals at or after the moment it writes `liveChunks`, and
	/// that write is what re-evaluates this view — so every stream-driven
	/// evaluation read a last arrival that had not happened yet, pinned
	/// `paused` to false, and left the display link running until the row was
	/// torn down.
	private var isSettled: Bool {
		guard let settleDeadline else { return true }
		return settledThrough == settleDeadline
	}

	/// The line height the second newline of a blank line has to occupy for the
	/// blank line to read as exactly one block gap.
	///
	/// `blockGap - lineSpacing`, where every other block metric in the app adds:
	/// the newline itself already contributes one `lineSpacing`, so only the
	/// remainder is left to draw.
	private var gapLineHeight: Double {
		max(0, blockGap - lineSpacing)
	}
}

// MARK: - Text assembly

/// Turns the growing chunk list into one `Text`, incrementally.
///
/// Two jobs, both about not redoing work. The chunk-to-segment walk resumes
/// where it left off instead of re-reading the whole reply on every flush. And
/// every segment old enough to have finished fading is folded into a single
/// *untagged* run of text, which lets Core Text merge the settled body down to
/// one run per line — so the number of runs a frame touches stays flat at
/// roughly a pacing window's worth of pieces however long the reply gets.
/// Tagging every word instead measured ~14x the layout cost on every flush,
/// which is the difference between shippable and not.
@MainActor
private final class StreamTextCache {

	/// One drawable span: a run of non-newline characters, or a single newline.
	private struct Segment {
		var text: String
		var arrival: ContinuousClock.Instant
		/// The second newline of a blank line, drawn small enough that the
		/// blank line stands `blockGap - lineSpacing` tall instead of a full
		/// line.
		var isGap: Bool
	}

	/// What the assembled `Text` was last built from. Body runs for reasons
	/// that have nothing to do with the stream — a hover, a theme change — and
	/// none of them change a single glyph.
	private struct BuildKey: Equatable {
		var consumed: Int
		var folded: Int
	}

	/// Everything already faded in, folded down.
	private var settledHead = Text(verbatim: "")

	/// Settled text since the last gap, still a `String` so `settledHead` only
	/// deepens where a gap forces a font change rather than once per word.
	private var settledTail = ""

	/// Whether the folded text ends on a gap newline. Only reachable when
	/// `settledTail` is empty and nothing live follows, but that is exactly the
	/// state a reply ending in a blank line settles into.
	private var settledEndsWithGap = false

	/// Segmented, still fading or still to come.
	private var live: [Segment] = []

	/// How many chunks have been walked, and how many segments have been
	/// folded. Together they identify the assembled text.
	private var consumed = 0

	private var folded = 0

	/// The last chunk walked, to notice a list that was replaced rather than
	/// appended to — `recordChunk` starts over when a snapshot stops extending
	/// the one before it.
	private var consumedLast: StreamChunk?

	/// Consecutive newlines waiting to find out whether they are a line break
	/// or a block gap. The answer can be in the next chunk, so this carries
	/// across the chunk boundary; a run of text does not, since a chunk
	/// boundary always ends one.
	private var heldNewlines: [ContinuousClock.Instant] = []

	/// What the folded text was built against. A change starts over, because
	/// the gap font is baked into `settledHead`.
	private var gapLineHeight = Double.nan

	private var gapFont = Font.system(size: 1)

	private var builtKey: BuildKey?

	private var built = Text(verbatim: "")

	func text(
		for chunks: [StreamChunk],
		gapLineHeight: Double,
		settledBefore: ContinuousClock.Instant
	) -> Text {
		if gapLineHeight != self.gapLineHeight {
			self.gapLineHeight = gapLineHeight
			gapFont = .system(size: Self.fontSize(forLineHeight: gapLineHeight))
			reset()
		}
		if consumed > chunks.count || (consumed > 0 && chunks[consumed - 1] != consumedLast) {
			reset()
		}

		consume(chunks)
		settle(before: settledBefore)

		let key = BuildKey(consumed: consumed, folded: folded)
		if key == builtKey { return built }

		var assembled = Text("\(settledHead)\(Text(verbatim: settledTail))")
		var endsWithGap = settledTail.isEmpty && settledEndsWithGap
		for segment in live {
			assembled = Text("\(assembled)\(tagged(segment))")
			endsWithGap = segment.isGap
		}
		// Trailing newlines can still turn into a block gap once the next chunk
		// lands, so they are drawn but never committed.
		for segment in Self.gapSegments(heldNewlines) {
			assembled = Text("\(assembled)\(tagged(segment))")
			endsWithGap = segment.isGap
		}
		if endsWithGap {
			// A trailing empty line is the one place `.textRenderer` stops
			// honouring the gap font: it falls back to a fixed line box that
			// ignores both that font and `lineSpacing`, standing 14pt too tall at
			// the default spacing. Any character at all restores the real
			// metrics, so the cheapest fix is one that draws nothing. Streaming
			// hits this constantly — every flush whose snapshot happens to end on
			// a blank line would jolt the bubble until the next token landed.
			assembled = Text("\(assembled)\(Text(verbatim: "\u{200B}").font(gapFont))")
		}

		builtKey = key
		built = assembled
		return assembled
	}

	// MARK: - Segmentation

	private func consume(_ chunks: [StreamChunk]) {
		guard consumed < chunks.count else { return }

		var buffer = ""
		var bufferArrival = chunks[consumed].arrival

		func flushBuffer() {
			guard !buffer.isEmpty else { return }
			live.append(Segment(text: buffer, arrival: bufferArrival, isGap: false))
			buffer.removeAll(keepingCapacity: true)
		}

		func flushHeld() {
			guard !heldNewlines.isEmpty else { return }
			live.append(contentsOf: Self.gapSegments(heldNewlines))
			heldNewlines.removeAll(keepingCapacity: true)
		}

		for chunk in chunks[consumed...] {
			for character in chunk.text {
				if character == "\n" {
					flushBuffer()
					heldNewlines.append(chunk.arrival)
				} else {
					flushHeld()
					if buffer.isEmpty { bufferArrival = chunk.arrival }
					buffer.append(character)
				}
			}
			flushBuffer()
		}

		consumed = chunks.count
		consumedLast = chunks.last
	}

	/// A run of newlines as it is drawn: the first at full height, the second
	/// shrunk to the block gap, the rest dropped — which is what keeps a
	/// model's stray blank lines from tearing a hole in the reply.
	private static func gapSegments(_ held: [ContinuousClock.Instant]) -> [Segment] {
		guard let first = held.first else { return [] }
		var segments = [Segment(text: "\n", arrival: first, isGap: false)]
		if held.count >= 2 {
			segments.append(Segment(text: "\n", arrival: held[1], isGap: true))
		}
		return segments
	}

	// MARK: - Folding

	/// Arrivals are non-decreasing, so everything settled is a prefix.
	private func settle(before instant: ContinuousClock.Instant) {
		var count = 0
		while count < live.count, live[count].arrival <= instant {
			count += 1
		}
		guard count > 0 else { return }
		for segment in live.prefix(count) { fold(segment) }
		live.removeFirst(count)
		folded += count
	}

	private func fold(_ segment: Segment) {
		guard segment.isGap else {
			settledTail += segment.text
			settledEndsWithGap = false
			return
		}
		let gap = Text(verbatim: segment.text).font(gapFont)
		settledHead = Text("\(settledHead)\(Text(verbatim: settledTail))\(gap)")
		settledTail = ""
		settledEndsWithGap = true
	}

	private func tagged(_ segment: Segment) -> Text {
		// Interpolation, not `+`: `Text + Text` is deprecated as of macOS 26,
		// and the two lay out identically.
		let piece = Text(verbatim: segment.text)
			.customAttribute(StreamPiece(arrival: segment.arrival))
		return segment.isGap ? piece.font(gapFont) : piece
	}

	private func reset() {
		settledHead = Text(verbatim: "")
		settledTail = ""
		settledEndsWithGap = false
		live.removeAll(keepingCapacity: true)
		heldNewlines.removeAll(keepingCapacity: true)
		consumed = 0
		folded = 0
		consumedLast = nil
		builtKey = nil
		built = Text(verbatim: "")
	}

	/// The size at which the system font's line box is `target` tall, from its
	/// own ascender/descender/leading ratio.
	///
	/// Probes the system font whatever the body font is, as the old renderer
	/// did. The gap line is whitespace, and matching the body font's metrics
	/// here would shift every measured row height for no visible difference —
	/// including the ones `VirtualizedMessageList` estimates.
	private static func fontSize(forLineHeight target: Double) -> Double {
		let probe = NSFont.systemFont(ofSize: 10)
		let ratio = (probe.ascender - probe.descender + probe.leading) / 10
		guard ratio > 0 else { return max(0.5, target) }
		return max(0.5, target / ratio)
	}
}
