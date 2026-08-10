//
//  VirtualizedMessageList.swift
//  ChatCore
//

import SwiftUI
import AppKit

// MARK: - SwiftUI entry point

struct VirtualizedMessageList: TranscriptRendering {
	@Environment(ModelManager.self) private var manager
	@Environment(ThemeManager.self) private var themes
	var messages: [Message]
	@Binding var scrollOffsetFromBottom: Double
	var scrollToBottomToken: Int = 0
	var bottomInset: CGFloat = 0

	/// `conversationID` goes unused: nothing here outlives the view, so there is
	/// no cache for it to name. Switching chats is a `reloadData` either way.
	init(_ context: TranscriptContext) {
		self.messages = context.messages
		self._scrollOffsetFromBottom = context.scrollOffsetFromBottom
		self.scrollToBottomToken = context.scrollToBottomToken
		self.bottomInset = context.bottomInset
	}

	var body: some View {
		MessageTableView(
			messages: messages,
			liveText: manager.liveText,
			initialOffsetFromBottom: scrollOffsetFromBottom,
			manager: manager,
			themes: themes,
			appearance: themes.appearance,
			offset: $scrollOffsetFromBottom,
			scrollToBottomToken: scrollToBottomToken,
			bottomInset: bottomInset
		)
	}
}

// MARK: - Representable

private struct MessageTableView: NSViewControllerRepresentable {
	var messages: [Message]
	var liveText: [UUID: String]
	var initialOffsetFromBottom: Double
	var manager: ModelManager
	var themes: ThemeManager
	var appearance: ChatAppearance
	var offset: Binding<Double>
	var scrollToBottomToken: Int
	var bottomInset: CGFloat

	func makeCoordinator() -> Coordinator { Coordinator(offset: offset) }

	func makeNSViewController(context: Context) -> MessageListViewController {
		let vc = MessageListViewController(
			manager: manager,
			themes: themes,
			appearance: appearance,
			initialOffsetFromBottom: CGFloat(initialOffsetFromBottom),
			bottomInset: bottomInset
		)
		context.coordinator.controller = vc
		context.coordinator.lastScrollToken = scrollToBottomToken
		context.coordinator.lastAppearance = appearance
		vc.apply(messages: messages, liveText: liveText)
		return vc
	}

	func updateNSViewController(_ vc: MessageListViewController, context: Context) {
		if context.coordinator.lastAppearance != appearance {
			context.coordinator.lastAppearance = appearance
			vc.updateAppearance(appearance)
		}
		vc.updateBottomInset(bottomInset)
		let forced = context.coordinator.consumeScrollRequest(scrollToBottomToken)
		vc.apply(messages: messages, liveText: liveText, forceScrollToBottom: forced)
	}

	static func dismantleNSViewController(_ vc: MessageListViewController, coordinator: Coordinator) {
		coordinator.offset.wrappedValue = Double(vc.currentDistanceFromBottom)
	}

	@MainActor
	final class Coordinator {
		let offset: Binding<Double>
		weak var controller: MessageListViewController?
		var lastScrollToken = 0
		var lastAppearance = ChatAppearance.default
		init(offset: Binding<Double>) { self.offset = offset }

		func consumeScrollRequest(_ token: Int) -> Bool {
			guard token != lastScrollToken else { return false }
			lastScrollToken = token
			return true
		}
	}
}

// MARK: - Row geometry

/// The gap between a bubble and the edges of its row.
///
/// Read by the row's own view and by the estimator that has to predict the row's
/// height before that view exists, so the two can't drift apart.
private enum RowInsets {
	static let leading: CGFloat = 16
	static let trailing: CGFloat = 26
	static let vertical: CGFloat = 6
}

// MARK: - Row root

/// The root SwiftUI view of a row, hosted by the display cell and by the
/// offscreen measurer alike.
///
/// A concrete type rather than an `AnyView`: handing a hosting view a fresh
/// `AnyView` leaves SwiftUI nothing to diff against, so every cell coming back
/// off the reuse queue rebuilt its whole subtree instead of updating it. The
/// `.id(message.id)` stays on the inside — that is what resets `MessageBubble`'s
/// hover and copied state when a recycled cell takes a different message.
private struct BubbleRoot: View {
	var message: Message?
	var manager: ModelManager
	var themes: ThemeManager

	/// Set only by the measurer, which has to pin a width before it can ask for
	/// a fitting height. A cell takes its width from the column instead.
	var width: CGFloat?

	var body: some View {
		if let message {
			MessageBubble(message: message)
				.id(message.id)
				.padding(.leading, RowInsets.leading)
				.padding(.trailing, RowInsets.trailing)
				.padding(.vertical, RowInsets.vertical)
				.textSelection(.enabled)
				.environment(manager)
				.environment(themes)
				.frame(width: width)
		}
	}
}

// MARK: - Controller

@MainActor
final class MessageListViewController: NSViewController {

	private let bottomThreshold: CGFloat = 80
	private static let cellID = NSUserInterfaceItemIdentifier("BubbleCell")

	private let manager: ModelManager
	private let themes: ThemeManager
	private let initialOffsetFromBottom: CGFloat

	/// The appearance the cached heights were measured against.
	///
	/// Held here rather than read from `ThemeManager` where it's needed:
	/// `appearance` is a computed property that rebuilds itself out of four font
	/// catalog scans, and `estimatedHeight` runs once per row on every full
	/// height pass.
	private var appearance: ChatAppearance

	private var bottomInset: CGFloat

	private(set) var messages: [Message] = []
	private var liveText: [UUID: String] = [:]

	private(set) var currentDistanceFromBottom: CGFloat = 0

	private enum RowRenderMode { case markdown, streamingPlain }

	private struct HeightEntry {
		var width: CGFloat
		var text: String
		var mode: RowRenderMode
		var height: CGFloat
	}
	private var heightCache: [UUID: HeightEntry] = [:]

	/// `MathMarkdown.preprocess` rewritten per message, kept for as long as the
	/// message text stands still. The estimator needs the rewritten form to walk
	/// it, and it runs for every row on every full height pass.
	private var estimateSourceCache: [UUID: (raw: String, source: String)] = [:]

	/// Kept for the life of the controller and re-pointed at each row it measures,
	/// so SwiftUI updates one graph rather than building and discarding one per
	/// measurement.
	private let measureHost: NSHostingView<BubbleRoot>

	private var scrollView: NSScrollView!
	private var tableView: NSTableView!
	private var column: NSTableColumn!
	private var clip: NSClipView { scrollView.contentView }

	private var lastLayoutWidth: CGFloat = 0
	private var didInitialScroll = false

	private var pendingCorrections = IndexSet()
	private var flushScheduled = false

	private var widthFlushWork: DispatchWorkItem?
	private var lastFlushedWidth: CGFloat = 0

	private var lastStreamingMeasureAt: [UUID: Date] = [:]

	private var isAnimatingScroll = false

	/// Set across our own writes to the clip origin, so the bounds observer can
	/// tell a move we made from one the user's gesture made.
	private var isWritingClipOrigin = false

	private var isLiveScrolling = false

	/// When the clip origin last moved on its own — i.e. not from a write of ours.
	///
	/// Momentum has no notification to observe and `NSApp.currentEvent` is only
	/// the event *being dispatched*, so reading it from a timer callback — which
	/// is exactly where the deferral asks — sees whatever event happened to run
	/// last, not the momentum still in flight. The origin moving is the one
	/// signal that is true for the whole of a momentum phase.
	private var lastPassiveOriginMoveAt: TimeInterval = 0

	/// How long after the last unattributed origin move to keep treating the
	/// scroll as in flight. Momentum posts bounds changes every frame, so one
	/// missed frame at 60Hz is well inside this.
	private static let momentumIdleWindow: TimeInterval = 0.12

	private var isInMomentum: Bool {
		CACurrentMediaTime() - lastPassiveOriginMoveAt < Self.momentumIdleWindow
	}

	private var scrollPhase: ScrollPhase {
		if isAnimatingScroll { return .animating }
		if isLiveScrolling { return .live }
		if isInMomentum { return .momentum }
		return .idle
	}

	/// Whether the user is driving the scroll right now, by hand or by momentum.
	///
	/// These are the phases where a write to the clip origin is a fight: AppKit
	/// recomputes the origin from the gesture on the next event and whatever we
	/// wrote is gone by the time it would have been drawn.
	private var isScrolling: Bool {
		let phase = scrollPhase
		return phase == .live || phase == .momentum
	}

	nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
	nonisolated(unsafe) private var liveScrollObserver: NSObjectProtocol?
	nonisolated(unsafe) private var endLiveScrollObserver: NSObjectProtocol?

	init(
		manager: ModelManager,
		themes: ThemeManager,
		appearance: ChatAppearance,
		initialOffsetFromBottom: CGFloat,
		bottomInset: CGFloat
	) {
		self.manager = manager
		self.themes = themes
		self.appearance = appearance
		self.initialOffsetFromBottom = initialOffsetFromBottom
		self.bottomInset = bottomInset
		self.measureHost = NSHostingView(
			rootView: BubbleRoot(message: nil, manager: manager, themes: themes)
		)
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

	func updateAppearance(_ new: ChatAppearance) {
		guard new != appearance else { return }
		appearance = new
		invalidateAllHeights()
	}

	deinit {
		if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
		if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
		if let endLiveScrollObserver { NotificationCenter.default.removeObserver(endLiveScrollObserver) }
	}

	// MARK: View construction

	override func loadView() {
		let table = BufferedTableView()
		table.style = .plain
		table.headerView = nil
		table.backgroundColor = .clear
		table.selectionHighlightStyle = .none
		table.allowsColumnResizing = false
		table.allowsColumnReordering = false
		table.intercellSpacing = .zero
		table.usesAutomaticRowHeights = false
		table.gridStyleMask = []

		let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bubble"))
		col.resizingMask = .autoresizingMask
		table.addTableColumn(col)
		table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
		self.tableView = table
		self.column = col

		let scroll = OverlayScrollView()
		scroll.hasHorizontalScroller = false
		LazyScroller.install(on: scroll)
		scroll.drawsBackground = false
		scroll.backgroundColor = .clear
		scroll.automaticallyAdjustsContentInsets = false
		scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
		self.scrollView = scroll
		scroll.documentView = table

		table.delegate = self
		table.dataSource = self

		self.view = scroll
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
				guard let self else { return }
				if !self.isWritingClipOrigin, !self.isAnimatingScroll {
					self.lastPassiveOriginMoveAt = CACurrentMediaTime()
				}
				self.updateDistanceFromBottom()
				if ListMetrics.enabled {
					ListMetrics.observedOrigin(self.clip.bounds.origin.y, phase: self.scrollPhase)
				}
				if self.isAnimatingScroll {
					self.scrollView.reflectScrolledClipView(self.clip)
				}
			}
		}
		liveScrollObserver = NotificationCenter.default.addObserver(
			forName: NSScrollView.willStartLiveScrollNotification,
			object: scrollView,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.isLiveScrolling = true
				self.cancelScrollAnimation()
			}
		}
		endLiveScrollObserver = NotificationCenter.default.addObserver(
			forName: NSScrollView.didEndLiveScrollNotification,
			object: scrollView,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.isLiveScrolling = false
				// This fires when the fingers lift, which on a flick is the moment
				// *before* momentum starts, not after it ends. Go through the
				// deferral so a momentum phase gets a chance to declare itself —
				// flushing straight into it put a full SwiftUI layout of every
				// visible bubble on the first frames of the coast.
				if !self.pendingCorrections.isEmpty {
					self.deferHeightCorrections(IndexSet())
				}
				ListMetrics.summarize()
			}
		}
		tableView.reloadData()
	}

	override func viewDidLayout() {
		super.viewDidLayout()
		let width = columnWidth
		if column.width != width { column.width = width }

		if width != lastLayoutWidth {
			let hadWidth = lastLayoutWidth != 0
			lastLayoutWidth = width
			ListMetrics.widthSample(width)
			if !hadWidth {
				lastFlushedWidth = width
			} else if width > 0, abs(width - lastFlushedWidth) >= 0.5 {
				scheduleWidthFlush()
			}
		}

		if !didInitialScroll, tableView.numberOfRows > 0, width > 0 {
			didInitialScroll = true
			performInitialScroll()
		}
		updateDistanceFromBottom()
	}

	// MARK: Data application (diffing)

	func apply(messages new: [Message], liveText newLive: [UUID: String], forceScrollToBottom: Bool = false) {
		guard isViewLoaded else {
			messages = new
			liveText = newLive
			return
		}

		let oldIDs = messages.map(\.id)
		let newIDs = new.map(\.id)
		let prevCache = heightCache

		if oldIDs == newIDs {
			messages = new
			liveText = newLive
			var changed = IndexSet()
			let nowStamp = Date()
			for (i, m) in new.enumerated() {
				guard let prev = prevCache[m.id],
				      prev.text != effectiveText(m) || prev.mode != renderMode(m)
				else { continue }
				if newLive[m.id] != nil {
					if let last = lastStreamingMeasureAt[m.id],
					   nowStamp.timeIntervalSince(last) < 0.1 { continue }
					lastStreamingMeasureAt[m.id] = nowStamp
				} else {
					lastStreamingMeasureAt.removeValue(forKey: m.id)
				}
				changed.insert(i)
			}
			if !changed.isEmpty { refreshHeights(for: changed) }
			return
		}

		if newIDs.count > oldIDs.count, Array(newIDs.prefix(oldIDs.count)) == oldIDs {
			let wasAtBottom = isAtBottom
			messages = new
			liveText = newLive
			let inserted = IndexSet(oldIDs.count ..< newIDs.count)
			tableView.beginUpdates()
			tableView.insertRows(at: inserted, withAnimation: [])
			tableView.endUpdates()
			if wasAtBottom || forceScrollToBottom { scrollToBottom(animated: true) }
			return
		}

		// A wholesale replacement — switching chats — shares no rows with what
		// was on screen, so a captured anchor names an arbitrary row of the
		// incoming conversation. There is nothing to hold still: land at the
		// bottom rather than at a row index that meant something else.
		let replacesEverything = Set(oldIDs).isDisjoint(with: newIDs)
		let wasAtBottom = isAtBottom
		let anchor = (wasAtBottom || replacesEverything) ? nil : captureTopAnchor()
		messages = new
		liveText = newLive
		heightCache.removeAll()
		estimateSourceCache.removeAll()
		lastStreamingMeasureAt.removeAll()
		pendingCorrections = IndexSet()
		tableView.reloadData()

		// `reloadData` just discarded every exact height, and `estimatedHeight`
		// is only ever a guess. Without measuring first, the frame this scroll
		// lands on is built entirely out of guesses and then collapses onto the
		// real heights a runloop later, once `correctHeightIfNeeded` catches up
		// row by row. That collapse is the settle you see on a chat swap.
		if let anchor {
			premeasureViewport(min(anchor.row, max(0, new.count - 1)) ..< new.count)
		} else {
			premeasureViewport((0 ..< new.count).reversed())
		}

		withoutAnimation {
			if let anchor { restore(anchor) }
			else { scrollToBottom() }
		}
		view.needsLayout = true
	}

	// MARK: Heights

	private func withoutAnimation(_ body: () -> Void) {
		NSAnimationContext.runAnimationGroup { ctx in
			ctx.duration = 0
			ctx.allowsImplicitAnimation = false
			body()
		}
	}

	private var columnWidth: CGFloat { max(0, scrollView?.contentSize.width ?? 0) }

	private func effectiveText(_ m: Message) -> String { liveText[m.id] ?? m.text }

	private func renderMode(_ m: Message) -> RowRenderMode {
		guard liveText[m.id] != nil,
		      !(manager.liveChunks[m.id] ?? []).isEmpty,
		      StreamingMode(rawValue: UserDefaults.standard.string(forKey: Defaults.Key.streamingMode) ?? "") == .token
		else { return .markdown }
		return .streamingPlain
	}

	private func height(for row: Int) -> CGFloat {
		let m = messages[row]
		let w = columnWidth
		if let e = heightCache[m.id], e.width == w, e.text == effectiveText(m), e.mode == renderMode(m) {
			return e.height
		}
		return estimatedHeight(m, width: w)
	}

	@discardableResult
	private func measureExact(row: Int) -> CGFloat {
		let m = messages[row]
		let w = columnWidth
		guard w > 0 else { return estimatedHeight(m, width: w) }
		measureHost.rootView = rootView(for: m, width: w)
		measureHost.layoutSubtreeIfNeeded()
		let h = measureHost.fittingSize.height
		// Deliberately left holding the last bubble measured. Swapping in an
		// empty root afterwards tore the graph down a second time for nothing —
		// the next measurement re-points it either way.
		heightCache[m.id] = HeightEntry(width: w, text: effectiveText(m), mode: renderMode(m), height: h)
		return h
	}

	private func hasExactHeight(_ m: Message) -> Bool {
		guard let e = heightCache[m.id] else { return false }
		return e.width == columnWidth && e.text == effectiveText(m) && e.mode == renderMode(m)
	}

	private let chipRowHeight: CGFloat = 72

	/// A first guess at a row's height, refined by `measureExact` once the row
	/// is actually built.
	///
	/// Whatever gap is left between the two is what the user watches settle, so
	/// this has to model *rendered* markdown rather than wrapped plain text.
	/// Three things the plain-text reading gets badly wrong:
	///
	/// - Fenced code and table rows scroll horizontally inside
	///   `HorizontalScrollBox`. They never wrap, however long the source line
	///   is, so wrapping them inflates a 17pt code line into 60pt of guess.
	/// - Markup characters (fences, pipe rules, `#`, `**`) are counted as text
	///   they are not, while headings and math render far taller than one line.
	/// - Every bubble reserves `ChatBubbleMetrics.copyButtonHeight` for a
	///   hover-only button that `opacity` hides but does not remove.
	private func estimatedHeight(_ m: Message, width: CGFloat) -> CGFloat {
		let text = effectiveText(m)
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return m.attachments.isEmpty ? 1 : chipRowHeight + 2 * RowInsets.vertical
		}

		let a = appearance
		let isAssistant = m.role != "user"

		let usable = max(
			40,
			width
				- RowInsets.leading
				- RowInsets.trailing
				- 2 * ChatBubbleMetrics.horizontalPadding(assistant: isAssistant)
				- ChatBubbleMetrics.trailingGutter
		)

		var height = 2 * RowInsets.vertical
			+ 2 * ChatBubbleMetrics.verticalPadding(assistant: isAssistant)
			+ ChatBubbleMetrics.copyButtonHeight
			+ (isAssistant ? 2 * ChatBubbleMetrics.assistantColumnPadding : 0)

		if !m.attachments.isEmpty {
			height += chipRowHeight + ChatBubbleMetrics.attachmentSpacing
		}

		let lineSpacing = CGFloat(a.lineSpacing)
		let lineBox = CGFloat(a.fontSize) * Self.lineHeightRatio
		let bodyChars = max(1, usable / (CGFloat(a.fontSize) * Self.averageCharRatio))

		/// A run of `lines` stacked text lines. `lineSpacing` sits *between*
		/// lines, so a single line doesn't pay for it.
		func textRun(_ lines: CGFloat, box: CGFloat) -> CGFloat {
			lines * box + max(0, lines - 1) * lineSpacing
		}

		// A user bubble is a plain `Text` — wrapped source really is what renders.
		guard isAssistant else {
			return height + textRun(Self.wrappedLines(text, charsPerLine: bodyChars), box: lineBox)
		}

		let blockGap = CGFloat(ChatMarkdownMetrics.blockGap) + lineSpacing
		let codeLine = CGFloat(a.codeFontSize) * Self.lineHeightRatio
		let tableRow = CGFloat(a.tableFontSize) * Self.lineHeightRatio + 2 * Self.tableCellPadding
		let tableChars = max(1, usable / (CGFloat(a.tableFontSize) * Self.averageCharRatio))
		let mathBlock = CGFloat(a.equationFontSize) * Self.mathDisplayRatio + 2 * Self.mathPadding

		// The renderer folds `$$…$$` into a fenced `math` block before parsing,
		// so walking the same rewrite means one state machine covers both.
		let source = estimateSource(for: m, text: text, rendersMath: a.rendersMath)

		// Block margins collapse the way CSS margins do — adjacent blocks are
		// separated by the larger of the two, not their sum — and the last block
		// emits no trailing margin at all. Summing them instead was worth a
		// spurious 10pt at every block boundary.
		var pendingMargin: CGFloat = 0
		var emittedBlock = false

		func emit(_ blockHeight: CGFloat, top: CGFloat, bottom: CGFloat) {
			if emittedBlock { height += max(pendingMargin, top) }
			height += blockHeight
			pendingMargin = bottom
			emittedBlock = true
		}

		var fence: String?
		var fenceIsMath = false
		var fenceLines: CGFloat = 0

		var textLines: CGFloat = 0
		var textIsList = false
		var tableRows: CGFloat = 0

		func flushText() {
			guard textLines > 0 else { return }
			emit(textRun(textLines, box: lineBox), top: 0, bottom: blockGap)
			textLines = 0
		}

		func flushTable() {
			guard tableRows > 0 else { return }
			emit(tableRows * tableRow, top: Self.tableMargin, bottom: Self.tableMargin)
			tableRows = 0
		}

		func flushFence() {
			guard fence != nil else { return }
			emit(
				fenceIsMath
					? mathBlock
					: max(1, fenceLines) * codeLine + 2 * Self.codeCardPadding,
				top: blockGap,
				bottom: blockGap
			)
			fence = nil
			fenceIsMath = false
			fenceLines = 0
		}

		func flushBlocks() {
			flushText()
			flushTable()
		}

		for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
			let line = raw.drop { $0 == " " || $0 == "\t" }

			if let open = fence {
				if line.hasPrefix(open) { flushFence() } else { fenceLines += 1 }
				continue
			}

			// A table row lays out as a row of cells; the `|---|---|` rule draws
			// a border and takes no height of its own.
			if line.hasPrefix("|") {
				flushText()
				if !Self.isTableRule(line) {
					tableRows += Self.wrappedLines(line, charsPerLine: tableChars)
				}
				continue
			}
			flushTable()

			if let opener = Self.openingFence(line) {
				flushText()
				fence = opener
				fenceIsMath = line.dropFirst(opener.count)
					.trimmingCharacters(in: .whitespaces) == MathMarkdown.language
				continue
			}

			if line.isEmpty {
				flushText()
				continue
			}

			if let level = Self.headingLevel(line) {
				flushText()
				emit(
					CGFloat(a.headingSize(level)) * Self.lineHeightRatio,
					top: lineSpacing + 10,
					bottom: max(2, 10 - CGFloat(level))
				)
				continue
			}

			if Self.isThematicBreak(line) {
				flushText()
				emit(1, top: blockGap, bottom: blockGap)
				continue
			}

			// A list's per-item margin is the same `lineSpacing` that separates
			// wrapped lines, so items and paragraph lines stack identically —
			// only the switch between the two kinds starts a new block.
			let isList = Self.isListItem(line)
			if isList != textIsList { flushText() }
			textIsList = isList
			textLines += Self.wrappedLines(line, charsPerLine: bodyChars)
		}

		flushFence()
		flushBlocks()
		return height
	}

	/// The text `estimatedHeight` walks, with `$$…$$` already folded into fenced
	/// math blocks.
	///
	/// The rewrite is over the whole message and the estimate runs per row, so
	/// the result is held until the message text moves. A streaming row misses
	/// every flush by definition; every other row hits.
	private func estimateSource(for m: Message, text: String, rendersMath: Bool) -> String {
		guard rendersMath else { return text }
		if let cached = estimateSourceCache[m.id], cached.raw == text { return cached.source }
		let source = MathMarkdown.preprocess(text)
		estimateSourceCache[m.id] = (text, source)
		return source
	}

	// MARK: Estimation constants

	/// Line box as a multiple of point size.
	///
	/// Measured off `NSFont.systemFont` and `.monospacedSystemFont`, which both
	/// hold this ratio flat from 11pt to 24pt — the whole range the appearance
	/// sliders can reach.
	private static let lineHeightRatio: CGFloat = 1.178

	/// Average glyph advance as a multiple of point size.
	private static let averageCharRatio: CGFloat = 0.5

	/// Display-mode math runs taller than its point size; enough for a fraction.
	private static let mathDisplayRatio: CGFloat = 2.2

	private static let codeCardPadding: CGFloat = 16
	private static let mathPadding: CGFloat = 10
	private static let tableCellPadding: CGFloat = 7
	private static let tableMargin: CGFloat = 8

	/// Rendered lines one source line occupies once wrapped.
	///
	/// `SoftBreakMarkdown` gives every source line a hard break, so each wraps
	/// on its own rather than reflowing into its neighbours.
	private static func wrappedLines(_ line: some StringProtocol, charsPerLine: CGFloat) -> CGFloat {
		max(1, (CGFloat(line.count) / charsPerLine).rounded(.up))
	}

	private static func openingFence(_ trimmed: Substring) -> String? {
		for marker: Character in ["`", "~"] {
			let run = trimmed.prefix { $0 == marker }
			if run.count >= 3 { return String(run) }
		}
		return nil
	}

	private static func headingLevel(_ trimmed: Substring) -> Int? {
		let hashes = trimmed.prefix { $0 == "#" }.count
		guard (1 ... 6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
		return hashes
	}

	private static func isTableRule(_ trimmed: Substring) -> Bool {
		trimmed.allSatisfy { "|-: \t".contains($0) }
	}

	private static func isThematicBreak(_ trimmed: Substring) -> Bool {
		let stripped = trimmed.filter { $0 != " " && $0 != "\t" }
		guard stripped.count >= 3 else { return false }
		return ["-", "*", "_"].contains { marker in stripped.allSatisfy { $0 == Character(marker) } }
	}

	private static func isListItem(_ trimmed: Substring) -> Bool {
		if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
			return true
		}
		let digits = trimmed.prefix(while: \.isNumber)
		guard !digits.isEmpty else { return false }
		let after = trimmed.dropFirst(digits.count)
		return (after.first == "." || after.first == ")") && after.dropFirst().first == " "
	}

	private func refreshHeights(for rows: IndexSet) {
		let wasAtBottom = isAtBottom
		for r in rows { measureExact(row: r) }
		let anchor = wasAtBottom ? nil : captureAnchor(changedRows: rows)
		withoutAnimation {
			tableView.noteHeightOfRows(withIndexesChanged: rows)
			if wasAtBottom { scrollToBottom() }
			else if let anchor { restore(anchor) }
		}
	}

	// MARK: Correction on appear (estimate → exact, absorbed off-screen)

	private func correctHeightIfNeeded(row: Int) {
		guard row >= 0, row < messages.count else { return }
		let m = messages[row]
		if hasExactHeight(m) { return }

		// Nothing about a row's height gets touched while a gesture is in flight.
		// Measuring is a full SwiftUI layout of the bubble, and every row crossing
		// the prepared rect wants one — that cost lands on the scroll's critical
		// path. Landing the result is worse: a noted height changes the document
		// height, and a document height that moves under a live scroll makes the
		// scroll view recompute its content size on every frame of the gesture,
		// which drags the toolbar's scroll edge effect along with it.
		guard !isScrolling else {
			deferHeightCorrections(IndexSet(integer: row))
			return
		}

		let used = height(for: row)
		let exact = measureExact(row: row)
		if ListMetrics.enabled {
			let text = effectiveText(m)
			ListMetrics.rowSample(ListMetrics.RowSample(
				role: m.role,
				measured: exact,
				estimated: used,
				hasCode: text.contains("```"),
				hasTable: text.contains("|"),
				hasMath: MathMarkdown.blockCount(in: text) > 0,
				sourceLines: text.split(separator: "\n", omittingEmptySubsequences: false).count,
				chars: text.count
			))
		}
		if abs(exact - used) > 0.5 {
			pendingCorrections.insert(row)
			scheduleHeightFlush()
		}
	}

	private func scheduleHeightFlush() {
		guard !flushScheduled else { return }
		flushScheduled = true
		DispatchQueue.main.async { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.flushScheduled = false
				self.flushHeightCorrections()
			}
		}
	}

	/// How long to sit on a correction that arrived mid-gesture before looking
	/// again. There is no "momentum ended" notification to wait on, so the
	/// deferral re-arms itself until the scroll settles.
	private static let scrollSettleRetry: TimeInterval = 0.05

	private func deferHeightCorrections(_ rows: IndexSet) {
		pendingCorrections.formUnion(rows)
		guard !flushScheduled else { return }
		flushScheduled = true
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollSettleRetry) { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.flushScheduled = false
				self.flushHeightCorrections()
			}
		}
	}

	/// Land the heights `correctHeightIfNeeded` has queued.
	///
	/// Every correction waits for the gesture to settle, wherever its row sits.
	/// A row above the viewport moves everything on screen by its delta, and
	/// cancelling that shift means writing the clip origin — which mid-gesture
	/// AppKit overwrites from the scroll on the very next event, so the shift is
	/// what the user actually sees. A row below the fold disturbs no pixel of its
	/// own, but noting it still moves the document height, and the scroll view
	/// re-derives its content size from that — once per frame, for the whole
	/// gesture, with the toolbar's glass edge effect recomposited each time.
	private func flushHeightCorrections() {
		// A correction queued before a reload names a row of the conversation that
		// was on screen then, not the one on screen now.
		let rows = pendingCorrections.intersection(IndexSet(integersIn: 0 ..< tableView.numberOfRows))
		pendingCorrections = IndexSet()
		guard !rows.isEmpty else { return }

		guard !isScrolling else {
			deferHeightCorrections(rows)
			return
		}

		// Rows queued mid-gesture never got measured — keeping that layout off the
		// scroll's critical path was the point. Settle up now, but only for what
		// is on screen: a gesture that crosses the whole transcript queues
		// hundreds of rows, and measuring every one of them here would trade a
		// stuttering scroll for a frozen one. The rest carry their estimate until
		// they come back into view and re-queue themselves.
		let onScreen = IndexSet(visibleRowIndexes())
		for row in rows.intersection(onScreen) where !hasExactHeight(messages[row]) {
			measureExact(row: row)
		}

		// Noting a row whose height is still a guess re-tiles the table for
		// nothing, so only the ones holding a real measurement land.
		let landing = IndexSet(rows.filter { hasExactHeight(messages[$0]) })
		guard !landing.isEmpty else { return }

		let wasAtBottom = isAtBottom
		let anchor = wasAtBottom ? nil : captureAnchor(changedRows: landing)
		withoutAnimation {
			tableView.noteHeightOfRows(withIndexesChanged: landing)
			if wasAtBottom { scrollToBottom() }
			else if let anchor { restore(anchor) }
		}
	}

	// MARK: Scroll math (clip view)

	private var isAtBottom: Bool { distanceFromBottom() <= bottomThreshold }

	private func distanceFromBottom() -> CGFloat {
		max(0, tableView.bounds.height + bottomInset - (clip.bounds.origin.y + clip.bounds.height))
	}

	private func updateDistanceFromBottom() {
		currentDistanceFromBottom = distanceFromBottom()
	}

	private func maxScrollY() -> CGFloat {
		max(0, tableView.bounds.height + bottomInset - clip.bounds.height)
	}

	func updateBottomInset(_ inset: CGFloat) {
		guard abs(inset - bottomInset) >= 0.5 else { return }
		guard isViewLoaded else {
			bottomInset = inset
			return
		}
		let wasAtBottom = isAtBottom
		bottomInset = inset
		scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: inset, right: 0)

		guard didInitialScroll else { return }

		if wasAtBottom {
			withoutAnimation { scrollToBottom() }
		} else {
			withoutAnimation { setClipY(clip.bounds.origin.y) }
		}
	}

	private func setClipY(_ y: CGFloat, animated: Bool = false, source: String = #function) {
		let clamped = min(max(0, y), maxScrollY())
		let target = NSPoint(x: clip.bounds.origin.x, y: clamped)
		if ListMetrics.enabled {
			ListMetrics.clipWrite(
				source: source,
				requested: y,
				clamped: clamped,
				before: clip.bounds.origin.y,
				maxY: maxScrollY(),
				phase: scrollPhase
			)
		}

		guard animated else {
			cancelScrollAnimation()
			isWritingClipOrigin = true
			clip.setBoundsOrigin(target)
			isWritingClipOrigin = false
			scrollView.reflectScrolledClipView(clip)
			updateDistanceFromBottom()
			return
		}

		isAnimatingScroll = true
		NSAnimationContext.runAnimationGroup { ctx in
			ctx.duration = 0.22
			ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
			clip.animator().setBoundsOrigin(target)
		} completionHandler: { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.isAnimatingScroll = false
				self.scrollView.reflectScrolledClipView(self.clip)
				self.updateDistanceFromBottom()
			}
		}
	}

	private func cancelScrollAnimation() {
		guard isAnimatingScroll else { return }
		isAnimatingScroll = false
		NSAnimationContext.runAnimationGroup { ctx in
			ctx.duration = 0
			ctx.allowsImplicitAnimation = false
			clip.animator().setBoundsOrigin(clip.bounds.origin)
		}
	}

	private func scrollToBottom(animated: Bool = false) {
		setClipY(maxScrollY(), animated: animated)
	}

	private struct TopAnchor { let row: Int; let offsetWithin: CGFloat }

	private func captureTopAnchor() -> TopAnchor? {
		let visibleTop = clip.bounds.origin.y
		var row = tableView.row(at: NSPoint(x: 2, y: visibleTop + 1))
		if row < 0 { row = tableView.numberOfRows > 0 ? 0 : -1 }
		guard row >= 0 else { return nil }
		let rect = tableView.rect(ofRow: row)
		return TopAnchor(row: row, offsetWithin: visibleTop - rect.minY)
	}

	private func restore(_ anchor: TopAnchor) {
		guard anchor.row >= 0, anchor.row < tableView.numberOfRows else { return }
		let rect = tableView.rect(ofRow: anchor.row)
		setClipY(rect.minY + anchor.offsetWithin)
	}

	private func captureAnchor(changedRows: IndexSet) -> TopAnchor? {
		let visible = visibleRowIndexes()
		guard
			let top = visible.first,
			let maxChanged = changedRows.max(),
			changedRows.contains(where: { $0 <= top })
		else { return captureTopAnchor() }
		let anchorRow = visible.first(where: { $0 > maxChanged }) ?? visible.last ?? top
		let rect = tableView.rect(ofRow: anchorRow)
		return TopAnchor(row: anchorRow, offsetWithin: clip.bounds.origin.y - rect.minY)
	}

	// MARK: Width change & initial position

	private func scheduleWidthFlush() {
		widthFlushWork?.cancel()
		let work = DispatchWorkItem { [weak self] in
			MainActor.assumeIsolated {
				guard let self else { return }
				self.performWidthFlush()
			}
		}
		widthFlushWork = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
	}

	private func invalidateAllHeights() {
		guard columnWidth > 0, !messages.isEmpty else {
			heightCache.removeAll()
			return
		}
		let wasAtBottom = isAtBottom
		let anchor = wasAtBottom ? nil : captureTopAnchor()
		heightCache.removeAll()
		lastStreamingMeasureAt.removeAll()
		for r in visibleRowIndexes() { measureExact(row: r) }
		withoutAnimation {
			tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0 ..< messages.count))
			if wasAtBottom { scrollToBottom() }
			else if let anchor { restore(anchor) }
		}
	}

	private func performWidthFlush() {
		let width = columnWidth
		lastFlushedWidth = width
		guard width > 0, !messages.isEmpty else { return }
		let wasAtBottom = isAtBottom
		let anchor = wasAtBottom ? nil : captureTopAnchor()
		let docBefore = tableView.bounds.height
		let discarded = heightCache.count
		heightCache.removeAll()
		let visible = visibleRowIndexes()
		for r in visible { measureExact(row: r) }
		withoutAnimation {
			tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0 ..< messages.count))
			if wasAtBottom { scrollToBottom() }
			else if let anchor { restore(anchor) }
		}
		ListMetrics.widthFlush(
			width: width,
			docBefore: docBefore,
			docAfter: tableView.bounds.height,
			measured: visible.count,
			reused: 0,
			rows: messages.count
		)
		if ListMetrics.enabled, discarded > 0 {
			print("[LM] Q4 discarded \(discarded) exact heights on a width change")
		}
	}

	private func performInitialScroll() {
		premeasureViewport(
			(0 ..< messages.count).reversed(),
			offsetFromBottom: initialOffsetFromBottom
		)
		if initialOffsetFromBottom <= 0 {
			scrollToBottom()
		} else {
			setClipY(maxScrollY() - initialOffsetFromBottom)
		}
	}

	/// Walk `rows` giving each an exact height until a viewport's worth is
	/// covered, so the frame that follows is built out of measurements rather
	/// than estimates.
	///
	/// Order the sequence the way the scroll is about to travel: bottom-up when
	/// landing at the bottom, top-down from an anchor when holding a position.
	private func premeasureViewport(_ rows: some Sequence<Int>, offsetFromBottom: CGFloat = 0) {
		let viewport = clip.bounds.height
		guard viewport > 0, !messages.isEmpty, columnWidth > 0 else { return }
		let budget = offsetFromBottom + viewport + 200
		let cap = 60
		var covered: CGFloat = 0
		var measured = IndexSet()
		for row in rows {
			guard covered < budget, measured.count < cap else { break }
			if hasExactHeight(messages[row]) {
				covered += height(for: row)
			} else {
				covered += measureExact(row: row)
				measured.insert(row)
			}
		}
		if !measured.isEmpty {
			withoutAnimation { tableView.noteHeightOfRows(withIndexesChanged: measured) }
		}
	}

	private func visibleRowIndexes() -> [Int] {
		let range = tableView.rows(in: tableView.visibleRect)
		guard range.length > 0 else { return [] }
		return Array(range.location ..< range.location + range.length)
	}

	// MARK: Bubble view (shared by measurement and display — must match)

	private func rootView(for message: Message, width: CGFloat? = nil) -> BubbleRoot {
		BubbleRoot(message: message, manager: manager, themes: themes, width: width)
	}
}

// MARK: - Data source / delegate

extension MessageListViewController: NSTableViewDataSource, NSTableViewDelegate {

	func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

	func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		height(for: row)
	}

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let root = rootView(for: messages[row])
		guard let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? BubbleCellView
		else { return BubbleCellView(identifier: Self.cellID, root: root) }
		cell.host.rootView = root
		return cell
	}

	func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
		if ListMetrics.enabled {
			ListMetrics.didAddRow(
				rowRect: tableView.rect(ofRow: row),
				visibleRect: tableView.visibleRect,
				preparedRect: tableView.preparedContentRect
			)
		}
		correctHeightIfNeeded(row: row)
		if ListMetrics.enabled { scheduleFidelityCheck(rowView: rowView, row: row) }
	}

	private func scheduleFidelityCheck(rowView: NSTableRowView, row: Int) {
		guard row >= 0, row < messages.count else { return }
		let m = messages[row]
		guard let cached = heightCache[m.id]?.height else { return }
		let text = effectiveText(m)
		let kind = text.contains("```") ? "code"
			: MathMarkdown.blockCount(in: text) > 0 ? "math"
			: text.contains("|") ? "table" : "plain"
		DispatchQueue.main.async { [weak self, weak rowView] in
			MainActor.assumeIsolated {
				guard
					let self,
					let rowView,
					let cell = rowView.subviews.lazy.compactMap({ $0 as? BubbleCellView }).first
				else { return }
				let w = self.columnWidth
				guard w > 0, abs(cell.bounds.width - w) < 0.5 else { return }
				ListMetrics.fidelity(
					row: row,
					offscreen: cached,
					onscreen: cell.host.fittingSize.height,
					kind: kind
				)
			}
		}
	}
}

// MARK: - Overdraw

private final class BufferedTableView: NSTableView {
	private let overdrawFactor: CGFloat = 1.0

	override func prepareContent(in rect: NSRect) {
		let buffer = visibleRect.height * overdrawFactor
		guard buffer > 0 else { return super.prepareContent(in: rect) }
		let expanded = rect.insetBy(dx: 0, dy: -buffer)
		super.prepareContent(in: expanded.intersection(bounds))
	}
}

// MARK: - Cell

private final class BubbleCellView: NSTableCellView {
	let host: NSHostingView<BubbleRoot>

	init(identifier: NSUserInterfaceItemIdentifier, root: BubbleRoot) {
		host = NSHostingView(rootView: root)
		super.init(frame: .zero)
		self.identifier = identifier
		host.translatesAutoresizingMaskIntoConstraints = false
		addSubview(host)
		NSLayoutConstraint.activate([
			host.leadingAnchor.constraint(equalTo: leadingAnchor),
			host.trailingAnchor.constraint(equalTo: trailingAnchor),
			host.topAnchor.constraint(equalTo: topAnchor),
			host.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }
}
