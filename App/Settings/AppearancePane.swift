//
//  AppearancePane.swift
//  ChatCore
//

import SwiftUI
import MarkdownUI

struct AppearancePane: View {

	@Environment(ThemeManager.self) private var themes
	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		@Bindable var themes = themes
		let t = themes.theme
		let a = themes.appearance

		return VStack(alignment: .leading, spacing: 0) {
			settingsPaneTitle("Appearance")

			Form {
				Section {
					themeRow($themes.selectedID)
				}

				Section {
					fontRow("Body font", selection: $themes.bodyFontID, catalog: ChatFont.prose)
					sizeRow(
						"Text size",
						value: $themes.fontSize,
						display: "\(Int(a.fontSize)) pt",
						range: ChatAppearance.fontSizeRange,
						min: "textformat.size.smaller",
						max: "textformat.size.larger"
					)
					sizeRow(
						"Line spacing",
						value: $themes.lineSpacing,
						display: "\(Int(a.lineSpacing)) pt",
						range: ChatAppearance.lineSpacingRange,
						min: "text.alignleft",
						max: "text.justify"
					)
				} header: {
					settingsSectionHeader("Body text", "The prose in every message, yours and the model's.")
				} footer: {
					sampleFooter { sample(t, a, Self.bodyContent) }
				}

				Section {
					fontRow("Heading font", selection: $themes.headingFontID, catalog: ChatFont.prose)
					sizeRow(
						"Heading scale",
						value: $themes.headingScale,
						display: percent(a.headingScale),
						range: ChatAppearance.headingScaleRange,
						step: 0.05,
						min: "textformat.size.smaller",
						max: "textformat.size.larger",
						note: "How much larger headings are than body text. All six levels scale together."
					)
				} header: {
					settingsSectionHeader("Headings", "Section titles the model uses to break up a long reply.")
				} footer: {
					sampleFooter { sample(t, a, Self.headingContent) }
				}

				Section {
					fontRow("Code font", selection: $themes.codeFontID, catalog: ChatFont.monospaced)
					sizeRow(
						"Code size",
						value: $themes.codeFontSize,
						display: "\(Int(a.codeFontSize)) pt",
						range: ChatAppearance.codeFontSizeRange,
						min: "chevron.left.forwardslash.chevron.right",
						max: "chevron.left.forwardslash.chevron.right",
						maxScale: .medium,
						note: "Set in points, not relative — monospaced text reads larger than prose at the same size."
					)
				} header: {
					settingsSectionHeader("Code", "Inline spans and fenced blocks.")
				} footer: {
					sampleFooter { sample(t, a, Self.codeContent) }
				}

				Section {
					Toggle(isOn: $themes.rendersMath) {
						VStack(alignment: .leading, spacing: 2) {
							Text("Render equations")
							Text("Off shows the LaTeX as written.")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
					}
					sizeRow(
						"Equation size",
						value: $themes.equationScale,
						display: percent(a.equationScale),
						range: ChatAppearance.equationScaleRange,
						step: 0.05,
						min: "function",
						max: "function",
						maxScale: .medium
					)
					.disabled(!a.rendersMath)
					.opacity(a.rendersMath ? 1 : 0.4)
				} header: {
					settingsSectionHeader("Equations", "Display math written as $$…$$ or \\[…\\].")
				} footer: {
					sampleFooter {
						sample(t, a, a.rendersMath ? Self.equationContentRendered : Self.equationContentLiteral)
					}
				}

				Section {
					fontRow("Table font", selection: $themes.tableFontID, catalog: ChatFont.prose)
					sizeRow(
						"Table text size",
						value: $themes.tableFontSize,
						display: "\(Int(a.tableFontSize)) pt",
						range: ChatAppearance.tableFontSizeRange,
						min: "tablecells",
						max: "tablecells",
						maxScale: .medium,
						note: "Its own size, so a wide table can be dialed down without shrinking the prose around it."
					)
					Toggle(isOn: $themes.stripedTables) {
						Text("Striped rows")
					}
				} header: {
					settingsSectionHeader("Tables", "Grids of rows and columns.")
				} footer: {
					sampleFooter { sample(t, a, Self.tableContent) }
				}

				Section {
					HStack {
						Spacer(minLength: 0)
						Button("Reset to Defaults", action: themes.resetAppearance)
							.disabled(a == .default && themes.selectedID == Defaults.defaultThemeID)
					}
				}
			}
			.formStyle(.grouped)
		}
	}

	// MARK: - Section chrome

	private func sampleFooter(
		_ note: String? = nil,
		@ViewBuilder sample: () -> some View
	) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			if let note {
				settingsFooterText(note)
			}
			sample()
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func caption(_ text: String) -> some View {
		Text(text)
			.font(.caption)
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
	}

	private func percent(_ scale: Double) -> String {
		"\(Int((scale * 100).rounded()))%"
	}

	// MARK: - Samples

	private func sample(
		_ t: ChatTheme,
		_ a: ChatAppearance,
		_ content: MarkdownContent
	) -> some View {
		Markdown(content)
			.chatMarkdownStyle(t, a)
			.padding(.horizontal, 15)
			.padding(.vertical, 11)
			.frame(maxWidth: .infinity, alignment: .topLeading)
			.background(t.assistantBubble)
			.clipShape(RoundedRectangle(cornerRadius: 10))
			.padding(8)
			.background(colorScheme == .dark ? Color.black.opacity(0.85) : Color.white.opacity(0.85))
			.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
			.animation(.easeInOut(duration: 0.12), value: a)
	}

	private static let bodySample = """
		Body text wraps across lines here, with **bold** in it.

		- A list item, because replies are mostly lists
		- And a second, so the spacing between them shows
		"""

	private static let headingSample = """
		# Heading 1
		### Heading 3
		##### Heading 5
		Body text, for comparison.
		"""

	private static let codeSample = """
		An `inline span`, then a block:

		```swift
		let greeting = "Hello"
		print(greeting)
		```
		"""

	private static let equationSample = """
		$$e^{i\\pi} + 1 = 0$$
		"""

	private static let tableSample = """
		| Control | Affects |
		| --- | --- |
		| Text size | Body, headings |
		| Code size | Inline and fenced |
		"""

	private static let bodyContent = MarkdownContent(bodySample)
	private static let headingContent = MarkdownContent(headingSample)
	private static let codeContent = MarkdownContent(codeSample)
	private static let tableContent = MarkdownContent(tableSample)

	private static let equationContentRendered = MarkdownContent(MathMarkdown.preprocess(equationSample))
	private static let equationContentLiteral = MarkdownContent(equationSample)

	// MARK: - Controls

	private func themeRow(_ selection: Binding<String>) -> some View {
		Picker("Theme", selection: selection) {
			Text("System").tag(ChatTheme.systemID)
			Divider()
			ForEach(ChatTheme.all) { theme in
				Text(theme.name).tag(theme.id)
			}
		}
		.pickerStyle(.menu)
	}

	private func fontRow(
		_ label: String,
		selection: Binding<String>,
		catalog: [ChatFont]
	) -> some View {
		Picker(label, selection: selection) {
			ForEach(catalog) { font in
				Text(font.name)
					.font(font.font(size: 13))
					.tag(font.id)
			}
		}
		.pickerStyle(.menu)
	}

	private func sizeRow(
		_ label: String,
		value: Binding<Double>,
		display: String,
		range: ClosedRange<Double>,
		step: Double = 1,
		min minSymbol: String,
		max maxSymbol: String,
		maxScale: Image.Scale = .large,
		note: String? = nil
	) -> some View {
		LabeledContent(label) {
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					Slider(value: value, in: range, step: step) {
						EmptyView()
					} minimumValueLabel: {
						Image(systemName: minSymbol).imageScale(.small)
					} maximumValueLabel: {
						Image(systemName: maxSymbol).imageScale(maxScale)
					}

					Text(display)
						.font(.caption.monospacedDigit())
						.foregroundStyle(.secondary)
						.frame(width: 34, alignment: .trailing)
				}

				if let note {
					caption(note)
				}
			}
		}
	}
}

// MARK: - Preview

#Preview("Appearance pane") {
	AppearancePane()
		.frame(width: 390, height: 560)
		.environment(ThemeManager())
}
