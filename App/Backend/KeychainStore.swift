//
//  KeychainStore.swift
//  ChatCore
//

import Foundation
import Security

nonisolated enum KeychainStore {

	static let anthropicAPIKeyRef = "anthropic.api-key"

	private static let service = "com.franken.ChatCore"

	private static let cacheLock = NSLock()
	nonisolated(unsafe) private static var cache: [String: String?] = [:]

	private static func query(_ ref: String) -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: ref,
		]
	}

	static func read(_ ref: String) -> String? {
		cacheLock.lock()
		if let cached = cache[ref] {
			cacheLock.unlock()
			return cached
		}
		cacheLock.unlock()

		var q = query(ref)
		q[kSecReturnData as String] = true
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		let value: String?
		if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
		   let data = item as? Data {
			value = String(data: data, encoding: .utf8)
		} else {
			value = nil
		}

		cacheLock.lock()
		cache[ref] = value
		cacheLock.unlock()
		return value
	}

	@discardableResult
	static func save(_ value: String, for ref: String) -> Bool {
		delete(ref)
		var q = query(ref)
		q[kSecValueData as String] = Data(value.utf8)
		let ok = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
		cacheLock.lock()
		cache[ref] = ok ? value : nil
		cacheLock.unlock()
		return ok
	}

	@discardableResult
	static func delete(_ ref: String) -> Bool {
		let status = SecItemDelete(query(ref) as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			return false
		}
		cacheLock.lock()
		cache.updateValue(nil, forKey: ref)
		cacheLock.unlock()
		return true
	}
}
