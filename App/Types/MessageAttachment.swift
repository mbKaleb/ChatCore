//
//  MessageAttachment.swift
//  ChatCore
//

import Foundation
import UniformTypeIdentifiers

/// `nonisolated`: attachments are built wherever their bytes are read — file
/// imports decode off the main thread — and carry only value storage.
nonisolated struct MessageAttachment: Codable, Identifiable, Hashable {
	var id: UUID = UUID()
	var title: String = "Pasted Text"
	var text: String = ""

	var imageData: Data?
	var imageType: String?
	var pixelWidth: Int?
	var pixelHeight: Int?

	var isImage: Bool { imageData != nil }

	init(title: String = "Pasted Text", text: String) {
		self.title = title
		self.text = text
	}

	init?(imageData data: Data, title: String) {
		guard let normalized = AttachmentImage.normalize(data) else { return nil }
		self.title = title
		self.text = ""
		self.imageData = normalized.data
		self.imageType = normalized.type.identifier
		self.pixelWidth = normalized.pixelWidth
		self.pixelHeight = normalized.pixelHeight
	}

	var subtitle: String {
		if let pixelWidth, let pixelHeight {
			return "\(pixelWidth) × \(pixelHeight)"
		}
		let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
		return lineCount > 1 ? "\(lineCount) lines" : "\(text.count) characters"
	}

	var preview: String {
		if isImage { return title }
		let head = text.prefix(400)
		return head.count < text.count ? head + "…" : String(head)
	}

	static func == (lhs: MessageAttachment, rhs: MessageAttachment) -> Bool {
		lhs.id == rhs.id
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
}

extension Array where Element == MessageAttachment {
	func composedPrompt(with typed: String) -> String {
		(map(\.text) + [typed])
			.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
			.joined(separator: "\n\n")
	}

	var images: [MessageAttachment] { filter(\.isImage) }
}
