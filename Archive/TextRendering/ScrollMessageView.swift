//
//  ScrollMessageView.swift
//  ChatCore
//
//  The scroll body shared by the `selectable` renderers.
//
//  A plain `ScrollView` around a non-lazy `VStack`, anchored to the bottom.
//  Unlike `List`, a SwiftUI `ScrollView` is not NSScrollView-backed, so
//  `defaultScrollAnchor(.bottom)` is honored and the transcript opens at the
//  bottom before the first frame — no scripted scroll on appear. The stack is
//  deliberately not lazy: every bubble is a live view, so content height is
//  exact from the first layout and the position restore lands where it aimed.
//  Keeping a long transcript alive is the accepted cost; the compiled and
//  virtualized renderers are the ones that economize.
//
//  The three selectable renderers all wrap this one view, each swapping in its
//  own assistant text container. Sharing the scroll, sticking and restore
//  logic is what makes comparing them mean something — anything that differs
//  between selectable renderers is the text container, not the scaffolding.
//

import SwiftUI

struct ScrollMessageView: View {
	var messages: [Message]

	@Binding var scrollOffsetFromBottom: Double

	var scrollToBottomToken: Int = 0
	var bottomInset: CGFloat = 0

	/// Which text container draws assistant markdown.
	var assistantText: AssistantTextEngine

	/// `conversationID` goes unused: the rows are ordinary SwiftUI views with
	/// nothing compiled or measured to hold onto between chats.
	init(_ context: TranscriptContext, assistantText: AssistantTextEngine) {
		self.messages = context.messages
		self._scrollOffsetFromBottom = context.scrollOffsetFromBottom
		self.scrollToBottomToken = context.scrollToBottomToken
		self.bottomInset = context.bottomInset
		self.assistantText = assistantText
	}

	@State private var viewportHeight: CGFloat = 0
	@State private var viewportWidth: CGFloat = 0

	@State private var isNearBottom = true

	private let bottomProximityThreshold: CGFloat = 80

	@State private var currentDistanceFromBottom: CGFloat = 0
	@State private var contentHeight: CGFloat = 0
	@State private var hasRestoredInitialScrollPosition = false
	@State private var scrollPosition = ScrollPosition()

	private static let bottomSpacerID = "ScrollMessageView.bottomSpacer"

	private let contentLeading: CGFloat = 16
	private let contentTrailing: CGFloat = 26

	var body: some View {
		let _ = Self.printChanges()

		ScrollViewReader { proxy in
			ScrollView {
				VStack(spacing: 0) {
					ForEach(messages) { message in
						MessageBubble(message: message, assistantText: assistantText)
							.padding(
								EdgeInsets(
									top: 6,
									leading: contentLeading,
									bottom: 6,
									trailing: contentTrailing
								)
							)
							.id(message.id)
					}

					// The view every scroll-to-bottom aims at. Scrolling to the
					// last message instead would put it under the compose bar,
					// which is what this view is holding space for. Exactly the
					// compose-bar clearance and nothing more — this used to also
					// reserve a viewport of blank space to park the newest
					// exchange at the top, and that rendered as a giant void
					// whose height changed as rows measured in.
					Color.clear
						.frame(height: bottomInset)
						.id(Self.bottomSpacerID)
				}
			}
			// Opens the transcript at the bottom before the first frame. When
			// the chat was left somewhere above the bottom, the restore below
			// overrides this once real geometry is in.
			//
			// `initialOffset` only, deliberately: the unrestricted anchor also
			// rewrites the offset on every content-size change, and streaming
			// changes content size constantly — worst with math, where closing
			// a `$$` fence collapses lines of source into one typeset block.
			// That correction raced the animated stick-to-bottom below and the
			// spacer resize, and the transcript visibly fought itself. One
			// follower: the `onChange` machinery.
			.defaultScrollAnchor(.bottom, for: .initialOffset)
			.scrollPosition($scrollPosition)
			.textSelection(.enabled)

			// The system indicator stays off in favor of the capsule overlaid
			// below — the same one every renderer shows, so switching renderers
			// in Settings doesn't change how the scrollbar looks.
			.scrollIndicators(.never)
			.overlay(alignment: .topTrailing) { scrollIndicator }

			.onGeometryChange(
				for: CGSize.self,
				of: { $0.size }
			) { _, newSize in
				viewportHeight = newSize.height
				viewportWidth = newSize.width
				restoreInitialScrollPositionIfNeeded()
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

			.onDisappear {
				scrollOffsetFromBottom = Double(currentDistanceFromBottom)
			}

			.onChange(of: messages.count) {
				stickToBottom(proxy)
			}

			.onChange(of: scrollToBottomToken) {
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

	/// The transcript's own scroll indicator, standing in for the system's.
	///
	/// Persistent: on screen whenever there is more transcript than viewport,
	/// like a legacy scrollbar — but drawn in an overlay, so it never takes
	/// width from the rows the way the system's legacy scroller would.
	/// Geometry falls out of state the view already tracks for its
	/// bottom-proximity logic; display-only.
	@ViewBuilder
	private var scrollIndicator: some View {
		let scrollable = contentHeight - viewportHeight
		if scrollable > 0, viewportHeight > 0 {
			let inset: CGFloat = 4
			let track = viewportHeight - 2 * inset
			let knobHeight = max(24, track * viewportHeight / contentHeight)
			let progress = min(1, max(0, 1 - currentDistanceFromBottom / scrollable))

			Capsule()
				.fill(.secondary.opacity(0.55))
				.frame(width: 6, height: knobHeight)
				.offset(y: inset + (track - knobHeight) * progress)
				.padding(.trailing, 3)
				.allowsHitTesting(false)
		}
	}

	private func stickToBottom(_ proxy: ScrollViewProxy) {
		// Short and linear because this retargets on every streamed chunk: a
		// spring that never gets to finish reads as wobble, a 100ms nudge
		// reads as tracking.
		withAnimation(.linear(duration: 0.1)) {
			proxy.scrollTo(
				Self.bottomSpacerID,
				anchor: .bottom
			)
		}
	}

	/// Puts the transcript back where it was left, once.
	///
	/// `defaultScrollAnchor(.bottom)` opens the view at the bottom, which is
	/// also the right answer when there is nothing to restore. When there is,
	/// the first geometry pass with real sizes converts the saved
	/// distance-from-bottom into a `y` and jumps there. The stack isn't lazy,
	/// so the content height in that pass is already exact.
	///
	/// `isNearBottom` and the distance are seeded from the saved offset in the
	/// same pass, so the stick-to-bottom `onChange`s firing on this first
	/// layout don't yank the view back down before the scroll-geometry
	/// callback has reported the restored position.
	private func restoreInitialScrollPositionIfNeeded() {
		guard
			!hasRestoredInitialScrollPosition,
			scrollOffsetFromBottom > 0,
			viewportHeight > 0,
			contentHeight > viewportHeight
		else {
			return
		}

		hasRestoredInitialScrollPosition = true

		currentDistanceFromBottom = scrollOffsetFromBottom
		isNearBottom = scrollOffsetFromBottom <= bottomProximityThreshold

		let targetY = max(
			0,
			contentHeight - viewportHeight - scrollOffsetFromBottom
		)

		scrollPosition.scrollTo(y: targetY)
	}

}
