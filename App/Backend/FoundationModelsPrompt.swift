//
//  FoundationModelsPrompt.swift
//  ChatCore
//

import Foundation
import FoundationModels

extension Array where Element == ChatTurn {

	var foundationModelsPrompt: Prompt {
		let attachments = allImages.compactMap { image -> Attachment<ImageAttachmentContent>? in
			guard let cgImage = image.decoded() else { return nil }
			return Attachment(cgImage).label(image.label)
		}
		let text = last?.content ?? ""

		return Prompt {
			attachments
			if !text.isEmpty {
				text
			}
		}
	}
}
