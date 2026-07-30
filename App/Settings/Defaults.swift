//
//  Defaults.swift
//  ChatCore
//

import Foundation

enum Defaults {

	enum Key {
		static let defaultModelID = "defaultModelID"
		static let selectedThemeID = "selectedThemeID"
		static let bodyFontID = "appearanceBodyFontID"
		static let headingFontID = "appearanceHeadingFontID"
		static let codeFontID = "appearanceCodeFontID"
		static let tableFontID = "appearanceTableFontID"
		static let fontSize = "appearanceFontSize"
		static let lineSpacing = "appearanceLineSpacing"
		static let headingScale = "appearanceHeadingScale"
		static let codeFontSize = "appearanceCodeFontSize"
		static let rendersMath = "appearanceRendersMath"
		static let equationScale = "appearanceEquationScale"
		static let tableFontSize = "appearanceTableFontSize"
		static let stripedTables = "appearanceStripedTables"
		static let streamingMode = "streamingMode"

		static let appearance = [
			selectedThemeID, fontSize, lineSpacing, headingScale,
			codeFontSize, rendersMath, equationScale,
			tableFontSize, stripedTables,
			bodyFontID, headingFontID, codeFontID, tableFontID,
		]
	}

	static let defaultThemeID = ChatTheme.midnight.id

	static let registered: Void = {
		UserDefaults.standard.register(defaults: [
			Key.defaultModelID: GenerativeChatModel.onDevice.id,
			Key.selectedThemeID: defaultThemeID,
			Key.bodyFontID: ChatAppearance.default.bodyFont.id,
			Key.headingFontID: ChatAppearance.default.headingFont.id,
			Key.codeFontID: ChatAppearance.default.codeFont.id,
			Key.tableFontID: ChatAppearance.default.tableFont.id,
			Key.fontSize: ChatAppearance.default.fontSize,
			Key.lineSpacing: ChatAppearance.default.lineSpacing,
			Key.headingScale: ChatAppearance.default.headingScale,
			Key.codeFontSize: ChatAppearance.default.codeFontSize,
			Key.rendersMath: ChatAppearance.default.rendersMath,
			Key.equationScale: ChatAppearance.default.equationScale,
			Key.tableFontSize: ChatAppearance.default.tableFontSize,
			Key.stripedTables: ChatAppearance.default.stripedTables,
			Key.streamingMode: StreamingMode.token.rawValue,
		])
	}()
}
