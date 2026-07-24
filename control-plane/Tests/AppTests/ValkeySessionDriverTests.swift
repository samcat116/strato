import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// The Valkey session driver's write-back and expiry policy (issue #695),
/// exercised against an in-memory `SessionStore` so no Valkey is needed.
@Suite("Valkey Session Driver Tests", .serialized)
struct ValkeySessionDriverTests {

    /// Session lifetime used throughout; distinct from any TTL a test seeds so
    /// a slid expiry is unambiguous.
    private static let ttl = 900

    /// Records operations, not just final state, so tests can assert on the
    /// round trips the driver actually makes.
    private actor RecordingSessionStore: SessionStore {
        struct Entry {
            var value: ByteBuffer
            var ttl: Int
        }

        private(set) var entries: [String: Entry] = [:]
        private(set) var reads = 0
        private(set) var writes = 0
        private(set) var deletes = 0

        func read(_ key: String, refreshingTTL ttl: Int) async throws -> ByteBuffer? {
            reads += 1
            guard var entry = entries[key] else { return nil }
            entry.ttl = ttl
            entries[key] = entry
            return entry.value
        }

        func write(_ key: String, value: ByteBuffer, ttl: Int) async throws {
            writes += 1
            entries[key] = Entry(value: value, ttl: ttl)
        }

        func delete(_ key: String) async throws {
            deletes += 1
            entries[key] = nil
        }

        /// Pretend time has passed since the key was last touched.
        func setTTL(_ ttl: Int, for key: String) {
            entries[key]?.ttl = ttl
        }

        func ttl(for key: String) -> Int? {
            entries[key]?.ttl
        }

        func storedData(for key: String) throws -> SessionData? {
            guard let entry = entries[key] else { return nil }
            return try JSONDecoder().decode(SessionData.self, from: entry.value)
        }
    }

    private func withDriver(
        _ test: (ValkeySessionDriver, RecordingSessionStore, Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        let store = RecordingSessionStore()
        let driver = ValkeySessionDriver(store: store, ttl: Self.ttl)
        do {
            try await test(driver, store, app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func request(on app: Application) -> Request {
        Request(application: app, on: app.eventLoopGroup.any())
    }

    private func key(for sessionID: SessionID) -> String {
        "vrs-\(sessionID.string)"
    }

    // MARK: - Write-back

    @Test("An unchanged session is not written back")
    func unchangedSessionSkipsWriteBack() async throws {
        try await withDriver { driver, store, app in
            let created = self.request(on: app)
            let id = try await driver.createSession(["user": "alice"], for: created).get()
            var writes = await store.writes
            #expect(writes == 1)

            // A later request: SessionsMiddleware reads the session, the handler
            // touches nothing, and the middleware still calls updateSession.
            let subsequent = self.request(on: app)
            let loaded = try #require(try await driver.readSession(id, for: subsequent).get())
            _ = try await driver.updateSession(id, to: loaded, for: subsequent).get()

            writes = await store.writes
            #expect(writes == 1)
        }
    }

    @Test("A changed session is written back")
    func changedSessionIsWrittenBack() async throws {
        try await withDriver { driver, store, app in
            let created = self.request(on: app)
            let id = try await driver.createSession(["user": "alice"], for: created).get()

            let subsequent = self.request(on: app)
            var data = try #require(try await driver.readSession(id, for: subsequent).get())
            data["theme"] = "dark"
            _ = try await driver.updateSession(id, to: data, for: subsequent).get()

            let writes = await store.writes
            #expect(writes == 2)
            let stored = try await store.storedData(for: self.key(for: id))
            #expect(stored?["theme"] == "dark")
            #expect(stored?["user"] == "alice")
        }
    }

    @Test("A write-back with no prior read on this request is persisted")
    func writeBackWithoutReadIsPersisted() async throws {
        try await withDriver { driver, store, app in
            let created = self.request(on: app)
            let id = try await driver.createSession(["user": "alice"], for: created).get()

            // No read on this request, so the driver has no snapshot to compare
            // against and must not assume the data is unchanged.
            let subsequent = self.request(on: app)
            _ = try await driver.updateSession(id, to: ["user": "alice"], for: subsequent).get()

            let writes = await store.writes
            #expect(writes == 2)
        }
    }

    @Test("A session written after a delete on the same request is persisted")
    func writeAfterDeleteIsPersisted() async throws {
        try await withDriver { driver, store, app in
            let request = self.request(on: app)
            let id = try await driver.createSession(["user": "alice"], for: request).get()
            try await driver.deleteSession(id, for: request).get()
            let deletes = await store.deletes
            #expect(deletes == 1)
            let afterDelete = try await store.storedData(for: self.key(for: id))
            #expect(afterDelete == nil)

            // Same data as before the delete: the snapshot must have been
            // cleared, or a logout-then-login within one request would lose the
            // write.
            _ = try await driver.updateSession(id, to: ["user": "alice"], for: request).get()
            let writes = await store.writes
            #expect(writes == 2)
            let restored = try await store.storedData(for: self.key(for: id))
            #expect(restored != nil)
        }
    }

    // MARK: - Expiry

    @Test("Creating and updating a session sets the TTL")
    func writesCarryTTL() async throws {
        try await withDriver { driver, store, app in
            let request = self.request(on: app)
            let id = try await driver.createSession(["user": "alice"], for: request).get()
            var ttl = await store.ttl(for: self.key(for: id))
            #expect(ttl == Self.ttl)

            await store.setTTL(5, for: self.key(for: id))
            _ = try await driver.updateSession(id, to: ["user": "bob"], for: request).get()
            ttl = await store.ttl(for: self.key(for: id))
            #expect(ttl == Self.ttl)
        }
    }

    @Test("Reading a session slides its expiry")
    func readSlidesExpiry() async throws {
        try await withDriver { driver, store, app in
            let created = self.request(on: app)
            let id = try await driver.createSession(["user": "alice"], for: created).get()
            await store.setTTL(5, for: self.key(for: id))

            let subsequent = self.request(on: app)
            _ = try await driver.readSession(id, for: subsequent).get()

            let ttl = await store.ttl(for: self.key(for: id))
            #expect(ttl == Self.ttl)
        }
    }

    @Test("An expired session reads as absent")
    func expiredSessionReadsAsAbsent() async throws {
        try await withDriver { driver, _, app in
            let unknown = SessionID(string: "does-not-exist")
            let data = try await driver.readSession(unknown, for: self.request(on: app)).get()
            #expect(data == nil)
        }
    }

    // MARK: - TTL configuration

    @Test("SESSION_TTL_SECONDS overrides the default lifetime")
    func ttlFromEnvironment() async throws {
        setenv("SESSION_TTL_SECONDS", "1800", 1)
        defer { unsetenv("SESSION_TTL_SECONDS") }
        let ttl = ValkeySessionDriver.ttlFromEnvironment(logger: Logger(label: "test"))
        #expect(ttl == 1800)
    }

    @Test(
        "An unusable SESSION_TTL_SECONDS falls back to the default",
        arguments: ["not-a-number", "0", "-1", "5"]
    )
    func invalidTTLFallsBackToDefault(value: String) async throws {
        setenv("SESSION_TTL_SECONDS", value, 1)
        defer { unsetenv("SESSION_TTL_SECONDS") }
        let ttl = ValkeySessionDriver.ttlFromEnvironment(logger: Logger(label: "test"))
        #expect(ttl == ValkeySessionDriver.defaultTTL)
    }

    @Test("An unset SESSION_TTL_SECONDS uses the default lifetime")
    func unsetTTLUsesDefault() async throws {
        unsetenv("SESSION_TTL_SECONDS")
        let ttl = ValkeySessionDriver.ttlFromEnvironment(logger: Logger(label: "test"))
        #expect(ttl == ValkeySessionDriver.defaultTTL)
    }
}
