//
//  AttachmentImage.swift
//  ChatCore
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum AttachmentImage {

	// MARK: - Formats

	static let readableTypes: [UTType] = [
		.png, .jpeg, .heic, .heif, .gif, .tiff, .webP, .bmp
	]

	static let wireTypes: Set<UTType> = [.png, .jpeg, .gif, .webP]

	static func isReadable(_ type: UTType?) -> Bool {
		guard let type else { return false }
		return readableTypes.contains { type.conforms(to: $0) } || type == .image
	}

	static func type(of url: URL) -> UTType? {
		try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
	}

	// MARK: - Limits

	static let maxLongEdge = 1568
	static let maxPixelCount = 1_150_000
	static let maxByteCount = 5 * 1024 * 1024

	// MARK: - Normalizing

	struct Normalized {
		var data: Data
		var type: UTType
		var pixelWidth: Int
		var pixelHeight: Int
	}

	static func normalize(_ data: Data) -> Normalized? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

		let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
		guard
			let width = properties?[kCGImagePropertyPixelWidth] as? Int,
			let height = properties?[kCGImagePropertyPixelHeight] as? Int,
			// The upper bound keeps `width * height` below, and anything derived
			// from it, safely inside Int — metadata is attacker-supplied.
			width > 0, height > 0, width <= 1 << 20, height <= 1 << 20
		else { return nil }

		let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
		let sourceType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }

		let fitsAsIs =
			orientation == 1
			&& max(width, height) <= maxLongEdge
			&& width * height <= maxPixelCount
			&& data.count <= maxByteCount

		if let sourceType, wireTypes.contains(sourceType), fitsAsIs {
			return Normalized(data: data, type: sourceType, pixelWidth: width, pixelHeight: height)
		}

		if sourceType == .gif, CGImageSourceGetCount(source) > 1, data.count <= maxByteCount {
			return Normalized(data: data, type: .gif, pixelWidth: width, pixelHeight: height)
		}

		guard let image = downsample(source, to: fittedLongEdge(width: width, height: height)) else {
			return nil
		}
		return encodeWithinBudget(
			image,
			lossless: prefersLossless(
				sourceType: sourceType,
				hasAlpha: properties?[kCGImagePropertyHasAlpha] as? Bool ?? false
			)
		)
	}

	private static func prefersLossless(sourceType: UTType?, hasAlpha: Bool) -> Bool {
		if hasAlpha { return true }
		guard let sourceType else { return false }
		return sourceType.conforms(to: .png) || sourceType.conforms(to: .gif)
	}

	private static func fittedLongEdge(width: Int, height: Int) -> Int {
		let longEdge = max(width, height)
		let shortEdge = min(width, height)
		let aspect = Double(shortEdge) / Double(longEdge)

		var target = Swift.min(longEdge, maxLongEdge)
		if Double(target) * Double(target) * aspect > Double(maxPixelCount) {
			target = Int((Double(maxPixelCount) / aspect).squareRoot().rounded(.down))
		}

		while target > 1 {
			let projectedShort = Int((Double(shortEdge) * Double(target) / Double(longEdge)).rounded(.up))
			if (target + 1) * (projectedShort + 1) <= maxPixelCount { break }
			target -= 1
		}
		return Swift.max(1, target)
	}

	private static func downsample(_ source: CGImageSource, to maxPixel: Int) -> CGImage? {
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceShouldCacheImmediately: true,
			kCGImageSourceThumbnailMaxPixelSize: maxPixel
		]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
	}

	private static func encodeWithinBudget(_ image: CGImage, lossless: Bool) -> Normalized? {
		let size = (width: image.width, height: image.height)

		if lossless, let png = encode(image, as: .png, quality: nil), png.count <= maxByteCount {
			return Normalized(data: png, type: .png, pixelWidth: size.width, pixelHeight: size.height)
		}

		for quality in [0.82, 0.6, 0.4] {
			guard let jpeg = encode(image, as: .jpeg, quality: quality), jpeg.count <= maxByteCount else {
				continue
			}
			return Normalized(data: jpeg, type: .jpeg, pixelWidth: size.width, pixelHeight: size.height)
		}
		return nil
	}

	private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
		let buffer = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(
			buffer, type.identifier as CFString, 1, nil
		) else { return nil }

		var properties: [CFString: Any] = [:]
		if let quality {
			properties[kCGImageDestinationLossyCompressionQuality] = quality
		}
		CGImageDestinationAddImage(destination, image, properties as CFDictionary)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return buffer as Data
	}

	// MARK: - Reading back

	static func decode(_ data: Data) -> CGImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
		return CGImageSourceCreateImageAtIndex(
			source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
		)
	}

	static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
		guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
		return downsample(source, to: maxPixel)
	}

	// MARK: - Pasteboard

	static let pasteboardTypes: [NSPasteboard.PasteboardType] =
		[UTType.png, .heic, .heif, .jpeg, .gif, .webP, .bmp, .tiff]
		.map { NSPasteboard.PasteboardType($0.identifier) }
}

extension NSPasteboard {

	func imageAttachments() -> [MessageAttachment] {
		let fileURLs = imageFileURLs
		if !fileURLs.isEmpty {
			return fileURLs.compactMap { url in
				guard let data = try? Data(contentsOf: url) else { return nil }
				return MessageAttachment(imageData: data, title: url.lastPathComponent)
			}
		}

		guard !prefersTextOverImages, let items = pasteboardItems else { return [] }

		return items.enumerated().compactMap { index, item in
			guard
				let type = AttachmentImage.pasteboardTypes.first(where: { item.types.contains($0) }),
				let data = item.data(forType: type)
			else { return nil }
			let title = items.count > 1 ? "Pasted Image \(index + 1)" : "Pasted Image"
			return MessageAttachment(imageData: data, title: title)
		}
	}

	var containsImages: Bool {
		if !imageFileURLs.isEmpty { return true }
		guard !prefersTextOverImages, let types else { return false }
		return AttachmentImage.pasteboardTypes.contains { types.contains($0) }
	}

	private var imageFileURLs: [URL] {
		guard types?.contains(.fileURL) == true else { return [] }
		guard let urls = readObjects(
			forClasses: [NSURL.self],
			options: [.urlReadingFileURLsOnly: true]
		) as? [URL] else { return [] }
		return urls.filter { AttachmentImage.isReadable(AttachmentImage.type(of: $0)) }
	}

	private var prefersTextOverImages: Bool {
		let styled: [NSPasteboard.PasteboardType] = [.html, .rtf]
		guard
			types?.contains(.string) == true,
			styled.contains(where: { types?.contains($0) == true })
		else { return false }

		let imageTypes = AttachmentImage.pasteboardTypes.filter { types?.contains($0) == true }
		return imageTypes == [NSPasteboard.PasteboardType(UTType.tiff.identifier)]
	}
}

// MARK: - Thumbnail Cache

@MainActor
enum AttachmentThumbnailCache {

	private static let storage: NSCache<NSUUID, NSImage> = {
		let cache = NSCache<NSUUID, NSImage>()
		cache.countLimit = 200
		return cache
	}()

	static func thumbnail(for attachment: MessageAttachment, maxPixel: Int = 128) -> NSImage? {
		guard let data = attachment.imageData else { return nil }
		let key = attachment.id as NSUUID
		if let cached = storage.object(forKey: key) { return cached }

		guard let cgImage = AttachmentImage.thumbnail(data, maxPixel: maxPixel) else { return nil }
		let image = NSImage(
			cgImage: cgImage,
			size: NSSize(width: cgImage.width, height: cgImage.height)
		)
		storage.setObject(image, forKey: key)
		return image
	}
}
