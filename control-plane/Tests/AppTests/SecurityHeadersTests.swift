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
            #expect(
                res.headers.first(name: "Content-Security-Policy")
                    == SecurityHeadersMiddleware.defaultContentSecurityPolicy)
        }

        try await app.shutdownForTesting()
    }

    @Test("Security headers are present on synthesized error responses")
    func testHeadersOnErrorResponse() async throws {
        let app = try await Application.makeForTesting()
        try await configure(app)
        try await app.autoMigrate()

        // An unmatched route becomes a 404 synthesized by Vapor's ErrorMiddleware.
        // The security middleware must sit outside ErrorMiddleware so these still
        // carry the headers. Authenticate the request so `SpiceDBAuthMiddleware`
        // (now active under .testing, issue #196) lets it fall through to the
        // router and produce the 404 we're asserting on — rather than a 401.
        let builder = TestDataBuilder(db: app.db)
        let user = try await builder.createUser()
        let token = try await user.generateAPIKey(on: app.db)

        try await app.test(.GET, "/this-route-does-not-exist") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        } afterResponse: { res async throws in
            #expect(res.status == .notFound)
            #expect(res.headers.first(name: "X-Content-Type-Options") == "nosniff")
            #expect(res.headers.first(name: "X-Frame-Options") == "DENY")
        }

        try await app.shutdownForTesting()
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

        try await app.shutdownForTesting()
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

        try await app.shutdownForTesting()
    }
}
