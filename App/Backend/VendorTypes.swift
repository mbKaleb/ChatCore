//
//  VendorTypes.swift
//  ChatCore
//

import Foundation

nonisolated struct ProviderConfig: Codable, Identifiable, Hashable, Sendable {

	enum Kind: String, Codable, Sendable {
		case apple
		case vendor
		case custom
	}

	var id: BackendID
	var kind: Kind
	var displayName: String
	var endpoint: URL?
	var dialect: WireDialect?
	var authKeychainRef: String?
}

nonisolated enum WireDialect: String, Codable, Sendable {
	case openAI
	case anthropic
}
