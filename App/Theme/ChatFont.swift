//
//  ChatFont.swift
//  ChatCore
//

import SwiftUI
import CoreText
import MarkdownUI

struct ChatFont: Identifiable, Hashable, Sendable {

	enum Kind: Hashable, Sendable {
		case system(Font.Design)
		case family(String)
	}

	let id: String
	let name: String
	let kind: Kind
	let isMonospaced: Bool

	// MARK: - Catalog

	static let system = ChatFont(id: "system", name: "System", kind: .system(.default), isMonospaced: false)

	static let systemMono = ChatFont(id: "systemMono", name: "System Mono", kind: .system(.monospaced), isMonospaced: true)

	static let prose: [ChatFont] = available([
		system,
		ChatFont(id: "rounded", name: "System Rounded", kind: .system(.rounded), isMonospaced: false),
		ChatFont(id: "serif", name: "New York", kind: .system(.serif), isMonospaced: false),
		ChatFont(id: "helveticaNeue", name: "Helvetica Neue", kind: .family("Helvetica Neue"), isMonospaced: false),
		ChatFont(id: "avenirNext", name: "Avenir Next", kind: .family("Avenir Next"), isMonospaced: false),
		ChatFont(id: "gillSans", name: "Gill Sans", kind: .family("Gill Sans"), isMonospaced: false),
		ChatFont(id: "futura", name: "Futura", kind: .family("Futura"), isMonospaced: false),
		ChatFont(id: "optima", name: "Optima", kind: .family("Optima"), isMonospaced: false),
		ChatFont(id: "charter", name: "Charter", kind: .family("Charter"), isMonospaced: false),
		ChatFont(id: "palatino", name: "Palatino", kind: .family("Palatino"), isMonospaced: false),
		ChatFont(id: "baskerville", name: "Baskerville", kind: .family("Baskerville"), isMonospaced: false),
		ChatFont(id: "hoeflerText", name: "Hoefler Text", kind: .family("Hoefler Text"), isMonospaced: false),
		ChatFont(id: "iowanOldStyle", name: "Iowan Old Style", kind: .family("Iowan Old Style"), isMonospaced: false),
		ChatFont(id: "americanTypewriter", name: "American Typewriter", kind: .family("American Typewriter"), isMonospaced: false),
	])

	static let monospaced: [ChatFont] = available([
		systemMono,
		ChatFont(id: "sfMono", name: "SF Mono", kind: .family("SF Mono"), isMonospaced: true),
		ChatFont(id: "menlo", name: "Menlo", kind: .family("Menlo"), isMonospaced: true),
		ChatFont(id: "monaco", name: "Monaco", kind: .family("Monaco"), isMonospaced: true),
		ChatFont(id: "courier", name: "Courier New", kind: .family("Courier New"), isMonospaced: true),
		ChatFont(id: "andaleMono", name: "Andale Mono", kind: .family("Andale Mono"), isMonospaced: true),
	])

	private static func available(_ candidates: [ChatFont]) -> [ChatFont] {
		let installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
		return candidates.filter {
			switch $0.kind {
			case .system: true
			case .family(let name): installed.contains(name)
			}
		}
	}

	static func resolve(_ id: String, in catalog: [ChatFont], fallback: ChatFont) -> ChatFont {
		catalog.first { $0.id == id } ?? fallback
	}

	// MARK: - Resolution

	func font(size: Double, weight: Font.Weight = .regular) -> Font {
		switch kind {
		case .system(let design):
			.system(size: size, weight: weight, design: design)
		case .family(let name):
			.custom(name, fixedSize: size).weight(weight)
		}
	}

	var markdownFamily: FontFamily {
		switch kind {
		case .system(let design): FontFamily(.system(design))
		case .family(let name): FontFamily(.custom(name))
		}
	}
}
