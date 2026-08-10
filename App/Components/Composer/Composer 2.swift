import AppKit
import SwiftUI

/// The draft: what's typed and what's staged to go with it.
///
/// A reference type rather than `@State` on the composer itself because the
/// draft is written from outside the compose bar — drops and pastes land
/// anywhere on the chat and stage attachments here, and a send that fails
/// with nothing streamed puts the draft back. Keeping it an `@Observable`
/// box also means the view hosting the transcript can hold and mutate it
/// without reading it in `body`, so keystrokes invalidate only `Composer`.
@Observable
@MainActor
final class ComposerState {
	var text: String = ""
	var attachments: [MessageAttachment] = []

	var isEmpty: Bool { text.isEmpty && attachments.isEmpty }

	/// Whether sending would do anything. Whitespace alone can't — `send`
	/// trims it away and bails — so it shouldn't light the button either,
	/// whether the whitespace was typed or arrived inside a text attachment.
	var isSendable: Bool {
		attachments.contains {
			$0.isImage || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		} || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	/// Armed by `setText`, consumed by the paste interceptor in `Composer` —
	/// a restored draft or an inlined chip is programmatic text, not a paste,
	/// and must not be promoted straight back into an attachment.
	@ObservationIgnored var bypassPasteInterception = false

	/// The one door for programmatic writes to `text`. The guard matters: an
	/// equal value fires no `onChange`, which would leave the bypass armed to
	/// swallow the next genuine paste.
	func setText(_ newText: String) {
		guard newText != text else { return }
		bypassPasteInterception = true
		text = newText
	}

	func add(_ attachment: MessageAttachment) {
		withAnimation(.smooth(duration: 0.34)) {
			attachments.append(attachment)
		}
	}

	func remove(_ attachment: MessageAttachment) {
		withAnimation(.smooth(duration: 0.28)) {
			attachments.removeAll { $0.id == attachment.id }
		}
	}
}

/// The compose bar: attachments tray, message field, and the send/stop pair.
///
/// Owns none of the machinery around it — ingest (drop, paste, file picker)
/// and the send pipeline stay with the parent, reached through the closures
/// below. This view only edits the draft and says when to go.

struct Composer: View {
	/// One height for the plus button, the field row, and send, so the bar's
	/// controls line up on a single baseline no matter how the field grows.
	private static let composerHeight: CGFloat = 24

	/// Inset between a control and the glass capsule around it. The message
	/// row wears it as padding, so the `+` capsule has to account for it too
	/// or the two capsules come out different heights.
	private static let capsuleInset: CGFloat = 3

	/// The height both capsules settle at with a single-line draft.
	private static var capsuleHeight: CGFloat { composerHeight + capsuleInset * 2 }

	@Bindable var state: ComposerState
	var isResponding: Bool
	/// Whether a drag is hovering anywhere over the chat. The drop zone is
	/// the whole window, not this bar; the tray here only dresses for it.
	var isDropTargeted: Bool
	/// Held by the parent: tap-anywhere, sidebar close, and the new-chat
	/// focus promise all move focus from outside this view.
	var focus: FocusState<Bool>.Binding
	/// Reported upward so the transcript can inset its bottom edge.
	@Binding var height: CGFloat
	var onSend: () -> Void
	var onStop: () -> Void
	var onAttach: () -> Void

	var body: some View {
		let _ = Self.printChanges()
		GlassEffectContainer(spacing: 8) {
			VStack(alignment: .leading, spacing: 8) {
				if !state.attachments.isEmpty || isDropTargeted {
					attachmentsTray
				}

				HStack(spacing: 8) {
					Button(action: onAttach) {
						Image(systemName: "plus")
							.font(.body)
							.frame(width: Self.capsuleHeight, height: Self.capsuleHeight)
							.contentShape(Circle())
					}
					.buttonStyle(.plain)
					.glassEffect(.clear, in: .rect(cornerRadius: 15))
					.help("Attach a file")
					.accessibilityLabel("Attach a file")

					HStack(alignment: .center, spacing: 8) {
						TextField("Message", text: $state.text, axis: .vertical)
							.textFieldStyle(.plain)
							// Caps how far the bar grows into the transcript;
							// past this the field scrolls its own contents.
							.lineLimit(1...12)
							// Matches the buttons at rest; a floor rather than a
							// fixed height so the field can still grow with the draft.
							.frame(minHeight: Self.composerHeight)
							.scrollContentBackground(.hidden)
							.focused(focus)
							.onSubmit {
								guard !isResponding else { return }
								onSend()
							}
							.onKeyPress(.return, phases: .down) { press in
								guard press.modifiers.contains(.shift) else { return .ignored }
								insertNewlineAtCursor()
								return .handled
							}
							.onKeyPress(.escape) {
								guard isResponding else { return .ignored }
								onStop()
								return .handled
							}
							.onChange(of: state.text) { oldValue, newValue in
								if state.bypassPasteInterception {
									state.bypassPasteInterception = false
									return
								}
								guard let pasted = pastedChunk(from: oldValue, to: newValue) else { return }
								state.text = oldValue
								state.add(MessageAttachment(text: pasted))
							}

						Button {
							if isResponding { onStop() } else { onSend() }
						} label: {
							Image(systemName: isResponding ? "stop.circle.fill" : "arrow.up.circle.fill")
								.font(.system(size: 22))
								.contentTransition(.symbolEffect(.replace))
								.frame(width: Self.composerHeight, height: Self.composerHeight)
								.contentShape(Circle())
						}
						.buttonStyle(.plain)
						.disabled(!isResponding && !state.isSendable)
						.help(isResponding ? "Stop generating (Esc)" : "Send")
						.accessibilityLabel(isResponding ? "Stop generating" : "Send message")
					}
					.padding(.leading, 11)
					.padding(.trailing, Self.capsuleInset)
					.padding(.vertical, Self.capsuleInset)
					.frame(maxWidth: .infinity)
					.glassEffect(.clear, in: .rect(cornerRadius: 15))
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
	}

	/// Insert the break where the caret is, not at the end of the draft.
	///
	/// SwiftUI exposes no caret for a `TextField`, but on macOS the focused
	/// field edits through the window's field editor — an `NSTextView` that
	/// knows exactly where the selection sits. Only reachable while this
	/// field has focus, so the first responder is that editor.
	private func insertNewlineAtCursor() {
		if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
			editor.insertText("\n", replacementRange: editor.selectedRange())
		} else {
			state.text.append("\n")
		}
	}

	/// The stretch of text a single change inserted, if it's big enough to
	/// be a paste worth promoting to an attachment rather than typing.
	/// Index-walked rather than through `Array(String)`s — this runs on every
	/// keystroke, over the whole draft.
	private func pastedChunk(from oldValue: String, to newValue: String) -> String? {
		guard newValue.count > oldValue.count else { return nil }

		var oldStart = oldValue.startIndex
		var newStart = newValue.startIndex
		while oldStart < oldValue.endIndex, newStart < newValue.endIndex,
		      oldValue[oldStart] == newValue[newStart] {
			oldValue.formIndex(after: &oldStart)
			newValue.formIndex(after: &newStart)
		}

		var oldEnd = oldValue.endIndex
		var newEnd = newValue.endIndex
		while oldEnd > oldStart, newEnd > newStart {
			let oldPrev = oldValue.index(before: oldEnd)
			let newPrev = newValue.index(before: newEnd)
			guard oldValue[oldPrev] == newValue[newPrev] else { break }
			oldEnd = oldPrev
			newEnd = newPrev
		}

		let chunk = newValue[newStart..<newEnd]
		guard Self.readsAsPaste(chunk) else { return nil }
		return String(chunk)
	}

	/// Big enough to be worth a chip. The bar is a real paste's size — a
	/// multi-line block, or hundreds of characters — because dictation and
	/// IME commits also insert whole phrases in one step, and a long URL is
	/// still typing. Anything below stays inline, where it can be edited.
	private static func readsAsPaste(_ chunk: Substring) -> Bool {
		chunk.count >= 500 || (chunk.count >= 150 && chunk.contains(where: \.isNewline))
	}

	// MARK: - Attachments tray

	private var attachmentsTray: some View {
		Group {
			if isDropTargeted {
				HStack(spacing: 8) {
					Image(systemName: "arrow.down.doc")
					Text("Drop here")
				}
				.font(.callout)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity)
				.frame(height: 48)
			} else {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 8) {
						ForEach(state.attachments) { attachment in
							AttachmentChip(attachment: attachment) {
								state.remove(attachment)
							}
							.contextMenu {
								if !attachment.isImage {
									Button("Insert as Text") { inlineAttachment(attachment) }
								}
								Button("Remove", role: .destructive) { state.remove(attachment) }
							}
							.transition(Self.chipTransition)
						}
					}
					.padding(6)
				}
				.fixedSize(horizontal: false, vertical: true)
			}
		}
		.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 18))
		.overlay {
			if isDropTargeted {
				RoundedRectangle(cornerRadius: 18)
					.strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
			}
		}
		.transition(Self.trayTransition)
	}

	private static let chipTransition: AnyTransition = .asymmetric(
		insertion: .scale(scale: 0.72)
			.combined(with: .opacity)
			.animation(.bouncy(duration: 0.38, extraBounce: 0.22)),
		removal: .opacity.animation(.easeOut(duration: 0.22))
	)

	private static let trayTransition: AnyTransition = .asymmetric(
		insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
		removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
	)

	/// Undo for the paste interception: the chip's text back into the draft
	/// as ordinary typing.
	private func inlineAttachment(_ attachment: MessageAttachment) {
		state.remove(attachment)
		state.setText(
			state.text.isEmpty ? attachment.text : state.text + "\n" + attachment.text
		)
		focus.wrappedValue = true
	}
}
