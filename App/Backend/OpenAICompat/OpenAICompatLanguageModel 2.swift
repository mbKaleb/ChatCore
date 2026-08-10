//
//  OpenAICompatLanguageModel.swift
//  ChatCore
//
//  An OpenAI-dialect endpoint as a Foundation Models language model — the
//  same seam ClaudeForFoundationModels sits on, so every one of these vendors
//  rides the LanguageModelSession plumbing the app already trusts:
//  ThinkingWatcher, transcript history, streamed snapshots, all unchanged.
//

import Foundation
import FoundationModels

nonisolated struct OpenAICompatLanguageModel: Sendable {

	/// The vendor's own id for the model — what goes in the request body.
	let wireModelID: String

	let profile: VendorWireProfile

	let apiKey: String

	let timeout: TimeInterval

	/// Capability flags resolved at construction, from the profile's id
	/// heuristics — the executor trusts them rather than re-deriving.
	let supportsVision: Bool
	let streamsReasoning: Bool
	let locksSampling: Bool

	init(
		wireModelID: String,
		profile: VendorWireProfile,
		apiKey: String,
		timeout: TimeInterval = 60
	) {
		self.wireModelID = wireModelID
		self.profile = profile
		self.apiKey = apiKey
		self.timeout = timeout
		self.supportsVision = profile.supportsVision(wireModelID)
		self.streamsReasoning = profile.streamsReasoning(wireModelID)
		self.locksSampling = profile.locksSampling(wireModelID)
	}

	func authenticateIfNeeded() async throws {}
}

nonisolated extension OpenAICompatLanguageModel: LanguageModel {
	typealias Executor = OpenAICompatExecutor

	var capabilities: LanguageModelCapabilities {
		var capabilities: [LanguageModelCapabilities.Capability] = [.toolCalling]
		if supportsVision { capabilities.append(.vision) }
		if streamsReasoning { capabilities.append(.reasoning) }
		if profile.supportsJSONSchema { capabilities.append(.guidedGeneration) }
		return LanguageModelCapabilities(capabilities)
	}

	var executorConfiguration: OpenAICompatExecutor.Configuration {
		.init(
			wireModelID: wireModelID,
			chatURL: profile.chatURL,
			headers: profile.authHeaders(key: apiKey),
			vendorName: profile.vendor.displayName,
			maxTokensField: profile.maxTokensField,
			supportsStreamOptions: profile.supportsStreamOptions,
			supportsJSONSchema: profile.supportsJSONSchema,
			locksSampling: locksSampling,
			timeout: timeout
		)
	}
}
