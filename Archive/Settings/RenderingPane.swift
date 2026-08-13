//
//  RenderingPane.swift
//  ChatCore
//

import SwiftUI

/// How the transcript is drawn, as distinct from what it looks like.
///
/// Neither choice here has a right answer — a renderer that scrolls better but
/// can't select text, a streaming mode that formats as the reply arrives
/// instead of animating it in. Appearance is where you say what a message
/// should look like; this is where you say what it costs to put one on screen.
struct RenderingPane: View {

	@AppStorage(Defaults.Key.transcriptRenderer) private var rendererID = TranscriptRenderer.default.rawValue
	@AppStorage(Defaults.Key.streamingMode) private var streamingModeRaw = StreamingMode.token.rawValue

	var body: some View {
		let _ = Self.printChanges()
		VStack(alignment: .leading, spacing: 0) {
			settingsPaneTitle("Rendering")

			Form {
				Section {
					Picker("", selection: $rendererID) {
						ForEach(TranscriptRenderer.allCases) { renderer in
							Text(renderer.displayName).tag(renderer.rawValue)
						}
					}
					.pickerStyle(.radioGroup)
					.labelsHidden()
				} header: {
					settingsSectionHeader("Transcript", "Which renderer draws the conversation.")
				} footer: {
					settingsFooterText(TranscriptRenderer(storedID: rendererID).summary)
				}

				Section {
					Picker("", selection: $streamingModeRaw) {
						ForEach(StreamingMode.allCases) { mode in
							Text(mode.displayName).tag(mode.rawValue)
						}
					}
					.pickerStyle(.radioGroup)
					.labelsHidden()
				} header: {
					settingsSectionHeader("Streaming", "How a reply is drawn while it's still arriving.")
				} footer: {
					settingsFooterText(StreamingMode(rawValue: streamingModeRaw)?.summary ?? "")
				}
			}
			.formStyle(.grouped)
		}
	}
}

// MARK: - Preview

#Preview("Rendering pane") {
	RenderingPane()
		.frame(width: 390, height: 420)
}
