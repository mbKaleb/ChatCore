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
	var id: UUID = UUID()
	var createdAt: Date = Date()
	var title: String = "New Chat"

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
			maxResponseTokens: maxResponseTokens
		)
	}

	init(config: Chat = .default) {
		self.modelID = config.modelID ?? GenerativeChatModel.onDevice.id
		self.temperature = config.temperature
		self.maxResponseTokens = config.maxResponseTokens
	}
}
