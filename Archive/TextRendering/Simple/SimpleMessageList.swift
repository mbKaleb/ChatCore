//
//  SimpleMessageList.swift
//  ChatCore
//
//  The `simple` transcript renderer: `BasicScrollView` around a plain VStack
//  of `SimpleMessageRow`s. It deliberately ignores `conversationID` (nothing
//  is cached) and `scrollOffsetFromBottom` (no restore — the transcript
//  always opens at the bottom).
//

import SwiftUI

struct SimpleMessageList: TranscriptRendering {

	private let messages: [Message]
	private let scrollToBottomToken: Int
	private let bottomInset: CGFloat

	init(_ context: TranscriptContext) {
		messages = context.messages
		scrollToBottomToken = context.scrollToBottomToken
		bottomInset = context.bottomInset
	}

	var body: some View {
		BasicScrollView(bottomInset: bottomInset, scrollToBottomToken: scrollToBottomToken) {
			VStack(spacing: 12) {
				ForEach(messages) { SimpleMessageRow(message: $0) }
			}
			.padding(.horizontal, 16)
		}
	}
}
