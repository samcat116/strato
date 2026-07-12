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
            userinfoEndpoint: nil, jwksURI: jwksURI, scopes: nil, enabled: nil
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
}
