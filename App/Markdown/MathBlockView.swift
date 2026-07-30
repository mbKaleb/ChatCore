//
//  MathBlockView.swift
//  ChatCore
//

import SwiftUI
import AppKit
import SwiftMath

struct MathBlockView: View {
	let latex: String
	var fontSize: CGFloat? = nil
	var color: Color? = nil

	@Environment(ThemeManager.self) private var themes
	@Environment(\.self) private var environment

	var body: some View {
		let prepared = LatexCompat.prepare(latex)

		HorizontalScrollBox {
			MathLabel(latex: prepared.latex, fontSize: resolvedFontSize, textColor: resolvedColor)
				.padding(.vertical, 10)
				.padding(.horizontal, prepared.boxed ? 14 : 4)
				.overlay {
					if prepared.boxed {
						RoundedRectangle(cornerRadius: 6)
							.stroke(Color(resolvedColor).opacity(0.45), lineWidth: 1)
					}
				}
		}
	}

	private var resolvedFontSize: CGFloat {
		fontSize ?? CGFloat(themes.appearance.equationFontSize)
	}

	private var resolvedColor: NSColor {
		let source = color ?? themes.theme.bodyText
		return NSColor(cgColor: source.resolve(in: environment).cgColor) ?? .labelColor
	}
}

// MARK: - LaTeX Compatibility

enum LatexCompat {

	static func prepare(_ latex: String) -> (latex: String, boxed: Bool) {
		var source = latex

		for (unsupported, supported) in [
			("align*", "aligned"),
			("align", "aligned"),
			("gather*", "gather"),
			("equation*", "aligned"),
			("equation", "aligned"),
		] {
			source = source
				.replacingOccurrences(of: "\\begin{\(unsupported)}", with: "\\begin{\(supported)}")
				.replacingOccurrences(of: "\\end{\(unsupported)}", with: "\\end{\(supported)}")
		}

		source = source.replacingOccurrences(of: "\\operatorname", with: "\\mathrm")

		return unwrapBoxed(source)
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

private struct MathLabel: NSViewRepresentable {
	var latex: String
	var fontSize: CGFloat
	var textColor: NSColor

	func makeNSView(context: Context) -> MTMathUILabel {
		let label = MTMathUILabel()
		label.labelMode = .display
		label.textAlignment = .left
		label.contentInsets = MTEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
		label.displayErrorInline = true
		apply(to: label)
		return label
	}

	func updateNSView(_ label: MTMathUILabel, context: Context) {
		apply(to: label)
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
		apply(to: nsView)
		guard nsView.mathList != nil else {
			return CGSize(width: 240, height: ceil(fontSize * 1.6))
		}
		let fitting = nsView.fittingSize
		return CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
	}

	private func apply(to label: MTMathUILabel) {
		if label.latex != latex { label.latex = latex }
		if label.fontSize != fontSize { label.fontSize = fontSize }
		if label.textColor != textColor { label.textColor = textColor }
	}
}
