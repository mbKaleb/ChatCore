//
//  CodeBlockCard.swift
//  ChatCore
//

import SwiftUI
import AppKit
import MarkdownUI

struct CodeBlockCard: View {
	let configuration: CodeBlockConfiguration

	@Environment(ThemeManager.self) private var themes
	@State private var isHovering = false
	@State private var didCopy = false

	private let cornerRadius: CGFloat = 12
	private var t: ChatTheme { themes.theme }
	private var a: ChatAppearance { themes.appearance }

	private var code: String {
		configuration.content.trimmingCharacters(in: .newlines)
	}

	var body: some View {
		HorizontalScrollBox {
			Text(code)
				.font(a.codeFont.font(size: a.codeFontSize))
				.foregroundStyle(t.bodyText)
				.textSelection(.enabled)
				.padding(16)
				.padding(.trailing, 34)
		}
		.background(
			RoundedRectangle(cornerRadius: cornerRadius)
				.fill(t.codeCardBackground)
		)
		.overlay {
			RoundedRectangle(cornerRadius: cornerRadius)
				.stroke(t.codeCardBorder, lineWidth: 1)
		}
		.overlay(alignment: .topTrailing) {
			copyButton
				.opacity(isHovering ? 1 : 0)
				.padding(8)
		}
		.onHover { isHovering = $0 }
		.animation(.easeInOut(duration: 0.12), value: isHovering)
	}

	private var copyButton: some View {
		Button(action: copy) {
			Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
				.font(.caption)
				.foregroundStyle(t.bodyText.opacity(0.75))
				.frame(width: 22, height: 22)
				.background(
					RoundedRectangle(cornerRadius: 6)
						.fill(t.codeCardCopyBackground)
				)
				.contentShape(RoundedRectangle(cornerRadius: 6))
		}
		.buttonStyle(.plain)
		.help(didCopy ? "Copied" : "Copy code")
		.disabled(didCopy)
	}

	private func copy() {
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(code, forType: .string)

		didCopy = true

		Task {
			try? await Task.sleep(for: .seconds(1.2))
			didCopy = false
		}
	}
}
