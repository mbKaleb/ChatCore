//
//  Message.swift
//  ChatCore
//
//  Created by Kaleb Franken on 6/21/26.
//
import SwiftData
import Foundation

@Model
class Message {
	var id: UUID = UUID()
	var role: String
	var text: String
	var timestamp: Date = Date()

	var attachments: [MessageAttachment] = []

	init(role: String, text: String, attachments: [MessageAttachment] = []) {
		self.role = role
		self.text = text
		self.attachments = attachments
	}
}
