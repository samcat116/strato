import Foundation
@testable import App

/// A real in-memory store with instrumentation at the external wait boundary.
actor CoordinationFixtureStore: CoordinationStore {
    let base = InMemoryCoordinationStore()
    var batches: [[String]] = []
    let beforeReserve: @Sendable () async throws -> Void
    init(beforeReserve: @escaping @Sendable () async throws -> Void = {}) {
        self.beforeReserve = beforeReserve
    }
    func setKey(_ key: String, ttlSeconds: Int) async throws { await base.setKey(key, ttlSeconds: ttlSeconds) }
    func setKeys(_ keys: [String], ttlSeconds: Int) async throws {
        batches.append(keys)
        try await base.setKeys(keys, ttlSeconds: ttlSeconds)
    }
    func keyExists(_ key: String) async throws -> Bool { await base.keyExists(key) }
    func keysExist(_ keys: [String]) async throws -> [Bool] { await base.keysExist(keys) }
    func deleteKey(_ key: String) async throws { await base.deleteKey(key) }
    func acquireLock(_ key: String, ttlSeconds: Int) async throws -> Bool {
        await base.acquireLock(key, ttlSeconds: ttlSeconds)
    }
    func tryReserve(
        agentKey: String, vmId: String, amounts: ReservationAmounts, capacity: ReservationAmounts, ttlSeconds: Int
    ) async throws -> Bool {
        try await beforeReserve()
        return await base.tryReserve(
            agentKey: agentKey, vmId: vmId, amounts: amounts, capacity: capacity, ttlSeconds: ttlSeconds)
    }
    func releaseReservation(agentKey: String, vmId: String) async throws {
        await base.releaseReservation(agentKey: agentKey, vmId: vmId)
    }
    func reservedVMIds(agentKey: String) async throws -> [String] { await base.reservedVMIds(agentKey: agentKey) }
    func reservedTotals(agentKeys: [String]) async throws -> [ReservationAmounts] {
        await base.reservedTotals(agentKeys: agentKeys)
    }
    func setValue(_ key: String, value: String, ttlSeconds: Int) async throws {
        try await base.setValue(key, value: value, ttlSeconds: ttlSeconds)
    }
    func getValue(_ key: String) async throws -> String? { await base.getValue(key) }
    func deleteValue(_ key: String, ifEquals value: String) async throws {
        await base.deleteValue(key, ifEquals: value)
    }
    func publish(channel: String, message: String) async throws {
        await base.publish(channel: channel, message: message)
    }
    func subscribe(channel: String, handler: @escaping @Sendable (String) -> Void) async throws {
        await base.subscribe(channel: channel, handler: handler)
    }
}
