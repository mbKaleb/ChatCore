//
//  SidebarSearch.swift
//  ChatCore
//

import SwiftUI

// MARK: - Focus

enum SidebarFocus: Hashable {
	case search
	case list
}

// MARK: - Search Field

struct SidebarSearchField: View {

	@Binding var text: String
	@FocusState.Binding var focus: SidebarFocus?

	var body: some View {
		HStack(spacing: 6) {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(.secondary)
				.font(.system(size: 12, weight: .medium))

			TextField("Search", text: $text)
				.textFieldStyle(.plain)
				.focused($focus, equals: .search)
				.onExitCommand {
					if text.isEmpty { focus = nil } else { text = "" }
				}
				.onKeyPress(.downArrow) {
					focus = .list
					return .handled
				}
				.onSubmit { focus = .list }

			if !text.isEmpty {
				Button {
					text = ""
					focus = .search
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.secondary)
						.contentShape(Circle())
				}
				.buttonStyle(.plain)
				.help("Clear search")
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 6)
		.glassEffect(.regular, in: .rect(cornerRadius: 10))
		.padding(.horizontal, 10)
		.padding(.top, 2)
		.padding(.bottom, 8)
	}
}

// MARK: - Snippets

enum SidebarSearchSnippet {

	static let resultLimit = 50

	private static let leadingBudget = 24
	private static let trailingBudget = 96

	private static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

	static func excerpt(for conversation: Conversation, matching term: String) -> AttributedString? {
		let matches = conversation.messages.filter { $0.text.localizedStandardContains(term) }
		guard let earliest = matches.min(by: { $0.timestamp < $1.timestamp }) else { return nil }
		return excerpt(of: earliest.text, matching: term)
	}

	static func excerpt(of text: String, matching term: String) -> AttributedString? {
		let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
		guard let match = flat.range(of: term, options: matchOptions) else { return nil }

		let start = flat.index(match.lowerBound, offsetBy: -leadingBudget, limitedBy: flat.startIndex) ?? flat.startIndex
		let end = flat.index(match.upperBound, offsetBy: trailingBudget, limitedBy: flat.endIndex) ?? flat.endIndex

		var window = ""
		if start > flat.startIndex { window += "…" }
		window += flat[start..<end]
		if end < flat.endIndex { window += "…" }

		var snippet = AttributedString(window)
		if let highlight = snippet.range(of: term, options: matchOptions) {
			snippet[highlight].inlinePresentationIntent = .stronglyEmphasized
		}
		return snippet
	}
}
