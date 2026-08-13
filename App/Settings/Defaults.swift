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

		/// One switch per vendor in the Models pane.
		nonisolated static func vendorEnabled(_ vendor: ModelVendor) -> String {
			"vendorEnabled.\(vendor.rawValue)"
		}

		/// One switch per model in the Models pane, under the id the vendor gave
		/// it.
		///
		/// These can't be pre-registered the way the vendor switches are: the set
		/// of models isn't known until a vendor answers, and writing a default for
		/// a model we assume exists would make this file a second catalog to keep
		/// in step with the real one. So an absent value means nobody has touched
		/// the switch, and what that means is derived from the vendor's own
		/// catalog — see `ModelManager.isEnabled(_:)`.
		nonisolated static func modelEnabled(_ id: GenerativeChatModel.ID) -> String {
			"modelEnabled.\(id)"
		}

		/// Whether a vendor's model list in the Models pane is open. Closed out of
		/// the box — the pane reads as a list of vendors, and a vendor that vends
		/// a dozen models shouldn't push the rest of them off screen.
		nonisolated static func vendorExpanded(_ vendor: ModelVendor) -> String {
			"vendorExpanded.\(vendor.rawValue)"
		}

		/// Whether the retired half of a vendor's model list is open. Its own key
		/// rather than a share of `vendorExpanded`: opening a vendor is a question
		/// about what it ships, and the answer to that shouldn't come with every
		/// version it ever shipped attached.
		nonisolated static func vendorOlderExpanded(_ vendor: ModelVendor) -> String {
			"vendorOlderExpanded.\(vendor.rawValue)"
		}

		/// Whether the Models pane's second group — the vendors we keep for
		/// completeness rather than for daily use — is showing. Closed out of the
		/// box so the frontier vendors are the whole pane until asked otherwise.
		static let showsAdditionalVendors = "showsAdditionalVendors"

		static let appearance = [
			selectedThemeID, fontSize, lineSpacing, headingScale,
			codeFontSize, rendersMath, equationScale,
			tableFontSize, stripedTables,
			bodyFontID, headingFontID, codeFontID, tableFontID,
		]
	}

	static let defaultThemeID = ChatTheme.systemID

	static let registered: Void = {
		var vendorDefaults: [String: Any] = [:]
		for vendor in ModelVendor.allCases {
			vendorDefaults[Key.vendorEnabled(vendor)] = vendor.isEnabledByDefault
		}
		UserDefaults.standard.register(defaults: vendorDefaults)

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
