//
//  ChatTheme.swift
//  ChatCore
//

import SwiftUI
import Observation

struct ChatTheme: Identifiable, Equatable {
	let id: String
	let name: String

	var userBubble: Color
	var userText: Color
	var assistantBubble: Color
	var chipBackground: Color

	var bodyText: Color
	var strongText: Color
	var emphasisText: Color
	var headingText: Color
	var linkText: Color
	var blockquoteRule: Color

	var inlineCodeText: Color
	var inlineCodeBackground: Color
	var codeCardBackground: Color
	var codeCardBorder: Color
	var codeCardCopyBackground: Color
}

extension ChatTheme {

	static let midnight = ChatTheme(
		id: "midnight",
		name: "Midnight",
		userBubble: .blue,
		userText: .white,
		assistantBubble: .white.opacity(0.06),
		chipBackground: .white.opacity(0.12),
		bodyText: .white.opacity(0.92),
		strongText: .white,
		emphasisText: .white.opacity(0.9),
		headingText: .white,
		linkText: .blue,
		blockquoteRule: .blue,
		inlineCodeText: .white,
		inlineCodeBackground: .white.opacity(0.06),
		codeCardBackground: Color(red: 0.12, green: 0.13, blue: 0.16),
		codeCardBorder: .white.opacity(0.06),
		codeCardCopyBackground: .white.opacity(0.10)
	)

	static let graphite = ChatTheme(
		id: "graphite",
		name: "Graphite",
		userBubble: .white.opacity(0.14),
		userText: .white,
		assistantBubble: .white.opacity(0.05),
		chipBackground: .white.opacity(0.11),
		bodyText: .white.opacity(0.90),
		strongText: .white,
		emphasisText: .white.opacity(0.88),
		headingText: .white,
		linkText: Color(red: 0.55, green: 0.75, blue: 1.0),
		blockquoteRule: .white.opacity(0.35),
		inlineCodeText: Color(red: 1.0, green: 0.86, blue: 0.72),
		inlineCodeBackground: .white.opacity(0.07),
		codeCardBackground: Color(red: 0.11, green: 0.11, blue: 0.12),
		codeCardBorder: .white.opacity(0.08),
		codeCardCopyBackground: .white.opacity(0.12)
	)

	static let all: [ChatTheme] = [.midnight, .graphite]
}

struct ChatAppearance: Equatable {

	var bodyFont: ChatFont
	var fontSize: Double
	var lineSpacing: Double

	var headingFont: ChatFont
	var headingScale: Double

	var codeFont: ChatFont
	var codeFontSize: Double

	var rendersMath: Bool
	var equationScale: Double

	var tableFont: ChatFont
	var tableFontSize: Double
	var stripedTables: Bool

	static let `default` = ChatAppearance(
		bodyFont: .system,
		fontSize: 15,
		lineSpacing: 4,
		headingFont: .system,
		headingScale: 1,
		codeFont: .systemMono,
		codeFontSize: 13,
		rendersMath: true,
		equationScale: 1.15,
		tableFont: .system,
		tableFontSize: 14,
		stripedTables: true
	)

	static let fontSizeRange: ClosedRange<Double> = 11...24
	static let lineSpacingRange: ClosedRange<Double> = 0...12
	static let headingScaleRange: ClosedRange<Double> = 0.8...1.3
	static let codeFontSizeRange: ClosedRange<Double> = 9...20
	static let equationScaleRange: ClosedRange<Double> = 0.9...1.6
	static let tableFontSizeRange: ClosedRange<Double> = 9...20

	func headingSize(_ level: Int) -> Double {
		let ramp: Double = switch level {
		case 1:  2.05
		case 2:  1.70
		case 3:  1.40
		case 4:  1.20
		case 5:  1.05
		default: 1.00
		}
		return fontSize * (1 + (ramp - 1) * headingScale)
	}

	var equationFontSize: Double { fontSize * equationScale }
}

@Observable
@MainActor
final class ThemeManager {

	var selectedID: String {
		didSet { persist(selectedID, forKey: Defaults.Key.selectedThemeID) }
	}

	@ObservationIgnored private var isRestoringDefaults = false

	private func persist(_ value: Any, forKey key: String) {
		guard !isRestoringDefaults else { return }
		UserDefaults.standard.set(value, forKey: key)
	}

	private var storedFontSize: Double
	private var storedLineSpacing: Double
	private var storedHeadingScale: Double
	private var storedCodeFontSize: Double
	private var storedEquationScale: Double
	private var storedTableFontSize: Double

	var fontSize: Double {
		get { storedFontSize }
		set {
			let clamped = newValue.clamped(to: ChatAppearance.fontSizeRange)
			guard clamped != storedFontSize else { return }
			storedFontSize = clamped
			persist(clamped, forKey: Defaults.Key.fontSize)
		}
	}

	var lineSpacing: Double {
		get { storedLineSpacing }
		set {
			let clamped = newValue.clamped(to: ChatAppearance.lineSpacingRange)
			guard clamped != storedLineSpacing else { return }
			storedLineSpacing = clamped
			persist(clamped, forKey: Defaults.Key.lineSpacing)
		}
	}

	var headingScale: Double {
		get { storedHeadingScale }
		set {
			let clamped = newValue.clamped(to: ChatAppearance.headingScaleRange)
			guard clamped != storedHeadingScale else { return }
			storedHeadingScale = clamped
			persist(clamped, forKey: Defaults.Key.headingScale)
		}
	}

	var codeFontSize: Double {
		get { storedCodeFontSize }
		set {
			let clamped = newValue.clamped(to: ChatAppearance.codeFontSizeRange)
			guard clamped != storedCodeFontSize else { return }
			storedCodeFontSize = clamped
			persist(clamped, forKey: Defaults.Key.codeFontSize)
		}
	}

	var equationScale: Double {
		get { storedEquationScale }
		set {
			let clamped = newValue.clamped(to: ChatAppearance.equationScaleRange)
			guard clamped != storedEquationScale else { return }
			storedEquationScale = clamped
			persist(clamped, forKey: Defaults.Key.equationScale)
		}
	}

	var tableFontSize: Double {
		get { storedTableFontSize }
		set {
			let clamped = newValue.clamped(to: ChatAppearance.tableFontSizeRange)
			guard clamped != storedTableFontSize else { return }
			storedTableFontSize = clamped
			persist(clamped, forKey: Defaults.Key.tableFontSize)
		}
	}

	var bodyFontID: String {
		didSet { persist(bodyFontID, forKey: Defaults.Key.bodyFontID) }
	}

	var headingFontID: String {
		didSet { persist(headingFontID, forKey: Defaults.Key.headingFontID) }
	}

	var codeFontID: String {
		didSet { persist(codeFontID, forKey: Defaults.Key.codeFontID) }
	}

	var tableFontID: String {
		didSet { persist(tableFontID, forKey: Defaults.Key.tableFontID) }
	}

	var rendersMath: Bool {
		didSet { persist(rendersMath, forKey: Defaults.Key.rendersMath) }
	}

	var stripedTables: Bool {
		didSet { persist(stripedTables, forKey: Defaults.Key.stripedTables) }
	}

	init() {
		_ = Defaults.registered
		let defaults = UserDefaults.standard

		let stored = defaults.string(forKey: Defaults.Key.selectedThemeID)
		selectedID = ChatTheme.all.contains { $0.id == stored } ? stored! : ChatTheme.midnight.id

		storedFontSize = defaults.double(forKey: Defaults.Key.fontSize)
			.clamped(to: ChatAppearance.fontSizeRange)
		storedLineSpacing = defaults.double(forKey: Defaults.Key.lineSpacing)
			.clamped(to: ChatAppearance.lineSpacingRange)
		storedHeadingScale = defaults.double(forKey: Defaults.Key.headingScale)
			.clamped(to: ChatAppearance.headingScaleRange)
		storedCodeFontSize = defaults.double(forKey: Defaults.Key.codeFontSize)
			.clamped(to: ChatAppearance.codeFontSizeRange)
		storedTableFontSize = defaults.double(forKey: Defaults.Key.tableFontSize)
			.clamped(to: ChatAppearance.tableFontSizeRange)
		storedEquationScale = defaults.double(forKey: Defaults.Key.equationScale)
			.clamped(to: ChatAppearance.equationScaleRange)
		rendersMath = defaults.bool(forKey: Defaults.Key.rendersMath)
		stripedTables = defaults.bool(forKey: Defaults.Key.stripedTables)

		bodyFontID = defaults.string(forKey: Defaults.Key.bodyFontID) ?? ChatFont.system.id
		headingFontID = defaults.string(forKey: Defaults.Key.headingFontID) ?? ChatFont.system.id
		codeFontID = defaults.string(forKey: Defaults.Key.codeFontID) ?? ChatFont.systemMono.id
		tableFontID = defaults.string(forKey: Defaults.Key.tableFontID) ?? ChatFont.system.id
	}

	var theme: ChatTheme {
		ChatTheme.all.first { $0.id == selectedID } ?? .midnight
	}

	var appearance: ChatAppearance {
		ChatAppearance(
			bodyFont: ChatFont.resolve(bodyFontID, in: ChatFont.prose, fallback: .system),
			fontSize: fontSize,
			lineSpacing: lineSpacing,
			headingFont: ChatFont.resolve(headingFontID, in: ChatFont.prose, fallback: .system),
			headingScale: headingScale,
			codeFont: ChatFont.resolve(codeFontID, in: ChatFont.monospaced, fallback: .systemMono),
			codeFontSize: codeFontSize,
			rendersMath: rendersMath,
			equationScale: equationScale,
			tableFont: ChatFont.resolve(tableFontID, in: ChatFont.prose, fallback: .system),
			tableFontSize: tableFontSize,
			stripedTables: stripedTables
		)
	}

	func resetAppearance() {
		let defaults = UserDefaults.standard
		for key in Defaults.Key.appearance {
			defaults.removeObject(forKey: key)
		}

		isRestoringDefaults = true
		defer { isRestoringDefaults = false }
		selectedID = defaults.string(forKey: Defaults.Key.selectedThemeID) ?? ChatTheme.midnight.id
		storedFontSize = defaults.double(forKey: Defaults.Key.fontSize)
		storedLineSpacing = defaults.double(forKey: Defaults.Key.lineSpacing)
		storedHeadingScale = defaults.double(forKey: Defaults.Key.headingScale)
		storedCodeFontSize = defaults.double(forKey: Defaults.Key.codeFontSize)
		storedEquationScale = defaults.double(forKey: Defaults.Key.equationScale)
		storedTableFontSize = defaults.double(forKey: Defaults.Key.tableFontSize)
		rendersMath = defaults.bool(forKey: Defaults.Key.rendersMath)
		stripedTables = defaults.bool(forKey: Defaults.Key.stripedTables)
		bodyFontID = defaults.string(forKey: Defaults.Key.bodyFontID) ?? ChatFont.system.id
		headingFontID = defaults.string(forKey: Defaults.Key.headingFontID) ?? ChatFont.system.id
		codeFontID = defaults.string(forKey: Defaults.Key.codeFontID) ?? ChatFont.systemMono.id
		tableFontID = defaults.string(forKey: Defaults.Key.tableFontID) ?? ChatFont.system.id
	}
}

private extension Double {
	func clamped(to range: ClosedRange<Double>) -> Double {
		min(max(self, range.lowerBound), range.upperBound)
	}
}
