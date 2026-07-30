//
//  VirtualizedMessageList.swift
//  ChatCore
//

import SwiftUI
import AppKit

// MARK: - SwiftUI entry point

struct VirtualizedMessageList: View {
	@Environment(ModelManager.self) private var manager
	@Environment(ThemeManager.self) private var themes
	var messages: [Message]
	@Binding var scrollOffsetFromBottom: Double
	var scrollToBottomToken: Int = 0
	var bottomInset: CGFloat = 0

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
			vc.invalidateAllHeights()
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

// MARK: - Controller

@MainActor
final class MessageListViewController: NSViewController {

	private let bottomThreshold: CGFloat = 80
	private let rowInsetLeading: CGFloat = 16
	private let rowInsetTrailing: CGFloat = 26
	private let rowInsetVertical: CGFloat = 6
	private static let cellID = NSUserInterfaceItemIdentifier("BubbleCell")

	private let manager: ModelManager
	private let themes: ThemeManager
	private let initialOffsetFromBottom: CGFloat

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

	private let measureHost = NSHostingView(rootView: AnyView(EmptyView()))

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

	private var isLiveScrolling = false

	private var scrollPhase: ScrollPhase {
		if isAnimatingScroll { return .animating }
		if isLiveScrolling { return .live }
		if let e = NSApp.currentEvent, e.type == .scrollWheel, !e.momentumPhase.isEmpty {
			return .momentum
		}
		return .idle
	}

	nonisolated(unsafe) private var boundsObserver: NSObjectProtocol?
	nonisolated(unsafe) private var liveScrollObserver: NSObjectProtocol?
	nonisolated(unsafe) private var endLiveScrollObserver: NSObjectProtocol?

	init(manager: ModelManager, themes: ThemeManager, initialOffsetFromBottom: CGFloat, bottomInset: CGFloat) {
		self.manager = manager
		self.themes = themes
		self.initialOffsetFromBottom = initialOffsetFromBottom
		self.bottomInset = bottomInset
		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError() }

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

		let scroll = NSScrollView()
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = false
		scroll.autohidesScrollers = true
		scroll.scrollerStyle = .overlay
		scroll.verticalScroller?.controlSize = .small
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
				self.updateDistanceFromBottom()
				ListMetrics.observedOrigin(self.clip.bounds.origin.y, phase: self.scrollPhase)
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

		let wasAtBottom = isAtBottom
		let anchor = wasAtBottom ? nil : captureTopAnchor()
		messages = new
		liveText = newLive
		heightCache.removeAll()
		tableView.reloadData()
		withoutAnimation {
			if wasAtBottom { scrollToBottom() }
			else if let anchor { restore(anchor) }
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
		measureHost.rootView = AnyView(rootView(for: m).frame(width: w))
		measureHost.layoutSubtreeIfNeeded()
		let h = measureHost.fittingSize.height
		measureHost.rootView = AnyView(EmptyView())
		heightCache[m.id] = HeightEntry(width: w, text: effectiveText(m), mode: renderMode(m), height: h)
		return h
	}

	private func hasExactHeight(_ m: Message) -> Bool {
		guard let e = heightCache[m.id] else { return false }
		return e.width == columnWidth && e.text == effectiveText(m) && e.mode == renderMode(m)
	}

	private let chipRowHeight: CGFloat = 72

	private func estimatedHeight(_ m: Message, width: CGFloat) -> CGFloat {
		guard !effectiveText(m).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return m.attachments.isEmpty ? 1 : chipRowHeight + 2 * rowInsetVertical
		}
		let usable = max(40, width - rowInsetLeading - rowInsetTrailing - 40)
		let avgChar: CGFloat = 7.5
		let charsPerLine = max(1, usable / avgChar)
		let lineHeight: CGFloat = 20
		var lines = 0
		for raw in effectiveText(m).split(separator: "\n", omittingEmptySubsequences: false) {
			lines += max(1, Int((CGFloat(raw.count) / charsPerLine).rounded(.up)))
		}
		let verticalChrome: CGFloat = 2 * rowInsetVertical + 40
		let mathBlocks = MathMarkdown.blockCount(in: effectiveText(m))
		let mathBlockHeight: CGFloat = 60
		let chipRow: CGFloat = m.attachments.isEmpty ? 0 : chipRowHeight
		return CGFloat(max(1, lines)) * lineHeight
			+ CGFloat(mathBlocks) * mathBlockHeight
			+ chipRow
			+ verticalChrome
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
				let rows = self.pendingCorrections
				self.pendingCorrections = IndexSet()
				guard !rows.isEmpty else { return }
				let wasAtBottom = self.isAtBottom
				let anchor = wasAtBottom ? nil : self.captureAnchor(changedRows: rows)
				self.withoutAnimation {
					self.tableView.noteHeightOfRows(withIndexesChanged: rows)
					if wasAtBottom { self.scrollToBottom() }
					else if let anchor { self.restore(anchor) }
				}
			}
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
			clip.setBoundsOrigin(target)
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

	func invalidateAllHeights() {
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
		premeasureInitialViewport()
		if initialOffsetFromBottom <= 0 {
			scrollToBottom()
		} else {
			setClipY(maxScrollY() - initialOffsetFromBottom)
		}
	}

	private func premeasureInitialViewport() {
		let viewport = clip.bounds.height
		guard viewport > 0, !messages.isEmpty, columnWidth > 0 else { return }
		let needed = initialOffsetFromBottom + viewport + 200
		let cap = 60
		var covered: CGFloat = 0
		var measured = IndexSet()
		var row = messages.count - 1
		while row >= 0, covered < needed, measured.count < cap {
			if !hasExactHeight(messages[row]) {
				covered += measureExact(row: row)
				measured.insert(row)
			} else {
				covered += height(for: row)
			}
			row -= 1
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

	private func rootView(for message: Message) -> AnyView {
		AnyView(
			MessageBubble(message: message)
				.id(message.id)
				.padding(.leading, rowInsetLeading)
				.padding(.trailing, rowInsetTrailing)
				.padding(.vertical, rowInsetVertical)
				.textSelection(.enabled)
				.environment(manager)
				.environment(themes)
		)
	}
}

// MARK: - Data source / delegate

extension MessageListViewController: NSTableViewDataSource, NSTableViewDelegate {

	func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

	func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		height(for: row)
	}

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		let cell = (tableView.makeView(withIdentifier: Self.cellID, owner: self) as? BubbleCellView)
			?? BubbleCellView(identifier: Self.cellID)
		cell.host.rootView = rootView(for: messages[row])
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
	let host = NSHostingView(rootView: AnyView(EmptyView()))

	init(identifier: NSUserInterfaceItemIdentifier) {
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
