import Testing
import Vapor
import VaporTesting
@testable import App

@Suite("Security Headers Tests", .serialized)
struct SecurityHeadersTests {

    @Test("Standard security headers are set on responses")
    func testStandardSecurityHeaders() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)

        try await app.test(.GET, "/health") { res async throws in
            #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
            #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
            #expect(res.headers.first(name: "Referrer-Policy") == "strict-origin-when-cross-origin")
            #expect(res.headers.first(name: "Content-Security-Policy")
                == SecurityHeadersMiddleware.defaultContentSecurityPolicy)
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
    }

    @Test("Security headers are present on synthesized error responses")
    func testHeadersOnErrorResponse() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)

        // An unmatched route becomes a 404 synthesized by Vapor's ErrorMiddleware.
        // The security middleware must sit outside ErrorMiddleware so these still
        // carry the headers.
        try await app.test(.GET, "/this-route-does-not-exist") { res async throws in
            #expect(res.status == .notFound)
            #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
            #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
    }

    @Test("HSTS is not sent from a plaintext (non-TLS) server")
    func testNoHSTSWithoutTLS() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)

        // The testing environment isn't served over TLS, so HSTS must be absent
        // to avoid pinning browsers to a non-existent https:// origin.
        try await app.test(.GET, "/health") { res async throws in
            #expect(res.headers.first(name: "Strict-Transport-Security") == nil)
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
    }

    @Test("Bundled frontend HTML is not given the strict same-origin CSP")
    func testHTMLNotGivenStrictCSP() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)

        // FileMiddleware serves Public/index.html, whose inline Next.js hydration
        // scripts would be blocked by the strict default CSP — so it must not be
        // applied to HTML. X-Frame-Options/nosniff still cover these responses.
        try await app.test(.GET, "/index.html") { res async throws in
            #expect(res.status == .ok)
            #expect(res.headers.first(name: "Content-Security-Policy")
                != SecurityHeadersMiddleware.defaultContentSecurityPolicy)
            #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
            #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
    }

    @Test("API docs page supplies its own CSP allowing Swagger CDN")
    func testDocsPageOverridesCSP() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)

        try await app.test(.GET, "/api/docs") { res async throws in
            let csp = res.headers.first(name: "Content-Security-Policy")
            #expect(csp != nil)
            #expect(csp != SecurityHeadersMiddleware.defaultContentSecurityPolicy)
            #expect(csp?.contains("https://unpkg.com") == true)
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
    }
}
