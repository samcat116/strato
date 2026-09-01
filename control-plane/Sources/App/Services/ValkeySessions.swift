import Foundation
import Valkey
import Vapor

/// The key/value operations session storage needs, split out from the driver so
/// the write-back and expiry policy can be exercised without a live Valkey
/// (the `.testing` environment has none and uses Fluent sessions).
protocol SessionStore: Sendable {
    /// Read a session payload and slide its expiry in the same round trip.
    /// Returns `nil` for an unknown or expired session.
    func read(_ key: String, refreshingTTL ttl: Int) async throws -> ByteBuffer?

    /// Store a session payload, (re)setting its expiry.
    func write(_ key: String, value: ByteBuffer, ttl: Int) async throws

    /// Remove a session payload.
    func delete(_ key: String) async throws
}

/// Valkey-backed session storage, replacing vapor/redis's `.redis` driver
/// (which has no Vapor-5-era successor). Wire format is kept compatible with
/// that driver — the same `vrs-` key prefix and JSON-encoded `SessionData`
/// values — so sessions created before the swap keep working.
///
/// Two things that driver got wrong, and this one doesn't (issue #695):
///
///  - **Keys expire.** With no TTL, every logged-out or abandoned session stayed
///    in Valkey forever — a slow memory leak in each deployment. The expiry is
///    idle-based: reads slide it (see `SessionStore.read`), so an active session
///    is never cut off mid-use.
///  - **Unchanged sessions aren't rewritten.** See `updateSession`.
///
/// `SessionDriver` is still an `EventLoopFuture` protocol in Vapor 4, so each
/// method bridges to async with `makeFutureWithTask`; the driver itself does
/// no future composition.
struct ValkeySessionDriver: SessionDriver {
    let store: any SessionStore

    /// Idle lifetime of a session key, in seconds.
    let ttl: Int

    private func key(for sessionID: SessionID) -> String {
        "vrs-\(sessionID.string)"
    }

    func createSession(_ data: SessionData, for request: Request) -> EventLoopFuture<SessionID> {
        let sessionID = SessionID(string: [UInt8].random(count: 32).base64)
        return request.eventLoop.makeFutureWithTask {
            try await persist(data, as: sessionID, for: request)
            return sessionID
        }
    }

    func readSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<SessionData?> {
        request.eventLoop.makeFutureWithTask {
            guard let stored = try await store.read(key(for: sessionID), refreshingTTL: ttl) else {
                return nil
            }
            let data = try JSONDecoder().decode(SessionData.self, from: stored)
            request.persistedSession = PersistedSession(id: sessionID, data: data)
            return data
        }
    }

    /// Vapor's `SessionsMiddleware` calls this on every response carrying a
    /// session, changed or not — so for a plain authenticated GET the old driver
    /// re-encoded and re-SET byte-identical data, spending a Valkey round trip
    /// on nothing. Skip the write when the data still matches what this request
    /// read (or last wrote); the read already slid the TTL, so staying quiet
    /// costs the session nothing.
    func updateSession(_ sessionID: SessionID, to data: SessionData, for request: Request) -> EventLoopFuture<SessionID>
    {
        if let persisted = request.persistedSession, persisted.id == sessionID, persisted.data == data {
            return request.eventLoop.makeSucceededFuture(sessionID)
        }
        return request.eventLoop.makeFutureWithTask {
            try await persist(data, as: sessionID, for: request)
            return sessionID
        }
    }

    func deleteSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<Void> {
        request.eventLoop.makeFutureWithTask {
            try await store.delete(key(for: sessionID))
            request.persistedSession = nil
        }
    }

    private func persist(_ data: SessionData, as sessionID: SessionID, for request: Request) async throws {
        let json = try JSONEncoder().encode(data)
        try await store.write(key(for: sessionID), value: ByteBuffer(data: json), ttl: ttl)
        request.persistedSession = PersistedSession(id: sessionID, data: data)
    }
}

// MARK: - Configuration

extension ValkeySessionDriver {
    /// Idle session lifetime when `SESSION_TTL_SECONDS` is unset: a week, which
    /// comfortably outlives the browser-session cookie carrying the ID while
    /// still reclaiming abandoned sessions.
    static let defaultTTL = 7 * 24 * 60 * 60

    /// Refuse implausibly short lifetimes: a typo (say `SESSION_TTL_SECONDS=1`)
    /// would expire sessions mid-use and read as random logouts.
    static let minimumTTL = 60

    static func ttlFromConfiguration(_ configuration: ControlPlaneConfiguration) -> Int {
        configuration.int(.sessionTTLSeconds)
    }
}

// MARK: - Valkey store

struct ValkeySessionStore: SessionStore {
    let client: ValkeyClient

    /// `GETEX key EX ttl`: the fetch and the sliding-expiry refresh in one round
    /// trip, so keeping a session alive costs nothing extra. Sessions written by
    /// the pre-TTL driver pick up an expiry the first time they're read.
    func read(_ key: String, refreshingTTL ttl: Int) async throws -> ByteBuffer? {
        guard let stored = try await client.getex(ValkeyKey(key), expiration: .seconds(ttl)) else {
            return nil
        }
        return ByteBuffer(stored)
    }

    func write(_ key: String, value: ByteBuffer, ttl: Int) async throws {
        _ = try await client.set(ValkeyKey(key), value: value, expiration: .seconds(ttl))
    }

    func delete(_ key: String) async throws {
        _ = try await client.del(keys: [ValkeyKey(key)])
    }
}

// MARK: - Request-scoped snapshot

/// What the store holds for this request's session, as far as the driver knows.
/// A `Request` handles exactly one read → mutate → write-back cycle, so this is
/// enough to tell a real change from Vapor's unconditional write-back.
private struct PersistedSession: Sendable {
    let id: SessionID
    let data: SessionData
}

extension Request {
    fileprivate var persistedSession: PersistedSession? {
        get { storage[PersistedSessionKey.self] }
        set { storage[PersistedSessionKey.self] = newValue }
    }

    private struct PersistedSessionKey: StorageKey {
        typealias Value = PersistedSession
    }
}

extension Application.Sessions.Provider {
    /// Session storage in `store`.
    ///
    /// The store is injected rather than resolved from `app` inside this
    /// closure so the caller decides which client backs sessions — the
    /// coordination client by default, or a separate one when
    /// `SESSION_VALKEY_HOST` names another endpoint (issue #855). It also lets
    /// `configure` hold on to the same instance for the readiness probe.
    static func valkey(store: any SessionStore) -> Self {
        .init {
            $0.sessions.use { app in
                ValkeySessionDriver(
                    store: store,
                    ttl: ValkeySessionDriver.ttlFromConfiguration(app.controlPlaneConfiguration)
                )
            }
        }
    }
}

// MARK: - Readiness

extension Application {
    /// The live session store, when one is configured (never under `.testing`,
    /// which uses Fluent sessions).
    ///
    /// Held so `/health/ready` can probe session storage directly. Unlike
    /// coordination, this dependency cannot fail open: a replica that cannot
    /// read sessions cannot authenticate anyone, so readiness grades it fatal.
    var sessionStore: (any SessionStore)? {
        get { storage[SessionStoreKey.self] }
        set { setStorageValue(SessionStoreKey.self, to: newValue) }
    }

    private struct SessionStoreKey: StorageKey {
        typealias Value = any SessionStore
    }
}

extension SessionStore {
    /// Readiness round-trip: a plain `GETEX` of a key nothing writes, so it
    /// proves reachability without touching a real session. A miss is the
    /// expected result — only a thrown error means the store is unusable.
    func probeReachability() async throws {
        _ = try await read(Self.readinessProbeKey, refreshingTTL: 60)
    }

    static var readinessProbeKey: String { "vrs-health-probe" }
}
