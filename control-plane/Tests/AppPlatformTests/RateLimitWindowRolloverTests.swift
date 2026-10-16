import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import App

private enum RolloverStoreError: Error { case unavailable }

private actor RolloverStore: RateLimitStore {
    let base: InMemoryRateLimitStore
    var unavailable = false
    init(now: @escaping @Sendable () -> Double) { base = InMemoryRateLimitStore(now: now) }
    func fail(_ unavailable: Bool) { self.unavailable = unavailable }
    func loseCounter(_ key: String) async { await base.reset(key) }
    func hit(_ key: String, window: Int) async throws -> RateLimitCount {
        if unavailable { throw RolloverStoreError.unavailable }
        return await base.hit(key, window: window)
    }
    func readInt(_ key: String) async throws -> Int? {
        if unavailable { throw RolloverStoreError.unavailable }
        return await base.readInt(key)
    }
    func writeInt(_ key: String, value: Int, ttl: Int) async throws {
        if unavailable { throw RolloverStoreError.unavailable }
        await base.writeInt(key, value: value, ttl: ttl)
    }
    func reset(_ key: String) async throws {
        if unavailable { throw RolloverStoreError.unavailable }
        await base.reset(key)
    }
}

@Suite("Rate-limit window rollover")
struct RateLimitWindowRolloverTests {
    @Test("Coordinator's rounded-TTL sequence cannot accumulate three, five, seven across windows")
    func roundedTTLRolloverReproduction() async {
        let clock = NIOLockedValueBox(1_000.0)
        let store = InMemoryRateLimitStore(now: { clock.withLockedValue { $0 } })
        _ = await store.hit("probe", window: 2)
        _ = await store.observeCount("probe", count: .init(count: 1, ttl: 2))
        for _ in 0..<3 {
            clock.withLockedValue { $0 += 0.3 }
            #expect(await store.hit("probe", window: 2).count == 2)
            _ = await store.observeCount("probe", count: .init(count: 2, ttl: 2))
            clock.withLockedValue { $0 += 1.8 }
            #expect(await store.hit("probe", window: 2).count == 1)
            _ = await store.observeCount("probe", count: .init(count: 1, ttl: 2))
        }
    }

    @Test("Consecutive shared windows start at one instead of inheriting the previous shadow")
    func healthyConsecutiveWindows() async throws {
        let clock = NIOLockedValueBox(1_000.0)
        let now: @Sendable () -> Double = { clock.withLockedValue { $0 } }
        let shared = RolloverStore(now: now)
        let backend = RateLimitBackend(fallbackStore: InMemoryRateLimitStore(now: now), valkeyStore: shared)
        for index in 0..<10 {
            clock.withLockedValue { $0 = 1_000 + Double(index) * 1.1 }
            let first = try await backend.hit("login", window: 1)
            #expect(first.count == 1)
            #expect(!FixedWindowRateLimitResult(limit: 2, count: first).exceeded)
            clock.withLockedValue { $0 += 0.8 }
            let second = try await backend.hit("login", window: 1)
            #expect(second.count == 2)
            #expect(!FixedWindowRateLimitResult(limit: 2, count: second).exceeded)
            #expect(try await backend.hit("login", window: 1).count == 3)
        }
    }

    @Test("Rounded TTL observations do not slide the local deadline while the store fails")
    func outageAtBoundary() async throws {
        let clock = NIOLockedValueBox(1_000.0)
        let now: @Sendable () -> Double = { clock.withLockedValue { $0 } }
        let shared = RolloverStore(now: now)
        let gate = CoordinationFailureGate(threshold: 1, cooldown: .seconds(60))
        let backend = RateLimitBackend(
            fallbackStore: InMemoryRateLimitStore(now: now), valkeyStore: shared, gate: gate, now: now)
        #expect(try await backend.hit("login", window: 1).count == 1)
        clock.withLockedValue { $0 = 1_000.8 }
        #expect(try await backend.hit("login", window: 1).count == 2)
        await shared.fail(true)
        clock.withLockedValue { $0 = 1_000.9 }
        #expect(try await backend.hit("login", window: 1).count == 3)
        clock.withLockedValue { $0 = 1_001.1 }
        #expect(try await backend.hit("login", window: 1).count == 1)
        clock.withLockedValue { $0 = 1_001.9 }
        #expect(try await backend.hit("login", window: 1).count == 2)
        clock.withLockedValue { $0 = 1_002.2 }
        #expect(try await backend.hit("login", window: 1).count == 1)
    }

    @Test("Recovery into the next shared window retires old counts but retains armed lockouts")
    func recoveryAcrossBoundary() async throws {
        let clock = NIOLockedValueBox(1_000.0)
        let gateClock = NIOLockedValueBox(ContinuousClock.now)
        let now: @Sendable () -> Double = { clock.withLockedValue { $0 } }
        let shared = RolloverStore(now: now)
        let gate = CoordinationFailureGate(
            threshold: 1, cooldown: .seconds(1),
            now: { gateClock.withLockedValue { $0 } }, probe: { _ = try await shared.readInt("probe") })
        let backend = RateLimitBackend(
            fallbackStore: InMemoryRateLimitStore(now: now), valkeyStore: shared, gate: gate, now: now)
        #expect(try await backend.hit("login", window: 1).count == 1)
        try await backend.writeInt("lock", value: 1_010, ttl: 10)
        clock.withLockedValue { $0 = 1_000.8 }
        #expect(try await backend.hit("login", window: 1).count == 2)
        await shared.fail(true)
        #expect(try await backend.hit("login", window: 1).count == 3)
        clock.withLockedValue { $0 = 1_001.1 }
        gateClock.withLockedValue { $0 = $0.advanced(by: .seconds(2)) }
        await shared.fail(false)
        #expect(try await backend.hit("login", window: 1).count == 1)
        #expect(try await backend.readInt("lock") == 1_010)
        clock.withLockedValue { $0 = 1_001.9 }
        #expect(try await backend.hit("login", window: 1).count == 2)
    }

    @Test("A counter lost during an outage does not discard the active local security window")
    func counterLossBeforeBoundary() async throws {
        let clock = NIOLockedValueBox(1_000.0)
        let gateClock = NIOLockedValueBox(ContinuousClock.now)
        let now: @Sendable () -> Double = { clock.withLockedValue { $0 } }
        let shared = RolloverStore(now: now)
        let gate = CoordinationFailureGate(
            threshold: 1, cooldown: .seconds(1),
            now: { gateClock.withLockedValue { $0 } }, probe: { _ = try await shared.readInt("probe") })
        let backend = RateLimitBackend(
            fallbackStore: InMemoryRateLimitStore(now: now), valkeyStore: shared, gate: gate, now: now)
        #expect(try await backend.hit("login", window: 2).count == 1)
        try await backend.writeInt("lock", value: 1_010, ttl: 10)
        clock.withLockedValue { $0 = 1_000.3 }
        #expect(try await backend.hit("login", window: 2).count == 2)
        await shared.fail(true)
        #expect(try await backend.hit("login", window: 2).count == 3)
        await shared.loseCounter("login")
        clock.withLockedValue { $0 = 1_000.5 }
        gateClock.withLockedValue { $0 = $0.advanced(by: .seconds(2)) }
        await shared.fail(false)
        #expect(try await backend.hit("login", window: 2).count == 4)
        #expect(try await backend.readInt("lock") == 1_010)
        clock.withLockedValue { $0 = 1_002.1 }
        await shared.fail(true)
        #expect(try await backend.hit("login", window: 2).count == 1)
        #expect(try await backend.readInt("lock") == 1_010)
    }

    @Test("Millisecond lifetime and window identity handle delayed and out-of-order observations")
    func preciseWindowIdentity() async throws {
        let clock = NIOLockedValueBox(1_000.0)
        let store = InMemoryRateLimitStore(now: { clock.withLockedValue { $0 } })
        _ = await store.hit("login", window: 1)
        _ = await store.observeCount(
            "login",
            count: .init(
                count: 20, ttl: 1, windowExpiresAtMilliseconds: 1_001_000, remainingMilliseconds: 1_000))
        clock.withLockedValue { $0 = 1_000.9 }
        // The request began in the old local window but Valkey has advanced to
        // a new one by the time its response arrives. Its first hit is one.
        #expect(
            await store.observeCount(
                "login",
                count: .init(
                    count: 1, ttl: 1, windowExpiresAtMilliseconds: 1_002_000, remainingMilliseconds: 1_000)
            ).count == 1)
        _ = await store.observeCount(
            "login",
            count: .init(
                count: 20, ttl: 0, windowExpiresAtMilliseconds: 1_001_000, remainingMilliseconds: 10))
        #expect(await store.hit("login", window: 1).count == 2)
        clock.withLockedValue { $0 = 1_001.8 }
        #expect(
            await store.observeCount(
                "login",
                count: .init(
                    count: 3, ttl: 1, windowExpiresAtMilliseconds: 1_002_000, remainingMilliseconds: 100)
            ).count == 3)
        clock.withLockedValue { $0 = 1_001.95 }
        #expect(await store.hit("login", window: 1).count == 1)
    }

    @Test("An expired slot remains reusable when the bounded store is full")
    func expiredSlotAtCapacity() async {
        let clock = NIOLockedValueBox(1_000.0)
        let store = InMemoryRateLimitStore(maxEntries: 1, now: { clock.withLockedValue { $0 } })
        #expect(await store.hit("login", window: 1).count == 1)
        clock.withLockedValue { $0 = 1_001.1 }
        #expect(await store.hit("login", window: 1).count == 1)
    }
}
