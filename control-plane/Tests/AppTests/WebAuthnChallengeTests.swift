import Testing
import Vapor
import Fluent
import FluentSQLiteDriver
import VaporTesting
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
            await #expect(throws: WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(challenge, on: app.db)
            }
        }
    }

    @Test("Consuming a challenge that was never stored fails")
    func unknownChallengeIsRejected() async throws {
        try await withTestApp { app in
            let service = makeService()

            await #expect(throws: WebAuthnError.self) {
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

            await #expect(throws: WebAuthnError.self) {
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

            await #expect(throws: WebAuthnError.self) {
                try await service.consumeAuthenticationChallenge(challenge, on: app.db)
            }
        }
    }
}
