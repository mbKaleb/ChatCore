//
//  TranscriptStore.swift
//  ChatCore
//

import Foundation
import FoundationModels

/// The transcript each conversation's last session ended with.
///
/// The seam hands a backend the entire conversation on every send, so without
/// somewhere to keep the previous session's transcript there is nothing to
/// append to — history has to be rebuilt from turns each time, and the model is
/// handed a prefix it has no way to recognize as one it just read. This is that
/// somewhere.
///
/// Correctness never depends on a hit. A stored transcript is used only while
/// it still describes exactly the turns preceding this send; an edited message,
/// a deleted one, a relaunch, a model switched mid-chat all miss and rebuild
/// from the turns, which are the source of truth in either case. The cache can
/// only cost time, never accuracy.
///
/// Shared rather than owned by the backend because `AppleBackend` is a struct
/// that `ModelVendor.backend()` builds fresh on every vendor toggle — an
/// instance-held cache would be thrown away each time Settings is touched.
actor TranscriptStore {

	static let shared = TranscriptStore()

	/// One entry per conversation *per route*.
	///
	/// Route belongs in the key because a transcript can carry entries one
	/// route understands and the other rejects — reasoning entries from Private
	/// Cloud mean nothing to the on-device model, and feeding them across earns
	/// `unsupportedTranscriptContent`. Switching model mid-chat is supposed to
	/// work, so it rebuilds rather than risking that.
	struct Key: Hashable, Sendable {
		var conversation: UUID
		var route: String
	}

	private struct Entry {
		var transcript: Transcript
		var fingerprint: Int
	}

	private var entries: [Key: Entry] = [:]

	/// Least-recently-used first.
	private var order: [Key] = []

	/// Transcripts are only text and image references, but a long conversation
	/// is not small and nothing else would ever evict one — the app can open
	/// chats all day.
	private static let capacity = 8

	// MARK: - Lookup

	/// The stored transcript for `history`, or nil if what's stored describes
	/// some other set of turns.
	func cached(for key: Key, history: [ChatTurn]) -> Transcript? {
		guard let entry = entries[key],
			  entry.fingerprint == Self.fingerprint(of: history)
		else { return nil }

		touch(key)
		return entry.transcript
	}

	func commit(_ transcript: Transcript, for key: Key, history: [ChatTurn]) {
		entries[key] = Entry(transcript: transcript, fingerprint: Self.fingerprint(of: history))
		touch(key)

		while order.count > Self.capacity, !order.isEmpty {
			entries.removeValue(forKey: order.removeFirst())
		}
	}

	/// Drop what a failed turn left behind.
	///
	/// A session that threw — cancelled mid-stream, context exceeded, guardrail
	/// — ends on a response nothing completed. Building the next send on that
	/// prefix would feed the model a truncated answer as though it had meant to
	/// stop there. Dropping it costs one rebuild from turns, which is what a
	/// cold cache does anyway.
	func invalidate(_ key: Key) {
		entries.removeValue(forKey: key)
		order.removeAll { $0 == key }
	}

	// MARK: - Internals

	private func touch(_ key: Key) {
		order.removeAll { $0 == key }
		order.append(key)
	}

	/// Identity of the turns a transcript stands for.
	///
	/// Content, not count. An appended turn and an edited one can leave the
	/// count looking the same, and serving a stale prefix is the one failure
	/// this cache could introduce that the user would actually see — the model
	/// answering a message they had already changed.
	private static func fingerprint(of history: [ChatTurn]) -> Int {
		var hasher = Hasher()
		hasher.combine(history.count)
		for turn in history {
			hasher.combine(turn.role.rawValue)
			hasher.combine(turn.content)
			hasher.combine(turn.images.count)
			for image in turn.images {
				hasher.combine(image.data.count)
				hasher.combine(image.title)
			}
		}
		return hasher.finalize()
	}
}
