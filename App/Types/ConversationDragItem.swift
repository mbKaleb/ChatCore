//
//  ConversationDragItem.swift
//  ChatCore
//

import Foundation
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
	/// Deliberately not declared in the Info.plist: the identifier resolves as a
	/// dynamic type, which is all a drag that never leaves this app needs — and
	/// it keeps a sidebar drag from being mistaken for the plain text and file
	/// drops the transcript already accepts as attachments.
	nonisolated static let chatCoreConversation = UTType(exportedAs: "com.chatcore.conversation")
}

/// A conversation's identity, in a form the drag system can carry.
///
/// The id and nothing else: the drop side re-fetches from the store, so a title
/// or message snapshot taken at drag time could only be stale by the time it
/// lands.
struct ConversationDragItem: Codable, Transferable {
	var id: UUID

	static var transferRepresentation: some TransferRepresentation {
		CodableRepresentation(contentType: .chatCoreConversation)
	}
}
