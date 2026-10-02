import Foundation
import Valkey
import Vapor

/// Result of incrementing a fixed-window counter: the new hit count within the
/// current window and the seconds remaining until that window resets.
struct RateLimitCount: Sendable {
    let count: Int
    let ttl: Int
    // Store window identity and precise remaining lifetime. Integer-second TTL
    // alone cannot distinguish rollover and must never slide a shadow's expiry.
    var windowExpiresAtMilliseconds: Int? = nil
    var remainingMilliseconds: Int? = nil
}

/// Backend-agnostic operations the rate limiter needs. Two implementations exist:
/// a Valkey-backed store (`ValkeyRateLimitStore`) used when Valkey is
/// configured so counters are shared across every control-plane instance, and an
/// in-process actor (`InMemoryRateLimitStore`) used as a fallback for single-node
/// or Valkey-less deployments.
protocol RateLimitStore: Sendable {
    /// Atomically increment the fixed-window counter at `key`, creating it with a
    /// `window`-second TTL on the first hit, and return the new count plus the
    /// seconds left in the window.
    func hit(_ key: String, window: Int) async throws -> RateLimitCount

    /// Read a stored integer (e.g. a lockout expiry epoch), or `nil` if absent.
    func readInt(_ key: String) async throws -> Int?

    /// Store an integer with a TTL (seconds).
    func writeInt(_ key: String, value: Int, ttl: Int) async throws

    /// Delete a key (used to clear failure state after a successful auth).
    func reset(_ key: String) async throws
    /// Reconcile one distributed result with the active shadow and return the
    /// enforced count without sliding the deadline or merging different windows.
    func observeCount(_ key: String, count: RateLimitCount) async throws -> RateLimitCount
}

extension RateLimitStore {
    func observeCount(_ key: String, count: RateLimitCount) async throws -> RateLimitCount { count }
}

/// Selects the shared or process-local rate-limit adapter and bounds every
/// backend operation. Both HTTP rate-limit entry points use this module so a
/// slow coordination backend has one fail-open deadline contract.
struct RateLimitBackend: Sendable {
    static let defaultDeadline: Duration = .seconds(2)

    private let fallbackStore: any RateLimitStore
    private let valkeyStore: (any RateLimitStore)?
    private let deadline: Duration
    private let gate: CoordinationFailureGate
    private let now: @Sendable () -> Double

    init(
        fallbackStore: any RateLimitStore,
        valkeyStore: (any RateLimitStore)? = nil,
        deadline: Duration = Self.defaultDeadline,
        gate: CoordinationFailureGate? = nil,
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.fallbackStore = fallbackStore
        self.valkeyStore = valkeyStore
        self.deadline = deadline
        self.now = now
        self.gate =
            gate
            ?? CoordinationFailureGate(
                deadline: deadline,
                probe: {
                    _ = try await valkeyStore?.readInt("health:probe")
                })
    }

    func hit(_ key: String, window: Int, useValkey: Bool = true) async throws -> RateLimitCount {
        // Shadow every hit while healthy so entering degradation cannot restart
        // an already active window. The stricter count wins during recovery too.
        let local = try await withStoreTimeout(deadline) { try await fallbackStore.hit(key, window: window) }
        guard useValkey, let valkeyStore else { return local }
        do {
            let shared = try await gate.run(operation: "rateLimit.hit", deadline: deadline) {
                try await valkeyStore.hit(key, window: window)
            }
            // Reconcile and choose the result atomically in the shadow. The
            // pre-request local count may belong to a window that just ended.
            return try await withStoreTimeout(deadline) { try await fallbackStore.observeCount(key, count: shared) }
        } catch is CancellationError { throw CancellationError() } catch { return local }
    }

    func readInt(_ key: String, useValkey: Bool = true) async throws -> Int? {
        let local = try await withStoreTimeout(deadline) { try await fallbackStore.readInt(key) }
        guard useValkey, let valkeyStore else { return local }
        do {
            let shared = try await gate.run(operation: "rateLimit.readInt", deadline: deadline) {
                try await valkeyStore.readInt(key)
            }
            if let shared {
                // These integers are lockout expiry epochs, so preserve the
                // remaining lifetime rather than extending it on every read.
                let expiry = max(local ?? shared, shared)
                let remaining = max(1, expiry - Int(now()))
                try await withStoreTimeout(deadline) {
                    try await fallbackStore.writeInt(key, value: expiry, ttl: remaining)
                }
            }
            return [local, shared].compactMap { $0 }.max()
        } catch is CancellationError { throw CancellationError() } catch { return local }
    }

    func writeInt(_ key: String, value: Int, ttl: Int, useValkey: Bool = true) async throws {
        try await withStoreTimeout(deadline) { try await fallbackStore.writeInt(key, value: value, ttl: ttl) }
        guard useValkey, let valkeyStore else { return }
        do {
            try await gate.run(operation: "rateLimit.writeInt", deadline: deadline) {
                try await valkeyStore.writeInt(key, value: value, ttl: ttl)
            }
        } catch is CancellationError { throw CancellationError() } catch { /* The local lockout remains armed. */  }
    }

    func reset(_ key: String, useValkey: Bool = true) async throws {
        try await withStoreTimeout(deadline) { try await fallbackStore.reset(key) }
        guard useValkey, let valkeyStore else { return }
        do {
            try await gate.run(operation: "rateLimit.reset", deadline: deadline) {
                try await valkeyStore.reset(key)
            }
        } catch is CancellationError { throw CancellationError() } catch
        { /* Successful authentication cleared this replica's state. */  }
    }

}

/// The shared fixed-window response contract for ordinary API requests and
/// authenticated-agent guest-identity minting.
struct FixedWindowRateLimitResult: Sendable {
    let limit: Int
    let remaining: Int
    let resetAfter: Int
    let exceeded: Bool

    init(limit: Int, count: RateLimitCount) {
        self.limit = limit
        self.remaining = max(0, limit - count.count)
        self.resetAfter = count.ttl
        self.exceeded = count.count > limit
    }

    func applyHeaders(to response: Response) {
        response.headers.replaceOrAdd(name: "X-RateLimit-Limit", value: String(limit))
        response.headers.replaceOrAdd(name: "X-RateLimit-Remaining", value: String(remaining))
        response.headers.replaceOrAdd(name: "X-RateLimit-Reset", value: String(resetAfter))
    }

    func limitedResponse() -> Response {
        let response = Response(status: .tooManyRequests)
        response.headers.contentType = .json
        struct ErrorBody: Content { let error: Bool; let reason: String }
        do {
            try response.content.encode(
                ErrorBody(
                    error: true,
                    reason: "Rate limit exceeded. Try again in \(resetAfter)s."))
        } catch {
            response.body = .init(string: #"{"error":true,"reason":"Rate limit exceeded."}"#)
        }
        applyHeaders(to: response)
        response.headers.replaceOrAdd(name: "Retry-After", value: String(resetAfter))
        return response
    }
}

// MARK: - Valkey backend

/// Valkey-backed store. Counters live in Valkey so that a rate limit is
/// enforced consistently no matter which control-plane replica a request lands
/// on. The increment+expire+TTL read is done in one cached atomic Lua script so
/// a crash between `INCR` and `EXPIRE` can't leave an immortal counter.
struct ValkeyRateLimitStore: RateLimitStore {
    let client: ValkeyClient
    private let scripts: ValkeyScriptExecutor

    init(client: ValkeyClient) {
        self.client = client
        self.scripts = ValkeyScriptExecutor(client: client)
    }

    /// Return the count, TTL, precise remaining lifetime and server expiry.
    /// The expiry identifies a fixed window across observations and replicas.
    private static let hitScript = """
        local count = redis.call('INCR', KEYS[1])
        if count == 1 then
            redis.call('EXPIRE', KEYS[1], ARGV[1])
        end
        local ttl = redis.call('TTL', KEYS[1])
        local remaining = redis.call('PTTL', KEYS[1])
        local expiry = redis.pcall('PEXPIRETIME', KEYS[1])
        if type(expiry) ~= 'number' then expiry = -1 end
        return {count, ttl, remaining, expiry}
        """

    func hit(_ key: String, window: Int) async throws -> RateLimitCount {
        let response = try await scripts.execute(
            name: "rate-limit.hit",
            script: Self.hitScript,
            keys: [ValkeyKey(key)],
            args: [String(window)]
        )

        guard let values = try? response.decode(as: [Int].self), values.count == 4 else {
            throw RateLimitError.unexpectedResponse
        }

        // A key with no expiry reports TTL -1; treat that as a full fresh window
        // rather than surfacing a negative reset to the client.
        return RateLimitCount(
            count: values[0], ttl: values[1] < 0 ? window : values[1],
            windowExpiresAtMilliseconds: values[3] < 0 ? nil : values[3],
            remainingMilliseconds: values[2] < 0 ? nil : values[2])
    }

    func readInt(_ key: String) async throws -> Int? {
        try await client.get(ValkeyKey(key)).map(String.init).flatMap(Int.init)
    }

    func writeInt(_ key: String, value: Int, ttl: Int) async throws {
        _ = try await client.set(
            ValkeyKey(key), value: String(value), expiration: .seconds(max(1, ttl)))
    }

    func reset(_ key: String) async throws {
        _ = try await client.del(keys: [ValkeyKey(key)])
    }
}

enum RateLimitError: Error {
    case unexpectedResponse
    case backendTimeout(Duration)
}

// MARK: - In-memory backend

/// Bounded process-local shadow used when Valkey is absent or unavailable. Correct for a
/// single control-plane instance; with multiple replicas each enforces its own
/// counters (roughly N× the effective limit), which is why Valkey is preferred
/// in multi-node deployments. State is swept lazily to keep memory bounded.
actor InMemoryRateLimitStore: RateLimitStore {
    private struct Window {
        var count: Int
        var expiresAt: Double
        var observedWindowEnd: Int? = nil
    }
    private struct StoredValue {
        var value: Int
        var expiresAt: Double
    }

    private let maxEntries: Int
    private let now: @Sendable () -> Double
    init(maxEntries: Int = 100_000, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.maxEntries = max(1, maxEntries)
        self.now = now
    }

    private var windows: [String: Window] = [:]
    private var values: [String: StoredValue] = [:]
    private var lastSweep: Double = 0
    // One conservative overflow horizon preserves newly armed lockouts even
    // after another entry expires and capacity becomes available. It cannot
    // track per-key exceptions without exceeding the memory bound.
    private var overflowLockoutUntil: Int = 0

    func hit(_ key: String, window: Int) -> RateLimitCount {
        let now = self.now()
        sweepIfNeeded(now)

        if let existing = windows[key], existing.expiresAt > now {
            let count = existing.count + 1
            let updated = Window(
                count: count, expiresAt: existing.expiresAt, observedWindowEnd: existing.observedWindowEnd)
            windows[key] = updated
            return windowCount(updated, at: now)
        }

        guard windows[key] != nil || windows.count < maxEntries else {
            // Never evict an active security window to admit an attacker-chosen
            // key. Overflow receives a conservative denial until capacity frees.
            return RateLimitCount(count: Int.max, ttl: max(1, window))
        }
        let expiresAt = now + Double(window)
        let created = Window(count: 1, expiresAt: expiresAt)
        windows[key] = created
        return windowCount(created, at: now)
    }

    private func windowCount(_ window: Window, at now: Double) -> RateLimitCount {
        RateLimitCount(
            count: window.count, ttl: ttlSeconds(from: now, to: window.expiresAt),
            windowExpiresAtMilliseconds: window.observedWindowEnd ?? Int((window.expiresAt * 1000).rounded()),
            remainingMilliseconds: max(0, Int(((window.expiresAt - now) * 1000).rounded(.down))))
    }

    func observeCount(_ key: String, count: RateLimitCount) async -> RateLimitCount {
        let now = self.now()
        sweepIfNeeded(now)
        guard windows[key] != nil || windows.count < maxEntries else {
            return RateLimitCount(count: Int.max, ttl: max(1, count.ttl))
        }
        let existing = windows[key].flatMap { $0.expiresAt > now ? $0 : nil }
        let remaining = count.remainingMilliseconds.map { Double($0) / 1000 } ?? Double(max(1, count.ttl))
        let observedExpiry = now + remaining
        if let existing, let previous = existing.observedWindowEnd, let incoming = count.windowExpiresAtMilliseconds {
            if incoming < previous {
                // An older request completed after a newer window's response.
                // Its caller receives its own result; it cannot overwrite the shadow.
                return count
            }
            let serverNow = count.remainingMilliseconds.map { incoming - $0 }
            if incoming > previous, let serverNow, serverNow >= previous {
                let renewed = Window(count: count.count, expiresAt: observedExpiry, observedWindowEnd: incoming)
                windows[key] = renewed
                return windowCount(renewed, at: now)
            }
        }
        // If the store lost its counter before the prior window ended, keep
        // this replica's active count and deadline until that window expires.
        let reconciled = Window(
            count: max(existing?.count ?? 0, count.count),
            // A rounded TTL observation must not renew an active fixed window.
            expiresAt: min(existing?.expiresAt ?? observedExpiry, observedExpiry),
            observedWindowEnd: count.windowExpiresAtMilliseconds ?? existing?.observedWindowEnd)
        windows[key] = reconciled
        return windowCount(reconciled, at: now)
    }

    func readInt(_ key: String) -> Int? {
        let now = self.now()
        sweepIfNeeded(now)
        guard let stored = values[key], stored.expiresAt > now else {
            if overflowLockoutUntil > Int(now) { return overflowLockoutUntil }
            if values[key] == nil, values.count >= maxEntries {
                return Int(now) + 60
            }
            values[key] = nil
            return nil
        }
        return stored.value
    }

    func writeInt(_ key: String, value: Int, ttl: Int) {
        let now = self.now()
        sweepIfNeeded(now)
        guard values[key] != nil || values.count < maxEntries else {
            let safeTTL = max(1, min(ttl, Int.max - Int(now)))
            overflowLockoutUntil = max(overflowLockoutUntil, max(value, Int(now) + safeTTL))
            return
        }
        values[key] = StoredValue(value: value, expiresAt: now + Double(max(1, ttl)))
    }

    func reset(_ key: String) {
        windows[key] = nil
        values[key] = nil
    }

    private func ttlSeconds(from now: Double, to expiresAt: Double) -> Int {
        max(1, Int((expiresAt - now).rounded(.up)))
    }

    /// Drop expired entries at most once per minute so a stream of unique keys
    /// (e.g. many distinct client IPs) can't grow the maps without bound.
    private func sweepIfNeeded(_ now: Double) {
        guard now - lastSweep > 60 else { return }
        lastSweep = now
        windows = windows.filter { $0.value.expiresAt > now }
        values = values.filter { $0.value.expiresAt > now }
    }
}
