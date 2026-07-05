import Foundation
import Vapor
import Redis

/// Result of incrementing a fixed-window counter: the new hit count within the
/// current window and the seconds remaining until that window resets.
struct RateLimitCount: Sendable {
    let count: Int
    let ttl: Int
}

/// Backend-agnostic operations the rate limiter needs. Two implementations exist:
/// a Valkey/Redis-backed store (`RedisRateLimitStore`) used when Valkey is
/// configured so counters are shared across every control-plane instance, and an
/// in-process actor (`InMemoryRateLimitStore`) used as a fallback for single-node
/// or Valkey-less deployments.
///
/// The protocol is intentionally *not* `Sendable`: the Redis implementation wraps
/// a per-request `RedisClient` and is only ever created and consumed as a local
/// inside a single request's task, so it never crosses an isolation boundary.
/// The in-memory implementation is an `actor`, which is `Sendable` on its own and
/// is shared across requests via the middleware.
protocol RateLimitStore {
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
}

// MARK: - Redis / Valkey backend

/// Valkey/Redis-backed store. Counters live in Valkey so that a rate limit is
/// enforced consistently no matter which control-plane replica a request lands
/// on. The increment+expire+TTL read is done in a single atomic `EVAL` so a
/// crash between `INCR` and `EXPIRE` can't leave an immortal counter.
struct RedisRateLimitStore: RateLimitStore {
    let client: any RedisClient

    /// `INCR` the key, set its TTL on the first hit only, and return `{count, ttl}`.
    private static let hitScript = """
        local count = redis.call('INCR', KEYS[1])
        if count == 1 then
            redis.call('EXPIRE', KEYS[1], ARGV[1])
        end
        return {count, redis.call('TTL', KEYS[1])}
        """

    func hit(_ key: String, window: Int) async throws -> RateLimitCount {
        let response = try await client.send(
            command: "EVAL",
            with: [
                Self.hitScript.convertedToRESPValue(),
                1.convertedToRESPValue(),
                key.convertedToRESPValue(),
                window.convertedToRESPValue(),
            ]
        ).get()

        guard let values = response.array,
            values.count == 2,
            let count = values[0].int,
            let ttl = values[1].int
        else {
            throw RateLimitError.unexpectedResponse
        }

        // A key with no expiry reports TTL -1; treat that as a full fresh window
        // rather than surfacing a negative reset to the client.
        return RateLimitCount(count: count, ttl: ttl < 0 ? window : ttl)
    }

    func readInt(_ key: String) async throws -> Int? {
        let response = try await client.send(
            command: "GET",
            with: [key.convertedToRESPValue()]
        ).get()
        return response.int
    }

    func writeInt(_ key: String, value: Int, ttl: Int) async throws {
        _ = try await client.send(
            command: "SET",
            with: [
                key.convertedToRESPValue(),
                value.convertedToRESPValue(),
                "EX".convertedToRESPValue(),
                max(1, ttl).convertedToRESPValue(),
            ]
        ).get()
    }

    func reset(_ key: String) async throws {
        _ = try await client.send(
            command: "DEL",
            with: [key.convertedToRESPValue()]
        ).get()
    }
}

enum RateLimitError: Error {
    case unexpectedResponse
}

// MARK: - In-memory backend

/// Process-local fallback used when Valkey isn't configured. Correct for a
/// single control-plane instance; with multiple replicas each enforces its own
/// counters (roughly N× the effective limit), which is why Valkey is preferred
/// in multi-node deployments. State is swept lazily to keep memory bounded.
actor InMemoryRateLimitStore: RateLimitStore {
    private struct Window {
        var count: Int
        var expiresAt: Double
    }
    private struct StoredValue {
        var value: Int
        var expiresAt: Double
    }

    private var windows: [String: Window] = [:]
    private var values: [String: StoredValue] = [:]
    private var lastSweep: Double = 0

    func hit(_ key: String, window: Int) -> RateLimitCount {
        let now = Date().timeIntervalSince1970
        sweepIfNeeded(now)

        if let existing = windows[key], existing.expiresAt > now {
            let count = existing.count + 1
            windows[key] = Window(count: count, expiresAt: existing.expiresAt)
            return RateLimitCount(count: count, ttl: ttlSeconds(from: now, to: existing.expiresAt))
        }

        let expiresAt = now + Double(window)
        windows[key] = Window(count: 1, expiresAt: expiresAt)
        return RateLimitCount(count: 1, ttl: window)
    }

    func readInt(_ key: String) -> Int? {
        let now = Date().timeIntervalSince1970
        guard let stored = values[key], stored.expiresAt > now else {
            values[key] = nil
            return nil
        }
        return stored.value
    }

    func writeInt(_ key: String, value: Int, ttl: Int) {
        let now = Date().timeIntervalSince1970
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
