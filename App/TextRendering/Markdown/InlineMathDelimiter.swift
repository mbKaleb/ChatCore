//
//  InlineMathDelimiter.swift
//  ChatCore
//
//  Telling `$…$` that means an equation from `$…$` that means money.
//
//  Split out of the renderer because it is the one piece of the math path that
//  is pure string reasoning, and the one most easily got wrong in a way nobody
//  notices — a false positive doesn't fail, it silently italicises a sentence
//  and hides the dollar signs the author typed.
//

import Foundation

enum InlineMathDelimiter {

	/// The closing `$` for an opener at `open`, or nil if this `$` isn't math.
	///
	/// The structural rules are the usual ones: no space just inside either
	/// delimiter, no empty body, no newline, and no digit immediately after the
	/// closer — which is what keeps "$5 to $10" from typesetting "5 to ".
	static func closingDollar(in string: String, after open: String.Index) -> String.Index? {
		let first = string.index(after: open)
		guard first < string.endIndex, !string[first].isWhitespace else { return nil }

		var i = first
		while i < string.endIndex {
			let character = string[i]
			if character == "$" {
				guard i > first else { return nil }
				let previous = string[string.index(before: i)]
				guard !previous.isWhitespace else { return nil }
				let after = string.index(after: i)
				if after < string.endIndex, string[after].isNumber { return nil }
				// Structurally this is a pair. Whether it is *mathematics* is a
				// separate question, and the answer is in the body.
				return looksLikeProse(String(string[first..<i])) ? nil : i
			}
			if character.isNewline { return nil }
			i = string.index(after: i)
		}
		return nil
	}

	/// Whether a candidate body is a sentence rather than an equation.
	///
	/// The structural rules alone accept far too much. In
	///
	///     the price is $5 and the other is 7, so a b$c
	///
	/// every one of them passes — no space inside the delimiters, non-empty, one
	/// line, and a letter after the closer — so the renderer typeset "5 and the
	/// other is 7, so a b" in italics and ate both dollar signs. Two prices in one
	/// sentence is not a rare thing to write.
	///
	/// What actually separates the two is that mathematics contains mathematics.
	/// A body with an operator, a script, a group or a command is an equation
	/// whatever else is in it; a body with none of those and several words in it
	/// is prose. One or two words stay math, so `$x$` and `$a b$` still render.
	static func looksLikeProse(_ body: String) -> Bool {
		guard !body.contains(where: mathMarkers.contains) else { return false }

		let words = body.split(whereSeparator: \.isWhitespace)
		return words.count >= 3
	}

	/// Characters that only appear in a body because it is mathematics.
	///
	/// Deliberately excludes `,` `.` `'` and `?`, which are at least as common in
	/// a sentence, and `(` `)`, which show up in ordinary parenthetical asides.
	/// `-` is in, because a spaced minus is far more often arithmetic than a dash,
	/// and leaving it out would have read `$x - 1$` as prose.
	private static let mathMarkers: Set<Character> = [
		"\\", "^", "_", "{", "}", "=", "<", ">", "+", "-", "*", "/", "|",
		"[", "]", "√", "∑", "∫", "π", "≤", "≥", "≠", "∞",
	]
}
