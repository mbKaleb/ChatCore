//
//  ModelRelease.swift
//  ChatCore
//

import Foundation

// MARK: - Release

/// The family and version a model id names, when it names one.
///
/// Catalogs hand back every release a vendor still serves, current and retired
/// alike, and the only thing separating the two is the id: `claude-opus-4-1`
/// and `claude-opus-5` are the same family, one version apart. Parsing that out
/// is what lets the picker lead with what a vendor ships today and file the
/// rest under "Other Models" — nothing in the wire format says which is which.
///
/// Both of Anthropic's id shapes land on the same values, since the family word
/// and the version numbers are collected independently of their order:
///
///     claude-3-5-sonnet-20241022  ->  sonnet, [3, 5]
///     claude-opus-4-1-20250805    ->  opus,   [4, 1]
///     claude-opus-5-20260401      ->  opus,   [5]
///
/// An id with no version in it — `apple.on-device` — has no release, which is
/// the honest answer: nothing there says it was superseded by anything.
nonisolated struct ModelRelease: Hashable, Sendable {

	/// The vendor prefix the id was namespaced under, so two vendors that happen
	/// to share a family word don't get compared against each other.
	var namespace: String

	/// The family word, lowercased — `opus`, `sonnet`, `haiku`.
	var family: String

	/// The version, most significant first: `4.5` is `[4, 5]`.
	var version: [Int]

	/// Whether the id pins a frozen build — a date stamp (`gpt-5.1-2025-11-13`,
	/// `claude-opus-4-1-20250805`) or a build number (`gemini-1.5-pro-002`).
	/// Vendors list these beside the undated alias that names the same model,
	/// and the alias is the one they keep current.
	var isSnapshot: Bool

	/// What two releases have to agree on before their versions mean anything
	/// relative to each other.
	var familyKey: String { "\(namespace)/\(family)" }

	init?(modelID: GenerativeChatModel.ID) {
		var components = modelID.split(separator: ".", omittingEmptySubsequences: false)

		// The namespace is the run of plain words the id was prefixed with —
		// `vendor.anthropic.` — and it stops at the first component carrying
		// structure of its own, which is the model name. Splitting on every dot
		// instead would cut `claude-2.1` in half.
		var namespaceParts: [Substring] = []
		while components.count > 1,
			  let first = components.first,
			  first.allSatisfy({ $0.isLetter || $0 == "_" }) {
			namespaceParts.append(first)
			components.removeFirst()
		}

		// OpenAI's ids carry readings of their own — `4o`, `o3`, `chatgpt`,
		// `turbo` — that would misread every other vendor's ids, so they only
		// apply under OpenAI's namespace.
		let isOpenAI = namespaceParts.joined(separator: ".") == "vendor.openAI"

		var words: [String] = []
		var numbers: [Int] = []
		var sawStamp = false

		for token in components.joined(separator: ".").split(separator: "-") {
			if let value = Self.versionNumbers(in: token) {
				// A stamp ends the version. OpenAI writes dates as
				// `-2025-08-07`: only the year is unmistakably a date, and the
				// month and day behind it would otherwise read as version
				// components deep enough to outrank the undated alias.
				if value.isEmpty { sawStamp = true }
				else if !sawStamp { numbers.append(contentsOf: value) }
				continue
			}

			if isOpenAI, let series = Self.openAISeriesVersion(in: token) {
				// `4o` and `o3` both number the trunk GPT-5 folded back
				// together, so each reads as a version of the `gpt` family —
				// which files the omni and o-series models behind it.
				if !sawStamp { numbers.append(series) }
				if !words.contains("gpt") { words.append("gpt") }
				continue
			}

			let word = token.lowercased()
			// `claude-` prefixes every Anthropic id and `-latest` suffixes the
			// aliases, so neither one distinguishes a family from another.
			guard word != "claude", word != "latest" else { continue }

			if isOpenAI {
				// Serving tiers of their era, not families: `gpt-4-turbo` is a
				// gpt-4, `chatgpt-4o-latest` is the 4o the ChatGPT app served,
				// `-16k` is a context size. Kept as words, each would found a
				// one-member family nothing could ever supersede.
				if word == "turbo" || word == "preview" || word == "instruct"
					|| word == "chatgpt"
					|| word.dropLast().allSatisfy(\.isNumber) && word.last == "k" {
					if word == "chatgpt", !words.contains("gpt") { words.append("gpt") }
					continue
				}
			}

			words.append(word)
		}

		guard !numbers.isEmpty, !words.isEmpty else { return nil }

		self.namespace = namespaceParts.joined(separator: ".")
		self.family = words.joined(separator: "-")
		self.version = numbers
		self.isSnapshot = sawStamp
	}

	/// The version numbers a token carries: `nil` if the token isn't a number at
	/// all, and empty if it is one that can't be a version.
	///
	/// The release date every dated id ends with is numeric too, and it is
	/// neither — counted as a version it outranks every real one, and counted as
	/// a word it makes each dated id its own family. So it drops out entirely.
	/// Two shapes give a date or build stamp away: more digits than any version
	/// uses (`20250805`, `2024`) and a leading zero (`08`, `002`), which version
	/// numbering never writes.
	private static func versionNumbers(in token: Substring) -> [Int]? {
		let parts = token.split(separator: ".")
		guard !parts.isEmpty, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }

		var numbers: [Int] = []
		for part in parts {
			guard part.count <= 3, !(part.count >= 2 && part.first == "0"),
				  let value = Int(part) else { return [] }
			numbers.append(value)
		}
		return numbers
	}

	/// The version an OpenAI series token carries: `4o` — the omni marker —
	/// or `o1`/`o3`/`o4` — the o-series. Nil for any other shape.
	private static func openAISeriesVersion(in token: Substring) -> Int? {
		if token.count >= 2, token.last == "o",
		   token.dropLast().allSatisfy(\.isNumber) {
			return Int(token.dropLast())
		}
		if token.count >= 2, token.first == "o",
		   token.dropFirst().allSatisfy(\.isNumber) {
			return Int(token.dropFirst())
		}
		return nil
	}
}

// MARK: - Ordering

nonisolated extension ModelRelease: Comparable {

	/// Ordering within a family, oldest first. Missing components read as zero,
	/// so `sonnet-4` sits below `sonnet-4-5` rather than beside it.
	static func < (lhs: ModelRelease, rhs: ModelRelease) -> Bool {
		for index in 0..<max(lhs.version.count, rhs.version.count) {
			let left = index < lhs.version.count ? lhs.version[index] : 0
			let right = index < rhs.version.count ? rhs.version[index] : 0
			if left != right { return left < right }
		}
		return false
	}
}

// MARK: - Superseded Models

nonisolated extension ModelRelease {

	/// The ids in `models` that a newer release of the same family replaces —
	/// plus the snapshots of the release leading the family, wherever the
	/// undated alias is listed beside them. `gpt-5.1` and `gpt-5.1-2025-11-13`
	/// are one model twice over, and the alias is the one the vendor moves.
	///
	/// Newest-per-family rather than newest overall: Haiku 4.5 is current even
	/// with Opus 5 in the same catalog, and a version comparison across families
	/// would retire it for no reason. A model whose id parses to no release
	/// can't be superseded by anything and never appears here.
	static func supersededIDs(in models: [GenerativeChatModel]) -> Set<GenerativeChatModel.ID> {
		var newest: [String: ModelRelease] = [:]
		var releases: [GenerativeChatModel.ID: ModelRelease] = [:]

		for model in models {
			guard let release = ModelRelease(modelID: model.id) else { continue }
			releases[model.id] = release
			if let known = newest[release.familyKey], release < known { continue }
			newest[release.familyKey] = release
		}

		// Families whose leading version is also served undated. In a catalog
		// of nothing but snapshots — Anthropic's — this stays empty and the
		// newest snapshot remains the family's current model.
		var aliasLeads: Set<String> = []
		for release in releases.values
		where !release.isSnapshot && !(release < newest[release.familyKey]!) {
			aliasLeads.insert(release.familyKey)
		}

		return Set(releases.compactMap { id, release in
			if release < newest[release.familyKey]! { return id }
			if release.isSnapshot, aliasLeads.contains(release.familyKey) { return id }
			return nil
		})
	}
}

nonisolated extension GenerativeChatModel {

	var release: ModelRelease? { ModelRelease(modelID: id) }
}
