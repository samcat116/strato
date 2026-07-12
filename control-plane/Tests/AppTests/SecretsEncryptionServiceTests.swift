import Crypto
import Foundation
import Testing
import Vapor

@testable import App

@Suite("SecretsEncryptionService Tests")
struct SecretsEncryptionServiceTests {

    private static let hexKey = String(repeating: "ab", count: 32)

    private func makeService() throws -> SecretsEncryptionService {
        SecretsEncryptionService(key: try SecretsEncryptionService.parseKey(Self.hexKey))
    }

    // MARK: - Key parsing

    @Test("parseKey accepts a 64-char hex key")
    func testParseHexKey() throws {
        _ = try SecretsEncryptionService.parseKey(Self.hexKey)
    }

    @Test("parseKey accepts a base64 32-byte key")
    func testParseBase64Key() throws {
        let base64 = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        _ = try SecretsEncryptionService.parseKey(base64)
    }

    @Test("parseKey rejects keys of the wrong length or encoding")
    func testParseInvalidKeys() {
        // 16 bytes hex
        #expect(throws: (any Error).self) {
            try SecretsEncryptionService.parseKey(String(repeating: "ab", count: 16))
        }
        // Not decodable at all
        #expect(throws: (any Error).self) {
            try SecretsEncryptionService.parseKey("!!! not a key !!!")
        }
        // Valid base64 of the wrong length
        #expect(throws: (any Error).self) {
            try SecretsEncryptionService.parseKey(Data([1, 2, 3]).base64EncodedString())
        }
    }

    // MARK: - Encrypt / decrypt

    @Test("Encrypt/decrypt roundtrip recovers the plaintext")
    func testRoundtrip() throws {
        let service = try makeService()
        let stored = try service.encrypt("super-secret-client-secret")
        #expect(stored.hasPrefix(SecretsEncryptionService.encryptedPrefix))
        #expect(!stored.contains("super-secret"))
        let recovered = try service.decrypt(stored)
        #expect(recovered == "super-secret-client-secret")
    }

    @Test("Encryption is randomized per call (fresh nonce)")
    func testRandomizedNonce() throws {
        let service = try makeService()
        let first = try service.encrypt("same-plaintext")
        let second = try service.encrypt("same-plaintext")
        #expect(first != second)
    }

    @Test("Decrypt passes legacy plaintext values through unchanged")
    func testLegacyPlaintextPassthrough() throws {
        let service = try makeService()
        let recovered = try service.decrypt("legacy-plaintext-secret")
        #expect(recovered == "legacy-plaintext-secret")
    }

    @Test("Decrypt with the wrong key fails rather than returning garbage")
    func testWrongKeyFails() throws {
        let service = try makeService()
        let stored = try service.encrypt("secret")
        let otherKey = try SecretsEncryptionService.parseKey(String(repeating: "cd", count: 32))
        let otherService = SecretsEncryptionService(key: otherKey)
        #expect(throws: (any Error).self) {
            try otherService.decrypt(stored)
        }
    }

    @Test("Decrypt rejects a malformed encrypted value")
    func testMalformedCiphertext() throws {
        let service = try makeService()
        #expect(throws: (any Error).self) {
            try service.decrypt(SecretsEncryptionService.encryptedPrefix + "not-base64!!!")
        }
    }

    // MARK: - Disabled (pass-through) mode

    @Test("Disabled service stores and reads plaintext")
    func testDisabledPassthrough() throws {
        let service = SecretsEncryptionService.disabled
        #expect(!service.isEnabled)
        let stored = try service.encrypt("plain")
        #expect(stored == "plain")
        let read = try service.decrypt("plain")
        #expect(read == "plain")
    }

    @Test("Disabled service refuses to read an encrypted value")
    func testDisabledRejectsEncryptedValue() throws {
        let enabled = try makeService()
        let stored = try enabled.encrypt("secret")
        #expect(throws: (any Error).self) {
            try SecretsEncryptionService.disabled.decrypt(stored)
        }
    }

    // MARK: - Startup sweep

    @Test("Startup sweep encrypts plaintext rows and leaves encrypted ones alone")
    func testStartupSweep() async throws {
        try await withTestApp { app in
            let org = Organization(name: "Sweep Org", description: "")
            try await org.save(on: app.db)

            let service = try makeService()

            let plaintextProvider = OIDCProvider(
                organizationID: org.id!,
                name: "Legacy",
                clientID: "client-legacy",
                clientSecret: "legacy-secret",
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks"
            )
            try await plaintextProvider.save(on: app.db)

            let alreadyEncrypted = try service.encrypt("already-encrypted-secret")
            let encryptedProvider = OIDCProvider(
                organizationID: org.id!,
                name: "Modern",
                clientID: "client-modern",
                clientSecret: alreadyEncrypted,
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks"
            )
            try await encryptedProvider.save(on: app.db)

            try await service.encryptStoredOIDCClientSecrets(on: app.db, logger: app.logger)

            let legacy = try await OIDCProvider.find(plaintextProvider.id, on: app.db)
            let legacySecret = try #require(legacy?.clientSecret)
            #expect(legacySecret.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let legacyDecrypted = try service.decrypt(legacySecret)
            #expect(legacyDecrypted == "legacy-secret")

            // The already-encrypted row must be untouched (not double-encrypted).
            let modern = try await OIDCProvider.find(encryptedProvider.id, on: app.db)
            #expect(modern?.clientSecret == alreadyEncrypted)

            // A second run is a no-op.
            try await service.encryptStoredOIDCClientSecrets(on: app.db, logger: app.logger)
            let legacyAgain = try await OIDCProvider.find(plaintextProvider.id, on: app.db)
            #expect(legacyAgain?.clientSecret == legacySecret)
        }
    }
}
