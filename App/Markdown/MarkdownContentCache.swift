//
//  MarkdownContentCache.swift
//  ChatCore
//

import Foundation
import MarkdownUI

@MainActor
enum MarkdownContentCache {
	private static var storage: [UUID: (text: String, content: MarkdownContent)] = [:]

	static func content(
		for message: Message,
		overrideText: String? = nil,
		rendersMath: Bool = true
	) -> MarkdownContent {
		let raw = overrideText ?? message.text
		let text = SoftBreakMarkdown.preserveLineBreaks(rendersMath ? MathMarkdown.preprocess(raw) : raw)
		if let cached = storage[message.id], cached.text == text {
			return cached.content
		}
		let parsed = MarkdownContent(text)
		storage[message.id] = (text, parsed)
		return parsed
	}
}
