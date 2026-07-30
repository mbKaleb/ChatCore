//
//  ListMessageView.swift
//  ChatCore
//

import SwiftUI
import AppKit

struct ListMessageView: View {
	var messages: [Message]

	@Binding var scrollOffsetFromBottom: Double

	@State private var viewportHeight: CGFloat = 0
	@State private var viewportWidth: CGFloat = 0

	@State private var lastMessageHeight: CGFloat = 0
	@State private var lastUserMessageHeight: CGFloat = 0

	@State private var isNearBottom = true

	private let bottomProximityThreshold: CGFloat = 80
	private let lineHeight: CGFloat = 20

	@State private var currentDistanceFromBottom: CGFloat = 0
	@State private var contentHeight: CGFloat = 0
	@State private var hasRestoredInitialScrollPosition = false
	@State private var scrollPosition = ScrollPosition()

	private static let bottomSpacerID = "ListMessageView.bottomSpacer"

	private let contentLeading: CGFloat = 16
	private let contentTrailing: CGFloat = 26

	private var bottomSpacerHeight: CGFloat {
		let userHeight = messages.last?.role == "assistant"
			? lastUserMessageHeight
			: 0

		let remainingLines =
			((viewportHeight - lastMessageHeight - userHeight) / lineHeight)
				.rounded(.down) - 1

		return max(0, remainingLines * lineHeight)
	}

	var body: some View {
		let _ = Self.printChanges()

		ScrollViewReader { proxy in
			List {
				ForEach(messages) { message in
					MessageBubble(message: message)
						.listRowBackground(Color.clear)
						.listRowInsets(
							EdgeInsets(
								top: 6,
								leading: contentLeading,
								bottom: 6,
								trailing: contentTrailing
							)
						)
						.background(ThinScrollerConfigurator())
						.id(message.id)
						.onGeometryChange(
							for: CGFloat.self,
							of: { $0.size.height }
						) { _, newHeight in
							if message.role == "user" {
								lastUserMessageHeight = newHeight
							}

							guard message.id == messages.last?.id else {
								return
							}

							lastMessageHeight = newHeight
						}
				}
				.listRowSeparator(.hidden)
			}
			.listStyle(.plain)
			.scrollContentBackground(.hidden)
			.textSelection(.enabled)
			.scrollPosition($scrollPosition)

			.onGeometryChange(
				for: CGSize.self,
				of: { $0.size }
			) { _, newSize in
				viewportHeight = newSize.height
				viewportWidth = newSize.width
			}

			.onScrollGeometryChange(
				for: CGFloat.self
			) { geometry in
				max(
					0,
					geometry.contentSize.height -
					(geometry.contentOffset.y + geometry.containerSize.height)
				)
			} action: { _, newDistance in
				currentDistanceFromBottom = newDistance
				isNearBottom = newDistance <= bottomProximityThreshold
			}

			.onScrollGeometryChange(
				for: CGFloat.self
			) { geometry in
				geometry.contentSize.height
			} action: { _, newHeight in
				contentHeight = newHeight
				restoreInitialScrollPositionIfNeeded()
			}

			.task {
				guard scrollOffsetFromBottom <= 0 else { return }

				await Task.yield()

				proxy.scrollTo(
					Self.bottomSpacerID,
					anchor: .bottom
				)

				hasRestoredInitialScrollPosition = true
			}

			.onDisappear {
				scrollOffsetFromBottom = Double(currentDistanceFromBottom)
			}

			.onChange(of: messages.count) {
				stickToBottom(proxy)
			}

			.onChange(of: messages.last?.text) {
				guard isNearBottom else { return }
				stickToBottom(proxy)
			}

			.onChange(of: viewportHeight) {
				guard isNearBottom else { return }
				stickToBottom(proxy)
			}

			.onChange(of: viewportWidth) {
				guard isNearBottom else { return }
				stickToBottom(proxy)
			}
		}
	}

	private func stickToBottom(_ proxy: ScrollViewProxy) {
		withAnimation(.linear(duration: 0.1)) {
			proxy.scrollTo(
				Self.bottomSpacerID,
				anchor: .bottom
			)
		}
	}

	private func restoreInitialScrollPositionIfNeeded() {
		guard
			!hasRestoredInitialScrollPosition,
			scrollOffsetFromBottom > 0,
			viewportHeight > 0,
			contentHeight > 0
		else {
			return
		}

		hasRestoredInitialScrollPosition = true

		let targetY = max(
			0,
			contentHeight - viewportHeight - scrollOffsetFromBottom
		)

		scrollPosition.scrollTo(y: targetY)
	}
}

private struct ThinScrollerConfigurator: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let probe = NSView(frame: .zero)
		configureWhenReady(probe, attemptsLeft: 8)
		return probe
	}

	func updateNSView(_ nsView: NSView, context: Context) {
		configureWhenReady(nsView, attemptsLeft: 1)
	}

	private func configureWhenReady(_ probe: NSView, attemptsLeft: Int) {
		guard attemptsLeft > 0 else { return }

		DispatchQueue.main.async {
			guard let scrollView = probe.enclosingScrollView else {
				configureWhenReady(probe, attemptsLeft: attemptsLeft - 1)
				return
			}

			scrollView.scrollerStyle = .overlay
			scrollView.hasVerticalScroller = true
			scrollView.autohidesScrollers = true
			scrollView.verticalScroller?.controlSize = .small

			if let table = scrollView.documentView as? NSTableView {
				table.gridStyleMask = []
				table.gridColor = .clear
				table.backgroundColor = .clear
			}
		}
	}
}
