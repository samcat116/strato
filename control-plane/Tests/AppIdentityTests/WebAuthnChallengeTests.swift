import Testing
import Vapor
import Fluent
import VaporTesting
import WebAuthn
import AppTestSupport
@testable import App

/// Regression tests for issue #170: WebAuthn assertion replay.
///
/// `finishAuthentication` must consume the stored authentication challenge
/// exactly once before accepting an assertion. These tests exercise the
/// `consumeAuthenticationChallenge` claim directly, which is the step that
/// provides replay protection.
@Suite("WebAuthn Challenge Consumption", .serialized)
struct WebAuthnChallengeTests {

    private func makeService(_ app: Application) -> WebAuthnService {
        WebAuthnService(
            relyingPartyID: "localhost",
            relyingPartyName: "Strato",
            relyingPartyOrigin: "http://localhost:8080",
            passkeys: app.passkeysPersistence,
            users: app.userDirectoryPersistence
        )
    }

    @Test("A stored authentication challenge can be consumed exactly once")
    func challengeIsSingleUse() async throws {
        try await withTestApp { app in
            let service = makeService(app)
            let challenge = "test-challenge-\(UUID().uuidString)"

            try await service.storeChallenge(
                challenge,
                operation: "authentication"
            )

            // First consumption succeeds.
            try await service.consumeAuthenticationChallenge(challenge)

            // Replaying the same challenge must now fail: the row is gone.
            await #expect(throws: App.WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(challenge)
            }
        }
    }

    @Test("Consuming a challenge that was never stored fails")
    func unknownChallengeIsRejected() async throws {
        try await withTestApp { app in
            let service = makeService(app)

            await #expect(throws: App.WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge("never-stored-\(UUID().uuidString)")
            }
        }
    }

    @Test("A registration challenge cannot be consumed as authentication")
    func wrongOperationIsRejected() async throws {
        try await withTestApp { app in
            let service = makeService(app)
            let challenge = "reg-challenge-\(UUID().uuidString)"

            try await service.storeChallenge(
                challenge,
                operation: "registration"
            )

            await #expect(throws: App.WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(challenge)
            }

            // The registration challenge must still exist (it was not consumed).
            #expect(
                try await app.passkeysPersistence.challenge(
                    challenge,
                    operation: "registration"
                ) != nil
            )
        }
    }

    @Test("An expired challenge is rejected and cannot be consumed")
    func expiredChallengeIsRejected() async throws {
        try await withTestApp { app in
            let service = makeService(app)
            let challenge = "expired-challenge-\(UUID().uuidString)"

            // Insert a challenge whose expiry is already in the past.
            _ = try await app.passkeysPersistence.storeChallenge(
                challenge,
                operation: "authentication",
                expiresAt: Date().addingTimeInterval(-60)
            )

            await #expect(throws: App.WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(challenge)
            }
        }
    }

    /// `beginAuthentication` for an unregistered username must NOT throw
    /// `userNotFound` (a 404 would make login a username-enumeration oracle).
    /// It returns a single decoy credential that is deterministic per
    /// (username, deployment key) and unguessable without the key.
    @Test("Unknown username yields a deterministic, keyed decoy (no enumeration oracle)")
    func unknownUsernameYieldsDeterministicDecoy() async throws {
        try await withTestApp { app in
            let service = makeService(app)
            let username = "definitely-not-registered-\(UUID().uuidString)"

            let a = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-A")
            let b = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-A")
            let c = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-B")

            // Shaped like a real single-passkey user, not an error.
            #expect(a.allowCredentials?.count == 1)
            // Stable per (username, key): a value that changed between requests
            // would itself reveal the account is fake.
            #expect(a.allowCredentials?.first?.id == b.allowCredentials?.first?.id)
            // Keyed: a different deployment key produces a different decoy, so
            // the id cannot be recomputed without the server secret.
            #expect(a.allowCredentials?.first?.id != c.allowCredentials?.first?.id)
        }
    }

    /// A registered user with zero passkeys (e.g. OIDC/SCIM JIT-provisioned)
    /// must get the same single-decoy response as an unknown username — an
    /// empty list here, while unknown usernames get a decoy, would identify
    /// real passkey-less accounts just as effectively as the original 404.
    @Test("Passkey-less user yields the same decoy shape as an unknown username")
    func passkeylessUserYieldsDecoy() async throws {
        try await withTestApp { app in
            let service = makeService(app)
            let username = "oidc-user-\(UUID().uuidString)"
            let user = User(
                username: username,
                email: "\(username)@example.com",
                displayName: "No Passkeys",
                source: .oidc
            )
            try await user.save(on: app.db)

            let a = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-A")
            let b = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-A")

            // Exactly one deterministic decoy — indistinguishable in shape from
            // both a real single-passkey user and an unknown username.
            #expect(a.allowCredentials?.count == 1)
            #expect(a.allowCredentials?.first?.id == b.allowCredentials?.first?.id)
        }
    }

    /// The decoy fallback must not leak into the real path: a user with a
    /// registered passkey still gets their actual credential back.
    @Test("User with a real passkey still receives their real credential")
    func realCredentialIsReturnedUnchanged() async throws {
        try await withTestApp { app in
            let service = makeService(app)
            let username = "passkey-user-\(UUID().uuidString)"
            let user = User(
                username: username,
                email: "\(username)@example.com",
                displayName: "Has Passkey"
            )
            try await user.save(on: app.db)

            let credentialID = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            _ = try await createTestPasskey(
                userID: user.requireID(),
                on: app,
                credentialID: credentialID,
                publicKey: Data([0x01, 0x02, 0x03])
            )

            let options = try await service.beginAuthentication(
                for: username, decoyKey: "deploy-key-A")

            #expect(options.allowCredentials?.count == 1)
            #expect(options.allowCredentials?.first?.id == Array(credentialID))
        }
    }
}
