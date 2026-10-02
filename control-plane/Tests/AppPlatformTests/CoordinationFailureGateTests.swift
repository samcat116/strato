import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
@testable import App

private enum GateFixtureError: Error { case unavailable }

private actor RecoveryProbeFixture {
    var calls = 0
    var waiter: CheckedContinuation<Void, Never>?
    func probe() async {
        calls += 1
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

@Suite("Coordination failure gate")
struct CoordinationFailureGateTests {
    @Test("A blackholed operation opens after three deadlines and skips many workloads promptly")
    func blackholeBudget() async throws {
        let gate = CoordinationFailureGate(deadline: .milliseconds(30), cooldown: .seconds(60))
        for _ in 0..<3 {
            await #expect(throws: StoreTimeoutError.self) {
                try await gate.run(operation: "fixture") { try await Task.sleep(for: .seconds(60)) }
            }
        }
        #expect(await gate.unavailable)
        let start = ContinuousClock.now
        for _ in 0..<40 {
            await #expect(throws: StoreUnavailableError.self) {
                try await gate.run(operation: "fixture") { Issue.record("Open gate called blackholed store") }
            }
        }
        #expect(start.duration(to: .now) < .milliseconds(30))
    }

    @Test("Concurrent recovery callers permit exactly one half-open probe")
    func singleRecoveryProbe() async throws {
        let clock = NIOLockedValueBox(ContinuousClock.now)
        let probe = RecoveryProbeFixture()
        let gate = CoordinationFailureGate(
            threshold: 1, cooldown: .seconds(1),
            now: { clock.withLockedValue { $0 } }, probe: { await probe.probe() })
        await #expect(throws: GateFixtureError.self) {
            try await gate.run(operation: "fixture") { throw GateFixtureError.unavailable }
        }
        clock.withLockedValue { $0 = $0.advanced(by: .seconds(2)) }
        let recovery = Task { try await gate.run(operation: "recovery") { 42 } }
        while await probe.calls == 0 { await Task.yield() }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await #expect(throws: StoreUnavailableError.self) {
                        try await gate.run(operation: "fixture") { Issue.record("Second recovery command") }
                    }
                }
            }
        }
        #expect(await probe.calls == 1)
        await probe.release()
        #expect(try await recovery.value == 42)
        #expect(!(await gate.unavailable))
        #expect(try await gate.run(operation: "healthy") { 7 } == 7)
    }

    @Test("Late success cannot close a newer open gate")
    func lateSuccessIsFenced() async throws {
        let gate = CoordinationFailureGate(threshold: 1, cooldown: .seconds(60))
        let suspended = RecoveryProbeFixture()
        let lateSuccess = Task {
            try await gate.run(operation: "late") { await suspended.probe() }
        }
        while await suspended.calls == 0 { await Task.yield() }
        await #expect(throws: GateFixtureError.self) {
            try await gate.run(operation: "failure") { throw GateFixtureError.unavailable }
        }
        await suspended.release()
        try await lateSuccess.value
        #expect(await gate.unavailable)
    }

    @Test("Cancellation does not mark a healthy store unavailable")
    func cancellation() async {
        let gate = CoordinationFailureGate(threshold: 1)
        await #expect(throws: CancellationError.self) {
            try await gate.run(operation: "fixture") { throw CancellationError() }
        }
        #expect(!(await gate.unavailable))
    }

    @Test("Outage preserves armed lockout and shared counts observed before failure")
    func securityShadow() async throws {
        let shared = InMemoryRateLimitStore()
        let fallback = InMemoryRateLimitStore()
        let gate = CoordinationFailureGate(threshold: 1, cooldown: .seconds(60))
        let backend = RateLimitBackend(fallbackStore: fallback, valkeyStore: shared, gate: gate)
        for _ in 0..<5 { _ = await shared.hit("window", window: 60) }
        #expect(try await backend.hit("window", window: 60).count == 6)
        let expiry = Int(Date().timeIntervalSince1970) + 60
        try await backend.writeInt("lock", value: expiry, ttl: 60)
        await #expect(throws: GateFixtureError.self) {
            try await gate.run(operation: "fixture") { throw GateFixtureError.unavailable }
        }
        #expect(try await backend.readInt("lock") == expiry)
        #expect(try await backend.hit("window", window: 60).count == 7)
        try await backend.reset("lock")
        #expect(try await backend.readInt("lock") == nil)
    }

    @Test("Fallback capacity never evicts active windows or lockouts")
    func boundedFallback() async throws {
        let store = InMemoryRateLimitStore(maxEntries: 1)
        #expect(await store.hit("first", window: 60).count == 1)
        #expect(await store.hit("overflow", window: 60).count == Int.max)
        #expect(await store.hit("first", window: 60).count == 2)
        await store.writeInt("armed", value: 100, ttl: 60)
        let overflowExpiry = Int(Date().timeIntervalSince1970) + 600
        await store.writeInt("overflow", value: overflowExpiry, ttl: 600)
        #expect(await store.readInt("armed") == 100)
        #expect(await store.readInt("overflow") == overflowExpiry)
        await store.reset("armed")
        // Freeing a slot must not erase a lockout already armed at capacity.
        #expect(await store.readInt("overflow") == overflowExpiry)
    }
}
