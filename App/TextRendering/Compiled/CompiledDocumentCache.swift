//
//  CompiledDocumentCache.swift
//  ChatCore
//

import AppKit

/// Compiled transcripts, kept alive across conversation switches.
///
/// `ChatView` puts `.id(conversation.id)` on the list, so changing chats destroys
/// the whole controller — its document, its lines and its typesetters with it.
/// Without somewhere to put them, coming back to a conversation costs a full
/// compile every time, which is the single most expensive thing the compiled
/// renderer still does.
///
/// This is a plain LRU box with no opinion about whether what it hands back is
/// still *correct*. That check belongs to the controller, which is the only thing
/// that knows how live streaming text folds into a message — see
/// `CompiledListViewController.restoreFromCache`.
///
/// Sizing is deliberate rather than generous: a 500-message transcript costs
/// roughly 55 MB of `CTLine`s and typesetters, so this trades tens of megabytes
/// for tens of milliseconds and shouldn't be raised without measuring both.
@MainActor
enum CompiledDocumentCache {

	/// Conversations kept. Three covers the flick between a couple of chats and a
	/// third one being referred to, which is the pattern worth optimising.
	private static let capacity = 3

	struct Entry {
		var document: CompiledDocument
		/// The text each message was compiled from, so the controller can tell
		/// whether the conversation moved while it was away.
		var compiledText: [UUID: String]
		/// What the document was compiled *against*. A style whose layout key has
		/// changed since invalidates every line in here.
		var layoutKey: CompileStyle.LayoutKey
		/// A mismatch here is recoverable — reflowing is far cheaper than
		/// recompiling — so it's recorded rather than treated as a miss.
		var width: CGFloat
	}

	private static var storage: [UUID: Entry] = [:]

	/// Least-recently-used first.
	private static var order: [UUID] = []

	static func entry(for id: UUID) -> Entry? {
		guard let hit = storage[id] else { return nil }
		promote(id)
		return hit
	}

	static func store(_ entry: Entry, for id: UUID) {
		if storage.updateValue(entry, forKey: id) == nil {
			order.append(id)
			evictOverflow()
		} else {
			promote(id)
		}
	}

	static func remove(_ id: UUID) {
		guard storage.removeValue(forKey: id) != nil else { return }
		order.removeAll { $0 == id }
	}

	static func removeAll() {
		storage.removeAll()
		order.removeAll()
	}

	private static func promote(_ id: UUID) {
		guard let index = order.firstIndex(of: id), index != order.count - 1 else { return }
		order.remove(at: index)
		order.append(id)
	}

	private static func evictOverflow() {
		let overflow = order.count - capacity
		guard overflow > 0 else { return }
		for id in order.prefix(overflow) { storage.removeValue(forKey: id) }
		order.removeFirst(overflow)
	}
}
