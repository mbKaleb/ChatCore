//
//  ImageAttachment3.swift
//  ChatCore
//
//  An image that reserves space in the text stream and draws nothing.
//
//  The same shape as `MathAttachment3`: one U+FFFC character, geometry that was
//  measured when the string was built, painting left to
//  `SelectableLayoutFragment3`. The one character keeps selection sweeping
//  *through* the image, and copy gives back `![alt](source)` rather than a
//  blank box.
//
//  What math doesn't have is the network: a bitmap may not be local, so
//  `ImageStore3` loads it once, process-wide, and the builder only ever emits
//  an attachment for an image that has already arrived. Until then the image
//  renders as its alt text — the coordinator rebuilds when the store says the
//  bitmap landed.
//

import AppKit

// MARK: - Attachment

nonisolated final class ImageAttachment3: NSTextAttachment {

	/// The destination exactly as authored — what copy puts back in the parens.
	let source: String
	let alt: String

	/// The loaded bitmap. Never nil in practice — the builder falls back to alt
	/// text when the store has nothing — but optional so `attachmentBounds`
	/// can't trap on a race.
	let display: NSImage?

	let naturalSize: CGSize
	let maxHeight: CGFloat

	/// Written by `attachmentBounds` when the image has to shrink to fit the
	/// column, read back by the fragment at draw time. Same ordering argument as
	/// `MathAttachment3.scale`: TextKit always lays out before it draws.
	private(set) var scale: CGFloat = 1

	init(source: String, alt: String, display: NSImage?, maxHeight: CGFloat) {
		self.source = source
		self.alt = alt
		self.display = display
		self.naturalSize = display?.size ?? .zero
		self.maxHeight = maxHeight
		super.init(data: nil, ofType: nil)
		// An attachment with no image and no cell draws the generic document
		// icon; a 1×1 empty image stands in for "draws nothing". The real bitmap
		// stays off this property on purpose — TextKit 2 would otherwise host it
		// in an attachment view, and a sibling view is exactly what this
		// renderer exists to avoid.
		image = NSImage(size: NSSize(width: 1, height: 1))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func attachmentBounds(
		for attributes: [NSAttributedString.Key: Any],
		location: NSTextLocation,
		textContainer: NSTextContainer?,
		proposedLineFragment: CGRect,
		position: CGPoint
	) -> CGRect {
		guard naturalSize.width > 0, naturalSize.height > 0 else { return .zero }

		let available = proposedLineFragment.width
		var fit: CGFloat = 1
		if available > 0, naturalSize.width > available {
			fit = available / naturalSize.width
		}
		if naturalSize.height * fit > maxHeight {
			fit = maxHeight / naturalSize.height
		}
		scale = min(1, fit)

		// Origin y of 0 sits the image's bottom on the baseline, which is the
		// ordinary inline-image behaviour — a paragraph that is only an image
		// reads as a block anyway.
		return CGRect(origin: .zero, size: size)
	}

	/// The reserved box, scaled to whatever fit the column.
	var size: CGSize {
		CGSize(width: naturalSize.width * scale, height: naturalSize.height * scale)
	}

	/// The reserved box in view coordinates, given where the line put it.
	/// Flipped coordinates: the image sits on the baseline and extends up.
	func box(x: CGFloat, baseline: CGFloat) -> CGRect {
		let size = size
		return CGRect(x: x, y: baseline - size.height, width: size.width, height: size.height)
	}
}

// MARK: - Store

/// One loaded bitmap per source, process-wide.
///
/// The builder runs on every streamed token, so the load path has to be a
/// dictionary hit — the same contract `MathCache` has with equations. A source
/// that hasn't arrived yet returns nil and the builder emits alt text; when the
/// fetch lands the store bumps `version` and posts `imageDidLoad3`, and every
/// coordinator whose message mentions the source rebuilds once.
@MainActor
enum ImageStore3 {

	nonisolated static let imageDidLoad3 = Notification.Name("cc3.imageDidLoad")

	/// Bumped on every arrival, so a rebuild guard can treat "which images have
	/// landed" as one comparable value instead of diffing the dictionary.
	private(set) static var version = 0

	private static var images: [String: NSImage] = [:]
	private static var inflight: Set<String> = []
	/// Sources that resolved to nothing — a bad URL, a 404, undecodable data.
	/// Remembered so a transcript full of the same broken link fetches it once.
	private static var failed: Set<String> = []

	static func image(for source: String) -> NSImage? {
		images[source]
	}

	/// Kicks off a fetch unless the source is loaded, loading, or known bad.
	static func request(_ source: String) {
		guard images[source] == nil, !inflight.contains(source), !failed.contains(source) else { return }
		guard let url = resolve(source) else {
			failed.insert(source)
			return
		}

		inflight.insert(source)
		Task {
			let image = await load(url)
			inflight.remove(source)
			if let image {
				images[source] = image
				version += 1
				NotificationCenter.default.post(name: imageDidLoad3, object: source)
			} else {
				failed.insert(source)
			}
		}
	}

	/// http(s) and file URLs, plus bare absolute paths. Anything else — relative
	/// paths, data URIs, unknown schemes — is treated as unloadable and keeps
	/// its alt text.
	private static func resolve(_ source: String) -> URL? {
		if source.hasPrefix("/") {
			return URL(filePath: source)
		}
		guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else { return nil }
		return ["http", "https", "file"].contains(scheme) ? url : nil
	}

	private static func load(_ url: URL) async -> NSImage? {
		if url.isFileURL {
			return NSImage(contentsOf: url)
		}
		guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
		if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
		guard let image = NSImage(data: data), image.size.width > 0 else { return nil }
		return image
	}
}
