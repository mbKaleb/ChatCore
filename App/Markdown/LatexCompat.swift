//
//  LatexCompat.swift
//  ChatCore
//
//  Bridging the LaTeX people write to the subset SwiftMath parses.
//
//  A command SwiftMath doesn't know isn't a missing glyph — it fails the parse,
//  and the whole equation falls back to showing its source. So the cheap fixes
//  live here: environments renamed to ones it implements, and the symbols it
//  ships no command for registered into its factory.
//

import Foundation
import SwiftMath

enum LatexCompat {

	static func prepare(_ latex: String) -> (latex: String, boxed: Bool) {
		// Every math path in the app funnels through here, so this is the one place
		// that can guarantee the symbol table is populated before a parse.
		_ = installedSymbols

		var source = normalizeUnicode(latex)
		source = expandMacros(source)
		source = expandDeclaredOperators(source)
		source = rewriteEnvironments(source)
		source = rewriteCommands(source)
		// Last, because the passes above insert spaces of their own.
		source = dropSpaceBeforeSign(source)

		return unwrapBoxed(source)
	}

	// MARK: - The space-before-a-sign crash

	/// SwiftMath's space atoms, by command name.
	private static let spaceCommands: Set<String> = [",", ">", ";", "!", "quad", "qquad"]

	/// Removes a space command sitting between a relation and a sign.
	///
	/// This one is a crash, not a fallback. `MTMathList.finalized` decides whether
	/// `+` is a binary operator or a sign by looking at the atom immediately
	/// before it — but a space atom sits in between, so the `+` in `x \;=\; +1`
	/// stays *binary*. The typesetter then skips spaces when it looks up
	/// inter-element spacing, asks for the Relation-to-BinaryOperator cell, finds
	/// it marked invalid, and trips an assertion:
	///
	///     MTTypesetter.swift:810: Assertion failed:
	///     Invalid space between Relation and Binary Operator
	///
	/// which takes the whole app down in a debug build. `x = +1` is fine; it is
	/// only the explicit space that does it, and models write `\;=\;` constantly.
	/// The same applies after an opening bracket, a punctuation mark, a large
	/// operator, or another binary operator — anywhere TeX would read the sign as
	/// unary.
	///
	/// Dropping the space is the only fix available from here: `{}` produces no
	/// atom at all, `\mathord` isn't implemented, and braces don't start a new
	/// list. What's lost is a few mu of gap in front of a sign that TeX sets tight
	/// anyway. The real fix is upstream — `finalized` should skip spaces when it
	/// looks backwards — and this can go when it does.
	private static func dropSpaceBeforeSign(_ source: String) -> String {
		guard source.contains("\\") else { return source }

		var out = ""
		/// Pending run of whitespace, tagged so that only the space *commands* are
		/// dropped — literal spaces are ignored by the parser and cost nothing.
		var pending: [(text: String, isSpaceCommand: Bool)] = []
		/// The previous atom's type. `nil` means the start of a list, where a sign
		/// is already unary.
		var previous: MTMathAtomType?
		var i = source.startIndex

		func flush() {
			for piece in pending { out += piece.text }
			pending.removeAll()
		}

		/// Emit the pending run without its space commands. Literal whitespace is
		/// kept — the parser ignores it, so it costs nothing and keeps the source
		/// readable when it round-trips.
		func flushDroppingSpaceCommands() {
			for piece in pending where !piece.isSpaceCommand { out += piece.text }
			pending.removeAll()
		}

		/// Whether a sign following `previous` is unary — the cases SwiftMath's own
		/// `isNotBinaryOperator` covers, plus the start of a list.
		func signWouldBeUnary() -> Bool {
			guard let previous else { return true }
			switch previous {
			case .binaryOperator, .relation, .open, .punctuation, .largeOperator: return true
			default: return false
			}
		}

		while i < source.endIndex {
			let character = source[i]

			if character == " " || character == "\n" || character == "\t" {
				pending.append((String(character), false))
				i = source.index(after: i)
				continue
			}

			if character == "{" || character == "&" {
				flush()
				out.append(character)
				previous = nil   // a fresh group or cell starts a fresh list
				i = source.index(after: i)
				continue
			}

			if character == "}" {
				flush()
				out.append(character)
				previous = .ordinary
				i = source.index(after: i)
				continue
			}

			// A script binds to the atom before it and doesn't change what the next
			// atom sits next to.
			if character == "^" || character == "_" {
				flush()
				out.append(character)
				i = source.index(after: i)
				continue
			}

			// A plain `+` or `-` is the common case, so the type has to be known
			// *before* the pending spaces are emitted.
			guard character == "\\" else {
				let type = MTMathAtomFactory.atom(forCharacter: character)?.type ?? .ordinary
				if type == .binaryOperator, signWouldBeUnary() {
					flushDroppingSpaceCommands()
					previous = .unaryOperator
				} else {
					flush()
					previous = type
				}
				out.append(character)
				i = source.index(after: i)
				continue
			}

			let (name, afterName) = commandName(in: source, backslashAt: i)
			guard !name.isEmpty else {
				flush()
				out.append(character)
				i = source.index(after: i)
				continue
			}

			if spaceCommands.contains(name) {
				pending.append(("\\" + name, true))
				i = afterName
				continue
			}

			switch name {
			case "\\":                            // new row
				flush()
				previous = nil
				i = afterName
			case "begin", "end":                  // new cell
				flush()
				previous = nil
				i = afterName
				// Carry the environment name across without classifying it.
				if i < source.endIndex, source[i] == "{",
				   let environment = readArgument(in: source, from: i) {
					out += "\\" + name + "{" + environment.text + "}"
					i = environment.end
					continue
				}
			case "left":
				flush()
				previous = .open
				i = afterName
			case "right":
				flush()
				previous = .close
				i = afterName
			default:
				let type = MTMathAtomFactory.atom(forLatexSymbol: name)?.type ?? .ordinary
				if type == .binaryOperator, signWouldBeUnary() {
					flushDroppingSpaceCommands()
					previous = .unaryOperator
				} else {
					flush()
					previous = type
				}
				i = afterName
			}
			out += "\\" + name
		}

		flush()
		return out
	}

	// MARK: - The command rewriter

	/// Commands rewritten one-for-one, by name.
	///
	/// Everything in here is applied to a *whole command token*, never to a
	/// substring — which is the entire reason this table replaced the pass of
	/// `replacingOccurrences` that used to do the job. `\big` is a prefix of
	/// `\bigcup`, so a substring replacement turned `\bigcup_{i=1}^n A_i` into
	/// `cup_{i=1}^n A_i`: a perfectly parseable equation that renders the italic
	/// word "cup" where a union operator belongs. Nothing failed and nothing
	/// warned — the mathematics was just silently wrong, which is the failure
	/// this file exists to prevent.
	private static let commandRewrites: [String: String] = [
		// Style-forcing fraction variants. SwiftMath implements `\frac` and none
		// of the others; what's lost is the size the author asked for, which the
		// surrounding style would mostly have chosen anyway.
		"dfrac": "\\frac", "tfrac": "\\frac", "cfrac": "\\frac",
		"dbinom": "\\binom", "tbinom": "\\binom",

		// Font families with no SwiftMath equivalent, folded onto the nearest one.
		"mathscr": "\\mathcal", "boldsymbol": "\\mathbf", "operatorname": "\\mathrm",

		// SwiftMath spells the medium space `\>`; `\,` `\;` `\!` `\quad` `\qquad`
		// all exist under their usual names, and the amsmath spellings don't.
		":": "\\>",
		"thinspace": "\\,", "medspace": "\\>", "thickspace": "\\;",
		"negthinspace": "\\!", "negmedspace": "\\!", "negthickspace": "\\!",
		"enspace": "\\,", "nobreakspace": "\\ ", "space": "\\ ",

		// `\%`, `\$`, `\_` and `\#` all resolve; `\&` is the one escape SwiftMath's
		// tokenizer can't name, so it routes to an alias registered below.
		"&": "\\ampersandsymbol ",

		// Ellipses. Only `\ldots` and `\cdots` exist.
		"dots": "\\ldots", "dotsc": "\\ldots", "dotsb": "\\cdots",
		"dotsi": "\\cdots", "dotsm": "\\cdots", "dotso": "\\ldots",

		// Vertical bars. The `\lvert` family is amsmath's; the plain ones are TeX's.
		"lvert": "|", "rvert": "|", "lVert": "\\|", "rVert": "\\|",

		// Multiple integrals are drawn as tight runs of `\int`.
		"iint": "\\int\\!\\int", "iiint": "\\int\\!\\int\\!\\int",
		"iiiint": "\\int\\!\\int\\!\\int\\!\\int", "oiint": "\\oint\\!\\oint",

		// Modular arithmetic. `\bmod` is a binary operator, so it keeps its spaces.
		"bmod": "\\;\\mathrm{mod}\\;", "mod": "\\;\\mathrm{mod}\\;",

		// Arrow accents, folded onto the one accent SwiftMath draws over a group.
		"overrightarrow": "\\vec", "overleftarrow": "\\vec",
		"overleftrightarrow": "\\vec",

		// Braces under/over a group become rules — the closest thing that draws.
		"underbrace": "\\underline", "overbrace": "\\overline",
		"underleftarrow": "\\underline", "underrightarrow": "\\underline",
		"underleftrightarrow": "\\underline",

		// The logos, as the words they stand for.
		"LaTeX": "\\text{LaTeX}", "TeX": "\\text{TeX}",

		// Struts reserve height for something invisible.
		"mathstrut": "", "strut": "",

		// Spelling variants for symbols SwiftMath already draws. Routed to its own
		// commands rather than registered as new atoms: reusing the real atom keeps
		// the maths class and the font handling that come with it, where a copied
		// `\bullet` wearing a new nucleus only approximates them.
		"lparen": "(", "rparen": ")", "lbrack": "[", "rbrack": "]",
		"lang": "\\langle", "rang": "\\rangle",
		"intop": "\\int", "smallint": "\\int",
		"sdot": "\\cdot", "textperiodcentered": "\\cdot",
		"dag": "\\dagger", "textdagger": "\\dagger",
		"ddag": "\\ddagger", "textdaggerdbl": "\\ddagger",
		"empty": "\\emptyset", "exist": "\\exists",
		"hdots": "\\ldots", "mathellipsis": "\\ldots", "textellipsis": "\\ldots",
		"mathparagraph": "\\P", "textparagraph": "\\P",
		"mathsection": "\\S", "textsection": "\\S",
		"mathsterling": "\\pounds", "ohm": "\\Omega", "qedsymbol": "\\qed",
		"textbar": "|", "textgreater": ">", "textless": "<", "gt": ">", "lt": "<",
		"textdegree": "\\circ", "textemdash": "-", "textendash": "-",
		"textquotedblleft": "\"", "textquotedblright": "\"",
		"textquoteleft": "'", "textquoteright": "'",
		"dprime": "''", "trprime": "'''", "ldotp": ".",
		"divides": "\\mid", "shortmid": "\\mid", "equivalent": "\\equiv",
		"gggtr": "\\ggg", "llless": "\\lll",
		"impliedby": "\\Leftarrow", "isin": "\\in", "owns": "\\ni",
		"notni": "\\nni", "nshortmid": "\\nmid", "nshortparallel": "\\nparallel",
		"restriction": "\\upharpoonright", "shortparallel": "\\parallel",
		"thickapprox": "\\approx", "thicksim": "\\sim", "varpropto": "\\propto",
		"vartriangle": "\\triangle", "bigtriangleup": "\\triangle",
		// amsmath's italic capitals; SwiftMath has one capital Greek set.
		"varDelta": "\\Delta", "varGamma": "\\Gamma", "varLambda": "\\Lambda",
		"varOmega": "\\Omega", "varPhi": "\\Phi", "varPi": "\\Pi",
		"varPsi": "\\Psi", "varSigma": "\\Sigma", "varTheta": "\\Theta",
		"varUpsilon": "\\Upsilon", "varXi": "\\Xi",

		// Relations whose exact glyph isn't in the maths fonts, folded onto the
		// one that means the same thing. `\geqslant` and `\geq` are the same
		// relation drawn with a different slant; substituting keeps the reading of
		// the formula intact, where failing loses the whole line. Anything whose
		// nearest neighbour would change the meaning is deliberately absent — it
		// falls back to source instead.
		"geqq": "\\geq", "geqslant": "\\geq", "leqq": "\\leq", "leqslant": "\\leq",
		"subseteqq": "\\subseteq", "supseteqq": "\\supseteq",
		"subsetneqq": "\\subsetneq", "supsetneqq": "\\supsetneq",
		"preccurlyeq": "\\preceq", "succcurlyeq": "\\succeq",
		"precsim": "\\preceq", "succsim": "\\succeq",
		"Vdash": "\\vdash", "Vvdash": "\\vdash",
		"nVdash": "\\nvdash", "nVDash": "\\nvDash",

		// Definition notation, spelled out as the characters it stands for.
		"coloneqq": "\\colon\\!=", "coloneq": "\\colon\\!=",
		"eqqcolon": "=\\!\\colon", "dblcolon": "\\colon\\!\\colon",
		"vcentcolon": "\\colon",

		// Uppercase Greek that LaTeX has no command for, because it is a Latin
		// letter — models write `\Alpha` anyway.
		"Alpha": "A", "Beta": "B", "Epsilon": "E", "Zeta": "Z", "Eta": "H",
		"Iota": "I", "Kappa": "K", "Mu": "M", "Nu": "N", "Omicron": "O",
		"Rho": "P", "Tau": "T", "Chi": "X",

		// Text-mode escapes.
		"textbackslash": "\\backslash", "textunderscore": "\\_",
		"textbraceleft": "\\{", "textbraceright": "\\}",
		"mathdollar": "\\$", "textdollar": "\\$",
		"textasciitilde": "\\sim", "textbullet": "\\bullet",
		"bigcirc": "\\circ", "diamond": "\\lozenge",
	]

	/// Commands dropped entirely, leaving whatever followed them.
	///
	/// The `\big` family sizes a delimiter to a fixed size; SwiftMath implements
	/// `\left`/`\right` (which size to content) and none of these. Dropping the
	/// command leaves the delimiter itself — the same expression one size down.
	/// Rewriting to `\left`/`\right` instead would need the pairs to match, and
	/// half a pair is how a cosmetic problem becomes a parse error.
	private static let droppedCommands: Set<String> = [
		"big", "bigl", "bigr", "bigm", "bigg", "biggl", "biggr", "biggm",
		"Big", "Bigl", "Bigr", "Bigm", "Bigg", "Biggl", "Biggr", "Biggm",
		"middle", "nonumber", "notag", "displaylimits", "allowbreak",
		// Horizontal rules in a table. SwiftMath's table draws no rules, and the
		// row structure is carried by `\\` rather than by these.
		"hline", "hdashline", "toprule", "midrule", "bottomrule",
	]

	/// Commands taking brace groups, rewritten with the arguments substituted in.
	///
	/// `$0` and `$1` stand for the first and second argument. The argument count
	/// matters as much as the template: reading the wrong number of groups leaves
	/// a stray `{…}` in the output, which parses as a plain group and silently
	/// changes the expression.
	private static let argumentRewrites: [String: (arity: Int, template: String)] = [
		// `\atop` is the one construction SwiftMath has for stacking without a
		// fraction bar, which is exactly what these three want.
		"overset": (2, "{{$0} \\atop {$1}}"),
		"stackrel": (2, "{{$0} \\atop {$1}}"),
		"underset": (2, "{{$1} \\atop {$0}}"),
		"xrightarrow": (1, "{{$0} \\atop {\\longrightarrow}}"),
		"xleftarrow": (1, "{{$0} \\atop {\\longleftarrow}}"),
		"xleftrightarrow": (1, "{{$0} \\atop {\\longleftrightarrow}}"),
		"xhookrightarrow": (1, "{{$0} \\atop {\\hookrightarrow}}"),
		"xhookleftarrow": (1, "{{$0} \\atop {\\hookleftarrow}}"),
		"xrightleftharpoons": (1, "{{$0} \\atop {\\rightleftharpoons}}"),
		"xmapsto": (1, "{{$0} \\atop {\\longmapsto}}"),
		"xlongequal": (1, "{{$0} \\atop {=}}"),

		"pmod": (1, "\\;(\\mathrm{mod}\\; {$0})"),

		// Spacing that reserves room for something invisible. Approximated rather
		// than measured — the alternative is failing the whole equation over a gap.
		"phantom": (1, "\\;"), "hphantom": (1, "\\;"), "vphantom": (1, ""),
		"hspace": (1, "\\quad"), "hskip": (1, "\\quad"), "mspace": (1, "\\,"),

		// Numbering and cross-references have nowhere to go in a chat transcript.
		"tag": (1, ""), "label": (1, ""), "ref": (1, ""), "eqref": (1, ""),
		"cline": (1, ""), "arraystretch": (1, ""),

		// Boxes and wrappers SwiftMath can't draw, reduced to the content they
		// wrap. The box is decoration; the argument inside it is the mathematics.
		"raisebox": (2, "{$1}"), "colorbox": (2, "{$1}"), "fcolorbox": (3, "{$2}"),
		"vcenter": (1, "{$0}"), "hbox": (1, "{$0}"), "mbox": (1, "{$0}"),
		"fbox": (1, "{$0}"), "smash": (1, "{$0}"), "rule": (2, ""),

		// KaTeX's HTML extensions. Dropping the first argument is deliberate for
		// `\href`: the URL goes nowhere, so a `javascript:` payload in an answer
		// can't become a live link.
		"href": (2, "{$1}"), "htmlClass": (2, "{$1}"), "htmlId": (2, "{$1}"),
		"htmlData": (2, "{$1}"), "htmlStyle": (2, "{$1}"),

		// Strike-throughs. SwiftMath draws no rule through a group, and the struck
		// expression *is* its content — `\cancel{2}` is 2 — so keeping the content
		// loses the annotation without changing the mathematics. `\cancelto` keeps
		// both halves by stacking them, since the target is information.
		"cancel": (1, "{$0}"), "bcancel": (1, "{$0}"), "xcancel": (1, "{$0}"),
		"sout": (1, "{$0}"), "cancelto": (2, "{{$0} \\atop {$1}}"),
	]

	/// Commands whose first argument is optional and bracketed, consumed and
	/// discarded before the required arguments are read.
	///
	/// `\xrightarrow[below]{above}` labels both sides of the arrow and SwiftMath
	/// stacks only one, so the under-label goes. Left in place the bracket would
	/// be read as ordinary characters and typeset as literal `[below]`.
	private static let leadingOptionalArgument: Set<String> = [
		"smash", "xrightarrow", "xleftarrow", "xhookrightarrow", "xhookleftarrow",
		"xrightleftharpoons", "xleftrightarrow", "xmapsto", "xlongequal",
	]

	/// `\not` applied to a relation, as the single negated symbol it means.
	///
	/// Dropping an unrecognised `\not` is not an option: it would assert the exact
	/// opposite of the answer. Anything not in this table keeps its `\not`, fails
	/// the parse, and falls back to showing the source — wrong-looking, but not
	/// wrong.
	private static let negations: [String: String] = [
		"=": "\\neq", "<": "\\nless", ">": "\\ngtr", "\\in": "\\notin",
		"\\leq": "\\nleq", "\\le": "\\nleq", "\\geq": "\\ngeq", "\\ge": "\\ngeq",
		"\\subset": "\\nsubset", "\\supset": "\\nsupset",
		"\\subseteq": "\\nsubseteq", "\\supseteq": "\\nsupseteq",
		"\\equiv": "\\nequiv", "\\sim": "\\nsim", "\\simeq": "\\nsimeq",
		"\\cong": "\\ncong", "\\mid": "\\nmid", "\\parallel": "\\nparallel",
		"\\exists": "\\nexists", "\\vdash": "\\nvdash", "\\models": "\\nvDash",
		"\\prec": "\\nprec", "\\succ": "\\nsucc", "\\ni": "\\nni",
		"\\rightarrow": "\\nrightarrow", "\\to": "\\nrightarrow",
		"\\Rightarrow": "\\nRightarrow", "\\leftrightarrow": "\\nleftrightarrow",
	]

	/// Rewrites whole command tokens, leaving everything else — including `\\`,
	/// `&` and `\begin`/`\end` — exactly as it was.
	private static func rewriteCommands(_ source: String) -> String {
		guard source.contains("\\") else { return source }

		var out = ""
		var i = source.startIndex

		while i < source.endIndex {
			guard source[i] == "\\" else {
				out.append(source[i])
				i = source.index(after: i)
				continue
			}

			let (name, afterName) = commandName(in: source, backslashAt: i)
			guard !name.isEmpty else {
				out.append(source[i])
				i = source.index(after: i)
				continue
			}

			// `\not` binds to whatever follows and has to become one negated
			// symbol; there is no atom in SwiftMath that overstrikes.
			if name == "not" {
				var cursor = afterName
				while cursor < source.endIndex, source[cursor] == " " {
					cursor = source.index(after: cursor)
				}
				if cursor < source.endIndex {
					let following: String
					let end: String.Index
					if source[cursor] == "\\" {
						let (next, nextEnd) = commandName(in: source, backslashAt: cursor)
						following = "\\" + next
						end = nextEnd
					} else {
						following = String(source[cursor])
						end = source.index(after: cursor)
					}
					if let negated = negations[following] {
						out += negated + " "
						i = end
						continue
					}
				}
				// Unknown: keep `\not` so the equation fails visibly rather than
				// rendering the opposite of what it says.
				out += "\\not"
				i = afterName
				continue
			}

			if name == "genfrac", let rewritten = rewriteGenfrac(in: source, from: afterName) {
				out += rewritten.text
				i = rewritten.end
				continue
			}

			// `\above` is `\over` with an explicit rule thickness SwiftMath has no
			// slot for.
			if name == "above" {
				out += "\\over"
				i = skipDimension(in: source, from: afterName)
				continue
			}

			if let (arity, template) = argumentRewrites[name] {
				var arguments: [String] = []
				var cursor = afterName
				if leadingOptionalArgument.contains(name) {
					cursor = skipOptionalArgument(in: source, from: cursor)
				}
				for _ in 0..<arity {
					guard let argument = readArgument(in: source, from: cursor) else { break }
					arguments.append(rewriteCommands(argument.text))
					cursor = argument.end
				}
				// A half-arrived `\frac{1}{` during streaming reaches here with too
				// few groups; leaving the command alone lets the parser report the
				// missing brace rather than this silently inventing one.
				guard arguments.count == arity else {
					out += "\\" + name
					i = afterName
					continue
				}
				out += substitute(template, arguments)
				i = cursor
				continue
			}

			if name == "substack" {
				if let argument = readArgument(in: source, from: afterName) {
					out += "{" + rewriteCommands(joinRows(argument.text)) + "}"
					i = argument.end
					continue
				}
			}

			if droppedCommands.contains(name) {
				i = afterName
				continue
			}

			out += commandRewrites[name].map { $0 } ?? "\\" + name
			// A rewritten alphabetic command needs its terminator back: `\dots` is
			// followed by `b` in `\dots b`, and `\ldotsb` is a different command.
			if commandRewrites[name] != nil, name.last?.isLetter == true,
			   out.last?.isLetter == true, afterName < source.endIndex,
			   source[afterName].isLetter {
				out += " "
			}
			i = afterName
		}

		return out
	}

	/// The command starting at `backslashAt`, and the index just past its name.
	///
	/// A run of letters is one command; anything else is a single-character
	/// command, which is what keeps `\\` (a row separator) and `\,` (a space) from
	/// being read as the start of a word.
	private static func commandName(
		in source: String,
		backslashAt backslash: String.Index
	) -> (name: String, end: String.Index) {
		var i = source.index(after: backslash)
		guard i < source.endIndex else { return ("", i) }

		if source[i].isLetter {
			let start = i
			while i < source.endIndex, source[i].isLetter { i = source.index(after: i) }
			return (String(source[start..<i]), i)
		}

		return (String(source[i]), source.index(after: i))
	}

	/// The next brace group, or the single token standing in for one.
	///
	/// `\vec x` is as legal as `\vec{x}`, so an argument that isn't braced is one
	/// character — or one command, since `\vec\alpha` binds the whole name.
	private static func readArgument(
		in source: String,
		from start: String.Index
	) -> (text: String, end: String.Index)? {
		var i = start
		while i < source.endIndex, source[i] == " " { i = source.index(after: i) }
		guard i < source.endIndex else { return nil }

		if source[i] == "{" {
			guard let close = matchingBrace(in: source, openingAt: i) else { return nil }
			return (String(source[source.index(after: i)..<close]), source.index(after: close))
		}

		if source[i] == "\\" {
			let (name, end) = commandName(in: source, backslashAt: i)
			guard !name.isEmpty else { return nil }
			return ("\\" + name, end)
		}

		return (String(source[i]), source.index(after: i))
	}

	/// Skips a `[…]` optional argument, if one is there.
	private static func skipOptionalArgument(in source: String, from start: String.Index) -> String.Index {
		var i = start
		while i < source.endIndex, source[i] == " " { i = source.index(after: i) }
		guard i < source.endIndex, source[i] == "[" else { return start }

		var depth = 0
		while i < source.endIndex {
			if source[i] == "[" { depth += 1 }
			if source[i] == "]" {
				depth -= 1
				if depth == 0 { return source.index(after: i) }
			}
			i = source.index(after: i)
		}
		return start
	}

	/// Skips a TeX dimension such as `1pt` or `-0.4 em`.
	private static func skipDimension(in source: String, from start: String.Index) -> String.Index {
		var i = start
		while i < source.endIndex, source[i] == " " { i = source.index(after: i) }
		if i < source.endIndex, source[i] == "-" || source[i] == "+" { i = source.index(after: i) }
		while i < source.endIndex, source[i].isNumber || source[i] == "." { i = source.index(after: i) }
		while i < source.endIndex, source[i] == " " { i = source.index(after: i) }
		// The unit: two letters, and nothing else is a valid TeX unit.
		var unit = i
		var letters = 0
		while unit < source.endIndex, source[unit].isLetter, letters < 2 {
			unit = source.index(after: unit)
			letters += 1
		}
		return letters == 2 ? unit : i
	}

	/// `\genfrac{left}{right}{thickness}{style}{numerator}{denominator}`.
	///
	/// Six arguments, of which SwiftMath can honour two — plus the delimiters,
	/// which become `\left`/`\right` when they're there. A zero thickness means
	/// the bar is suppressed, which is `\atop`.
	private static func rewriteGenfrac(
		in source: String,
		from start: String.Index
	) -> (text: String, end: String.Index)? {
		var arguments: [String] = []
		var cursor = start
		for _ in 0..<6 {
			guard let argument = readArgument(in: source, from: cursor) else { return nil }
			arguments.append(argument.text)
			cursor = argument.end
		}

		let thickness = arguments[2].trimmingCharacters(in: .whitespaces)
		let barless = thickness.hasPrefix("0") && !thickness.isEmpty
		let numerator = rewriteCommands(arguments[4])
		let denominator = rewriteCommands(arguments[5])
		let body = barless
			? "{\(numerator) \\atop \(denominator)}"
			: "\\frac{\(numerator)}{\(denominator)}"

		let left = arguments[0].trimmingCharacters(in: .whitespaces)
		let right = arguments[1].trimmingCharacters(in: .whitespaces)
		guard !left.isEmpty, !right.isEmpty else { return (body, cursor) }
		return ("\\left\(left) \(body) \\right\(right)", cursor)
	}

	private static func substitute(_ template: String, _ arguments: [String]) -> String {
		var out = template
		for (index, argument) in arguments.enumerated() {
			out = out.replacingOccurrences(of: "$\(index)", with: argument)
		}
		return out
	}

	/// `a \\ b \\ c` stacked, for `\substack`.
	private static func joinRows(_ body: String) -> String {
		let rows = splitTopLevel(body, on: "\\\\").map {
			$0.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		guard rows.count > 1 else { return body }
		return rows.dropFirst().reduce(rows[0]) { "{\($0)} \\atop {\($1)}" }
	}

	// MARK: - Macros

	private struct Macro {
		let parameters: Int
		let body: String
	}

	/// Definitions are collected and removed, then applied until nothing is left
	/// to expand.
	///
	/// The caps are the whole design. `\gdef\rec#1{#1 \cdot \rec{#1}}` is a
	/// perfectly ordinary thing to type and expands forever; `\newcommand{\xx}{\x\x}`
	/// chained three deep is exponential. Neither may hang the app, so expansion
	/// stops at a fixed budget and leaves whatever is left alone — the parser then
	/// reports an unknown command and the reader gets the source, which is the
	/// honest outcome for something that genuinely doesn't terminate.
	private static let macroExpansionLimit = 1_000
	private static let macroLengthLimit = 32_768

	private static func expandMacros(_ source: String) -> String {
		let definers = ["newcommand", "renewcommand", "providecommand", "def", "gdef", "edef", "xdef"]
		guard definers.contains(where: { source.contains("\\" + $0) }) else { return source }

		var macros: [String: Macro] = [:]
		var stripped = ""
		var i = source.startIndex

		while i < source.endIndex {
			guard source[i] == "\\" else {
				stripped.append(source[i])
				i = source.index(after: i)
				continue
			}

			let (name, afterName) = commandName(in: source, backslashAt: i)
			guard definers.contains(name) else {
				stripped += "\\" + (name.isEmpty ? String(source[source.index(after: i)]) : name)
				i = name.isEmpty ? source.index(i, offsetBy: 2) : afterName
				continue
			}

			// `\def\foo#1{…}` names the macro bare; `\newcommand{\foo}[1]{…}`
			// braces it and puts the count in brackets.
			var cursor = afterName
			var macroName = ""
			var parameters = 0

			if name.hasSuffix("def") {
				while cursor < source.endIndex, source[cursor] == " " { cursor = source.index(after: cursor) }
				guard cursor < source.endIndex, source[cursor] == "\\" else {
					stripped += "\\" + name
					i = afterName
					continue
				}
				let (defined, afterDefined) = commandName(in: source, backslashAt: cursor)
				macroName = defined
				cursor = afterDefined
				// A `\def` parameter text is a run of `#1#2…` before the body.
				while cursor < source.endIndex, source[cursor] == "#" {
					cursor = source.index(after: cursor)
					if cursor < source.endIndex, source[cursor].isNumber { cursor = source.index(after: cursor) }
					parameters += 1
				}
			} else {
				guard let named = readArgument(in: source, from: cursor) else {
					stripped += "\\" + name
					i = afterName
					continue
				}
				macroName = named.text.trimmingCharacters(in: CharacterSet(charactersIn: "\\ "))
				cursor = named.end
				let afterOptional = skipOptionalArgument(in: source, from: cursor)
				if afterOptional != cursor {
					let digits = source[cursor..<afterOptional].filter(\.isNumber)
					parameters = Int(digits) ?? 0
					cursor = afterOptional
				}
			}

			guard !macroName.isEmpty, let body = readArgument(in: source, from: cursor) else {
				stripped += "\\" + name
				i = afterName
				continue
			}

			macros[macroName] = Macro(parameters: parameters, body: body.text)
			i = body.end
		}

		guard !macros.isEmpty else { return source }

		var expansions = 0
		var out = stripped
		var changed = true

		while changed, expansions < macroExpansionLimit, out.count < macroLengthLimit {
			changed = false
			var next = ""
			var j = out.startIndex

			while j < out.endIndex {
				guard out[j] == "\\" else {
					next.append(out[j])
					j = out.index(after: j)
					continue
				}

				let (name, afterName) = commandName(in: out, backslashAt: j)
				guard let macro = macros[name], expansions < macroExpansionLimit else {
					if name.isEmpty {
						next.append(out[j])
						j = out.index(after: j)
					} else {
						next += "\\" + name
						j = afterName
					}
					continue
				}

				var arguments: [String] = []
				var cursor = afterName
				for _ in 0..<macro.parameters {
					guard let argument = readArgument(in: out, from: cursor) else { break }
					arguments.append(argument.text)
					cursor = argument.end
				}
				guard arguments.count == macro.parameters else {
					next += "\\" + name
					j = afterName
					continue
				}

				var body = macro.body
				for (index, argument) in arguments.enumerated() {
					body = body.replacingOccurrences(of: "#\(index + 1)", with: argument)
				}
				next += body
				j = cursor
				expansions += 1
				changed = true
			}

			out = next
		}

		return out
	}

	// MARK: - Declared operators

	/// `\DeclareMathOperator{\tr}{tr}` defines a command SwiftMath has never heard
	/// of, and then the answer uses it — so both halves have to go, together.
	/// The declaration is removed and every later `\tr` becomes `\mathrm{tr}`.
	private static func expandDeclaredOperators(_ source: String) -> String {
		guard source.contains("\\DeclareMathOperator") else { return source }

		var out = ""
		var operators: [String: String] = [:]
		var i = source.startIndex

		while i < source.endIndex {
			guard source[i...].hasPrefix("\\DeclareMathOperator") else {
				out.append(source[i])
				i = source.index(after: i)
				continue
			}

			var cursor = source.index(i, offsetBy: "\\DeclareMathOperator".count)
			// The starred form takes limits; the difference doesn't survive here.
			if cursor < source.endIndex, source[cursor] == "*" { cursor = source.index(after: cursor) }

			guard let name = readArgument(in: source, from: cursor),
			      let body = readArgument(in: source, from: name.end)
			else {
				out.append(source[i])
				i = source.index(after: i)
				continue
			}

			operators[name.text.trimmingCharacters(in: CharacterSet(charactersIn: "\\ "))] = body.text
			i = body.end
		}

		guard !operators.isEmpty else { return out }

		// Applied token-aware for the same reason as `commandRewrites`: a declared
		// `\d` must not eat the `\delta` three lines down.
		var expanded = ""
		var j = out.startIndex
		while j < out.endIndex {
			guard out[j] == "\\" else {
				expanded.append(out[j])
				j = out.index(after: j)
				continue
			}
			let (name, end) = commandName(in: out, backslashAt: j)
			if let replacement = operators[name] {
				expanded += "\\mathrm{\(replacement)}"
			} else if name.isEmpty {
				expanded.append(out[j])
				j = out.index(after: j)
				continue
			} else {
				expanded += "\\" + name
			}
			j = end
		}
		return expanded
	}

	// MARK: - Environments

	/// Environment names SwiftMath doesn't implement, mapped to ones it does.
	private static let environmentRewrites: [String: String] = [
		"array": "matrix", "smallmatrix": "matrix", "subarray": "matrix",
		"multline": "gather", "multline*": "gather", "gather*": "gather",
		"displaylines": "gather", "eqalign": "aligned", "split": "aligned",
		"align": "aligned", "align*": "aligned", "aligned*": "aligned",
		"alignat": "aligned", "alignat*": "aligned",
		"equation": "aligned", "equation*": "aligned",
	]

	/// How many columns SwiftMath's table builder insists on, by environment.
	///
	/// This is the constraint the old rewrite fell over: `aligned` accepts
	/// *exactly* two columns, so mapping `equation` onto it failed every ordinary
	/// one-line equation — `\begin{equation} E = mc^2 \end{equation}` has no `&`
	/// at all — and a three-column `align` failed the same way from the other
	/// side. The environment name alone was never enough; the body has to be
	/// reshaped to match it.
	private static let requiredColumns: [String: Int] = [
		"aligned": 2, "split": 2, "eqalign": 2, "cases": 2,
		"gather": 1, "displaylines": 1, "eqnarray": 3,
	]

	/// Rewrites environment names and reshapes their bodies to fit.
	///
	/// Innermost first, so a `cases` wrapping an `aligned` normalizes the inner
	/// table's columns before counting the outer one's.
	private static func rewriteEnvironments(_ source: String) -> String {
		guard source.contains("\\begin{") else { return source }

		var out = ""
		var i = source.startIndex

		while i < source.endIndex {
			guard source[i...].hasPrefix("\\begin{"),
			      let environment = environmentName(in: source, beginAt: i),
			      let body = environmentBody(in: source, name: environment.name, from: environment.end)
			else {
				out.append(source[i])
				i = source.index(after: i)
				continue
			}

			var name = environmentRewrites[environment.name] ?? environment.name
			var inner = rewriteEnvironments(String(source[environment.end..<body.bodyEnd]))

			// `\begin{array}{cc}` carries a column spec that `matrix` has no slot
			// for; left in place it parses as a first row of the letters `cc`.
			//
			// Stripped unconditionally, because the spec is mandatory for `array`
			// and its contents are not a fixed alphabet: testing that every
			// character was one of `lcr|@:` let `{r@{}l}` through — braces aren't
			// in that set — and it was typeset as the literal letters `r@l`.
			if environment.name.hasPrefix("array") || environment.name.hasPrefix("subarray") {
				// An optional `[t]`/`[b]` vertical position comes first.
				var cursor = skipOptionalArgument(in: inner, from: inner.startIndex)
				while cursor < inner.endIndex, inner[cursor] == " " || inner[cursor] == "\n" {
					cursor = inner.index(after: cursor)
				}
				if cursor < inner.endIndex, inner[cursor] == "{",
				   let close = matchingBrace(in: inner, openingAt: cursor) {
					inner = String(inner[inner.index(after: close)...])
				}
			}

			if let required = requiredColumns[name] {
				let widest = columnCount(of: inner)
				// A one-column `align` is a centred display, not a two-column
				// alignment — `gather` is what it actually wanted.
				if required == 2, widest <= 1, name != "cases" {
					name = "gather"
					inner = normalizeColumns(inner, to: 1)
				} else {
					inner = normalizeColumns(inner, to: required)
				}
			}

			out += "\\begin{\(name)}\(inner)\\end{\(name)}"
			i = body.end
		}

		return out
	}

	private static func environmentName(
		in source: String,
		beginAt begin: String.Index
	) -> (name: String, end: String.Index)? {
		let open = source.index(begin, offsetBy: "\\begin".count)
		guard let close = matchingBrace(in: source, openingAt: open) else { return nil }
		let name = String(source[source.index(after: open)..<close])
		guard !name.isEmpty else { return nil }
		return (name, source.index(after: close))
	}

	/// The matching `\end{name}`, counting nested `\begin{name}` of the same name.
	private static func environmentBody(
		in source: String,
		name: String,
		from start: String.Index
	) -> (bodyEnd: String.Index, end: String.Index)? {
		let opener = "\\begin{\(name)}"
		let closer = "\\end{\(name)}"
		var depth = 1
		var i = start

		while i < source.endIndex {
			if source[i...].hasPrefix(opener) {
				depth += 1
				i = source.index(i, offsetBy: opener.count)
				continue
			}
			if source[i...].hasPrefix(closer) {
				depth -= 1
				if depth == 0 { return (i, source.index(i, offsetBy: closer.count)) }
				i = source.index(i, offsetBy: closer.count)
				continue
			}
			i = source.index(after: i)
		}
		return nil
	}

	private static func columnCount(of body: String) -> Int {
		rows(of: body).map { splitTopLevel($0, on: "&").count }.max() ?? 1
	}

	/// Pads short rows and merges long ones so every row has exactly `target`
	/// cells — the shape SwiftMath's table builder requires.
	private static func normalizeColumns(_ body: String, to target: Int) -> String {
		let reshaped = rows(of: body).map { row -> String in
			var cells = splitTopLevel(row, on: "&")
			if cells.count > target {
				// The overflow joins the last kept cell rather than being dropped:
				// losing a column loses mathematics, running two together only
				// loses an alignment point.
				let tail = cells[(target - 1)...].joined(separator: " ")
				cells = Array(cells[..<(target - 1)]) + [tail]
			}
			while cells.count < target { cells.append(" {} ") }
			return cells.joined(separator: "&")
		}
		return reshaped.joined(separator: "\\\\")
	}

	/// Top-level rows, with a trailing `\\` (and the empty row it implies) dropped.
	private static func rows(of body: String) -> [String] {
		var rows = splitTopLevel(body, on: "\\\\")
		while rows.count > 1, rows.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
			rows.removeLast()
		}
		return rows
	}

	/// Splits on `separator`, ignoring anything inside braces or a nested
	/// environment — an inner `aligned`'s `&` belongs to the inner table.
	private static func splitTopLevel(_ source: String, on separator: String) -> [String] {
		var parts: [String] = []
		var current = ""
		var depth = 0
		var environmentDepth = 0
		var i = source.startIndex

		while i < source.endIndex {
			if source[i...].hasPrefix("\\begin{") {
				environmentDepth += 1
			} else if source[i...].hasPrefix("\\end{") {
				environmentDepth -= 1
			}

			if depth == 0, environmentDepth == 0, source[i...].hasPrefix(separator) {
				parts.append(current)
				current = ""
				i = source.index(i, offsetBy: separator.count)
				continue
			}

			switch source[i] {
			case "{": depth += 1
			case "}": depth -= 1
			case "\\":
				// An escaped brace is not a brace. Copy the pair across whole so
				// `\{` never opens a group the closer can't balance.
				current.append(source[i])
				i = source.index(after: i)
				if i < source.endIndex, separator != "\\\\" || source[i] != "\\" {
					current.append(source[i])
					i = source.index(after: i)
				}
				continue
			default: break
			}

			current.append(source[i])
			i = source.index(after: i)
		}

		parts.append(current)
		return parts
	}

	// MARK: - Unicode

	/// Rewrites characters the parser accepts and then silently discards.
	///
	/// `MTMathAtomFactory.atom(forCharacter:)` returns nil for anything outside
	/// printable ASCII, and a nil atom is dropped without an error — so a curly
	/// `’` typed as a prime, a real `−` minus, a `≤`, or a bare `α` all *parse*
	/// and then come out of the typesetter missing. That is worse than a failure:
	/// a failure shows the source, this quietly changes the mathematics.
	///
	/// Most of the work is done by SwiftMath's own reverse table, which knows the
	/// command for every glyph it can draw. The literals above it are the ones no
	/// command covers, or where the command is worse than the ASCII it stands for
	/// — `'` becomes a raised prime in the builder, while `\prime` sits on the
	/// baseline.
	private static func normalizeUnicode(_ source: String) -> String {
		guard source.contains(where: { !$0.isASCII }) else { return source }

		var out = ""
		for character in source {
			guard !character.isASCII else {
				out.append(character)
				continue
			}
			out += replacement(for: character) ?? String(character)
		}
		return out
	}

	private static let literalReplacements: [Character: String] = [
		"\u{2019}": "'", "\u{2018}": "'", "\u{02BC}": "'",   // curly apostrophes
		"\u{2032}": "'", "\u{2033}": "''", "\u{2034}": "'''", // primes
		"\u{201C}": "\"", "\u{201D}": "\"",
		"\u{2212}": "-", "\u{2013}": "-", "\u{2014}": "-",    // minus, en/em dash
		"\u{00A0}": " ", "\u{2002}": " ", "\u{2003}": " ", "\u{2009}": " ",
		"\u{2026}": "\\ldots ",

		// Everything below reaches the typesetter as nothing at all without a
		// mapping: SwiftMath's reverse table has no command for these, so they
		// survive `prepare`, parse cleanly, and then draw zero pixels. An answer
		// reading "the derivative ∂f/∂x" arrives as "f/x".
		"\u{2202}": "\\partial ",
		"\u{221A}": "\\sqrt ",   // as an operator: `√2` is `\sqrt 2`, which is right
		"\u{221B}": "\\sqrt[3] ", "\u{221C}": "\\sqrt[4] ",

		// Blackboard capitals, which models type directly for number sets.
		"\u{211D}": "\\mathbb{R}", "\u{2115}": "\\mathbb{N}", "\u{2124}": "\\mathbb{Z}",
		"\u{211A}": "\\mathbb{Q}", "\u{2102}": "\\mathbb{C}", "\u{210D}": "\\mathbb{H}",
		"\u{2119}": "\\mathbb{P}", "\u{1D53C}": "\\mathbb{E}", "\u{1D54A}": "\\mathbb{S}",

		// Superscript and subscript digits, which arrive whole from a model that
		// decided to write `x²` rather than `x^2`.
		"\u{2070}": "^{0}", "\u{00B9}": "^{1}", "\u{00B2}": "^{2}", "\u{00B3}": "^{3}",
		"\u{2074}": "^{4}", "\u{2075}": "^{5}", "\u{2076}": "^{6}", "\u{2077}": "^{7}",
		"\u{2078}": "^{8}", "\u{2079}": "^{9}", "\u{207A}": "^{+}", "\u{207B}": "^{-}",
		"\u{207F}": "^{n}", "\u{2071}": "^{i}",
		"\u{2080}": "_{0}", "\u{2081}": "_{1}", "\u{2082}": "_{2}", "\u{2083}": "_{3}",
		"\u{2084}": "_{4}", "\u{2085}": "_{5}", "\u{2086}": "_{6}", "\u{2087}": "_{7}",
		"\u{2088}": "_{8}", "\u{2089}": "_{9}", "\u{208A}": "_{+}", "\u{208B}": "_{-}",
		"\u{2099}": "_{n}", "\u{1D62}": "_{i}", "\u{2C7C}": "_{j}",

		// Vulgar fractions.
		"\u{00BD}": "\\frac{1}{2}", "\u{00BC}": "\\frac{1}{4}", "\u{00BE}": "\\frac{3}{4}",
		"\u{2153}": "\\frac{1}{3}", "\u{2154}": "\\frac{2}{3}", "\u{215B}": "\\frac{1}{8}",
	]

	/// Cached because `prepare` runs per equation and the reverse lookup allocates
	/// an atom. Unresolvable characters cache as `nil` too, so a paragraph of
	/// prose in an equation doesn't retry every character every time.
	private static var replacementCache: [Character: String?] = [:]

	private static func replacement(for character: Character) -> String? {
		if let cached = replacementCache[character] { return cached }

		let resolved: String?
		if let literal = literalReplacements[character] {
			resolved = literal
		} else if let template = MTMathAtomFactory.atom(forLatexSymbol: "bullet") {
			let probe: MTMathAtom = template.copy()
			probe.nucleus = String(character)
			// The trailing space terminates the command name: `≤y` has to become
			// `\leq y`, not `\leqy`. Math mode ignores the space itself.
			resolved = MTMathAtomFactory.latexSymbolName(for: probe).map { "\\" + $0 + " " }
		} else {
			resolved = nil
		}

		replacementCache[character] = resolved
		return resolved
	}

	// MARK: - Missing symbols

	/// Commands SwiftMath ships no entry for, registered into its factory the
	/// first time anything typesets.
	///
	/// Substituting the Unicode character into the source instead does not work,
	/// which is the non-obvious part: `MTMathAtomFactory.atom(forCharacter:)`
	/// refuses anything outside printable ASCII, so a bare `■` parses without
	/// error and then typesets to nothing at all — zero width, no glyph, no
	/// warning. Registering an atom is what makes the parser and the typesetter
	/// agree, and the fonts already have every glyph below.
	///
	/// Without this a missing command isn't a missing glyph: the *whole equation*
	/// fails to parse, and the reader gets `$\blacksquare$` where a QED mark
	/// should be.
	private static let installedSymbols: Void = {
		// Atoms can't be constructed from outside SwiftMath — `MTMathAtom.init` is
		// internal — but a copy of one the factory already knows can be retyped and
		// refilled, which is the only supported way in.
		guard let template = MTMathAtomFactory.atom(forLatexSymbol: "bullet") else { return }

		let ordinary = [
			"blacksquare": "■",
			"square": "□",
			"Box": "□",
			"qed": "∎",
			"checkmark": "✓",
			"blacktriangle": "▲",
			"blacktriangledown": "▼",
			"blacklozenge": "◆",
			"lozenge": "◇",
			"Diamond": "◇",
			"bigstar": "★",
			"varnothing": "∅",
			// Music, daggers and the amssymb oddities.
			"sharp": "♯", "flat": "♭", "natural": "♮",
			"dagger": "†", "ddagger": "‡",
			"clubsuit": "♣", "diamondsuit": "♢", "heartsuit": "♡", "spadesuit": "♠",
			"eth": "ð", "mho": "℧", "backprime": "‵", "hslash": "ℏ",
			"maltese": "✠", "yen": "¥", "pounds": "£", "circledS": "Ⓢ",
			"complement": "∁", "measuredangle": "∡", "sphericalangle": "∢",
			"surd": "√", "diagup": "╱", "diagdown": "╲",
			"varkappa": "ϰ", "digamma": "ϝ", "Digamma": "Ϝ",
			"beth": "ℶ", "gimel": "ℷ", "daleth": "ℸ",
			// Reached only by the `\&` rewrite below — SwiftMath's tokenizer has a
			// fixed list of single-character command names and `&` isn't on it, so
			// `\&` can never resolve under its own name however it is registered.
			// An alphabetic alias is a name the tokenizer will actually read.
			"ampersandsymbol": "&",
			"S": "§",
			"P": "¶",
		]
		let relations = [
			"therefore": "∴",
			"because": "∵",
			"nmid": "∤",
			"implies": "⟹",
			// Negated and strict set/order relations. SwiftMath ships the affirmative
			// of each pair and not the negation, so a proof that says "A ⊊ B" fails
			// the whole equation over one glyph.
			"subsetneq": "⊊", "supsetneq": "⊋",
			"nsubseteq": "⊈", "nsupseteq": "⊉",
			"nsubset": "⊄", "nsupset": "⊅",
			"nparallel": "∦", "nexists": "∄",
			"ncong": "≇", "nsim": "≁",
			"vdash": "⊢", "dashv": "⊣", "vDash": "⊨", "nvdash": "⊬",
			"sqsubseteq": "⊑", "sqsupseteq": "⊒",
			"preceq": "⪯", "succeq": "⪰", "prec": "≺", "succ": "≻",
			"lll": "⋘", "ggg": "⋙", "lesssim": "≲", "gtrsim": "≳",
			"bowtie": "⋈",
			// Every negation `\not` can rewrite to has to exist, or the rewrite
			// swaps one failure for another.
			"nless": "≮", "ngtr": "≯", "nleq": "≰", "ngeq": "≱",
			"nequiv": "≢", "nsimeq": "≄", "nvDash": "⊭", "nni": "∌",
			"nprec": "⊀", "nsucc": "⊁",
			"nrightarrow": "↛", "nleftarrow": "↚", "nRightarrow": "⇏",
			"nLeftarrow": "⇍", "nleftrightarrow": "↮", "nLeftrightarrow": "⇎",
			// Arrows are relations in TeX, and SwiftMath ships only the plain ones
			// — the hooked, harpooned and diagonal families are all missing.
			"hookrightarrow": "↪", "hookleftarrow": "↩",
			"rightleftharpoons": "⇌", "leftrightharpoons": "⇋",
			"rightharpoonup": "⇀", "rightharpoondown": "⇁",
			"leftharpoonup": "↼", "leftharpoondown": "↽",
			"rightleftarrows": "⇄", "leftrightarrows": "⇆",
			"upuparrows": "⇈", "downdownarrows": "⇊",
			"twoheadrightarrow": "↠", "twoheadleftarrow": "↞",
			"rightsquigarrow": "⇝", "leadsto": "⇝", "leftrightsquigarrow": "↭",
			"nearrow": "↗", "searrow": "↘", "swarrow": "↙", "nwarrow": "↖",
			"circlearrowleft": "↺", "circlearrowright": "↻",
			"curvearrowleft": "↶", "curvearrowright": "↷",
			"looparrowleft": "↫", "looparrowright": "↬",
			"upharpoonright": "↾", "upharpoonleft": "↿",
			"downharpoonright": "⇂", "downharpoonleft": "⇃",
			"multimap": "⊸", "longmapsto": "⟼",
		]

		// Binary operators, which need their own spacing class — a relation here
		// would put the wrong gap on both sides.
		let binary = [
			"circledast": "⊛", "circledcirc": "⊚", "circleddash": "⊝",
			"boxtimes": "⊠", "boxplus": "⊞", "boxminus": "⊟", "boxdot": "⊡",
			"curlyvee": "⋎", "curlywedge": "⋏",
			"ltimes": "⋉", "rtimes": "⋊",
			"leftthreetimes": "⋋", "rightthreetimes": "⋌",
			"divideontimes": "⋇", "smallsetminus": "∖",
			"dotplus": "∔", "centerdot": "⋅", "intercal": "⊺",
		]

		for (name, glyph) in ordinary { install(name, glyph, .ordinary, from: template) }
		for (name, glyph) in relations { install(name, glyph, .relation, from: template) }
		for (name, glyph) in binary { install(name, glyph, .binaryOperator, from: template) }

		// `\&` is the one escape SwiftMath's parser has no entry for — `\%`, `\$`,
		// `\_` and `\#` all resolve. A non-alphabetic command is looked up under
		// its single character, so this registers under the name "&".
		install("&", "&", .ordinary, from: template)
	}()

	/// Registers `name`, unless SwiftMath already knows it.
	///
	/// The guard is the point: `add(latexSymbol:)` overwrites, and a table entry
	/// SwiftMath ships is one it also has a font glyph and a spacing class for.
	/// Replacing a working symbol with a copied `\bullet` wearing a different
	/// nucleus is how a fix for a missing glyph breaks a correct one.
	private static func install(
		_ name: String,
		_ glyph: String,
		_ type: MTMathAtomType,
		from template: MTMathAtom
	) {
		guard MTMathAtomFactory.atom(forLatexSymbol: name) == nil else { return }

		let atom: MTMathAtom = template.copy()
		atom.type = type
		atom.nucleus = glyph
		MTMathAtomFactory.add(latexSymbol: name, value: atom)
	}

	private static func unwrapBoxed(_ source: String) -> (latex: String, boxed: Bool) {
		guard source.contains("\\boxed") else { return (source, false) }

		let whole = source.trimmingCharacters(in: .whitespacesAndNewlines)
		var out = ""
		var wrappedWhole = false
		var i = source.startIndex

		while i < source.endIndex {
			guard source[i...].hasPrefix("\\boxed") else {
				out.append(source[i])
				i = source.index(after: i)
				continue
			}

			var afterCommand = source.index(i, offsetBy: 6)
			while afterCommand < source.endIndex, source[afterCommand] == " " {
				afterCommand = source.index(after: afterCommand)
			}

			guard afterCommand < source.endIndex,
			      source[afterCommand] == "{",
			      let close = matchingBrace(in: source, openingAt: afterCommand)
			else {
				i = afterCommand
				continue
			}

			if source[i...close].trimmingCharacters(in: .whitespacesAndNewlines) == whole {
				wrappedWhole = true
			}
			out += unwrapBoxed(String(source[source.index(after: afterCommand)..<close])).latex
			i = source.index(after: close)
		}

		return (out, wrappedWhole)
	}

	private static func matchingBrace(in source: String, openingAt open: String.Index) -> String.Index? {
		var depth = 0
		var i = open
		while i < source.endIndex {
			switch source[i] {
			case "\\":
				i = source.index(after: i)
				if i < source.endIndex { i = source.index(after: i) }
				continue
			case "{":
				depth += 1
			case "}":
				depth -= 1
				if depth == 0 { return i }
			default:
				break
			}
			i = source.index(after: i)
		}
		return nil
	}
}

