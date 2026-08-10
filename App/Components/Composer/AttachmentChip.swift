//
//  AttachmentChip.swift
//  ChatCore
//

import SwiftUI

struct AttachmentChip: View {

	@Environment(ThemeManager.self) private var themes
	let attachment: MessageAttachment
	var onRemove: (() -> Void)?

	private static let contentHeight: CGFloat = 32

	var body: some View {
		Group {
			if attachment.isImage { imageChip } else { textChip }
		}
		.padding(8)
		.background(themes.theme.chipBackground)
		.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay(alignment: .topTrailing) {
			if let onRemove {
				Button(action: onRemove) {
					Image(systemName: "xmark.circle.fill")
						.symbolRenderingMode(.hierarchical)
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.offset(x: 5, y: -5)
			}
		}
		.help(attachment.preview)
	}

	private var textChip: some View {
		VStack(spacing: 2) {
			Text(attachment.title)
				.font(.caption)
				.fontWeight(.medium)
				.lineLimit(1)
			Text(attachment.subtitle)
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.multilineTextAlignment(.center)
		.frame(width: 120, height: Self.contentHeight)
	}

	private var imageChip: some View {
		HStack(spacing: 8) {
			thumbnail
			VStack(alignment: .leading, spacing: 2) {
				Text(attachment.title)
					.font(.caption)
					.fontWeight(.medium)
					.lineLimit(1)
					.truncationMode(.middle)
				Text(attachment.subtitle)
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
			Spacer(minLength: 0)
		}
		.frame(width: 150, height: Self.contentHeight)
	}

	@ViewBuilder
	private var thumbnail: some View {
		if let image = AttachmentThumbnailCache.thumbnail(for: attachment) {
			Image(nsImage: image)
				.resizable()
				.aspectRatio(contentMode: .fill)
				.frame(width: Self.contentHeight, height: Self.contentHeight)
				.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		} else {
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.fill(.quaternary)
				.frame(width: Self.contentHeight, height: Self.contentHeight)
				.overlay {
					Image(systemName: "photo")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
		}
	}
}
