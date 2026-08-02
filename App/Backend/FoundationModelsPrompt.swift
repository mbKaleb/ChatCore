//
//  FoundationModelsPrompt.swift
//  ChatCore
//

import Foundation
import FoundationModels

extension Array where Element == ChatTurn {

	/// The turns as transcript entries, each in the slot the framework means it
	/// for.
	///
	/// The distinction that earns this its own path is `instructions` versus
	/// `prompt`. Instructions are the app speaking, and they carry standing
	/// that a prompt does not — which is exactly why prior *user* turns must
	/// not land there. Replaying a conversation as instructions promotes
	/// whatever the user typed three turns ago to the same authority as the
	/// app's own rules, and hands the model no way to tell the two apart.
	///
	/// Only genuine system turns fold into instructions. Everything else
	/// alternates prompt and response, which is the shape the model was trained
	/// to read and the shape it can recognize again on the next send.
	func transcript(instructions: String? = nil) -> Transcript {
		var entries: [Transcript.Entry] = []

		let preamble = ([instructions].compactMap { $0 }
			+ filter { $0.role == .system }.map(\.content))
			.filter { !$0.isEmpty }
			.joined(separator: "\n\n")

		if !preamble.isEmpty {
			entries.append(.instructions(
				Transcript.Instructions(
					segments: [.text(Transcript.TextSegment(content: preamble))],
					toolDefinitions: []
				)
			))
		}

		for turn in self {
			let segments = turn.transcriptSegments
			guard !segments.isEmpty else { continue }
			switch turn.role {
			case .user:
				entries.append(.prompt(Transcript.Prompt(segments: segments)))
			case .assistant:
				entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
			case .system:
				break	// already folded into the instructions entry above
			}
		}

		return Transcript(entries: entries)
	}

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

// MARK: - Turn → Segments

extension ChatTurn {

	/// One turn's content as transcript segments.
	///
	/// Images lead, matching `foundationModelsPrompt` — an image the text
	/// refers to should already be in view by the time the sentence about it
	/// arrives.
	var transcriptSegments: [Transcript.Segment] {
		var segments: [Transcript.Segment] = images.compactMap { image in
			guard let cgImage = image.decoded() else { return nil }
			return .attachment(
				Transcript.AttachmentSegment(
					content: .image(Transcript.ImageAttachment(cgImage)),
					label: image.label
				)
			)
		}
		if !content.isEmpty {
			segments.append(.text(Transcript.TextSegment(content: content)))
		}
		return segments
	}
}
