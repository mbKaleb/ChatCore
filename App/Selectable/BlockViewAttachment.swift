//
//  BlockViewAttachment.swift
//  ChatCore
//
//  Prototype: a real SwiftUI view living inside the text stream.
//
//  This is the escape hatch for content that genuinely isn't text — math, images,
//  tables. The attachment occupies exactly one character (U+FFFC), so selection
//  sweeps *through* it instead of stopping at it. The cost is that you cannot
//  select the text inside it, which is why code blocks stay real text instead.
//



import AppKit
import SwiftUI

nonisolated final class BlockViewAttachment: NSTextAttachment {

	let latex: String
	let style: SelectableStyle

	init(latex: String, style: SelectableStyle) {
		self.latex = latex
		self.style = style
		super.init(data: nil, ofType: nil)
		allowsTextAttachmentView = true
		// An attachment with no image, no cell and no file wrapper still draws the
		// generic document icon underneath the provider's view. An empty NSImage
		// draws nothing and leaves the hosting view alone.
		image = NSImage(size: NSSize(width: 1, height: 1))
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func viewProvider(
		for parentView: NSView?,
		location: NSTextLocation,
		textContainer: NSTextContainer?
	) -> NSTextAttachmentViewProvider? {
		let provider = BlockViewProvider(
			textAttachment: self,
			parentView: parentView,
			textLayoutManager: textContainer?.textLayoutManager,
			location: location
		)
		provider.tracksTextAttachmentViewBounds = true
		return provider
	}

	override func attachmentBounds(
		for attributes: [NSAttributedString.Key: Any],
		location: NSTextLocation,
		textContainer: NSTextContainer?,
		proposedLineFragment: CGRect,
		position: CGPoint
	) -> CGRect {
		// Fixed geometry keeps the prototype predictable. Real content would measure
		// its hosting view against the proposed width and cache by (content, width).
		let lines = max(1, latex.components(separatedBy: "\n").count)
		let width = proposedLineFragment.width > 0 ? proposedLineFragment.width : 320
		return CGRect(x: 0, y: -6, width: width, height: 26 + CGFloat(lines) * 24)
	}
}

nonisolated final class BlockViewProvider: NSTextAttachmentViewProvider {

	override func loadView() {
		let attachment = textAttachment as? BlockViewAttachment
		view = Self.makeHostingView(
			latex: attachment?.latex ?? "",
			style: attachment?.style ?? SelectableStyle()
		)
	}

	// TextKit only ever calls `loadView()` on the main thread, but the superclass
	// declares it nonisolated — so the hop has to be asserted. It goes through a
	// static function on purpose: capturing `self` in the isolated closure would
	// send a non-Sendable object into the main-actor region.
	private static func makeHostingView(latex: String, style: SelectableStyle) -> NSView {
		MainActor.assumeIsolated {
			let hosting = NSHostingView(rootView: AttachmentPlaceholder(latex: latex, style: style))
			// TextKit installs this as a subview of the text view, so light/dark is
			// inherited. Intrinsic sizing is off because `attachmentBounds` decides
			// the geometry.
			hosting.sizingOptions = []
			return hosting
		}
	}
}

/// Stands in for the real `MathBlockView` so the prototype has no dependency on
/// the app's rendering stack. Swap the body for `MathBlockView(latex:)` to see
/// actual equations flow through the selection.
private struct AttachmentPlaceholder: View {

	let latex: String
	let style: SelectableStyle

	var body: some View {
		Text(latex)
			.font(.system(size: style.codeFont.pointSize + 1, design: .serif))
			.italic()
			.foregroundStyle(Color(style.bodyColor))
			.frame(maxWidth: .infinity)
			.padding(.vertical, 10)
			.background {
				RoundedRectangle(cornerRadius: style.cardCornerRadius)
					.fill(Color(style.codeCardFill))
					.overlay {
						RoundedRectangle(cornerRadius: style.cardCornerRadius)
							.strokeBorder(Color(style.codeCardStroke), lineWidth: 1)
					}
			}
	}
}
