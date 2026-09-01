import Crypto
import Foundation
import Testing
import Vapor

import AppTestSupport
@testable import App

@Suite("SecretsEncryptionService Tests")
struct SecretsEncryptionServiceTests {

    private static let hexKey = String(repeating: "ab", count: 32)
    private static let previousHexKey = String(repeating: "cd", count: 32)

    private func makeService() throws -> SecretsEncryptionService {
        SecretsEncryptionService(key: try SecretsEncryptionService.parseKey(Self.hexKey))
    }

    private func legacyV1(_ plaintext: String, key: SymmetricKey) throws -> String {
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        return SecretsEncryptionService.legacyEncryptedPrefix
            + (try #require(sealed.combined)).base64EncodedString()
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

    @Test("Previous keys are strictly parsed and decrypt-only")
    func previousKeysFromConfiguration() async throws {
        let configuration = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "STRATO_SECRET_ENCRYPTION_KEY": Self.hexKey,
                "STRATO_SECRET_ENCRYPTION_KEYS_PREVIOUS": "  \(Self.previousHexKey)  ",
            ],
            for: .testing)
        let service = try SecretsEncryptionService.fromConfiguration(configuration)
        let previous = SecretsEncryptionService(
            key: try SecretsEncryptionService.parseKey(Self.previousHexKey))
        #expect(try service.decrypt(previous.encrypt("old-secret")) == "old-secret")

        let malformed = try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "STRATO_SECRET_ENCRYPTION_KEY": Self.hexKey,
                "STRATO_SECRET_ENCRYPTION_KEYS_PREVIOUS": "\(Self.previousHexKey),,bad",
            ],
            for: .testing)
        #expect(throws: (any Error).self) {
            try SecretsEncryptionService.fromConfiguration(malformed)
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
        let components = stored.split(separator: ":", maxSplits: 3)
        #expect(components.count == 4)
        #expect(components[0] == "enc")
        #expect(components[1] == "v2")
        #expect(components[2].count == 16)
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
        #expect(try service.decrypt("enc:customer-token") == "enc:customer-token")
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

    @Test("Legacy v1 opens under a previous key")
    func legacyV1OpensUnderPreviousKey() throws {
        let primary = try SecretsEncryptionService.parseKey(Self.hexKey)
        let previous = try SecretsEncryptionService.parseKey(Self.previousHexKey)
        let service = SecretsEncryptionService(key: primary, previousKeys: [previous])
        let stored = try legacyV1("legacy-secret", key: previous)

        #expect(try service.decrypt(stored) == "legacy-secret")
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

    @Test("Unknown-key and malformed ciphertext are distinct failures")
    func typedDecryptFailures() throws {
        let service = try makeService()
        let other = SecretsEncryptionService(
            key: try SecretsEncryptionService.parseKey(Self.previousHexKey))
        let unknown = try other.encrypt("secret")

        #expect(throws: SecretsEncryptionError.unknownKey(keyID: String(unknown.split(separator: ":")[2]))) {
            try service.decrypt(unknown)
        }
        #expect(throws: SecretsEncryptionError.self) {
            try service.decrypt("enc:v2:not-a-key-id:not-base64")
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

            try await service.encryptStoredSecrets(on: app.db, logger: app.logger)

            let legacy = try await OIDCProvider.find(plaintextProvider.id, on: app.db)
            let legacySecret = try #require(legacy?.clientSecret)
            #expect(legacySecret.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let legacyDecrypted = try service.decrypt(legacySecret)
            #expect(legacyDecrypted == "legacy-secret")

            // The already-encrypted row must be untouched (not double-encrypted).
            let modern = try await OIDCProvider.find(encryptedProvider.id, on: app.db)
            #expect(modern?.clientSecret == alreadyEncrypted)

            // A second run is a no-op.
            try await service.encryptStoredSecrets(on: app.db, logger: app.logger)
            let legacyAgain = try await OIDCProvider.find(plaintextProvider.id, on: app.db)
            #expect(legacyAgain?.clientSecret == legacySecret)
        }
    }

    @Test("Startup sweep encrypts plaintext SSF auth tokens and skips token-less streams")
    func testStartupSweepSSFAuthTokens() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(username: "ssfsweep", email: "ssfsweep@example.com")
            let org = try await builder.createOrganization(name: "SSF Sweep Org")

            let service = try makeService()

            let plaintextStream = SSFStream(
                organizationID: org.id!,
                name: "Legacy",
                transmitterURL: "https://idp.example.com",
                authToken: "legacy-token",
                deliveryMethod: .poll,
                createdByID: user.id!
            )
            try await plaintextStream.save(on: app.db)

            let tokenlessStream = SSFStream(
                organizationID: org.id!,
                name: "Tokenless",
                transmitterURL: "https://idp.example.com",
                deliveryMethod: .poll,
                createdByID: user.id!
            )
            try await tokenlessStream.save(on: app.db)

            let alreadyEncrypted = try service.encrypt("modern-token")
            let encryptedStream = SSFStream(
                organizationID: org.id!,
                name: "Modern",
                transmitterURL: "https://idp.example.com",
                authToken: alreadyEncrypted,
                deliveryMethod: .poll,
                createdByID: user.id!
            )
            try await encryptedStream.save(on: app.db)

            try await service.encryptStoredSecrets(on: app.db, logger: app.logger)

            let legacy = try await SSFStream.find(plaintextStream.id, on: app.db)
            let legacyToken = try #require(legacy?.authToken)
            #expect(legacyToken.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let legacyDecrypted = try service.decrypt(legacyToken)
            #expect(legacyDecrypted == "legacy-token")

            let tokenless = try await SSFStream.find(tokenlessStream.id, on: app.db)
            #expect(tokenless?.authToken == nil)

            // The already-encrypted row must be untouched (not double-encrypted).
            let modern = try await SSFStream.find(encryptedStream.id, on: app.db)
            #expect(modern?.authToken == alreadyEncrypted)
        }
    }

    @Test("Rotation rewraps every populated stored-secret column to the primary")
    func rotationRewrapsAllTables() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "rotation", email: "rotation@example.com")
            let org = try await builder.createOrganization(name: "Rotation Org")
            let project = try await builder.createProject(
                name: "Rotation Project", description: "", organization: org)
            let oldKey = try SecretsEncryptionService.parseKey(Self.previousHexKey)
            let primary = try SecretsEncryptionService.parseKey(Self.hexKey)
            let service = SecretsEncryptionService(key: primary, previousKeys: [oldKey])

            let provider = OIDCProvider(
                organizationID: org.id!, name: "Legacy OIDC", clientID: "legacy",
                clientSecret: try legacyV1("oidc-secret", key: oldKey),
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks")
            try await provider.save(on: app.db)

            let stream = SSFStream(
                organizationID: org.id!, name: "Legacy SSF",
                transmitterURL: "https://idp.example.com",
                authToken: try legacyV1("ssf-secret", key: oldKey),
                deliveryMethod: .poll, createdByID: user.id!)
            try await stream.save(on: app.db)

            let pullSecret = RegistryPullSecret(
                projectID: project.id!, registry: "registry.example.com",
                username: "robot", secret: try legacyV1("registry-secret", key: oldKey))
            try await pullSecret.save(on: app.db)

            let subscription = WebhookSubscription(
                organizationID: org.id!, name: "Legacy webhook",
                url: "https://hooks.example.com/strato", eventTypes: [],
                signingSecret: try legacyV1("webhook-secret", key: oldKey),
                createdByID: user.id!)
            try await subscription.save(on: app.db)

            let report = try await service.encryptStoredSecrets(
                on: app.db, logger: app.logger)
            #expect(report.totalRewrapped == 4)
            #expect(report.totalUnopenable == 0)
            #expect(report.tables.count == 5)
            #expect(report.tables.count(where: { $0.rewrapped == 1 }) == 4)
            #expect(
                report.tables.contains {
                    $0.table == "stored_secrets.encrypted_value" && $0.rewrapped == 0
                        && $0.unopenable == 0
                })

            let values = [
                try #require(try await OIDCProvider.find(provider.id, on: app.db)?.clientSecret),
                try #require(try await SSFStream.find(stream.id, on: app.db)?.authToken),
                try #require(try await RegistryPullSecret.find(pullSecret.id, on: app.db)?.secret),
                try #require(
                    try await WebhookSubscription.find(subscription.id, on: app.db)?.signingSecret),
            ]
            #expect(values.allSatisfy { $0.hasPrefix(SecretsEncryptionService.encryptedPrefix) })
            #expect(
                try values.map { try service.decrypt($0) } == [
                    "oidc-secret", "ssf-secret", "registry-secret", "webhook-secret",
                ])

            let second = try await service.encryptStoredSecrets(on: app.db, logger: app.logger)
            #expect(second.totalRewrapped == 0)
            #expect(second.totalUnopenable == 0)
        }
    }

    @Test("Unknown-key rows are counted and left untouched")
    func unknownRowsRemainUntouched() async throws {
        try await withTestApp { app in
            let org = Organization(name: "Unknown Key Org", description: "")
            try await org.save(on: app.db)
            let unknownService = SecretsEncryptionService(
                key: try SecretsEncryptionService.parseKey(Self.previousHexKey))
            let stored = try unknownService.encrypt("unavailable")
            let provider = OIDCProvider(
                organizationID: org.id!, name: "Unknown", clientID: "unknown",
                clientSecret: stored,
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks")
            try await provider.save(on: app.db)

            let service = try makeService()
            let report = try await service.encryptStoredSecrets(on: app.db, logger: app.logger)
            #expect(report.totalRewrapped == 0)
            #expect(report.totalUnopenable == 1)
            #expect(service.degradation?.total == 1)
            #expect(try await OIDCProvider.find(provider.id, on: app.db)?.clientSecret == stored)
        }
    }

    @Test("Ciphertext without a key refuses boot audit and later plaintext writes")
    func ciphertextWithoutKeyFailsClosed() async throws {
        try await withTestApp { app in
            let org = Organization(name: "No Key Org", description: "")
            try await org.save(on: app.db)
            let stored = try makeService().encrypt("unavailable")
            let provider = OIDCProvider(
                organizationID: org.id!, name: "No Key", clientID: "no-key",
                clientSecret: stored,
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks")
            try await provider.save(on: app.db)

            let disabled = SecretsEncryptionService.disabled
            do {
                _ = try await disabled.encryptStoredSecrets(on: app.db, logger: app.logger)
                Issue.record("Expected ciphertext without a key to fail the boot audit")
            } catch let error as SecretsEncryptionError {
                #expect(error.reason.contains("oidc_providers.client_secret=1"))
                #expect(error.reason.contains("restore the key"))
            }
            #expect(throws: SecretsEncryptionError.plaintextWriteRefused) {
                try disabled.encrypt("must-not-be-plaintext")
            }
        }
    }

    @Test("Concurrent rotation passes update a row only once")
    func concurrentRotationIsCompareAndSwapSafe() async throws {
        try await withTestApp { app in
            let org = Organization(name: "Concurrent Rotation Org", description: "")
            try await org.save(on: app.db)
            let previous = try SecretsEncryptionService.parseKey(Self.previousHexKey)
            let provider = OIDCProvider(
                organizationID: org.id!, name: "Concurrent", clientID: "concurrent",
                clientSecret: try legacyV1("secret", key: previous),
                authorizationEndpoint: "https://idp.example.com/authorize",
                tokenEndpoint: "https://idp.example.com/token",
                jwksURI: "https://idp.example.com/jwks")
            try await provider.save(on: app.db)
            let service = SecretsEncryptionService(
                key: try SecretsEncryptionService.parseKey(Self.hexKey),
                previousKeys: [previous])

            async let first = service.encryptStoredSecrets(on: app.db, logger: app.logger)
            async let second = service.encryptStoredSecrets(on: app.db, logger: app.logger)
            let (firstReport, secondReport) = try await (first, second)
            #expect(firstReport.totalRewrapped + secondReport.totalRewrapped == 1)

            let stored = try #require(
                try await OIDCProvider.find(provider.id, on: app.db)?.clientSecret)
            #expect(stored.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            #expect(try service.decrypt(stored) == "secret")
        }
    }
}
