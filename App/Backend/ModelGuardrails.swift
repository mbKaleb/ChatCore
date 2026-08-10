//
//  ModelGuardrails.swift
//  ChatCore
//

import Foundation
import FoundationModels
import os

// MARK: - Context Budget

/// How much of a model's context window one send may spend.
///
/// The on-device window is small enough that ordinary conversations outgrow
/// it, and outgrowing it is not discovered cheaply: the overflow error only
/// comes back after a full prompt-processing pass — the most memory-hungry
/// work a turn does. The budget lets a send be cut to fit before the model
/// ever sees it, so that pass runs once, against a prompt that fits.
nonisolated struct ContextBudget {

	/// The whole window, in tokens.
	let contextSize: Int

	/// Tokens held back for the answer. Generation shares the window with the
	/// prompt; an answer with no room reserved can run the window out
	/// mid-sentence, which is the one overflow no retry can hide.
	let responseReserve: Int

	init(contextSize: Int, requestedResponseTokens: Int?) {
		self.contextSize = contextSize
		// A quarter of the window, at most 1k: enough for a real answer on
		// the 4k device window. A user-set ceiling is honored, but never
		// allowed to claim more than half the window — past that, budgeting
		// would starve the prompt to feed a reply the window can't hold
		// alongside it anyway.
		let fallback = min(1_024, max(256, contextSize / 4))
		responseReserve = min(requestedResponseTokens ?? fallback, contextSize / 2)
	}

	/// The window minus the estimate's safety margin: what budgeting treats
	/// as actually spendable, prompt and answer together. The margin absorbs
	/// the character estimate undercounting dense text — erring small costs
	/// an old turn, erring large costs an overflow.
	var usableTokens: Int {
		Int(Double(contextSize) * Self.margin)
	}

	/// What the prompt side — instructions, history, current message — may
	/// spend.
	var promptAllowance: Int {
		max(0, usableTokens - responseReserve)
	}

	private static let margin = 0.85
}

// MARK: - Token Estimation

/// The character arithmetic every estimate here shares.
///
/// No tokenizer is exposed, so four characters to the token is the working
/// rule. Real tokenizers land either side of it; every consumer pairs the
/// estimate with a margin (the budget) or an overshoot (shedding) so a miss
/// costs an old turn, not an overflow.
nonisolated enum TokenEstimate {

	static let charactersPerToken = 4.0

	/// What one image is worth in characters. Rough on purpose — it only has
	/// to be the right order of magnitude to stop a transcript full of
	/// screenshots from estimating as small.
	static let nonTextCharacters = 4 * 1024

	static func tokens(forCharacters characters: Int) -> Int {
		Int((Double(characters) / charactersPerToken).rounded(.up))
	}
}

nonisolated extension Transcript {

	/// Roughly what this transcript spends of a context window.
	var estimatedTokens: Int {
		TokenEstimate.tokens(forCharacters: reduce(0) { $0 + $1.estimatedCharacters })
	}

	/// Drop the oldest turns until roughly `tokens` worth of them are gone.
	///
	/// Instructions stay. They are the app's own rules, and dropping them to
	/// save a few tokens changes what the model *is* rather than what it
	/// remembers. Everything else goes oldest first and in whole entries —
	/// half a response is worse context than none of it.
	func shedding(tokens: Int) -> Transcript {
		guard tokens > 0 else { return self }

		var entries = Array(self)
		var preamble: [Transcript.Entry] = []
		if let first = entries.first, case .instructions = first {
			preamble.append(entries.removeFirst())
		}

		// No per-entry token count is exposed, so this estimates from characters
		// and overshoots on purpose: landing under the limit matters more than
		// keeping one extra turn.
		var budget = Double(tokens) * TokenEstimate.charactersPerToken * Self.overshoot
		while budget > 0, !entries.isEmpty {
			budget -= Double(entries.removeFirst().estimatedCharacters)
		}

		// A response — or the reasoning behind one — whose prompt just went is
		// a reply to nothing. Drop those too, rather than leave the model
		// reading its own words as the opener.
		orphans: while let first = entries.first {
			switch first {
			case .response, .reasoning: entries.removeFirst()
			default: break orphans
			}
		}

		return Transcript(entries: preamble + entries)
	}

	private static let overshoot = 1.25
}

nonisolated extension Transcript.Entry {

	/// Text length, with a flat charge for anything that isn't text.
	var estimatedCharacters: Int {
		let segments: [Transcript.Segment]
		switch self {
		case .instructions(let entry): segments = entry.segments
		case .prompt(let entry):       segments = entry.segments
		case .response(let entry):     segments = entry.segments
		case .reasoning(let entry):    segments = entry.segments
		case .toolCalls, .toolOutput:  return TokenEstimate.nonTextCharacters
		@unknown default:              return TokenEstimate.nonTextCharacters
		}
		return segments.reduce(0) { total, segment in
			if case .text(let text) = segment { return total + text.content.count }
			return total + TokenEstimate.nonTextCharacters
		}
	}
}

nonisolated extension ChatTurn {

	/// Roughly what this turn spends arriving as a prompt, image freight
	/// included.
	var estimatedPromptTokens: Int {
		TokenEstimate.tokens(
			forCharacters: content.count + images.count * TokenEstimate.nonTextCharacters
		)
	}
}

// MARK: - Memory Pressure

/// Watches the system's memory-pressure signal and sheds what the app can
/// spare.
///
/// Running the on-device model is the biggest allocation this app causes, and
/// the system's warning usually arrives because of it. What the app can hand
/// back voluntarily are the cached transcripts — image attachments included —
/// whose loss costs one rebuild from turns, and the eager session prewarms,
/// whose loss costs latency. Both beat the alternative, which is the system
/// reclaiming memory the hard way.
nonisolated final class MemoryPressureMonitor: Sendable {

	static let shared = MemoryPressureMonitor()

	/// True from the moment a warning arrives until the system reports the
	/// pressure back to normal. Best-effort by design: a stale read wastes at
	/// most one prewarm.
	var isConstrained: Bool {
		constrained.withLock { $0 }
	}

	private let constrained = OSAllocatedUnfairLock(initialState: false)

	/// Kept alive for the life of the process; an unreferenced source is
	/// cancelled at deinit.
	private let source: DispatchSourceMemoryPressure

	private init() {
		let source = DispatchSource.makeMemoryPressureSource(
			eventMask: [.normal, .warning, .critical],
			queue: .global(qos: .utility)
		)
		self.source = source

		let constrained = constrained
		source.setEventHandler { [weak source] in
			guard let source else { return }
			let event = source.data
			// Events coalesce: a warning and the recovery to normal can land
			// as one bitmask, with nothing further coming to break the tie.
			// Believe the recovery — a flag latched constrained forever costs
			// every future prewarm, while one optimistic prewarm under
			// pressure merely spends what the app always used to.
			let pressed = !event.isDisjoint(with: [.warning, .critical])
			let recovered = event.contains(.normal)
			constrained.withLock { $0 = pressed && !recovered }
			if pressed {
				Task { await TranscriptStore.shared.flush() }
			}
		}
		source.activate()
	}
}
