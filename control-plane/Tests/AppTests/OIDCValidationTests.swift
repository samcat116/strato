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

    // MARK: - SSRF allow-lists (defaults)

    @Test("allowedHosts falls back to the built-in default host set")
    func testAllowedHostsDefault() {
        let hosts = OIDCValidation.allowedHosts(from: .testing)
        #expect(hosts.contains("accounts.google.com"))
        #expect(hosts.contains("login.microsoftonline.com"))
    }

    @Test("allowedDomainSuffixes falls back to the built-in default suffix set")
    func testAllowedSuffixesDefault() {
        let suffixes = OIDCValidation.allowedDomainSuffixes(from: .testing)
        #expect(suffixes.contains(".okta.com"))
        #expect(suffixes.contains(".amazonaws.com"))
    }
}
