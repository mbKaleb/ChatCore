//
//  MathMarkdown.swift
//  ChatCore
//

import Foundation

enum MathMarkdown {

	static let language = "math"

	private static let delimiters: [(open: String, close: String)] = [
		("$$", "$$"),
		("\\[", "\\]"),
	]

	/// The inline counterpart, rewritten to `$…$` rather than to a fence.
	private static let inlineDelimiters: [(open: String, close: String)] = [
		("\\(", "\\)"),
	]

	/// - Parameter inlineMath: Rewrite `\( … \)` into `$ … $` as well.
	///
	///   This has to happen *before* the markdown parser runs, and that is the
	///   whole reason it exists: CommonMark treats a backslash before ASCII
	///   punctuation as an escape, so `\(x\)` reaches a renderer as the literal
	///   text `(x)` with the delimiters already eaten and no way to tell it from
	///   a parenthesis the author typed. Models write inline math this way
	///   constantly, which is why `( f(x) = x^n )` shows up in transcripts.
	///
	///   Off by default because only `selectable2` renders `$…$`; for the other
	///   renderers the rewrite would swap one piece of visible punctuation for
	///   another.
	static func preprocess(_ source: String, inlineMath: Bool = false) -> String {
		let hasBlock = source.contains("$$") || source.contains("\\[")
		let hasInline = inlineMath && source.contains("\\(")
		guard hasBlock || hasInline else { return source }

		var out: [String] = []
		var plain: [String] = []
		var fence: String?

		func flushPlain() {
			guard !plain.isEmpty else { return }
			out.append(
				contentsOf: rewrite(plain.joined(separator: "\n"), inlineMath: inlineMath)
					.components(separatedBy: "\n")
			)
			plain.removeAll()
		}

		// An indented code block only starts after a blank line — otherwise four
		// spaces are a wrapped paragraph, which is ordinary prose that can hold
		// an equation.
		var blankRun = true
		// ...and it can't start inside a list at all, where the same indent is how
		// a paragraph stays attached to its bullet. Models put display math under
		// list items constantly, so reading that as code would cost far more than
		// the literal `$$` in an indented block this is here to protect.
		var inList = false

		for line in source.components(separatedBy: "\n") {
			let trimmed = line.drop { $0 == " " || $0 == "\t" }
			let isBlank = trimmed.isEmpty

			if let open = fence {
				out.append(line)
				if trimmed.hasPrefix(open) { fence = nil }
			} else if let opener = openingFence(trimmed) {
				flushPlain()
				out.append(line)
				fence = opener
			} else if blankRun, !inList, isIndentedCode(line) {
				// Markdown reads this as code, so the `$$` in it is literal.
				flushPlain()
				out.append(line)
			} else {
				plain.append(line)
			}

			if fence == nil {
				blankRun = isBlank
				if isListItem(trimmed) {
					inList = true
				} else if !isBlank, !line.hasPrefix(" "), !line.hasPrefix("\t") {
					// Unindented prose ends the list.
					inList = false
				}
			}
		}

		flushPlain()
		return out.joined(separator: "\n")
	}

	/// A bullet or an ordered marker, already stripped of its indent.
	private static func isListItem(_ trimmed: Substring) -> Bool {
		if let first = trimmed.first, "-*+".contains(first) {
			return trimmed.dropFirst().first == " "
		}
		let digits = trimmed.prefix { $0.isNumber }
		guard !digits.isEmpty else { return false }
		let rest = trimmed.dropFirst(digits.count)
		guard let marker = rest.first, marker == "." || marker == ")" else { return false }
		return rest.dropFirst().first == " "
	}

	/// Four spaces or a tab of indent, and something after it.
	private static func isIndentedCode(_ line: String) -> Bool {
		if line.hasPrefix("\t") { return true }
		guard line.hasPrefix("    ") else { return false }
		return !line.dropFirst(4).allSatisfy { $0 == " " || $0 == "\t" }
	}

	private static func openingFence(_ trimmed: Substring) -> String? {
		for marker: Character in ["`", "~"] {
			let run = trimmed.prefix { $0 == marker }
			if run.count >= 3 { return String(run) }
		}
		return nil
	}

	private static func rewrite(_ chunk: String, inlineMath: Bool) -> String {
		var emitted = ""
		var pending = ""
		var i = chunk.startIndex

		while i < chunk.endIndex {
			if chunk[i] == "`" {
				let runStart = i
				while i < chunk.endIndex, chunk[i] == "`" { i = chunk.index(after: i) }
				let runLength = chunk.distance(from: runStart, to: i)
				pending += chunk[runStart..<i]
				if let close = closingBacktickRun(ofLength: runLength, in: chunk, from: i) {
					pending += chunk[i..<close.upperBound]
					i = close.upperBound
				}
				continue
			}

			if let pair = delimiter(startingAt: i, in: chunk),
			   let body = matchedBody(for: pair, after: i, in: chunk) {
				emitted += pending
				pending = ""
				emitted += fenced(body.text)
				i = body.end
				continue
			}

			// Inline math stays in the flow of its sentence, so it appends to
			// `pending` rather than closing it out the way a block does.
			if inlineMath,
			   let pair = inlineDelimiters.first(where: { chunk[i...].hasPrefix($0.open) }),
			   let body = matchedBody(for: pair, after: i, in: chunk),
			   isInlineBody(body.text) {
				pending += "$" + body.text + "$"
				i = body.end
				continue
			}

			pending.append(chunk[i])
			i = chunk.index(after: i)
		}

		let result = emitted + pending
		return result.replacingOccurrences(
			of: "\n{3,}",
			with: "\n\n",
			options: .regularExpression
		)
	}

	/// Whether a `\( … \)` body is plausibly one inline equation.
	///
	/// `matchedBody` takes the first closer anywhere ahead, so an unmatched `\(`
	/// would otherwise swallow the rest of the message into one equation. A `$`
	/// inside the body is rejected too — it would close the very delimiters this
	/// is about to write.
	private static func isInlineBody(_ body: String) -> Bool {
		!body.contains("$") && !body.contains("\n\n") && body.count <= 400
	}

	private static func delimiter(startingAt i: String.Index, in chunk: String) -> (open: String, close: String)? {
		delimiters.first { chunk[i...].hasPrefix($0.open) }
	}

	private static func matchedBody(
		for pair: (open: String, close: String),
		after i: String.Index,
		in chunk: String
	) -> (text: String, end: String.Index)? {
		let bodyStart = chunk.index(i, offsetBy: pair.open.count)
		guard bodyStart <= chunk.endIndex,
		      let close = chunk.range(of: pair.close, range: bodyStart..<chunk.endIndex)
		else { return nil }

		let body = chunk[bodyStart..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
		guard !body.isEmpty else { return nil }
		return (body, close.upperBound)
	}

	private static func closingBacktickRun(
		ofLength length: Int,
		in chunk: String,
		from start: String.Index
	) -> Range<String.Index>? {
		let needle = String(repeating: "`", count: length)
		var searchStart = start
		while let found = chunk.range(of: needle, range: searchStart..<chunk.endIndex) {
			let precededByTick = found.lowerBound > chunk.startIndex
				&& chunk[chunk.index(before: found.lowerBound)] == "`"
			let followedByTick = found.upperBound < chunk.endIndex
				&& chunk[found.upperBound] == "`"
			if !precededByTick && !followedByTick { return found }
			searchStart = found.upperBound
		}
		return nil
	}

	private static func fenced(_ body: String) -> String {
		"\n\n```\(language)\n\(body)\n```\n\n"
	}

	static func blockCount(in source: String) -> Int {
		guard source.contains("$$") || source.contains("\\[") else { return 0 }
		return preprocess(source).components(separatedBy: "\n```\(language)\n").count - 1
	}
}
