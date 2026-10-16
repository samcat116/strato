import Foundation
import Testing
import Valkey
import Vapor
import AppTestSupport
@testable import App

@Suite("Rate-limit disposable Valkey windows", .enabled(if: Environment.get("STRATO_RATELIMIT_VALKEY_PORT") != nil))
struct RateLimitValkeyWindowTests {
    @Test("Real Lua results retain one expiry within a window and reset the shadow on rollover")
    func realWindowMetadata() async throws {
        let port = try #require(Environment.get("STRATO_RATELIMIT_VALKEY_PORT").flatMap(Int.init))
        let app = try await Application.make(.testing)
        let endpoint = ValkeyConfiguration(hostname: "127.0.0.1", port: port)
        app.configureValkey(.init(coordination: endpoint, session: endpoint, warnings: []))
        let client = app.coordinationValkey
        let run = Task { await client.run() }
        let key = "fixture:rollover:\(UUID())"
        let shared = ValkeyRateLimitStore(client: client)
        let backend = RateLimitBackend(fallbackStore: InMemoryRateLimitStore(), valkeyStore: shared)
        do {
            for _ in 0..<3 {
                let first = try await backend.hit(key, window: 1)
                #expect(first.count == 1)
                let expiry = try #require(first.windowExpiresAtMilliseconds)
                #expect(try #require(first.remainingMilliseconds) > 0)
                let second = try await backend.hit(key, window: 1)
                #expect(second.count == 2)
                #expect(second.windowExpiresAtMilliseconds == expiry)
                #expect(try await backend.hit(key, window: 1).count == 3)
                try await Task.sleep(for: .milliseconds(1_100))
            }
            try await shared.reset(key)
        } catch {
            run.cancel()
            try await app.shutdownForTesting()
            throw error
        }
        run.cancel()
        try await app.shutdownForTesting()
    }
}
