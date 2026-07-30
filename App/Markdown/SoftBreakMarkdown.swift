//
//  SoftBreakMarkdown.swift
//  ChatCore
//

import Foundation

enum SoftBreakMarkdown {

	static func preserveLineBreaks(_ source: String) -> String {
		guard source.contains("\n") else { return source }

		var lines = source.components(separatedBy: "\n")
		var fence: String?

		for i in lines.indices {
			let line = lines[i]
			let trimmed = line.drop { $0 == " " || $0 == "\t" }

			if let open = fence {
				if trimmed.hasPrefix(open) { fence = nil }
				continue
			}
			if let opener = openingFence(trimmed) {
				fence = opener
				continue
			}

			guard i + 1 < lines.count else { continue }
			let next = lines[i + 1]
			guard !isBlank(line), !isBlank(next), openingFence(next.drop { $0 == " " || $0 == "\t" }) == nil
			else { continue }
			guard !endsWithHardBreak(line) else { continue }

			lines[i] = line + "  "
		}

		return lines.joined(separator: "\n")
	}

	private static func isBlank(_ line: String) -> Bool {
		line.allSatisfy { $0 == " " || $0 == "\t" }
	}

	private static func endsWithHardBreak(_ line: String) -> Bool {
		if line.hasSuffix("  ") || line.hasSuffix("\t") { return true }
		let backslashes = line.reversed().prefix { $0 == "\\" }.count
		return backslashes % 2 == 1
	}

	private static func openingFence(_ trimmed: Substring) -> String? {
		for marker: Character in ["`", "~"] {
			let run = trimmed.prefix { $0 == marker }
			if run.count >= 3 { return String(run) }
		}
		return nil
	}
}
