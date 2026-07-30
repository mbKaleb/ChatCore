//
//  Chat.swift
//  ChatCore
//

import Foundation

nonisolated struct Chat: Codable, Hashable, Sendable {

	var modelID: GenerativeChatModel.ID?

	var temperature: Double = 1.0
	var maxResponseTokens: Int? = nil

	var isLocked: Bool = false

	var options: ChatOptions {
		ChatOptions(
			temperature: temperature,
			maxResponseTokens: maxResponseTokens
		)
	}

	static let `default` = Chat()

	private enum CodingKeys: String, CodingKey {
		case modelID, temperature, maxResponseTokens
	}
}
