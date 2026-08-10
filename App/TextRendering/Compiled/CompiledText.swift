//
//  CompiledText.swift
//  ChatCore
//
//  Prototype renderer — see CompiledMessageList.swift for what this is and how
//  to turn it on. Nothing here is reachable unless the toggle is set.
//

import AppKit
import CoreText
// `ChatFont.Kind` is expressed in terms of SwiftUI's `Font.Design`, so matching
// on it needs SwiftUI in scope even though nothing here renders with it.
import SwiftUI

// MARK: - A laid-out line

/// One laid-out line of text and where its baseline sits inside its block.
///
/// Origins are in flipped (top-left, y-down) space — the space the document view
/// draws in — so painting a line on the scroll path is a `textPosition` write and
/// a `CTLineDraw`, with no per-line coordinate conversion.
struct CompiledLine {
	let line: CTLine
	/// Baseline origin, block-relative.
	let origin: CGPoint
	let ascent: CGFloat
	let descent: CGFloat
	let width: CGFloat

	/// The box this line paints into, block-relative.
	var bounds: CGRect {
		CGRect(x: origin.x, y: origin.y - ascent, width: width, height: ascent + descent)
	}
}

// MARK: - Layout

enum TextLayout {

	/// A string that has been handed to CoreText but not yet committed to a width.
	///
	/// A `CTTypesetter` holds the glyphs, their advances and the shaping work for
	/// its string — all of which are width-independent. Only
	/// `CTTypesetterSuggestLineBreak` takes a width, and it takes one per call. So
	/// the expensive half of wrapping can be done once at compile time and reused by
	/// every subsequent resize, which is the whole reason a reflow is cheaper than a
	/// compile.
	///
	/// Segments are the hard-break split: one typesetter per source line, so a
	/// paragraph containing a newline stacks identically to two paragraphs rather
	/// than letting CoreText discover the break itself.
	struct Prepared {
		fileprivate let segments: [Segment]

		fileprivate struct Segment {
			let typesetter: CTTypesetter
			let length: Int
		}

		var isEmpty: Bool { segments.isEmpty }
	}

	/// Do the width-independent half of wrapping.
	static func prepare(_ string: NSAttributedString) -> Prepared {
		guard string.length > 0 else { return Prepared(segments: []) }
		return Prepared(
			segments: hardBreakSegments(of: string).map {
				Prepared.Segment(
					typesetter: CTTypesetterCreateWithAttributedString($0),
					length: $0.length
				)
			}
		)
	}

	/// Wrap `string` to `width`.
	///
	/// `lineSpacing` sits *between* lines, so a single line doesn't pay for it —
	/// the same rule `MDTheme` applies, so the two renderers agree.
	static func wrapped(
		_ string: NSAttributedString,
		width: CGFloat,
		lineSpacing: CGFloat
	) -> (lines: [CompiledLine], size: CGSize) {
		wrapped(prepare(string), width: width, lineSpacing: lineSpacing)
	}

	/// Commit an already-prepared string to `width`.
	static func wrapped(
		_ prepared: Prepared,
		width: CGFloat,
		lineSpacing: CGFloat
	) -> (lines: [CompiledLine], size: CGSize) {
		guard !prepared.isEmpty, width > 0 else { return ([], .zero) }

		var lines: [CompiledLine] = []
		var y: CGFloat = 0
		var maxWidth: CGFloat = 0

		for segment in prepared.segments {
			var start = 0
			let length = segment.length

			repeat {
				let count = CTTypesetterSuggestLineBreak(segment.typesetter, start, Double(width))
				// A width too narrow for a single glyph would otherwise spin here.
				let taken = max(1, count)
				let line = CTTypesetterCreateLine(
					segment.typesetter,
					CFRange(location: start, length: min(taken, length - start))
				)
				append(line, to: &lines, y: &y, maxWidth: &maxWidth, lineSpacing: lineSpacing)
				start += taken
			} while start < length
		}

		return (lines, CGSize(width: maxWidth, height: y))
	}

	/// Lay out one line per hard break, never wrapping.
	///
	/// Code and table rows scroll horizontally instead of wrapping, which is what
	/// makes their heights width-invariant — a resize never has to recompile them.
	static func unwrapped(
		_ string: NSAttributedString,
		lineSpacing: CGFloat = 0
	) -> (lines: [CompiledLine], size: CGSize) {
		guard string.length > 0 else { return ([], .zero) }

		var lines: [CompiledLine] = []
		var y: CGFloat = 0
		var maxWidth: CGFloat = 0

		for paragraph in hardBreakSegments(of: string) {
			let line = CTLineCreateWithAttributedString(paragraph)
			append(line, to: &lines, y: &y, maxWidth: &maxWidth, lineSpacing: lineSpacing)
		}

		return (lines, CGSize(width: maxWidth, height: y))
	}

	private static func append(
		_ line: CTLine,
		to lines: inout [CompiledLine],
		y: inout CGFloat,
		maxWidth: inout CGFloat,
		lineSpacing: CGFloat
	) {
		var ascent: CGFloat = 0
		var descent: CGFloat = 0
		var leading: CGFloat = 0
		let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

		if !lines.isEmpty { y += lineSpacing }
		y += ascent
		lines.append(
			CompiledLine(
				line: line,
				origin: CGPoint(x: 0, y: y),
				ascent: ascent,
				descent: descent,
				width: width
			)
		)
		y += descent + leading
		maxWidth = max(maxWidth, width)
	}

	/// Split on newlines, keeping empty segments so a blank line still occupies
	/// its line box.
	private static func hardBreakSegments(of string: NSAttributedString) -> [NSAttributedString] {
		let text = string.string
		guard text.contains("\n") else { return [string] }

		var segments: [NSAttributedString] = []
		var segmentStart = 0
		let ns = text as NSString

		for index in 0 ..< ns.length where ns.character(at: index) == 0x000A {
			segments.append(
				string.attributedSubstring(from: NSRange(location: segmentStart, length: index - segmentStart))
			)
			segmentStart = index + 1
		}
		segments.append(
			string.attributedSubstring(from: NSRange(location: segmentStart, length: ns.length - segmentStart))
		)
		return segments
	}

	/// Where `range` sits within `lines`, in block space.
	///
	/// Used for inline-code pills, which need a box behind a run rather than a
	/// whole line. A range that wraps produces one rect per line it touches.
	static func rects(for range: NSRange, in lines: [CompiledLine]) -> [CGRect] {
		guard range.length > 0 else { return [] }
		var rects: [CGRect] = []

		for compiled in lines {
			let lineRange = CTLineGetStringRange(compiled.line)
			let lineStart = lineRange.location
			let lineEnd = lineStart + lineRange.length
			let start = max(range.location, lineStart)
			let end = min(range.location + range.length, lineEnd)
			guard start < end else { continue }

			let startX = CTLineGetOffsetForStringIndex(compiled.line, start, nil)
			let endX = CTLineGetOffsetForStringIndex(compiled.line, end, nil)
			rects.append(
				CGRect(
					x: compiled.origin.x + startX,
					y: compiled.origin.y - compiled.ascent,
					width: endX - startX,
					height: compiled.ascent + compiled.descent
				)
			)
		}
		return rects
	}

	/// Glyphs are laid out y-up; the document view is flipped, so drawing into it
	/// needs the text matrix inverted to match.
	static let flippedTextMatrix = CGAffineTransform(scaleX: 1, y: -1)

	/// Draw `lines`, skipping anything the dirty rect doesn't touch.
	///
	/// `origin` is the block's top-left in view space.
	///
	/// Sets the text matrix itself rather than trusting the caller to have set it
	/// once per pass. It isn't part of the graphics state, so a `saveGState` around
	/// a neighbouring draw won't put it back — anything that changes it leaks, and
	/// the symptom is upside-down glyphs several blocks later. Establishing it here
	/// makes the invariant local to the code that depends on it.
	static func draw(
		_ lines: [CompiledLine],
		at origin: CGPoint,
		in context: CGContext,
		dirty: CGRect
	) {
		context.textMatrix = flippedTextMatrix
		for compiled in lines {
			let top = origin.y + compiled.origin.y - compiled.ascent
			let bottom = top + compiled.ascent + compiled.descent
			guard bottom >= dirty.minY else { continue }
			guard top <= dirty.maxY else { return }

			context.textPosition = CGPoint(
				x: origin.x + compiled.origin.x,
				y: origin.y + compiled.origin.y
			)
			CTLineDraw(compiled.line, context)
		}
	}

	/// Draw a single line at `origin` — list markers, which sit outside their
	/// block's line array. Sets the text matrix for the same reason `draw` does.
	static func draw(_ line: CompiledLine, at origin: CGPoint, in context: CGContext) {
		context.textMatrix = flippedTextMatrix
		context.textPosition = CGPoint(x: origin.x + line.origin.x, y: origin.y + line.origin.y)
		CTLineDraw(line.line, context)
	}
}

// MARK: - Fonts

/// `ChatFont` resolved to a `CTFont`, which is what CoreText needs and SwiftUI's
/// `Font` can't give us.
enum CompiledFonts {

	private struct Key: Hashable {
		let id: String
		let size: CGFloat
		let bold: Bool
		let italic: Bool
	}

	private static var cache: [Key: CTFont] = [:]

	static func font(
		_ chatFont: ChatFont,
		size: CGFloat,
		bold: Bool = false,
		italic: Bool = false
	) -> CTFont {
		let key = Key(id: chatFont.id, size: size, bold: bold, italic: italic)
		if let hit = cache[key] { return hit }

		let base: NSFont
		switch chatFont.kind {
		case .system(let design):
			let weight: NSFont.Weight = bold ? .bold : .regular
			switch design {
			case .monospaced:
				base = .monospacedSystemFont(ofSize: size, weight: weight)
			case .rounded:
				base = descended(.systemFont(ofSize: size, weight: weight), design: .rounded)
			case .serif:
				base = descended(.systemFont(ofSize: size, weight: weight), design: .serif)
			default:
				base = .systemFont(ofSize: size, weight: weight)
			}
		case .family(let name):
			base = NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
		}

		var traits: NSFontTraitMask = []
		if bold { traits.insert(.boldFontMask) }
		if italic { traits.insert(.italicFontMask) }

		let resolved = traits.isEmpty
			? base
			: (NSFontManager.shared.convert(base, toHaveTrait: traits))

		let ct = resolved as CTFont
		cache[key] = ct
		return ct
	}

	private static func descended(_ font: NSFont, design: NSFontDescriptor.SystemDesign) -> NSFont {
		guard let descriptor = font.fontDescriptor.withDesign(design) else { return font }
		return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
	}

	/// Line box height for a font, used to give empty blocks a sane height.
	static func lineHeight(_ font: CTFont) -> CGFloat {
		CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
	}
}
