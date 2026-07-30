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

	static func preprocess(_ source: String) -> String {
		guard source.contains("$$") || source.contains("\\[") else { return source }

		var out: [String] = []
		var plain: [String] = []
		var fence: String?

		func flushPlain() {
			guard !plain.isEmpty else { return }
			out.append(contentsOf: rewrite(plain.joined(separator: "\n")).components(separatedBy: "\n"))
			plain.removeAll()
		}

		for line in source.components(separatedBy: "\n") {
			let trimmed = line.drop { $0 == " " || $0 == "\t" }

			if let open = fence {
				out.append(line)
				if trimmed.hasPrefix(open) { fence = nil }
			} else if let opener = openingFence(trimmed) {
				flushPlain()
				out.append(line)
				fence = opener
			} else {
				plain.append(line)
			}
		}

		flushPlain()
		return out.joined(separator: "\n")
	}

	private static func openingFence(_ trimmed: Substring) -> String? {
		for marker: Character in ["`", "~"] {
			let run = trimmed.prefix { $0 == marker }
			if run.count >= 3 { return String(run) }
		}
		return nil
	}

	private static func rewrite(_ chunk: String) -> String {
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
