//
//  CompiledMessageList.swift
//  ChatCore
//
//  The default transcript renderer, one of the `TranscriptRenderer` cases —
//  Settings ▸ Rendering ▸ Transcript, or launch with `-renderer <id>`.
//
//  The idea: compile every message to CoreText lines once, keep a prefix sum of
//  row heights, and make scrolling a binary search plus `CTLineDraw`. There is no
//  height estimator, no offscreen measurement pass and no correction flush,
//  because measurement and rendering are the same object — a block's height is
//  whatever the lines it will paint add up to.
//
//  Still missing versus the fallback, in the order they hurt:
//   • No attachment chips. The only one that loses information rather than an
//     affordance: a message whose content is an image renders as an empty bubble.
//   • No text selection. The real cost of owning layout, and the milestone that
//     decides whether the native path is worth finishing.
//   • No hover copy buttons, on bubbles or code cards.
//   • Code blocks and wide tables clip instead of scrolling horizontally.
//   • No accessibility.
//   • The initial compile is synchronous. Chunking it is the next step; the
//     `[CR]` timing log under `-renderDebug` says whether it needs to be.
//

import SwiftUI
import AppKit

// MARK: - SwiftUI entry point

struct CompiledMessageList: TranscriptRendering {
	@Environment(ModelManager.self) private var manager
	@Environment(ThemeManager.self) private var themes
	/// Names the transcript in `CompiledDocumentCache`. Switching chats tears this
	/// whole view down, so identity has to come from outside it.
	var conversationID: UUID
	var messages: [Message]
	@Binding var scrollOffsetFromBottom: Double
	var scrollToBottomToken: Int = 0
	var bottomInset: CGFloat = 0

	init(_ context: TranscriptContext) {
		self.conversationID = context.conversationID
		self.messages = context.messages
		self._scrollOffsetFromBottom = context.scrollOffsetFromBottom
		self.scrollToBottomToken = context.scrollToBottomToken
		self.bottomInset = context.bottomInset
	}

	var body: some View {
		CompiledListRepresentable(
			conversationID: conversationID,
			messages: messages,
			liveText: manager.liveText,
			style: CompileStyle(theme: themes.theme, appearance: themes.appearance),
			initialOffsetFromBottom: scrollOffsetFromBottom,
			offset: $scrollOffsetFromBottom,
			scrollToBottomToken: scrollToBottomToken,
			bottomInset: bottomInset
		)
	}
}

// MARK: - Representable

private struct CompiledListRepresentable: NSViewControllerRepresentable {
	var conversationID: UUID
	var messages: [Message]
	var liveText: [UUID: String]
	var style: CompileStyle
	var initialOffsetFromBottom: Double
	var offset: Binding<Double>
	var scrollToBottomToken: Int
	var bottomInset: CGFloat

	func makeCoordinator() -> Coordinator { Coordinator(offset: offset) }

	func makeNSViewController(context: Context) -> CompiledListViewController {
		let controller = CompiledListViewController(
			conversationID: conversationID,
			style: style,
			initialOffsetFromBottom: CGFloat(initialOffsetFromBottom),
			bottomInset: bottomInset
		)
		context.coordinator.lastScrollToken = scrollToBottomToken
		controller.apply(messages: messages, liveText: liveText)
		return controller
	}

	func updateNSViewController(_ controller: CompiledListViewController, context: Context) {
		controller.updateStyle(style)
		controller.updateBottomInset(bottomInset)
		let forced = context.coordinator.consumeScrollRequest(scrollToBottomToken)
		controller.apply(messages: messages, liveText: liveText, forceScrollToBottom: forced)
	}

	static func dismantleNSViewController(_ controller: CompiledListViewController, coordinator: Coordinator) {
		coordinator.offset.wrappedValue = Double(controller.currentDistanceFromBottom)
		controller.persistToCache()
	}

	@MainActor
	final class Coordinator {
		let offset: Binding<Double>
		var lastScrollToken = 0
		init(offset: Binding<Double>) { self.offset = offset }

		func consumeScrollRequest(_ token: Int) -> Bool {
			guard token != lastScrollToken else { return false }
			lastScrollToken = token
			return true
		}
	}
}

// MARK: - Controller

@MainActor
final class CompiledListViewController: NSViewController {

	private let bottomThreshold: CGFloat = 80

	private let conversationID: UUID
	private var style: CompileStyle
	private var bottomInset: CGFloat
	private let initialOffsetFromBottom: CGFloat

	private var scrollView: NSScrollView!
	private var documentView: CompiledDocumentView!
	private var clip: NSClipView { scrollView.contentView }

	/// Keeps the scroller off the transcript until the user scrolls it — every
	/// placement this controller performs is its own, not theirs.
	private let lazyScroller = LazyScroller()

	private var messages: [Message] = []
	private var liveText: [UUID: String] = [:]

	/// The text each message was compiled from, so a streaming tick can tell which
	/// rows actually moved without re-running the compiler to find out.
	private var compiledText: [UUID: String] = [:]

	/// Block layouts from the last compile of the streaming message, so a tick that
	/// added a few tokens only typesets the block those tokens landed in.
	private var streamingCache = BlockLayoutCache()
	private var streamingCacheID: UUID?

	private(set) var currentDistanceFromBottom: CGFloat = 0

	private var didInitialLayout = false
	private var lastWidth: CGFloat = 0
	private var widthFlush: DispatchWorkItem?

	nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?

	init(
		conversationID: UUID,
		style: CompileStyle,
		initialOffsetFromBottom: CGFloat,
		bottomInset: CGFloat
	) {
		self.conversationID = conversationID
		self.style = style
		self.initialOffsetFromBottom = initialOffsetFromBottom
		self.bottomInset = bottomInset
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	deinit {
		if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
	}

	// MARK: View

	override func loadView() {
		let document = CompiledDocumentView(frame: .zero)
		document.style = style
		documentView = document

		let scroll = OverlayScrollView()
		scroll.hasHorizontalScroller = false
		lazyScroller.attach(to: scroll)
		scroll.drawsBackground = false
		scroll.backgroundColor = .clear
		scroll.automaticallyAdjustsContentInsets = false
		scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
		scroll.documentView = document
		scrollView = scroll

		view = scroll
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		clip.postsBoundsChangedNotifications = true
		boundsObserver = NotificationCenter.default.addObserver(
			forName: NSView.boundsDidChangeNotification,
			object: clip,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				self?.updateDistanceFromBottom()
			}
		}
	}

	override func viewDidLayout() {
		super.viewDidLayout()
		let width = contentWidth
		guard width > 0 else { return }

		if !didInitialLayout {
			didInitialLayout = true
			lastWidth = width
			if !restoreFromCache(at: width) { recompileAll() }
			if initialOffsetFromBottom <= 0 {
				scrollToBottom()
			} else {
				setClipY(maxScrollY() - initialOffsetFromBottom)
			}
			return
		}

		if abs(width - lastWidth) >= 0.5 {
			lastWidth = width
			scheduleWidthFlush()
		}
		updateDistanceFromBottom()
	}

	private var contentWidth: CGFloat { max(0, scrollView?.contentSize.width ?? 0) }

	// MARK: Data

	func apply(
		messages new: [Message],
		liveText newLive: [UUID: String],
		forceScrollToBottom: Bool = false
	) {
		let oldIDs = messages.map(\.id)
		let newIDs = new.map(\.id)
		messages = new
		liveText = newLive

		// A reply that finished streaming and then got a user message under it will
		// never be compiled again; its layouts would otherwise sit there until the
		// next assistant turn displaced them.
		if let cached = streamingCacheID, cached != newIDs.last { discardStreamingCache() }

		guard isViewLoaded, didInitialLayout, contentWidth > 0 else { return }

		var shared = 0
		while shared < oldIDs.count, shared < newIDs.count, oldIDs[shared] == newIDs[shared] {
			shared += 1
		}

		// Anything other than "the prefix survived" — switching chats, deleting a
		// message — is rare enough that starting over is simpler than diffing.
		guard shared == oldIDs.count else {
			recompileAll(preservingAnchor: !isAtBottom)
			return
		}

		let wasAtBottom = isAtBottom

		// Streaming: usually exactly one row moved, and it's the last one.
		var didChange = false
		for index in 0 ..< shared {
			let message = new[index]
			let text = effectiveText(message)
			guard compiledText[message.id] != text else { continue }
			documentView.document.replace(at: index, with: compiled(message))
			compiledText[message.id] = text
			didChange = true
		}

		for index in shared ..< new.count {
			let message = new[index]
			documentView.document.append(compiled(message))
			compiledText[message.id] = effectiveText(message)
			didChange = true
		}

		guard didChange else { return }
		syncDocumentFrame()

		if wasAtBottom || forceScrollToBottom {
			scrollToBottom(animated: newIDs.count > oldIDs.count)
		}
	}

	func updateStyle(_ new: CompileStyle) {
		guard new != style else { return }
		let wasLayoutKey = style.layoutKey
		style = new
		// `didSet` on the document view marks it for redraw, which is the whole cost
		// of a chrome-only change: bubble fills, card backgrounds, rules and table
		// stripes are all looked up while painting.
		documentView.style = new

		// Math entries are keyed on the colour and size they were typeset at, so a
		// style change that moved either simply misses and typesets the new one —
		// flushing the cache here would only throw away the entries a change back
		// would have reused.
		guard style.layoutKey != wasLayoutKey else { return }
		guard didInitialLayout, contentWidth > 0 else { return }
		recompileAll(preservingAnchor: !isAtBottom)
	}

	func updateBottomInset(_ inset: CGFloat) {
		guard abs(inset - bottomInset) >= 0.5 else { return }
		let wasAtBottom = isAtBottom
		bottomInset = inset
		guard isViewLoaded else { return }
		scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)
		guard didInitialLayout else { return }
		if wasAtBottom { scrollToBottom() } else { setClipY(clip.bounds.origin.y) }
	}

	private func effectiveText(_ message: Message) -> String {
		liveText[message.id] ?? message.text
	}

	private func compiled(_ message: Message) -> CompiledMessage {
		// Only the last message is ever recompiled repeatedly, so it's the only one
		// worth carrying block layouts for — and holding more would double the
		// `CTLine` footprint of the whole transcript to speed up work that never
		// happens. Anything else compiles from scratch, exactly as before.
		guard message.id == messages.last?.id, message.role != "user" else {
			return MessageCompiler.compile(
				id: message.id,
				role: message.role,
				text: effectiveText(message),
				width: contentWidth,
				style: style
			)
		}

		if streamingCacheID != message.id {
			streamingCache = BlockLayoutCache()
			streamingCacheID = message.id
		}
		let started = Date()
		let compiled = MessageCompiler.compile(
			id: message.id,
			role: message.role,
			text: effectiveText(message),
			width: contentWidth,
			style: style,
			cache: &streamingCache
		)

		if RenderDebug.enabled {
			print(String(
				format: "[CR] tick: %d blocks reused, %d laid out, %.2f ms",
				streamingCache.hits, streamingCache.misses,
				Date().timeIntervalSince(started) * 1000
			))
		}
		return compiled
	}

	/// Drop the streaming cache.
	///
	/// Correctness doesn't depend on this — the cache keys on the column and checks
	/// the style's layout key, so a resize or a restyle simply misses. It's called
	/// on the paths that rebuild the document wholesale so the entries don't sit
	/// there holding a message's worth of `CTLine`s that nothing will ask for again.
	private func discardStreamingCache() {
		streamingCache = BlockLayoutCache()
		streamingCacheID = nil
	}

	// MARK: Compilation

	// MARK: Cross-conversation cache

	/// Adopt a previously compiled transcript, if one is still valid.
	///
	/// "Valid" is stricter than "present". A conversation can move while another is
	/// on screen — a reply finishes streaming, a message is deleted — and the style
	/// can change underneath both. So the ids, the text each row was compiled from,
	/// and the layout key all have to still agree; anything less and compiling again
	/// is the only correct answer.
	///
	/// A width mismatch is the one difference worth recovering from rather than
	/// discarding: reflowing costs about a tenth of a compile, so a transcript last
	/// seen at a different window size is still very much worth keeping.
	private func restoreFromCache(at width: CGFloat) -> Bool {
		guard let cached = CompiledDocumentCache.entry(for: conversationID) else { return false }
		guard cached.layoutKey == style.layoutKey else { return false }
		guard cached.document.count == messages.count else { return false }

		for (index, message) in messages.enumerated() {
			guard cached.document[index].id == message.id,
			      cached.compiledText[message.id] == effectiveText(message)
			else { return false }
		}

		documentView.document = cached.document
		compiledText = cached.compiledText

		let started = Date()
		let needsReflow = abs(cached.width - width) >= 0.5
		if needsReflow {
			reflowAll()
		} else {
			syncDocumentFrame()
		}

		if RenderDebug.enabled {
			print(String(
				format: "[CR] restored %d messages from cache in %.1f ms (%@)",
				messages.count,
				Date().timeIntervalSince(started) * 1000,
				needsReflow ? "reflowed to new width" : "width unchanged"
			))
		}
		return true
	}

	/// Hand the compiled transcript to the cache on the way out.
	func persistToCache() {
		let document = documentView.document
		guard !document.isEmpty else { return }
		CompiledDocumentCache.store(
			CompiledDocumentCache.Entry(
				document: document,
				compiledText: compiledText,
				layoutKey: style.layoutKey,
				width: document.width
			),
			for: conversationID
		)
	}

	private func recompileAll(preservingAnchor: Bool = false) {
		let width = contentWidth
		guard width > 0 else { return }

		let anchor = preservingAnchor ? captureAnchor() : nil
		let started = Date()

		var document = CompiledDocument(width: width)
		compiledText.removeAll(keepingCapacity: true)
		discardStreamingCache()
		for message in messages {
			document.append(compiled(message))
			compiledText[message.id] = effectiveText(message)
		}
		documentView.document = document
		syncDocumentFrame()

		if RenderDebug.enabled {
			let elapsed = Date().timeIntervalSince(started) * 1000
			let characters = messages.reduce(0) { $0 + effectiveText($1).count }
			print(String(
				format: "[CR] compiled %d messages / %d chars in %.1f ms at %.2f pt wide (%.0f pt tall)",
				messages.count, characters, elapsed, width, document.totalHeight
			))
		}

		if let anchor { restore(anchor) } else { scrollToBottom() }
	}

	/// Re-lay the document at the current width without recompiling it.
	///
	/// A resize is the one event that touches every message at once, so it's the
	/// one that most wants to avoid the compiler. Nothing about the *content* has
	/// changed: the markdown parses the same, the equations typeset the same, the
	/// table cells measure the same. Only wrapped text moves, and only `.text`

	private func reflowAll(preservingAnchor: Bool = false) {
		let width = contentWidth
		guard width > 0, !documentView.document.isEmpty else { return }

		let anchor = preservingAnchor ? captureAnchor() : nil
		let started = Date()

		// Every entry was laid out against the old column, so none of them can be
		// reused at the new one — keeping them would only delay the release.
		discardStreamingCache()

		let old = documentView.document
		var document = CompiledDocument(width: width)
		for index in 0 ..< old.count {
			document.append(MessageCompiler.reflow(old[index], to: width, style: style))
		}
		documentView.document = document
		syncDocumentFrame()

		if RenderDebug.enabled {
			let elapsed = Date().timeIntervalSince(started) * 1000
			print(String(
				format: "[CR] reflowed %d messages in %.1f ms at %.2f pt wide (%.0f pt tall)",
				document.count, elapsed, width, document.totalHeight
			))
		}

		if let anchor { restore(anchor) } else { scrollToBottom() }
	}

	private func scheduleWidthFlush() {
		widthFlush?.cancel()
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.reflowAll(preservingAnchor: !self.isAtBottom)
			}
		}
		widthFlush = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
	}

	private func syncDocumentFrame() {
		let size = NSSize(width: contentWidth, height: documentView.document.totalHeight)
		if documentView.frame.size != size {
			documentView.setFrameSize(size)
		}
		documentView.needsDisplay = true
		updateDistanceFromBottom()
	}

	// MARK: Scrolling

	private var isAtBottom: Bool { distanceFromBottom() <= bottomThreshold }

	private func distanceFromBottom() -> CGFloat {
		max(0, documentView.bounds.height + bottomInset - (clip.bounds.origin.y + clip.bounds.height))
	}

	private func updateDistanceFromBottom() {
		currentDistanceFromBottom = distanceFromBottom()
	}

	private func maxScrollY() -> CGFloat {
		max(0, documentView.bounds.height + bottomInset - clip.bounds.height)
	}

	private func setClipY(_ y: CGFloat, animated: Bool = false) {
		let target = NSPoint(x: clip.bounds.origin.x, y: min(max(0, y), maxScrollY()))
		guard animated else {
			clip.setBoundsOrigin(target)
			scrollView.reflectScrolledClipView(clip)
			updateDistanceFromBottom()
			return
		}
		NSAnimationContext.runAnimationGroup { context in
			context.duration = 0.22
			context.timingFunction = CAMediaTimingFunction(name: .easeOut)
			clip.animator().setBoundsOrigin(target)
		} completionHandler: { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.scrollView.reflectScrolledClipView(self.clip)
				self.updateDistanceFromBottom()
			}
		}
	}

	private func scrollToBottom(animated: Bool = false) {
		setClipY(maxScrollY(), animated: animated)
	}

	private struct Anchor {
		let id: UUID
		let offsetWithin: CGFloat
	}

	/// Hold the topmost visible message still across a recompile.
	///
	/// Anchored by id rather than index so it survives a document that changed
	/// length, and by offset-within-row so a row that got taller doesn't jump.
	private func captureAnchor() -> Anchor? {
		let document = documentView.document
		guard !document.isEmpty else { return nil }
		let top = clip.bounds.origin.y
		let index = min(document.firstIndex(endingAtOrAfter: top), document.count - 1)
		return Anchor(id: document[index].id, offsetWithin: top - document.top(of: index))
	}

	private func restore(_ anchor: Anchor) {
		let document = documentView.document
		guard let index = (0 ..< document.count).first(where: { document[$0].id == anchor.id })
		else { return }
		setClipY(document.top(of: index) + anchor.offsetWithin)
	}
}
