import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Metadata Token Store Tests")
struct MetadataTokenStoreTests {

    /// Deterministic tokens, so a test can name the one it means.
    private static func counting() -> (@Sendable () -> String) {
        let counter = Counter()
        return { counter.next() }
    }

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return "token-\(value)"
        }
    }

    @Test("A minted session validates for its own instance and no other")
    func sessionIsBoundToItsInstance() async {
        let store = MetadataTokenStore()
        let vmA = UUID()
        let vmB = UUID()
        let now = ContinuousClock.now

        let token = await store.mint(for: vmA, ttlSeconds: 60, at: now)
        #expect(await store.isValid(token, for: vmA, at: now))
        // The property that survives credential theft: B holding A's token is
        // still not A.
        #expect(await store.isValid(token, for: vmB, at: now) == false)
    }

    @Test("A session lapses exactly at its TTL")
    func sessionExpires() async {
        let store = MetadataTokenStore()
        let vmId = UUID()
        let now = ContinuousClock.now
        let token = await store.mint(for: vmId, ttlSeconds: 60, at: now)

        #expect(await store.isValid(token, for: vmId, at: now.advanced(by: .seconds(59))))
        // At the instant it expires it is already gone — `>`, not `>=`.
        #expect(await store.isValid(token, for: vmId, at: now.advanced(by: .seconds(60))) == false)
        #expect(await store.isValid(token, for: vmId, at: now.advanced(by: .seconds(61))) == false)
    }

    @Test("An unminted string is never valid")
    func unknownTokenIsInvalid() async {
        let store = MetadataTokenStore()
        #expect(await store.isValid("", for: UUID(), at: .now) == false)
        #expect(await store.isValid("token-1", for: UUID(), at: .now) == false)
    }

    @Test("Two mints yield two different tokens")
    func mintsAreDistinct() async {
        let store = MetadataTokenStore()
        let vmId = UUID()
        let now = ContinuousClock.now
        let first = await store.mint(for: vmId, ttlSeconds: 60, at: now)
        let second = await store.mint(for: vmId, ttlSeconds: 60, at: now)
        #expect(first != second)
        // Minting again does not invalidate the previous session — a guest may
        // legitimately hold several.
        #expect(await store.isValid(first, for: vmId, at: now))
        #expect(await store.isValid(second, for: vmId, at: now))
    }

    @Test("The default token is long, opaque, and header-safe")
    func defaultTokenShape() {
        let token = MetadataTokenStore.defaultRandomToken()
        #expect(token.count >= 32)
        #expect(token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        #expect(MetadataTokenStore.defaultRandomToken() != token)
    }

    @Test("Expired sessions are swept rather than accumulating")
    func expiredSessionsAreSwept() async {
        let store = MetadataTokenStore(randomToken: Self.counting())
        let vmId = UUID()
        let now = ContinuousClock.now
        for _ in 0..<5 { _ = await store.mint(for: vmId, ttlSeconds: 1, at: now) }
        #expect(await store.liveTokenCount() == 5)

        // The next mint is what notices — no timer task to supervise.
        _ = await store.mint(for: vmId, ttlSeconds: 60, at: now.advanced(by: .seconds(2)))
        #expect(await store.liveTokenCount() == 1)
    }

    @Test("A guest minting in a loop is bounded, and keeps its newest session")
    func perInstanceCapEvictsOldest() async {
        let store = MetadataTokenStore(randomToken: Self.counting())
        let vmId = UUID()
        let now = ContinuousClock.now

        var tokens: [String] = []
        for index in 0..<(MetadataLimits.maxTokensPerVM + 10) {
            // Ascending TTLs, so the soonest-expiring is also the oldest.
            tokens.append(await store.mint(for: vmId, ttlSeconds: 60 + index, at: now))
        }

        #expect(await store.liveTokenCount() <= MetadataLimits.maxTokensPerVM)
        #expect(await store.isValid(tokens.last!, for: vmId, at: now))
        #expect(await store.isValid(tokens.first!, for: vmId, at: now) == false)
    }

    @Test("The cap is per instance, so one noisy guest cannot evict another's session")
    func capIsPerInstance() async {
        let store = MetadataTokenStore(randomToken: Self.counting())
        let noisy = UUID()
        let quiet = UUID()
        let now = ContinuousClock.now

        let quietToken = await store.mint(for: quiet, ttlSeconds: 60, at: now)
        for index in 0..<(MetadataLimits.maxTokensPerVM + 10) {
            _ = await store.mint(for: noisy, ttlSeconds: 60 + index, at: now)
        }
        #expect(await store.isValid(quietToken, for: quiet, at: now))
    }

    @Test("Sessions of an instance this host no longer serves are dropped")
    func retainDropsWithdrawnInstances() async {
        // An address outlives the VM it was allocated to, so a deleted
        // instance's token must not stay valid for whoever inherits it.
        let store = MetadataTokenStore()
        let staying = UUID()
        let leaving = UUID()
        let now = ContinuousClock.now
        let stayingToken = await store.mint(for: staying, ttlSeconds: 3600, at: now)
        let leavingToken = await store.mint(for: leaving, ttlSeconds: 3600, at: now)

        await store.retain(servable: [staying])

        #expect(await store.isValid(stayingToken, for: staying, at: now))
        #expect(await store.isValid(leavingToken, for: leaving, at: now) == false)
        #expect(await store.liveTokenCount() == 1)
    }
}
