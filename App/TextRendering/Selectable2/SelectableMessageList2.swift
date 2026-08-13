//
//  SelectableMessageList2.swift
//  ChatCore
//
//  The `selectable2` transcript renderer: TextKit 2 message bubbles hosted in
//  the SwiftUI List.
//
//  The List host is deliberate, and it is the second time we learned why: an
//  NSTableView-backed List proposes one fixed width to every row and reuses
//  rows as they scroll in. A ScrollView + VStack instead probes flexible rows
//  at several candidate widths per layout pass — and for a row whose sizing
//  is a full TextKit document layout, that probing is the lag, and its
//  intrinsic-size fallbacks are the phantom gaps. SwiftUI-native rows can
//  afford those probes; NSTextView rows cannot. Keep the TextKit bubbles in
//  the List, or move the whole transcript into one text view — nothing in
//  between has survived contact with a real chat.
//
//  Scroll position restore comes with the List host; the bottom spacer is
//  compose-bar clearance only.
//

import SwiftUI

struct SelectableMessageList2: TranscriptRendering {

	private let context: TranscriptContext

	init(_ context: TranscriptContext) {
		self.context = context
	}

	var body: some View {
		ListMessageView(context, assistantText: .selectable2)
	}
}
