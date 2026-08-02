//
//  SelectableMessageList.swift
//  ChatCore
//
//  The `selectable` transcript renderer.
//
//  Deliberately thin: it is `ListMessageView` with the assistant text container
//  swapped for `SelectableMarkdownView`. Sharing the scroll, sticking and
//  restore logic is what makes the comparison mean something — anything that
//  differs between this and the SwiftUI list is the text renderer, not the
//  scaffolding around it.
//

import SwiftUI

struct SelectableMessageList: TranscriptRendering {

	private let context: TranscriptContext

	init(_ context: TranscriptContext) {
		self.context = context
	}

	var body: some View {
		ListMessageView(context, assistantText: .selectable)
	}
}
