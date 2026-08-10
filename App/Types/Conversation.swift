//
//  Conversation.swift
//  ChatCore
//
//  Created by Kaleb Franken on 6/21/26.
//
import SwiftData
import Foundation

@Model
class Conversation {

	/// The placeholder a chat is born with, replaced by the generated title
	/// after the first exchange. Named because it doubles as a sentinel: the
	/// title generator only runs on chats still carrying it.
	static let untitledTitle = "New Chat"

	var id: UUID = UUID()
	var createdAt: Date = Date()
	var title: String = Conversation.untitledTitle

	var modelID: String = GenerativeChatModel.onDevice.id

	private(set) var temperature: Double = 1.0
	private(set) var maxResponseTokens: Int? = nil

	@Relationship(deleteRule: .cascade) var messages: [Message] = []

	var scrollOffsetFromBottom: Double = 0

	var config: Chat {
		Chat(
			modelID: modelID,
			temperature: temperature,
			maxResponseTokens: maxResponseTokens
		)
	}

	var options: ChatOptions {
		ChatOptions(
			temperature: temperature,
			maxResponseTokens: maxResponseTokens,
			sessionKey: id
		)
	}

	init(config: Chat = .default) {
		self.modelID = config.modelID ?? GenerativeChatModel.onDevice.id
		self.temperature = config.temperature
		self.maxResponseTokens = config.maxResponseTokens
	}
}
