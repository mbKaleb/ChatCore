//
//  NetworkMonitor.swift
//  ChatCore
//

import Foundation
import Network

nonisolated final class NetworkMonitor: @unchecked Sendable {

	static let shared = NetworkMonitor()

	private let monitor = NWPathMonitor()
	private let queue = DispatchQueue(label: "com.mbkaleb.corechat.network-path")

	private let lock = NSLock()
	private var online = true
	private var started = false
	private var observers: [UUID: @Sendable (Bool) -> Void] = [:]

	private init() {}

	var isOnline: Bool {
		lock.lock()
		defer { lock.unlock() }
		return online
	}

	func start() {
		lock.lock()
		guard !started else {
			lock.unlock()
			return
		}
		started = true
		lock.unlock()

		monitor.pathUpdateHandler = { [weak self] path in
			self?.pathChanged(satisfied: path.status == .satisfied)
		}
		monitor.start(queue: queue)
	}

	@discardableResult
	func addObserver(_ handler: @escaping @Sendable (Bool) -> Void) -> UUID {
		let token = UUID()
		lock.lock()
		observers[token] = handler
		lock.unlock()
		return token
	}

	func removeObserver(_ token: UUID) {
		lock.lock()
		observers.removeValue(forKey: token)
		lock.unlock()
	}

	private func pathChanged(satisfied: Bool) {
		lock.lock()
		guard satisfied != online else {
			lock.unlock()
			return
		}
		online = satisfied
		let handlers = Array(observers.values)
		lock.unlock()

		for handler in handlers {
			handler(satisfied)
		}
	}
}
