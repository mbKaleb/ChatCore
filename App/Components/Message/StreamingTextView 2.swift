//
//  StreamingTextView.swift
//  ChatCore
//

import SwiftUI
import AppKit

struct StreamingTextView: View {

	let chunks: [StreamChunk]
	var font: ChatFont = .system
	let fontSize: Double
	let lineSpacing: Double
	let color: Color
	var blockGap: Double = ChatMarkdownMetrics.blockGap

	private let fadeDuration: TimeInterval = 0.4

	private let initialOpacity: Double = 0.12

	var body: some View {
		let segments = Self.segmented(chunks)
		let gapFont = Font.system(size: Self.fontSize(forLineHeight: gapLineHeight))

		return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isSettled)) { timeline in
			rendered(segments, gapFont: gapFont, at: timeline.date)
				.font(font.font(size: fontSize))
				.lineSpacing(lineSpacing)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var gapLineHeight: Double {
		max(0, blockGap - lineSpacing)
	}

	private var isSettled: Bool {
		guard let last = chunks.last else { return true }
		return Date().timeIntervalSince(last.arrival) > fadeDuration
	}

	private func rendered(_ segments: [Segment], gapFont: Font, at now: Date) -> Text {
		segments.reduce(Text(verbatim: "")) { accumulated, segment in
			let text = Text(verbatim: segment.text)
				.foregroundColor(color.opacity(opacity(at: segment.arrival, now: now)))
			return accumulated + (segment.isGap ? text.font(gapFont) : text)
		}
	}

	private func opacity(at arrival: Date, now: Date) -> Double {
		let elapsed = now.timeIntervalSince(arrival)
		guard elapsed < fadeDuration else { return 1 }
		let t = max(0, elapsed / fadeDuration)
		let eased = 1 - pow(1 - t, 3)
		return initialOpacity + (1 - initialOpacity) * eased
	}

	// MARK: - Segmentation

	private struct Segment {
		var text: String
		var arrival: Date
		var isGap: Bool
	}

	private static func segmented(_ chunks: [StreamChunk]) -> [Segment] {
		var segments: [Segment] = []
		var held: [Date] = []
		var buffer = ""
		var bufferArrival = Date.distantPast

		func flushBuffer() {
			guard !buffer.isEmpty else { return }
			segments.append(Segment(text: buffer, arrival: bufferArrival, isGap: false))
			buffer.removeAll(keepingCapacity: true)
		}

		func flushHeld() {
			guard !held.isEmpty else { return }
			segments.append(Segment(text: "\n", arrival: held[0], isGap: false))
			if held.count >= 2 {
				segments.append(Segment(text: "\n", arrival: held[1], isGap: true))
			}
			held.removeAll(keepingCapacity: true)
		}

		for chunk in chunks {
			for character in chunk.text {
				if character == "\n" {
					flushBuffer()
					held.append(chunk.arrival)
				} else {
					flushHeld()
					if buffer.isEmpty { bufferArrival = chunk.arrival }
					buffer.append(character)
				}
			}
			flushBuffer()
		}

		flushBuffer()
		flushHeld()
		return segments
	}

	private static func fontSize(forLineHeight target: Double) -> Double {
		let probe = NSFont.systemFont(ofSize: 10)
		let ratio = (probe.ascender - probe.descender + probe.leading) / 10
		guard ratio > 0 else { return max(0.5, target) }
		return max(0.5, target / ratio)
	}
}
