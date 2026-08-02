//
//  LatexPackages.swift
//  ChatCore
//
//  The extension packages, translated into the core LaTeX SwiftMath parses.
//
//  `\ce{}`, `\pu{}` and `\qty{}{}` aren't commands with arguments — they are
//  small languages of their own, with their own grammar inside the braces. That
//  is why they live here rather than in `LatexCompat`'s rewrite tables: a table
//  entry maps one command to another, and none of these can be expressed that
//  way. A model asked about chemistry reaches for `\ce` immediately, and without
//  this the whole equation comes back as a wall of source.
//

import Foundation

// MARK: - mhchem

enum Chemistry {

	/// Translates the body of a `\ce{…}` into core LaTeX.
	///
	/// The grammar implemented is the part answers actually use: coefficients,
	/// element symbols, subscripted counts, charges, isotopes, states of matter,
	/// arrows with optional labels, bonds, hydrate dots, and the precipitate and
	/// gas markers.
	static func translate(_ body: String) -> String {
		var out: [String] = []
		for token in tokenize(body) {
			switch token {
			case .arrow(let latex): out.append(latex)
			case .plus: out.append("+")
			case .precipitate: out.append("\\downarrow")
			case .gas: out.append("\\uparrow")
			case .formula(let text): out.append(formula(text))
			}
		}
		return out.joined(separator: " ")
	}

	private enum Token {
		case formula(String)
		case arrow(String)
		case plus
		case precipitate
		case gas
	}

	/// Arrows, longest first — `<=>>` has to be tried before `<=>` and `<-`.
	private static let arrows: [(String, String)] = [
		("<=>>", "\\rightleftharpoons"), ("<<=>", "\\rightleftharpoons"),
		("<=>", "\\rightleftharpoons"), ("<->", "\\leftrightarrow"),
		("->", "\\rightarrow"), ("<-", "\\leftarrow"),
		("=>", "\\Rightarrow"), ("<=", "\\Leftarrow"),
	]

	private static func tokenize(_ body: String) -> [Token] {
		var tokens: [Token] = []
		var current = ""
		var i = body.startIndex

		func flush() {
			let trimmed = current.trimmingCharacters(in: .whitespaces)
			current = ""
			guard !trimmed.isEmpty else { return }
			// A lone `v` or `^` after a formula is the precipitate or gas marker.
			switch trimmed {
			case "v": tokens.append(.precipitate)
			case "^": tokens.append(.gas)
			default: tokens.append(.formula(trimmed))
			}
		}

		while i < body.endIndex {
			if let arrow = arrows.first(where: { body[i...].hasPrefix($0.0) }) {
				flush()
				i = body.index(i, offsetBy: arrow.0.count)
				// `->[above][below]` labels the arrow.
				var above = "", below = ""
				for slot in 0..<2 {
					guard i < body.endIndex, body[i] == "[",
					      let close = body[i...].firstIndex(of: "]")
					else { break }
					let label = String(body[body.index(after: i)..<close])
					if slot == 0 { above = label } else { below = label }
					i = body.index(after: close)
				}
				if above.isEmpty, below.isEmpty {
					tokens.append(.arrow(arrow.1))
				} else {
					// Both labels can't be drawn; the one above wins, as in mhchem's
					// own reading order.
					let label = above.isEmpty ? below : above
					tokens.append(.arrow("{\\text{\(label)} \\atop {\(arrow.1)}}"))
				}
				continue
			}

			// A `+` with space around it joins two species; one touching a symbol is
			// a charge, and belongs to the formula.
			if body[i] == "+", current.trimmingCharacters(in: .whitespaces).isEmpty
				|| body[body.index(before: i)] == " " {
				let next = body.index(after: i)
				if next >= body.endIndex || body[next] == " " {
					flush()
					tokens.append(.plus)
					i = next
					continue
				}
			}

			if body[i] == " " {
				flush()
				i = body.index(after: i)
				continue
			}

			current.append(body[i])
			i = body.index(after: i)
		}

		flush()
		return tokens
	}

	private static let states: Set<String> = ["s", "l", "g", "aq", "sln", "cr", "am"]

	/// One species: `2CO`, `SO4^2-`, `Ca(OH)2`, `^{227}_{90}Th+`, `CuSO4.5H2O`.
	private static func formula(_ token: String) -> String {
		// `\ce{2 CO}` writes the coefficient as its own word, so a token that is
		// nothing but digits is stoichiometry rather than a count of atoms — read
		// as a formula it would come out as a subscript attached to nothing.
		if token.allSatisfy(\.isNumber) { return token }

		var out = ""
		var i = token.startIndex
		/// Set by the hydrate dot, which changes what the next digits mean.
		var afterHydrateDot = false

		// A leading count is stoichiometry and stays an upright number.
		let digitsStart = i
		while i < token.endIndex, token[i].isNumber { i = token.index(after: i) }
		if i > digitsStart {
			out += String(token[digitsStart..<i])
		} else {
			i = digitsStart
		}

		while i < token.endIndex {
			let character = token[i]

			if character == "^" || character == "_" {
				let script = String(character)
				i = token.index(after: i)
				if i < token.endIndex, token[i] == "{" {
					guard let close = matchingBrace(in: token, openingAt: i) else { break }
					out += "\(script){\(token[token.index(after: i)..<close])}"
					i = token.index(after: close)
				} else {
					// A bare charge or count: `^2-`, `^+`, `_2`.
					var run = ""
					while i < token.endIndex, token[i].isNumber || token[i] == "+" || token[i] == "-" {
						run.append(token[i])
						i = token.index(after: i)
					}
					out += run.isEmpty ? "" : "\(script){\(run)}"
				}
				continue
			}

			if character.isUppercase {
				var symbol = String(character)
				i = token.index(after: i)
				while i < token.endIndex, token[i].isLowercase {
					symbol.append(token[i])
					i = token.index(after: i)
				}
				out += "\\text{\(symbol)}"
				continue
			}

			if character.isNumber {
				var run = ""
				while i < token.endIndex, token[i].isNumber {
					run.append(token[i])
					i = token.index(after: i)
				}
				// `CuSO4.5H2O` — the 5 counts whole water molecules, so it sits on
				// the line. Everywhere else a digit counts atoms and drops.
				out += afterHydrateDot ? run : "_{\(run)}"
				afterHydrateDot = false
				continue
			}

			// A trailing charge: `Th+`, `Ca^2+`, `Cl-`.
			if character == "+" || character == "-" {
				var run = ""
				while i < token.endIndex, token[i] == "+" || token[i] == "-" {
					run.append(token[i])
					i = token.index(after: i)
				}
				// A `-` between two element symbols is a bond, not a charge.
				if i < token.endIndex, run == "-" {
					out += "{-}"
				} else {
					out += "^{\(run)}"
				}
				continue
			}

			if character == "(" {
				// `(aq)` and friends are labels rather than groupings.
				if let close = token[i...].firstIndex(of: ")") {
					let inside = String(token[token.index(after: i)..<close])
					if states.contains(inside) {
						out += "\\text{(\(inside))}"
						i = token.index(after: close)
						continue
					}
				}
				out += "("
				i = token.index(after: i)
				continue
			}

			if character == ")" {
				out += ")"
				i = token.index(after: i)
				continue
			}

			// The hydrate dot, as in `CuSO4.5H2O`.
			if character == "." || character == "*" {
				out += "\\cdot "
				afterHydrateDot = true
				i = token.index(after: i)
				continue
			}

			if character == "=" { out += "{=}"; i = token.index(after: i); continue }
			if character == "#" { out += "\\equiv"; i = token.index(after: i); continue }

			// Anything unrecognised is passed through as text rather than dropped.
			out += "\\text{\(character)}"
			i = token.index(after: i)
		}

		return out
	}

	/// `\pu{123 kJ//mol}` — a number and a unit.
	///
	/// `//` is a fraction and `/` a solidus; mhchem's own default is to print the
	/// solidus either way once there is more than one denominator, which is what
	/// this does.
	static func units(_ body: String) -> String {
		let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
		guard let value = parts.first else { return "" }
		guard parts.count > 1 else { return String(value) }

		let unit = String(parts[1])
			.replacingOccurrences(of: "//", with: "/")
			.replacingOccurrences(of: "...", with: "")
		return "\(value)\\,\\mathrm{\(escapeText(unit))}"
	}

	private static func escapeText(_ source: String) -> String {
		source.replacingOccurrences(of: "%", with: "\\%")
	}

	private static func matchingBrace(in source: String, openingAt open: String.Index) -> String.Index? {
		var depth = 0
		var i = open
		while i < source.endIndex {
			if source[i] == "{" { depth += 1 }
			if source[i] == "}" {
				depth -= 1
				if depth == 0 { return i }
			}
			i = source.index(after: i)
		}
		return nil
	}
}

// MARK: - siunitx

enum SIUnits {

	/// `\qty{5}{\meter}` and `\SI{5}{\metre}` — a number and a unit expression.
	static func quantity(value: String, unit: String) -> String {
		let printed = expand(unit)
		guard !printed.isEmpty else { return value }
		return "\(value)\\,\\mathrm{\(printed)}"
	}

	/// `\qtyrange{1}{5}{\meter}` — a span, with the unit on both ends.
	static func range(_ from: String, _ to: String, unit: String) -> String {
		let printed = expand(unit)
		guard !printed.isEmpty else { return "\(from)\\text{ to }\(to)" }
		return "\(from)\\,\\mathrm{\(printed)}\\text{ to }\(to)\\,\\mathrm{\(printed)}"
	}

	/// `\qtylist{1;2;3}{\meter}` — siunitx separates the values with semicolons.
	static func list(_ values: String, unit: String) -> String {
		let printed = expand(unit)
		let items = values.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
		let joined = items.joined(separator: ", ")
		guard !printed.isEmpty else { return joined }
		return "\(joined)\\,\\mathrm{\(printed)}"
	}

	/// `\si{\kilo\gram\per\second}` — the unit alone.
	static func unit(_ unit: String) -> String {
		let printed = expand(unit)
		return printed.isEmpty ? "" : "\\mathrm{\(printed)}"
	}

	/// Turns a run of unit macros into the symbols they print.
	///
	/// Handles the prefix-then-unit shape (`\kilo\gram` is kg, not k g) by simple
	/// concatenation, and the power qualifiers, which apply to whatever follows
	/// them rather than to what came before.
	private static func expand(_ source: String) -> String {
		guard source.contains("\\") else { return source }

		var out = ""
		var pendingPower: String?
		var perMode = false
		var i = source.startIndex

		while i < source.endIndex {
			guard source[i] == "\\" else {
				if !source[i].isWhitespace { out.append(source[i]) }
				i = source.index(after: i)
				continue
			}

			var j = source.index(after: i)
			let start = j
			while j < source.endIndex, source[j].isLetter { j = source.index(after: j) }
			let name = String(source[start..<j])
			i = j

			switch name {
			case "per":
				perMode = true
				out += "/"
			// `\square` and `\cubic` qualify the unit that follows them;
			// `\squared` and `\cubed` qualify the one already written.
			case "square": pendingPower = "2"
			case "cubic": pendingPower = "3"
			case "squared": out += "^{2}"
			case "cubed": out += "^{3}"
			default:
				guard let symbol = table[name] else { continue }
				out += symbol
				if let power = pendingPower {
					out += "^{\(power)}"
					pendingPower = nil
				}
			}
			_ = perMode
		}

		return out
	}

	/// Prefixes and units, by macro name. Prefixes are concatenated with whatever
	/// unit follows, which is why they share one table.
	static let table: [String: String] = [
		// Prefixes
		"yocto": "y", "zepto": "z", "atto": "a", "femto": "f", "pico": "p",
		"nano": "n", "micro": "\\mu ", "milli": "m", "centi": "c", "deci": "d",
		"deca": "da", "deka": "da", "hecto": "h", "kilo": "k", "mega": "M",
		"giga": "G", "tera": "T", "peta": "P", "exa": "E", "zetta": "Z", "yotta": "Y",
		// SI base
		"metre": "m", "meter": "m", "gram": "g", "second": "s", "ampere": "A",
		"kelvin": "K", "mole": "mol", "candela": "cd", "kilogram": "kg",
		// SI derived
		"hertz": "Hz", "newton": "N", "pascal": "Pa", "joule": "J", "watt": "W",
		"coulomb": "C", "volt": "V", "farad": "F", "ohm": "\\Omega ", "siemens": "S",
		"weber": "Wb", "tesla": "T", "henry": "H", "lumen": "lm", "lux": "lx",
		"becquerel": "Bq", "gray": "Gy", "sievert": "Sv", "katal": "kat",
		"radian": "rad", "steradian": "sr", "celsius": "^{\\circ}C",
		"degreeCelsius": "^{\\circ}C", "degree": "^{\\circ}", "percent": "\\%",
		// Common non-SI
		"litre": "L", "liter": "L", "tonne": "t", "dalton": "Da",
		"electronvolt": "eV", "angstrom": "\\text{Å}", "bar": "bar", "barn": "b",
		"day": "d", "hour": "h", "minute": "min", "year": "yr",
		"astronomicalunit": "au", "atomicmassunit": "u", "bohr": "a_0",
		"hartree": "E_h", "clight": "c_0", "elementarycharge": "e",
		"electronmass": "m_e", "planckbar": "\\hbar ",
		// Computing
		"byte": "B", "bit": "b", "kibi": "Ki", "mebi": "Mi", "gibi": "Gi", "tebi": "Ti",
	]
}
