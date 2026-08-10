//
//  TranscriptRenderer.swift
//  ChatCore
//
//  Which of the transcript renderers draws the chat.
//
//  There is more than one way to put a conversation on screen and no single
//  winner yet: the compiled path scrolls best but doesn't select text, the
//  virtualized one keeps every SwiftUI affordance but pays to measure, and the
//  plain list is the reference implementation both are judged against. So the
//  choice stays a value — `ChatView` takes one and asks it for a view, rather
//  than knowing which renderers exist or what each one is built out of.
//
//  Adding a fourth is two edits: conform it to `TranscriptRendering`, and add a
//  case here.
//

import SwiftUI

// MARK: - What a renderer is given

/// Everything a transcript renderer needs to draw a conversation.
///
/// One shape for every renderer, including the parts a particular one has no
/// use for — `conversationID` only means something to a renderer that caches
/// across chats. The alternative is a per-renderer argument list, which puts
/// the knowledge of what each one takes back into the caller this exists to
/// keep ignorant of them.
struct TranscriptContext {

	/// Names the transcript in caches that outlive the view.
	var conversationID: UUID

	/// Oldest first. The renderer treats this as the whole truth about the
	/// conversation; live streaming text is picked up from `ModelManager`.
	var messages: [Message]

	/// Where the transcript was left, in points above the bottom. Read on the
	/// way in to restore the position, written on the way out.
	var scrollOffsetFromBottom: Binding<Double>

	/// Bumped when something outside the list — sending a message — wants the
	/// transcript pinned to the bottom whether or not it was already there.
	var scrollToBottomToken: Int

	/// Room to leave under the last message for the compose bar floating over it.
	var bottomInset: CGFloat
}

/// A view that can draw a transcript.
///
/// The initializer is the whole contract: a renderer is handed the context and
/// is otherwise on its own — its own scrolling, its own layout, its own idea of
/// how much of the transcript to keep alive at once.
protocol TranscriptRendering: View {
	init(_ context: TranscriptContext)
}

// MARK: - The choice

/// How the transcript is drawn.
enum TranscriptRenderer: String, CaseIterable, Identifiable {

	/// Every message compiled to CoreText lines once, painted from memory.
	case compiled

	/// SwiftUI bubbles hosted in an `NSTableView`, measured as rows scroll in.
	case virtualized

	/// A plain SwiftUI `List`, one live bubble per row.
	case list

	/// The SwiftUI list again, but each assistant message is one TextKit 2 text
	/// container instead of a tree of `Text` views.
	case selectable

	/// The selectable renderer with a math path: equations are typeset once and
	/// painted by the layout fragment rather than hosted in a SwiftUI view.
	case selectable2

	static let `default` = TranscriptRenderer.selectable2

	var id: String { rawValue }

	/// The stored preference, or the default when it names a renderer that no
	/// longer exists.
	init(storedID: String) {
		self = TranscriptRenderer(rawValue: storedID) ?? .default
	}

	var displayName: String {
		switch self {
		case .compiled:    "Compiled"
		case .virtualized: "Virtualized"
		case .list:        "SwiftUI list"
		case .selectable:  "Selectable"
		case .selectable2: "Selectable 2"
		}
	}

	/// One paragraph in Settings ▸ Rendering ▸ Transcript, written as a
	/// trade-off rather than a description — the whole reason to have the switch
	/// is that none of these is strictly better.
	var summary: String {
		switch self {
		case .compiled:
			"Every message is laid out once with CoreText and painted straight "
				+ "from memory, so scrolling never measures anything. Text selection, "
				+ "copy buttons and image attachments aren't implemented yet — pick "
				+ "another renderer to get them back."
		case .virtualized:
			"SwiftUI bubbles hosted in a table, measured as their rows scroll into "
				+ "view. Slower to scroll than the compiled path, but it keeps text "
				+ "selection, copy buttons and image attachments."
		case .list:
			"A plain SwiftUI List. The simplest of the three and the reference for "
				+ "how a message is meant to look, but every bubble stays a live view, "
				+ "so a long transcript costs the most to keep on screen."
		case .selectable:
			"The SwiftUI List, with each assistant message drawn as one TextKit 2 "
				+ "text container. Selection flows across the whole message — "
				+ "headings, lists, quotes and code — and copying gives back markdown "
				+ "rather than rendered text. Tables fall back to their source, code "
				+ "blocks wrap instead of scrolling, and selection still stops at the "
				+ "message boundary."
		case .selectable2:
			"Selectable, plus math. Equations are typeset once when the message is "
				+ "built and painted straight from cache as rows scroll, so nothing "
				+ "measures or hosts a view on the scroll path. Inline $…$ sits on "
				+ "the text baseline; everything else matches Selectable."
		}
	}

	/// The renderer as a view.
	///
	/// Each case names a distinct branch, so switching renderers tears the old
	/// one down and builds the new one — none of them can adopt another's scroll
	/// state, and a view that changed type underneath SwiftUI would try.
	@ViewBuilder
	func transcript(_ context: TranscriptContext) -> some View {
		switch self {
		case .compiled:    CompiledMessageList(context)
		case .virtualized: VirtualizedMessageList(context)
		case .list:        ListMessageView(context)
		case .selectable:  SelectableMessageList(context)
		case .selectable2: SelectableMessageList2(context)
		}
	}
}
