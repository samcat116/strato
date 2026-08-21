import ControlPlanePostgres
import Crypto
import Foundation
import Testing
import Vapor

import AppTestSupport
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
            try await org.save(on: app.testPostgres)

            let service = try makeService()

            let plaintextProvider = try await app.oidcProvidersPersistence.create(OIDCProviderWrite(
                organizationID: org.id!,
                name: "Legacy",
                clientID: "client-legacy",
                encryptedClientSecret: "legacy-secret",
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks"
            ))

            let alreadyEncrypted = try service.encrypt("already-encrypted-secret")
            let encryptedProvider = try await app.oidcProvidersPersistence.create(OIDCProviderWrite(
                organizationID: org.id!,
                name: "Modern",
                clientID: "client-modern",
                encryptedClientSecret: alreadyEncrypted,
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks"
            ))

            try await service.encryptStoredSecrets(
                oidcProviders: app.oidcProvidersPersistence,
                ssfStreams: app.ssfStreamsPersistence,
                registryPullSecrets: app.registryPullSecretsPersistence,
                webhookSubscriptions: app.webhookSubscriptionsPersistence,
                logger: app.logger
            )

            let legacy = try await app.oidcProvidersPersistence.provider(id: plaintextProvider.id)
            let legacySecret = try #require(legacy?.encryptedClientSecret)
            #expect(legacySecret.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let legacyDecrypted = try service.decrypt(legacySecret)
            #expect(legacyDecrypted == "legacy-secret")

            // The already-encrypted row must be untouched (not double-encrypted).
            let modern = try await app.oidcProvidersPersistence.provider(id: encryptedProvider.id)
            #expect(modern?.encryptedClientSecret == alreadyEncrypted)

            // A second run is a no-op.
            try await service.encryptStoredSecrets(
                oidcProviders: app.oidcProvidersPersistence,
                ssfStreams: app.ssfStreamsPersistence,
                registryPullSecrets: app.registryPullSecretsPersistence,
                webhookSubscriptions: app.webhookSubscriptionsPersistence,
                logger: app.logger
            )
            let legacyAgain = try await app.oidcProvidersPersistence.provider(id: plaintextProvider.id)
            #expect(legacyAgain?.encryptedClientSecret == legacySecret)
        }
    }

    @Test("Startup sweep encrypts plaintext SSF auth tokens and skips token-less streams")
    func testStartupSweepSSFAuthTokens() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let user = try await builder.createUser(username: "ssfsweep", email: "ssfsweep@example.com")
            let org = try await builder.createOrganization(name: "SSF Sweep Org")

            let service = try makeService()

            let plaintextStream = try await app.ssfStreamsPersistence.create(
                SSFStreamWrite(
                    organizationID: org.id!,
                    name: "Legacy",
                    transmitterURL: "https://idp.example.com",
                    encryptedAuthToken: "legacy-token",
                    deliveryMethod: .poll,
                    createdByID: user.id!
                )
            )

            let tokenlessStream = try await app.ssfStreamsPersistence.create(
                SSFStreamWrite(
                    organizationID: org.id!,
                    name: "Tokenless",
                    transmitterURL: "https://idp.example.com",
                    deliveryMethod: .poll,
                    createdByID: user.id!
                )
            )

            let alreadyEncrypted = try service.encrypt("modern-token")
            let encryptedStream = try await app.ssfStreamsPersistence.create(
                SSFStreamWrite(
                    organizationID: org.id!,
                    name: "Modern",
                    transmitterURL: "https://idp.example.com",
                    encryptedAuthToken: alreadyEncrypted,
                    deliveryMethod: .poll,
                    createdByID: user.id!
                )
            )

            try await service.encryptStoredSecrets(
                oidcProviders: app.oidcProvidersPersistence,
                ssfStreams: app.ssfStreamsPersistence,
                registryPullSecrets: app.registryPullSecretsPersistence,
                webhookSubscriptions: app.webhookSubscriptionsPersistence,
                logger: app.logger
            )

            let legacy = try await app.ssfStreamsPersistence.stream(id: plaintextStream.id)
            let legacyToken = try #require(legacy?.encryptedAuthToken)
            #expect(legacyToken.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let legacyDecrypted = try service.decrypt(legacyToken)
            #expect(legacyDecrypted == "legacy-token")

            let tokenless = try await app.ssfStreamsPersistence.stream(id: tokenlessStream.id)
            #expect(tokenless?.encryptedAuthToken == nil)

            // The already-encrypted row must be untouched (not double-encrypted).
            let modern = try await app.ssfStreamsPersistence.stream(id: encryptedStream.id)
            #expect(modern?.encryptedAuthToken == alreadyEncrypted)
        }
    }
}
