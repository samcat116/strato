import Testing
import Vapor
import VaporTesting
@testable import App

@Suite("Rate Limiting Tests", .serialized)
struct RateLimitTests {

    /// Build a minimal app wired with only the rate-limit middleware and a couple
    /// of test routes, so these tests exercise the limiter in isolation without a
    /// database, SpiceDB, or the full middleware stack.
    private func withRateLimitedApp(
        config: RateLimitConfig,
        _ test: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            app.middleware.use(
                RateLimitMiddleware(
                    config: config,
                    fallbackStore: InMemoryRateLimitStore()
                ))
            // General API route (scope: api).
            app.get("api", "things") { _ in "ok" }
            // Auth route that always fails (scope: auth) — drives the backoff.
            app.post("auth", "login", "finish") { _ in Response(status: .unauthorized) }
            // Auth route that fails by *throwing* (the real controllers do this).
            app.post("auth", "login", "throw") { _ -> Response in throw Abort(.unauthorized) }
            // Auth route that succeeds (scope: auth) — clears failure state.
            app.post("auth", "login", "ok") { _ in Response(status: .ok) }
            // Health probe (must never be throttled).
            app.get("health") { _ in "healthy" }

            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func baseConfig(
        authLimit: Int = 100,
        authWindow: Int = 60,
        apiLimit: Int = 100,
        apiWindow: Int = 60,
        failureThreshold: Int = 5,
        failureBaseDelay: Int = 2,
        failureMaxDelay: Int = 300,
        failureWindow: Int = 900
    ) -> RateLimitConfig {
        RateLimitConfig(
            enabled: true,
            authLimit: authLimit,
            authWindow: authWindow,
            apiLimit: apiLimit,
            apiWindow: apiWindow,
            failureThreshold: failureThreshold,
            failureBaseDelay: failureBaseDelay,
            failureMaxDelay: failureMaxDelay,
            failureWindow: failureWindow,
            trustForwardedFor: true
        )
    }

    @Test("Requests under the API limit succeed and carry rate-limit headers")
    func testUnderLimitHasHeaders() async throws {
        try await withRateLimitedApp(config: baseConfig(apiLimit: 5)) { app in
            try await app.test(.GET, "/api/things") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "X-RateLimit-Limit") == "5")
                #expect(res.headers.first(name: "X-RateLimit-Remaining") == "4")
                #expect(res.headers.first(name: "X-RateLimit-Reset") != nil)
            }
        }
    }

    @Test("Exceeding the API limit returns 429 with Retry-After")
    func testApiLimitExceeded() async throws {
        try await withRateLimitedApp(config: baseConfig(apiLimit: 3)) { app in
            for _ in 0..<3 {
                try await app.test(.GET, "/api/things") { res async throws in
                    #expect(res.status == .ok)
                }
            }
            try await app.test(.GET, "/api/things") { res async throws in
                #expect(res.status == .tooManyRequests)
                #expect(res.headers.first(name: "Retry-After") != nil)
                #expect(res.headers.first(name: "X-RateLimit-Remaining") == "0")
            }
        }
    }

    @Test("Auth routes use the stricter auth limit, independent of the API bucket")
    func testAuthLimitStricter() async throws {
        // Low auth limit, high api limit: auth throttles while api keeps flowing.
        try await withRateLimitedApp(config: baseConfig(authLimit: 2, apiLimit: 1000)) { app in
            for _ in 0..<2 {
                try await app.test(.POST, "/auth/login/ok") { res async throws in
                    #expect(res.status == .ok)
                }
            }
            try await app.test(.POST, "/auth/login/ok") { res async throws in
                #expect(res.status == .tooManyRequests)
            }
        }
    }

    @Test("Health checks are never throttled")
    func testHealthNotThrottled() async throws {
        try await withRateLimitedApp(config: baseConfig(apiLimit: 1)) { app in
            for _ in 0..<10 {
                try await app.test(.GET, "/health") { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: "X-RateLimit-Limit") == nil)
                }
            }
        }
    }

    @Test("Repeated auth failures trigger an exponential lockout")
    func testExponentialBackoffOnFailures() async throws {
        // threshold 2, base delay 5s, high auth limit so the fixed window doesn't
        // mask the backoff. Failures: 1,2 (no lock), 3rd arms a lock; the 4th
        // request is rejected with a lockout 429.
        let config = baseConfig(authLimit: 1000, failureThreshold: 2, failureBaseDelay: 5)
        try await withRateLimitedApp(config: config) { app in
            for _ in 0..<3 {
                try await app.test(.POST, "/auth/login/finish") { res async throws in
                    #expect(res.status == .unauthorized)
                }
            }
            try await app.test(.POST, "/auth/login/finish") { res async throws in
                #expect(res.status == .tooManyRequests)
                #expect(res.headers.first(name: "Retry-After") != nil)
            }
        }
    }

    @Test("Backoff counts failures that surface as thrown Aborts")
    func testExponentialBackoffOnThrownFailures() async throws {
        let config = baseConfig(authLimit: 1000, failureThreshold: 2, failureBaseDelay: 5)
        try await withRateLimitedApp(config: config) { app in
            for _ in 0..<3 {
                try await app.test(.POST, "/auth/login/throw") { res async throws in
                    #expect(res.status == .unauthorized)
                }
            }
            try await app.test(.POST, "/auth/login/throw") { res async throws in
                #expect(res.status == .tooManyRequests)
                #expect(res.headers.first(name: "Retry-After") != nil)
            }
        }
    }

    @Test("A successful auth clears the failure backoff state")
    func testSuccessResetsBackoff() async throws {
        let config = baseConfig(authLimit: 1000, failureThreshold: 2, failureBaseDelay: 5)
        try await withRateLimitedApp(config: config) { app in
            // Two failures — below the threshold, no lock yet.
            for _ in 0..<2 {
                try await app.test(.POST, "/auth/login/finish") { res async throws in
                    #expect(res.status == .unauthorized)
                }
            }
            // A success clears the counter.
            try await app.test(.POST, "/auth/login/ok") { res async throws in
                #expect(res.status == .ok)
            }
            // Failures start over: a single further failure must not lock out.
            try await app.test(.POST, "/auth/login/finish") { res async throws in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("A spoofed left-most X-Forwarded-For entry can't mint a fresh bucket")
    func testForwardedForUsesRightmostHop() async throws {
        // Trusted proxy appends the real peer, so the right-most entry is the one
        // the client can't forge. Two requests that vary only the left-most
        // (attacker-supplied) entry must share a bucket — otherwise a client could
        // evade the limiter by rotating that value per request.
        try await withRateLimitedApp(config: baseConfig(apiLimit: 1)) { app in
            var first = HTTPHeaders()
            first.add(name: "X-Forwarded-For", value: "1.1.1.1, 9.9.9.9")
            try await app.test(.GET, "/api/things", headers: first) { res async throws in
                #expect(res.status == .ok)
            }
            var second = HTTPHeaders()
            second.add(name: "X-Forwarded-For", value: "2.2.2.2, 9.9.9.9")
            try await app.test(.GET, "/api/things", headers: second) { res async throws in
                #expect(res.status == .tooManyRequests)
            }
        }
    }

    @Test("X-Real-IP is trusted over a client-supplied X-Forwarded-For")
    func testRealIPPreferredOverForwardedFor() async throws {
        // The proxy sets X-Real-IP to the immediate peer; a forged XFF must not
        // override it. Both requests carry different (spoofed) XFF values but the
        // same X-Real-IP, so they share a bucket and the second is throttled.
        try await withRateLimitedApp(config: baseConfig(apiLimit: 1)) { app in
            var first = HTTPHeaders()
            first.add(name: "X-Real-IP", value: "9.9.9.9")
            first.add(name: "X-Forwarded-For", value: "1.1.1.1")
            try await app.test(.GET, "/api/things", headers: first) { res async throws in
                #expect(res.status == .ok)
            }
            var second = HTTPHeaders()
            second.add(name: "X-Real-IP", value: "9.9.9.9")
            second.add(name: "X-Forwarded-For", value: "2.2.2.2")
            try await app.test(.GET, "/api/things", headers: second) { res async throws in
                #expect(res.status == .tooManyRequests)
            }
        }
    }

    @Test("Disabled config lets all traffic through untouched")
    func testDisabledPassesThrough() async throws {
        try await withRateLimitedApp(config: baseConfig(apiLimit: 1).with { $0.enabled = false }) { app in
            for _ in 0..<5 {
                try await app.test(.GET, "/api/things") { res async throws in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: "X-RateLimit-Limit") == nil)
                }
            }
        }
    }
}

private extension RateLimitConfig {
    /// Small mutating-copy helper for tweaking one field in a test.
    func with(_ mutate: (inout RateLimitConfig) -> Void) -> RateLimitConfig {
        var copy = self
        mutate(&copy)
        return copy
    }
}
