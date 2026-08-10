//
//  DebugSeed.swift
//  ChatCore
//

#if DEBUG

import Foundation
import SwiftData

enum DebugSeed {

	static var isRequested: Bool {
		ProcessInfo.processInfo.arguments.contains("-seedLargeChat")
	}

	@MainActor
	static func populate(_ context: ModelContext, turns: Int = 250) {
		var config = Chat.default
		config.modelID = GenerativeChatModel.onDevice.id
		let convo = Conversation(config: config)
		convo.title = "Seeded (\(turns * 2) messages)"

		let epoch = Date(timeIntervalSince1970: 1_700_000_000)
		var stamp = epoch

		for i in 0 ..< turns {
			stamp += 1
			let user = Message(role: "user", text: prompt(i))
			user.timestamp = stamp
			convo.messages.append(user)

			stamp += 1
			let assistant = Message(role: "assistant", text: reply(i))
			assistant.timestamp = stamp
			convo.messages.append(assistant)
		}

		context.insert(convo)
		try? context.save()
		print("[LM] seeded \(convo.messages.count) messages in \"\(convo.title)\"")
	}

	// MARK: - Content

	private static func prompt(_ i: Int) -> String {
		switch i % 5 {
		case 0: return "How does the row height cache work in case \(i)?"
		case 1: return "Show me the code for that."
		case 2:
			return """
			I have a longer question this time. When the sidebar collapses, the \
			detail pane widens, and every cached measurement keyed on the old \
			width stops matching. What happens to the rows that were already \
			measured, and does the table re-query them? Case \(i).
			"""
		case 3: return "Give me the numbers as a table."
		default: return "And the equation for it?"
		}
	}

	private static func reply(_ i: Int) -> String {
		switch i % 5 {
		case 0:
			return """
			The cache is keyed on `(id, width, text, mode)`, so a change to any \
			component invalidates the entry. This is reply \(i), and it is a \
			plain-prose paragraph of the sort that makes up most of a transcript.

			A second paragraph, because block spacing is one of the things the \
			character-count estimate does not model at all — it charges a blank \
			separator line a full line height against a real paragraph margin.
			"""
		case 1:
			return """
			Here is the relevant part:

			```swift
			private func height(for row: Int) -> CGFloat {
			    let m = messages[row]
			    let w = columnWidth
			    if let e = heightCache[m.id], e.width == w {
			        return e.height
			    }
			    return estimatedHeight(m, width: w)
			}
			```

			Note the exact float comparison on `width` — reply \(i).
			"""
		case 2:
			return """
			## Heading for reply \(i)

			A few points:

			- The table caches row heights and does not re-query on a column resize.
			- `noteHeightOfRows(withIndexesChanged:)` is the only invalidation hook.
			- A live `heightOfRow` violates the documented stability contract.

			> And a blockquote, which the estimate also does not model.

			Closing prose so the block is not the last thing in the message.
			"""
		case 3:
			return """
			| Case | Estimated | Measured | Error |
			|------|-----------|----------|-------|
			| \(i) | 120 | 162 | +42 |
			| \(i + 1) | 240 | 286 | +46 |
			| \(i + 2) | 80 | 108 | +28 |

			Table rows are charged as plain text lines today, which is why the \
			error is large and one-directional here.
			"""
		default:
			return """
			The limit works out as

			$$\\lim_{x \\to 0} \\frac{\\sin x}{x} = 1$$

			which is one short source line and a much taller rendered block — \
			reply \(i). The estimate charges a flat 60pt for it.
			"""
		}
	}
}

#endif
