//
//  ListMetrics.swift
//  ChatCore
//

import Foundation
import AppKit
import QuartzCore

enum ScrollPhase: String {
	case idle
	case live
	case momentum
	case animating
}

@MainActor
enum ListMetrics {

	static var enabled: Bool {
		#if DEBUG
		return RenderDebug.listMetrics
		#else
		return false
		#endif
	}

	private static func log(_ s: String) { print("[LM] \(s)") }

	// MARK: - Q1: does the width interpolate or snap?

	private static var widthSamples: [(t: Double, w: CGFloat)] = []

	static func widthSample(_ w: CGFloat) {
		guard enabled else { return }
		widthSamples.append((CACurrentMediaTime(), w))
	}

	static func widthFlush(
		width: CGFloat,
		docBefore: CGFloat,
		docAfter: CGFloat,
		measured: Int,
		reused: Int,
		rows: Int
	) {
		guard enabled else { return }
		defer { widthSamples.removeAll(keepingCapacity: true) }

		let now = CACurrentMediaTime()
		let first = widthSamples.first?.t ?? now
		let distinct = Set(widthSamples.map { Int(($0.w * 100).rounded()) }).count
		let span = (widthSamples.last?.t ?? now) - first

		log(String(
			format: "Q1 widthFlush w=%.1f samples=%d distinct=%d span=%.0fms flushLag=%.0fms",
			width, widthSamples.count, distinct, span * 1000, (now - first) * 1000
		))
		let hitRate = rows > 0 ? Double(reused) / Double(rows) * 100 : 0
		log(String(
			format: "Q4 doc %.0f -> %.0f (delta %+.0f) rows=%d measured=%d reused=%d (%.0f%% hit)",
			docBefore, docAfter, docAfter - docBefore, rows, measured, reused, hitRate
		))
	}

	// MARK: - Q3/Q4: clip writes, clamping, and whether they survive

	private static var pendingWrite: (y: CGFloat, t: Double)?
	private static var clampedWrites = 0
	private static var writesDuringScroll = 0
	private static var overwrittenWrites = 0

	static func clipWrite(
		source: String,
		requested: CGFloat,
		clamped: CGFloat,
		before: CGFloat,
		maxY: CGFloat,
		phase: ScrollPhase
	) {
		guard enabled else { return }
		pendingWrite = (clamped, CACurrentMediaTime())

		let wasClamped = abs(requested - clamped) > 0.5
		if wasClamped { clampedWrites += 1 }
		if phase == .live || phase == .momentum { writesDuringScroll += 1 }
		guard wasClamped || phase == .live || phase == .momentum else { return }

		log(String(
			format: "Q3/Q4 clipWrite src=%@ phase=%@ req=%.1f -> %.1f (clamp %+.1f) from=%.1f max=%.1f",
			source, phase.rawValue, requested, clamped, clamped - requested, before, maxY
		))
	}

	static func observedOrigin(_ y: CGFloat, phase: ScrollPhase) {
		guard enabled, let write = pendingWrite else { return }
		guard CACurrentMediaTime() - write.t < 0.05 else { pendingWrite = nil; return }
		pendingWrite = nil
		guard abs(write.y - y) > 0.5 else { return }
		overwrittenWrites += 1
		log(String(
			format: "Q3 clipWrite OVERWRITTEN phase=%@ wrote=%.1f observed=%.1f (delta %+.1f)",
			phase.rawValue, write.y, y, y - write.y
		))
	}

	// MARK: - Q2: are corrections landing on-screen?

	private static var didAddOnScreen = 0
	private static var didAddOffScreen = 0
	private static var runwayRatios: [Double] = []

	static func didAddRow(rowRect: NSRect, visibleRect: NSRect, preparedRect: NSRect) {
		guard enabled else { return }
		if rowRect.intersects(visibleRect) { didAddOnScreen += 1 } else { didAddOffScreen += 1 }
		if visibleRect.height > 0 {
			runwayRatios.append(Double(preparedRect.height / visibleRect.height))
		}
	}

	// MARK: - Q6: does the offscreen measure agree with the on-screen cell?

	private static var fidelityChecked = 0
	private static var fidelityMismatched = 0
	private static var worstFidelity: (row: Int, delta: CGFloat, kind: String)?

	static func fidelity(row: Int, offscreen: CGFloat, onscreen: CGFloat, kind: String) {
		guard enabled else { return }
		fidelityChecked += 1
		let delta = onscreen - offscreen
		guard abs(delta) > 0.5 else { return }
		fidelityMismatched += 1
		if abs(delta) > abs(worstFidelity?.delta ?? 0) {
			worstFidelity = (row, delta, kind)
		}
		log(String(
			format: "Q6 fidelity row=%d kind=%@ offscreen=%.1f onscreen=%.1f (delta %+.1f)",
			row, kind, offscreen, onscreen, delta
		))
	}

	// MARK: - Q7: fit the estimate against ground truth

	struct RowSample {
		var role: String
		var measured: CGFloat
		var estimated: CGFloat
		var hasCode: Bool
		var hasTable: Bool
		var hasMath: Bool
		var sourceLines: Int
		var chars: Int
	}

	private static var rowSamples: [RowSample] = []

	static func rowSample(_ s: RowSample) {
		guard enabled else { return }
		rowSamples.append(s)
		if rowSamples.count % 50 == 0 { summarize() }
	}

	static func summarize() {
		guard enabled, !rowSamples.isEmpty else { return }

		func report(_ label: String, _ rows: [RowSample]) {
			guard !rows.isEmpty else { return }
			let errors = rows.map { $0.measured - $0.estimated }
			let mean = errors.reduce(0, +) / CGFloat(errors.count)
			let minErr = errors.min() ?? 0
			let maxErr = errors.max() ?? 0
			let perLine = rows.map { r -> CGFloat in
				let lines = max(1, r.sourceLines)
				return (r.measured - r.estimated) / CGFloat(lines)
			}
			let meanPerLine = perLine.reduce(0, +) / CGFloat(perLine.count)
			log(String(
				format: "Q7 %-16@ n=%3d meanErr=%+7.1f [%+.0f..%+.0f] perLine=%+.1f",
				label, rows.count, mean, minErr, maxErr, meanPerLine
			))
		}

		log("---- Q7 estimate vs measured (n=\(rowSamples.count)) ----")
		report("user", rowSamples.filter { $0.role == "user" })
		report("assistant-plain", rowSamples.filter {
			$0.role != "user" && !$0.hasCode && !$0.hasTable && !$0.hasMath
		})
		report("assistant-code", rowSamples.filter { $0.role != "user" && $0.hasCode })
		report("assistant-table", rowSamples.filter { $0.role != "user" && $0.hasTable })
		report("assistant-math", rowSamples.filter { $0.role != "user" && $0.hasMath })

		let onScreenTotal = didAddOnScreen + didAddOffScreen
		if onScreenTotal > 0 {
			let pct = Double(didAddOnScreen) / Double(onScreenTotal) * 100
			let runway = runwayRatios.isEmpty
				? 0
				: runwayRatios.reduce(0, +) / Double(runwayRatios.count)
			log(String(
				format: "Q2 didAdd on-screen=%d off-screen=%d (%.0f%% in front of the user) runway=%.2fx",
				didAddOnScreen, didAddOffScreen, pct, runway
			))
		}
		if fidelityChecked > 0 {
			log("Q6 fidelity checked=\(fidelityChecked) mismatched=\(fidelityMismatched)"
				+ (worstFidelity.map {
					String(format: " worst=row %d %@ %+.1f", $0.row, $0.kind, $0.delta)
				} ?? ""))
		}
		log("Q3/Q4 clampedWrites=\(clampedWrites) writesDuringScroll=\(writesDuringScroll) overwritten=\(overwrittenWrites)")
		log("--------------------------------------------------")
	}
}
