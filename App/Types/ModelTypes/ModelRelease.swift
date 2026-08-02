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

		var words: [String] = []
		var numbers: [Int] = []

		for token in components.joined(separator: ".").split(separator: "-") {
			if let value = Self.versionNumbers(in: token) {
				numbers.append(contentsOf: value)
			} else {
				let word = token.lowercased()
				// `claude-` prefixes every Anthropic id and `-latest` suffixes the
				// aliases, so neither one distinguishes a family from another.
				guard word != "claude", word != "latest" else { continue }
				words.append(word)
			}
		}

		guard !numbers.isEmpty, !words.isEmpty else { return nil }

		self.namespace = namespaceParts.joined(separator: ".")
		self.family = words.joined(separator: "-")
		self.version = numbers
	}

	/// The version numbers a token carries: `nil` if the token isn't a number at
	/// all, and empty if it is one that can't be a version.
	///
	/// The release date every dated id ends with is numeric too, and it is
	/// neither — counted as a version it outranks every real one, and counted as
	/// a word it makes each dated id its own family. So it drops out entirely.
	private static func versionNumbers(in token: Substring) -> [Int]? {
		let parts = token.split(separator: ".")
		guard !parts.isEmpty, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }

		var numbers: [Int] = []
		for part in parts {
			guard part.count <= 3, let value = Int(part) else { return [] }
			numbers.append(value)
		}
		return numbers
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

	/// The ids in `models` that a newer release of the same family replaces.
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

		return Set(releases.compactMap { id, release in
			release < newest[release.familyKey]! ? id : nil
		})
	}
}

nonisolated extension GenerativeChatModel {

	var release: ModelRelease? { ModelRelease(modelID: id) }
}
