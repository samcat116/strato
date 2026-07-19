import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
import WebAuthn
@testable import App

/// Regression tests for issue #170: WebAuthn assertion replay.
///
/// `finishAuthentication` must consume the stored authentication challenge
/// exactly once before accepting an assertion. These tests exercise the
/// `consumeAuthenticationChallenge` claim directly, which is the step that
/// provides replay protection.
@Suite("WebAuthn Challenge Consumption", .serialized)
struct WebAuthnChallengeTests {

    private func makeService() -> WebAuthnService {
        WebAuthnService(
            relyingPartyID: "localhost",
            relyingPartyName: "Strato",
            relyingPartyOrigin: "http://localhost:8080"
        )
    }

    @Test("A stored authentication challenge can be consumed exactly once")
    func challengeIsSingleUse() async throws {
        try await withTestApp { app in
            let service = makeService()
            let challenge = "test-challenge-\(UUID().uuidString)"

            try await service.storeChallenge(
                challenge,
                operation: "authentication",
                on: app.db
            )

            // First consumption succeeds.
            try await service.consumeAuthenticationChallenge(challenge, on: app.db)

            // Replaying the same challenge must now fail: the row is gone.
            await #expect(throws: App.WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(challenge, on: app.db)
            }
        }
    }

    @Test("Consuming a challenge that was never stored fails")
    func unknownChallengeIsRejected() async throws {
        try await withTestApp { app in
            let service = makeService()

            await #expect(throws: App.WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(
                    "never-stored-\(UUID().uuidString)",
                    on: app.db
                )
            }
        }
    }

    @Test("A registration challenge cannot be consumed as authentication")
    func wrongOperationIsRejected() async throws {
        try await withTestApp { app in
            let service = makeService()
            let challenge = "reg-challenge-\(UUID().uuidString)"

            try await service.storeChallenge(
                challenge,
                operation: "registration",
                on: app.db
            )

            await #expect(throws: App.WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(challenge, on: app.db)
            }

            // The registration challenge must still exist (it was not consumed).
            let remaining = try await AuthenticationChallenge.query(on: app.db)
                .filter(\.$challenge == challenge)
                .count()
            #expect(remaining == 1)
        }
    }

    @Test("An expired challenge is rejected and cannot be consumed")
    func expiredChallengeIsRejected() async throws {
        try await withTestApp { app in
            let service = makeService()
            let challenge = "expired-challenge-\(UUID().uuidString)"

            // Insert a challenge whose expiry is already in the past.
            let stored = AuthenticationChallenge(
                challenge: challenge,
                operation: "authentication"
            )
            stored.expiresAt = Date().addingTimeInterval(-60)
            try await stored.save(on: app.db)

            await #expect(throws: App.WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(challenge, on: app.db)
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
            let service = makeService()
            let username = "definitely-not-registered-\(UUID().uuidString)"

            let a = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-A", on: app.db)
            let b = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-A", on: app.db)
            let c = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-B", on: app.db)

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
            let service = makeService()
            let username = "oidc-user-\(UUID().uuidString)"
            let user = User(
                username: username,
                email: "\(username)@example.com",
                displayName: "No Passkeys",
                source: .oidc
            )
            try await user.save(on: app.db)

            let a = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-A", on: app.db)
            let b = try await service.beginAuthentication(for: username, decoyKey: "deploy-key-A", on: app.db)

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
            let service = makeService()
            let username = "passkey-user-\(UUID().uuidString)"
            let user = User(
                username: username,
                email: "\(username)@example.com",
                displayName: "Has Passkey"
            )
            try await user.save(on: app.db)

            let credentialID = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let credential = UserCredential(
                userID: try user.requireID(),
                credentialID: credentialID,
                publicKey: Data([0x01, 0x02, 0x03])
            )
            try await credential.save(on: app.db)

            let options = try await service.beginAuthentication(
                for: username, decoyKey: "deploy-key-A", on: app.db)

            #expect(options.allowCredentials?.count == 1)
            #expect(options.allowCredentials?.first?.id == Array(credentialID))
        }
    }
}
