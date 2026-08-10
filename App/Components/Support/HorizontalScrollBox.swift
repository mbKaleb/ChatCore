//
//  HorizontalScrollBox.swift
//  ChatCore
//

import SwiftUI
import AppKit

final class PassthroughScrollView: NSScrollView {

	private var claimsCurrentGesture = false

	override func scrollWheel(with event: NSEvent) {
		let isGestureStart = event.phase.contains(.began)
		let isDiscrete = event.phase.isEmpty && event.momentumPhase.isEmpty

		if isGestureStart || isDiscrete {
			claimsCurrentGesture = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
		}

		if claimsCurrentGesture {
			super.scrollWheel(with: event)
		} else {
			nextResponder?.scrollWheel(with: event)
		}
	}
}

struct HorizontalScrollBox<Content: View>: NSViewRepresentable {
	@ViewBuilder var content: Content

	func makeNSView(context: Context) -> PassthroughScrollView {
		let scroll = PassthroughScrollView()
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = false
		scroll.hasHorizontalScroller = false
		scroll.autohidesScrollers = true
		scroll.verticalScrollElasticity = .none
		scroll.horizontalScrollElasticity = .automatic

		// Hosted as `Content`, not `AnyView`: a code block re-renders whenever its
		// bubble does, and an erased root gives SwiftUI nothing to diff, so every
		// one of those updates rebuilt the nested graph from scratch.
		let host = NSHostingView(rootView: content)
		scroll.documentView = host
		return scroll
	}

	func updateNSView(_ scroll: PassthroughScrollView, context: Context) {
		guard let host = scroll.documentView as? NSHostingView<Content> else { return }
		host.rootView = content
		host.frame = CGRect(origin: .zero, size: host.fittingSize)
	}

	func sizeThatFits(
		_ proposal: ProposedViewSize,
		nsView: PassthroughScrollView,
		context: Context
	) -> CGSize? {
		guard let host = nsView.documentView as? NSHostingView<Content> else { return nil }
		let fitting = host.fittingSize
		return CGSize(
			width: proposal.width ?? fitting.width,
			height: ceil(fitting.height)
		)
	}
}
