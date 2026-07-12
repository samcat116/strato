import Testing
import Foundation
import Vapor
@testable import App

@Suite("OIDCValidation Tests")
struct OIDCValidationTests {

    // MARK: - HTTPS URL validation

    @Test("isValidHTTPSURL accepts https URLs with a host")
    func testValidHTTPS() {
        #expect(OIDCValidation.isValidHTTPSURL("https://accounts.google.com/.well-known/openid-configuration"))
        #expect(OIDCValidation.isValidHTTPSURL("https://example.com"))
    }

    @Test("isValidHTTPSURL rejects non-https, hostless, or malformed URLs")
    func testInvalidHTTPS() {
        #expect(!OIDCValidation.isValidHTTPSURL("http://example.com"))
        #expect(!OIDCValidation.isValidHTTPSURL("ftp://example.com"))
        #expect(!OIDCValidation.isValidHTTPSURL("https://"))
        #expect(!OIDCValidation.isValidHTTPSURL("not a url"))
    }

    // MARK: - validateDiscoveredEndpoints

    private func discovery(tokenEndpoint: String) -> OIDCDiscoveryDocument {
        OIDCDiscoveryDocument(
            issuer: "https://idp.example.com",
            authorizationEndpoint: "https://idp.example.com/authorize",
            tokenEndpoint: tokenEndpoint,
            userinfoEndpoint: nil,
            endSessionEndpoint: nil,
            jwksURI: "https://idp.example.com/.well-known/jwks.json",
            responseTypesSupported: ["code"],
            subjectTypesSupported: ["public"],
            idTokenSigningAlgValuesSupported: ["RS256"]
        )
    }

    @Test("validateDiscoveredEndpoints accepts an all-HTTPS document")
    func testDiscoveredEndpointsValid() throws {
        try OIDCValidation.validateDiscoveredEndpoints(discovery(tokenEndpoint: "https://idp.example.com/token"))
    }

    @Test("validateDiscoveredEndpoints rejects an http token endpoint")
    func testDiscoveredEndpointsInsecure() {
        // The token endpoint receives the client secret, so a discovery
        // document must not be able to downgrade it to http.
        #expect(throws: Error.self) {
            try OIDCValidation.validateDiscoveredEndpoints(
                self.discovery(tokenEndpoint: "http://idp.example.com/token"))
        }
    }

    // MARK: - validateURLFields

    private func request(discoveryURL: String? = nil, jwksURI: String? = nil) -> CreateOIDCProviderRequest {
        CreateOIDCProviderRequest(
            name: "p", clientID: "c", clientSecret: "s",
            discoveryURL: discoveryURL, authorizationEndpoint: nil, tokenEndpoint: nil,
            userinfoEndpoint: nil, jwksURI: jwksURI, scopes: nil, enabled: nil,
            groupsClaim: nil, groupMappings: nil, adminClaimValues: nil, defaultRole: nil
        )
    }

    @Test("validateURLFields passes when endpoints are valid or absent")
    func testValidateURLFieldsValid() throws {
        try OIDCValidation.validateURLFields(request: request())
        try OIDCValidation.validateURLFields(request: request(discoveryURL: "https://issuer.example.com"))
    }

    @Test("validateURLFields rejects a non-https endpoint")
    func testValidateURLFieldsInvalid() {
        #expect(throws: Abort.self) {
            try OIDCValidation.validateURLFields(request: request(discoveryURL: "http://issuer.example.com"))
        }
        #expect(throws: Abort.self) {
            try OIDCValidation.validateURLFields(request: request(jwksURI: "http://issuer.example.com/jwks"))
        }
    }

    // MARK: - base64url decoding

    @Test("decodeBase64URLSafe restores padding and decodes")
    func testDecodeBase64URLSafe() throws {
        // base64url of "Hello" (no padding)
        let data = try OIDCValidation.decodeBase64URLSafe("SGVsbG8")
        #expect(String(data: data, encoding: .utf8) == "Hello")
    }

    @Test("decodeBase64URLSafe handles url-safe characters")
    func testDecodeBase64URLSafeURLChars() throws {
        // Bytes 0xFB 0xFF 0xBF encode to "-_-_" style url-safe output; round-trip a known value.
        let original = Data([0xFB, 0xEF, 0xBE])
        let urlSafe = original.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let decoded = try OIDCValidation.decodeBase64URLSafe(urlSafe)
        #expect(decoded == original)
    }

    @Test("decodeBase64URLSafe throws on invalid input")
    func testDecodeBase64URLSafeInvalid() {
        #expect(throws: Abort.self) {
            try OIDCValidation.decodeBase64URLSafe("@@@not-base64@@@")
        }
    }

    // MARK: - SSRF allow-lists

    // Assert on the default constants directly so the test is independent of any
    // OIDC_DISCOVERY_ALLOWED_* environment variables present on the CI host.
    @Test("default host allow-list contains the well-known providers")
    func testDefaultAllowedHosts() {
        #expect(OIDCValidation.defaultAllowedHosts.contains("accounts.google.com"))
        #expect(OIDCValidation.defaultAllowedHosts.contains("login.microsoftonline.com"))
    }

    @Test("default suffix allow-list contains the well-known suffixes")
    func testDefaultAllowedSuffixes() {
        #expect(OIDCValidation.defaultAllowedDomainSuffixes.contains(".okta.com"))
        #expect(OIDCValidation.defaultAllowedDomainSuffixes.contains(".amazonaws.com"))
    }

    @Test("parseAllowList splits on commas and semicolons, trimming and dropping empties")
    func testParseAllowList() {
        #expect(OIDCValidation.parseAllowList("a.com, b.com ; c.com") == ["a.com", "b.com", "c.com"])
        #expect(OIDCValidation.parseAllowList("  only.com  ") == ["only.com"])
        #expect(OIDCValidation.parseAllowList(",; ,") == [])
    }

    // MARK: - issuerMatches

    @Test("issuerMatches accepts an exact issuer and rejects a different one")
    func testIssuerExact() {
        #expect(OIDCValidation.issuerMatches(expected: "https://idp.example.com", actual: "https://idp.example.com"))
        #expect(
            !OIDCValidation.issuerMatches(expected: "https://idp.example.com", actual: "https://evil.example.com"))
    }

    @Test("issuerMatches resolves a templated multi-tenant issuer to one path segment")
    func testIssuerTemplated() {
        let expected = "https://login.microsoftonline.com/{tenantid}/v2.0"
        // Concrete tenant GUID substituted in — the real Entra `common` case.
        #expect(
            OIDCValidation.issuerMatches(
                expected: expected,
                actual: "https://login.microsoftonline.com/9188040d-6c67-4c5b-b112-36a304b66dad/v2.0"))
        // Wrong host must still fail.
        #expect(
            !OIDCValidation.issuerMatches(
                expected: expected, actual: "https://evil.example.com/9188040d/v2.0"))
        // The wildcard is a single segment: it must not span extra `/` segments.
        #expect(
            !OIDCValidation.issuerMatches(
                expected: expected, actual: "https://login.microsoftonline.com/a/b/v2.0"))
        // A missing tenant segment must not match.
        #expect(
            !OIDCValidation.issuerMatches(
                expected: expected, actual: "https://login.microsoftonline.com//v2.0"))
    }

    @Test("issuerMatches does not treat regex metacharacters in the literal as patterns")
    func testIssuerLiteralIsEscaped() {
        // The `.` must match a literal dot, not any character.
        #expect(!OIDCValidation.issuerMatches(expected: "https://a.example.com", actual: "https://axexample.com"))
    }

    @Test("issuerMatches tolerates a single trailing-slash difference")
    func testIssuerTrailingSlash() {
        // A URL-derived issuer can't know whether the IdP uses a trailing slash
        // (Auth0 does, Google doesn't); both forms are the same issuer.
        #expect(
            OIDCValidation.issuerMatches(expected: "https://tenant.auth0.com", actual: "https://tenant.auth0.com/"))
        #expect(
            OIDCValidation.issuerMatches(expected: "https://tenant.auth0.com/", actual: "https://tenant.auth0.com"))
        // A genuine mismatch is still rejected even with slashes involved.
        #expect(!OIDCValidation.issuerMatches(expected: "https://a.example.com", actual: "https://b.example.com/"))
    }

    // MARK: - discoveryIssuer

    @Test("discoveryIssuer strips the well-known suffix for standard IdPs")
    func testDiscoveryIssuerStandard() {
        #expect(
            OIDCValidation.discoveryIssuer(
                forDiscoveryURL: "https://accounts.google.com/.well-known/openid-configuration")
                == "https://accounts.google.com")
        // A literal `/common/` segment on a non-Microsoft host is part of the issuer.
        #expect(
            OIDCValidation.discoveryIssuer(
                forDiscoveryURL: "https://idp.example.com/common/.well-known/openid-configuration")
                == "https://idp.example.com/common")
    }

    @Test("discoveryIssuer templates Entra v2.0 multi-tenant aliases, keeps concrete tenants exact")
    func testDiscoveryIssuerEntraV2() {
        for alias in ["common", "organizations", "consumers"] {
            let derived = OIDCValidation.discoveryIssuer(
                forDiscoveryURL: "https://login.microsoftonline.com/\(alias)/v2.0/.well-known/openid-configuration")
            #expect(derived == "https://login.microsoftonline.com/{tenantid}/v2.0")
        }
        // Concrete single-tenant v2.0: exact.
        #expect(
            OIDCValidation.discoveryIssuer(
                forDiscoveryURL:
                    "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0/.well-known/openid-configuration"
            ) == "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0")
    }

    @Test("discoveryIssuer maps Entra v1 endpoints to the sts.windows.net issuer")
    func testDiscoveryIssuerEntraV1() {
        // Multi-tenant alias → templated sts issuer.
        #expect(
            OIDCValidation.discoveryIssuer(
                forDiscoveryURL: "https://login.microsoftonline.com/common/.well-known/openid-configuration")
                == "https://sts.windows.net/{tenantid}/")
        // Concrete tenant v1 → concrete sts issuer.
        #expect(
            OIDCValidation.discoveryIssuer(
                forDiscoveryURL:
                    "https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/.well-known/openid-configuration"
            ) == "https://sts.windows.net/11111111-1111-1111-1111-111111111111/")
    }

    @Test("discoveryIssuer leaves Entra domain authorities unbackfillable")
    func testDiscoveryIssuerEntraDomain() {
        // A tenant *domain* resolves to the GUID issuer in metadata, which the URL
        // doesn't contain — must not be stored as the domain URL. nil = fail closed.
        #expect(
            OIDCValidation.discoveryIssuer(
                forDiscoveryURL:
                    "https://login.microsoftonline.com/contoso.onmicrosoft.com/v2.0/.well-known/openid-configuration")
                == nil)
        #expect(
            OIDCValidation.discoveryIssuer(
                forDiscoveryURL:
                    "https://login.microsoftonline.com/contoso.onmicrosoft.com/.well-known/openid-configuration")
                == nil)
    }

    @Test("discoveryIssuer returns nil for a URL without the well-known suffix")
    func testDiscoveryIssuerNoSuffix() {
        #expect(OIDCValidation.discoveryIssuer(forDiscoveryURL: "https://idp.example.com/issuer") == nil)
    }

    // MARK: - resolveEmailVerification

    @Test("A verified email in the ID token is trusted as-is")
    func testEmailVerifiedFromIDToken() {
        let r = OIDCValidation.resolveEmailVerification(
            idTokenEmail: "u@example.com", idTokenEmailVerified: true,
            userInfoEmail: nil, userInfoEmailVerified: nil)
        #expect(r.email == "u@example.com")
        #expect(r.verified)
    }

    @Test("UserInfo email_verified is merged when the ID token omits the flag")
    func testEmailVerifiedFromUserInfo() {
        // ID token carries the email but not email_verified; UserInfo asserts it
        // for the same address — the real case that blocked first logins.
        let r = OIDCValidation.resolveEmailVerification(
            idTokenEmail: "u@example.com", idTokenEmailVerified: nil,
            userInfoEmail: "u@example.com", userInfoEmailVerified: true)
        #expect(r.email == "u@example.com")
        #expect(r.verified)
    }

    @Test("UserInfo email_verified is ignored for a different address")
    func testEmailVerifiedUserInfoDifferentAddress() {
        let r = OIDCValidation.resolveEmailVerification(
            idTokenEmail: "u@example.com", idTokenEmailVerified: nil,
            userInfoEmail: "other@example.com", userInfoEmailVerified: true)
        #expect(r.email == "u@example.com")
        #expect(!r.verified)
    }

    @Test("An explicit false in the ID token is not overridden by UserInfo")
    func testEmailVerifiedExplicitFalseRespected() {
        let r = OIDCValidation.resolveEmailVerification(
            idTokenEmail: "u@example.com", idTokenEmailVerified: false,
            userInfoEmail: "u@example.com", userInfoEmailVerified: true)
        #expect(!r.verified)
    }

    @Test("Email is adopted from UserInfo when the ID token has none")
    func testEmailAdoptedFromUserInfo() {
        let r = OIDCValidation.resolveEmailVerification(
            idTokenEmail: nil, idTokenEmailVerified: nil,
            userInfoEmail: "u@example.com", userInfoEmailVerified: true)
        #expect(r.email == "u@example.com")
        #expect(r.verified)
    }

    @Test("No verification anywhere fails closed")
    func testEmailVerifiedNoneFailsClosed() {
        let r = OIDCValidation.resolveEmailVerification(
            idTokenEmail: "u@example.com", idTokenEmailVerified: nil,
            userInfoEmail: nil, userInfoEmailVerified: nil)
        #expect(!r.verified)
    }

    // MARK: - PKCE

    @Test("codeChallengeS256 matches the RFC 7636 appendix B vector")
    func testCodeChallengeKnownVector() {
        let challenge = OIDCValidation.codeChallengeS256(
            for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("generateCodeVerifier produces RFC 7636-compliant, unique verifiers")
    func testGenerateCodeVerifier() {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var seen = Set<String>()
        for _ in 0..<32 {
            let verifier = OIDCValidation.generateCodeVerifier()
            // 32 random bytes base64url-encode to exactly 43 characters, the
            // RFC 7636 minimum length.
            #expect(verifier.count == 43)
            #expect(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
            seen.insert(verifier)
        }
        #expect(seen.count == 32)
    }

    // MARK: - Base URL resolution

    @Test("resolveBaseURL returns the configured value when set")
    func testResolveBaseURLConfigured() throws {
        let url = try OIDCValidation.resolveBaseURL(
            configured: "https://cloud.example.com", environment: .production)
        #expect(url == "https://cloud.example.com")
    }

    @Test("resolveBaseURL throws in production when BASE_URL is unset or blank")
    func testResolveBaseURLProductionUnset() {
        // A silently-defaulted localhost base URL produces redirect URIs the
        // IdP rejects; production must fail loudly instead.
        #expect(throws: Error.self) {
            try OIDCValidation.resolveBaseURL(configured: nil, environment: .production)
        }
        #expect(throws: Error.self) {
            try OIDCValidation.resolveBaseURL(configured: "  ", environment: .production)
        }
    }

    @Test("resolveBaseURL falls back to localhost outside production")
    func testResolveBaseURLDevelopmentFallback() throws {
        let url = try OIDCValidation.resolveBaseURL(configured: nil, environment: .development)
        #expect(url == "http://localhost:8080")
    }
}
