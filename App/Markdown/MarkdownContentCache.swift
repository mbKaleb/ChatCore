//
//  MarkdownContentCache.swift
//  ChatCore
//

import Foundation
import MarkdownUI

@MainActor
enum MarkdownContentCache {

	/// Enough to hold several conversations' worth of history without letting a
	/// long session accumulate every message it has ever rendered.
	private static let capacity = 512

	private struct Entry {
		var raw: String
		var rendersMath: Bool
		var content: MarkdownContent
	}

	private static var storage: [UUID: Entry] = [:]

	/// Insertion order, for eviction. Only ids present in `storage` appear here,
	/// and only once each.
	private static var order: [UUID] = []

	static func content(
		for message: Message,
		overrideText: String? = nil,
		rendersMath: Bool = true
	) -> MarkdownContent {
		let raw = overrideText ?? message.text

		// Matched against the *source* text, ahead of the two whole-string
		// rewrites below. Keying on the rewritten string meant running both of
		// them to find out the answer was already cached — once per row, every
		// time a row scrolled into view.
		if let cached = storage[message.id], cached.rendersMath == rendersMath, cached.raw == raw {
			return cached.content
		}

		let text = SoftBreakMarkdown.preserveLineBreaks(rendersMath ? MathMarkdown.preprocess(raw) : raw)
		let parsed = MarkdownContent(text)
		let entry = Entry(raw: raw, rendersMath: rendersMath, content: parsed)
		if storage.updateValue(entry, forKey: message.id) == nil {
			order.append(message.id)
			evictOverflow()
		}
		return parsed
	}

	private static func evictOverflow() {
		let overflow = order.count - capacity
		guard overflow > 0 else { return }
		for id in order.prefix(overflow) { storage.removeValue(forKey: id) }
		order.removeFirst(overflow)
	}
}
