# LaTeX in `selectable2`

Goal: equations that cost nothing to scroll past. A visible frame must never
parse, typeset, measure, or instantiate a view — it may only blit something that
was already laid out.

## What it replaced

`selectable`'s math path is `BlockViewAttachment`, and every part of it is on the
scroll budget: an `NSHostingView` built **per equation, during layout**; a height
guessed from a line count (`26 + lines * 24`), which is wrong for anything with a
fraction; content that isn't math at all but the source in italic serif; and no
cache, so a streamed rebuild recreates every attachment per token.

## What is there now

**Math is painted, not hosted.** Same trick the renderer already used for code
cards and inline-code pills: the content stays inside the one `NSTextContainer`,
and `SelectableLayoutFragment2.draw(at:in:)` paints it. One selection domain, one
draw pass, no sibling views.

| | |
|---|---|
| [MathAttachment2.swift](MathAttachment2.swift) | A hole in the text: one U+FFFC, exact geometry, no `viewProvider`. Carries the typeset `MathCache.Entry`. |
| [MarkdownAttributedBuilder2.swift](MarkdownAttributedBuilder2.swift) | Typesets at build time — fenced ` ```math ` and inline `$…$` — and puts the entry on the attachment. |
| [SelectableLayoutFragment2.swift](SelectableLayoutFragment2.swift) | `drawMath` finds where the line put each attachment and blits the cached display there. |
| [MathCache.swift](../Markdown/MathCache.swift) | Shared with `compiled`. Gained an `inline` key dimension, a `descent` on `Entry`, and a `nonisolated` `draw`. |

The costs, in order: **build time** typesets each equation once (a dictionary hit
on every rebuild after the first, since `MathCache` is keyed on
`(latex, fontSize, colour, inline)` and shared process-wide); **layout** reads
stored `CGFloat`s out of `attachmentBounds`; **draw** is a blit.

### Details worth keeping in mind

- **Baseline, not top.** `attachmentBounds` is stated relative to the baseline, so
  the fragment places the box from `typographicBounds.minY + glyphOrigin.y`. Block
  math hangs by its full height; inline math hangs by its own descent, which is
  what puts it on the line rather than on top of it.
- **`NSGraphicsContext.current`.** SwiftMath strokes fraction bars and radical
  vinculums through `NSBezierPath`, which paints into the *current* context, not
  the one it was handed. `drawMath` pushes one explicitly — without it those
  strokes vanish silently off the `NSView.draw` path and everything else looks
  right.
- **Wide equations** shrink to the column. The scale is computed in
  `attachmentBounds` (the only place the available width is known) and stored, so
  the reserved height already accounts for it.
- **Colour is baked in** by SwiftMath at typeset time, so it is a cache key rather
  than a draw-time choice. `Coordinator.apply` resolves the theme colour against
  the view's appearance and includes it in the rebuild guard — a light/dark switch
  re-typesets once and then hits cache in both directions.
- **`$…$` only** for inline. `\(…\)` cannot work: CommonMark eats a backslash
  before ASCII punctuation, so by the time a `Text` node arrives the delimiters
  are gone and it reads as `(x)`. Block math is pre-fenced by
  `MathMarkdown.preprocess`, which runs before parsing and doesn't have that
  problem.
- **Prices stay prices.** No space just inside either delimiter, no empty body, no
  newline, and no digit right after the closer — which is what keeps "$5 to $10"
  from typesetting "5 to ".
- **Copy** gives back source: `$latex$` for inline, a `math` fence for block, on
  top of the whole-block `.markdownSource2` round-trip that was already there.
- **Parse failures** fall through to the source — a bad fence renders as a code
  card, bad inline math keeps its delimiters.
- **Missing commands are a parse failure, not a missing glyph.** SwiftMath ships
  no `\blacksquare`, so the whole equation fell back to `$\blacksquare$`.
  [LatexCompat.swift](../Markdown/LatexCompat.swift) now registers the gaps into
  `MTMathAtomFactory` on first use. Substituting the Unicode character into the
  source instead does *not* work: `atom(forCharacter:)` refuses anything outside
  printable ASCII, so a bare `■` parses without error and typesets to nothing —
  zero width, no glyph, no warning. This is shared with every renderer, not just
  this fork.

## Verified

An offscreen probe compiles the real `SelectableTextView2`, lays it out in a
borderless window and captures with `cacheDisplay`, light and dark. This is only
possible *because* the math moved into the fragment: `cacheDisplay` walks
`draw(_:)` and cannot capture a layer-backed `NSHostingView`, so the old
attachment came out blank.

Fraction bars, radicals, integral signs with limits, inline math on the baseline,
and `$5 to $10` left as text all came out right, and all four equations in the
sample resolved to typeset entries rather than fallback source.

## Not done

- **No scroll measurement yet.** The design says a scroll can't typeset; that
  hasn't been demonstrated on a real transcript. The check is a counter on
  `MathCache.entry` that must stay flat while scrolling ~200 messages with math
  in a third of them.
- **Streaming rebuilds the whole string per token,** as before. Each equation is
  now a dictionary hit rather than a typeset, which is probably enough; if it
  isn't, keep a per-coordinator `[Key: MathAttachment2]` so the attachment objects
  are reused too.
- **`MathCache` is shared with `compiled`,** so the `inline`/`descent` additions
  are the one place this fork isn't self-contained. Both changes are additive and
  `compiled` still passes its own path unchanged.
