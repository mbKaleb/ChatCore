//
//  TranscriptRenderer.swift
//  ChatCore
//
//  What a transcript renderer is given.
//
//  There is one renderer now — `SelectableMessageList2`, TextKit 2 bubbles in
//  the SwiftUI List — and `ChatView` builds it directly. The context/protocol
//  pair remains so a renderer is still handed one value and is otherwise on
//  its own, and so the archived renderers (Archive/TextRendering) can come
//  back by conforming again. The enum that chose between seven of them, and
//  the Settings pane that surfaced the choice, died with the experiment that
//  needed them.
//

import SwiftUI

/// Everything a transcript renderer needs to draw a conversation.
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
