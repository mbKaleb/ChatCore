//
//  BasicScrollView.swift
//  ChatCore
//
//  The scroll scheme for the `simple` transcript renderer: a ScrollView the
//  system runs end to end. No spacer math, no scroll geometry observation,
//  no restore — everything the other renderers do by hand is left to
//  `defaultScrollAnchor`.
//

import SwiftUI

struct BasicScrollView<Content: View>: View {

	var bottomInset: CGFloat
	var scrollToBottomToken: Int
	@ViewBuilder var content: Content

	@State private var position = ScrollPosition()

	var body: some View {
		ScrollView {
			content
		}
		// Full roles on purpose: the system opens at the bottom AND keeps the
		// bottom pinned while content grows. No manual follower to race it.
		.defaultScrollAnchor(.bottom)
		.scrollPosition($position)
		// Room for the compose bar floating over the transcript.
		.safeAreaPadding(.bottom, bottomInset)
		.textSelection(.enabled)
		.onChange(of: scrollToBottomToken) {
			withAnimation(.linear(duration: 0.1)) {
				position.scrollTo(edge: .bottom)
			}
		}
	}
}
