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
