//
//  ThinkingWatcher.swift
//  ChatCore
//

import Foundation
import FoundationModels

/// Surfaces a session's reasoning while the answer is still forming.
///
/// The framework's own hooks can't do this job: `onReasoning` delivers its
/// entries in a batch at end of turn, and no response-stream snapshots arrive
/// at all while the model is still reasoning. The one thing that moves during
/// that silence is `session.transcript` — under `streamResponse` a partial
/// `.reasoning` entry appears there within milliseconds of the first thinking
/// delta and its segments grow in place. That behavior is observed on the
/// macOS 27 beta rather than documented, so everything here is best-effort:
/// if the transcript stops updating live, the watcher reports nothing and the
/// turn otherwise proceeds untouched.
nonisolated enum ThinkingWatcher {

	/// How often the transcript is re-read while a turn is in flight. Also the
	/// effective cap on how fast thinking updates reach the UI, so no separate
	/// throttle exists downstream.
	private static let pollInterval: Duration = .milliseconds(100)

	/// Start reporting the session's reasoning into a reply stream.
	///
	/// `baseline` is how many transcript entries existed before this turn —
	/// reasoning entries a restored transcript carried in from earlier turns
	/// are history, not something the model is doing now. The caller owns the
	/// returned task and must cancel it when the turn ends.
	///
	/// The poll runs on the main actor, and that placement is load-bearing.
	/// `LanguageModelSession` is `@unchecked Sendable` with a plain
	/// `get`/`_modify` on `transcript`, so nothing verifiable stops a read from
	/// tearing against the framework's in-flight append. The one concurrent
	/// read the framework demonstrably supports is a SwiftUI view observing
	/// `session.transcript` while a response streams — a main-thread read. On
	/// the main actor this poll is safe whether the framework serializes its
	/// writes there (reads interleave) or locks internally (reads are safe
	/// anywhere); off it, only the second design saves us, and a beta
	/// framework's internals are no place to keep an unverifiable bet.
	static func watch(
		_ session: LanguageModelSession,
		skipping baseline: Int = 0,
		into continuation: AsyncThrowingStream<ReplyEvent, Error>.Continuation
	) -> Task<Void, Never> {
		Task { @MainActor in
			#if compiler(>=6.4)
			guard #available(macOS 27.0, *) else { return }
			var lastReported = ""
			while !Task.isCancelled {
				let thinking = session.transcript.thinkingText(skipping: baseline)
				if !thinking.isEmpty, thinking != lastReported {
					lastReported = thinking
					continuation.yield(.thinking(thinking))
				}
				try? await Task.sleep(for: pollInterval)
			}
			#endif
		}
	}
}

#if compiler(>=6.4)
@available(macOS 27.0, *)
private nonisolated extension Transcript {

	/// The turn's reasoning so far: the text segments of every reasoning entry
	/// past `baseline`, in order, one paragraph break between entries. Redacted
	/// thoughts arrive as signature-only entries with no text segments and
	/// contribute nothing.
	func thinkingText(skipping baseline: Int) -> String {
		var blocks: [String] = []
		for entry in self.dropFirst(baseline) {
			guard case .reasoning(let reasoning) = entry else { continue }
			let text = reasoning.segments.compactMap { segment -> String? in
				guard case .text(let textSegment) = segment else { return nil }
				return textSegment.content
			}.joined()
			if !text.isEmpty { blocks.append(text) }
		}
		return blocks.joined(separator: "\n\n")
	}
}
#endif
