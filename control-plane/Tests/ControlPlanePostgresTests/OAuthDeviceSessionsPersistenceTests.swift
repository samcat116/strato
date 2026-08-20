import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native OAuth device and CLI-session persistence", .serialized)
struct OAuthDeviceSessionsPersistenceTests {
    private let unrestricted = StoredCredentialRestriction(
        actions: ["*"],
        nodeType: nil,
        nodeID: nil
    )

    @Test("concurrent redemption creates exactly one CLI session")
    func concurrentRedemption() async throws {
        try await withOAuthDatabase(maximumConnections: 2) { _, oauth in
            let userID = UUID()
            let authorization = try await approvedAuthorization(oauth, userID: userID)

            let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
                for suffix in ["first", "second"] {
                    group.addTask {
                        do {
                            _ = try await oauth.redeemAndCreateSession(
                                authorizationID: authorization.id,
                                session: sessionWrite(userID: userID, suffix: suffix)
                            )
                            return true
                        } catch let error as OAuthDeviceSessionsPersistenceError
                            where error == .deviceCodeAlreadyRedeemed(authorization.id)
                        {
                            return false
                        }
                    }
                }

                var values: [Bool] = []
                for try await value in group { values.append(value) }
                return values
            }

            #expect(successes.filter { $0 }.count == 1)
            #expect(successes.filter { !$0 }.count == 1)
            #expect(try await oauth.activeSessions(userID: userID, now: Date()).count == 1)

            let reloaded = try #require(
                try await oauth.authorization(deviceCodeHash: authorization.deviceCodeHash)
            )
            #expect(reloaded.status == .redeemed)
        }
    }

    @Test("failed session creation rolls device redemption back")
    func redemptionRollback() async throws {
        try await withOAuthDatabase { _, oauth in
            let userID = UUID()
            let authorization = try await approvedAuthorization(oauth, userID: userID)
            let duplicate = sessionWrite(userID: userID, suffix: "duplicate")
            _ = try await oauth.createSession(duplicate)

            await #expect(throws: (any Error).self) {
                _ = try await oauth.redeemAndCreateSession(
                    authorizationID: authorization.id,
                    session: duplicate
                )
            }

            let reloaded = try #require(
                try await oauth.authorization(deviceCodeHash: authorization.deviceCodeHash)
            )
            #expect(reloaded.status == .approved)
            #expect(try await oauth.activeSessions(userID: userID, now: Date()).count == 1)
        }
    }

    @Test("refresh rotation retains one previous hash and revocation removes the session")
    func refreshRotationAndRevocation() async throws {
        try await withOAuthDatabase { _, oauth in
            let userID = UUID()
            let original = sessionWrite(userID: userID, suffix: "original")
            let created = try await oauth.createSession(original)
            let rotation = CLISessionRotation(
                accessTokenHash: "access-rotated",
                accessTokenPrefix: "st_rotated...",
                accessTokenExpiresAt: Date().addingTimeInterval(3_600),
                refreshTokenHash: "refresh-rotated",
                refreshTokenExpiresAt: Date().addingTimeInterval(86_400)
            )

            let rotated = try await oauth.rotateSession(
                sessionID: created.id,
                presentedRefreshTokenHash: original.refreshTokenHash,
                rotation: rotation
            )
            #expect(rotated.previousRefreshTokenHash == original.refreshTokenHash)
            #expect(rotated.refreshTokenHash == rotation.refreshTokenHash)
            #expect(
                try await oauth.session(
                    previousRefreshTokenHash: original.refreshTokenHash
                )?.id == created.id
            )

            await #expect(
                throws: OAuthDeviceSessionsPersistenceError.refreshTokenChanged(created.id)
            ) {
                _ = try await oauth.rotateSession(
                    sessionID: created.id,
                    presentedRefreshTokenHash: original.refreshTokenHash,
                    rotation: rotation
                )
            }

            #expect(
                try await oauth.revokeSession(
                    matchingTokenHash: rotation.refreshTokenHash,
                    at: Date()
                )
            )
            #expect(try await oauth.activeSessions(userID: userID, now: Date()).isEmpty)
        }
    }

    @Test("usage recording is conditionally debounced in PostgreSQL")
    func usageDebounce() async throws {
        try await withOAuthDatabase { _, oauth in
            let created = try await oauth.createSession(
                sessionWrite(userID: UUID(), suffix: "usage")
            )
            let first = Date()

            #expect(
                try await oauth.recordSessionUsage(
                    id: created.id,
                    usedAt: first,
                    sourceIP: "198.51.100.1",
                    staleBefore: first.addingTimeInterval(-900)
                )
            )
            #expect(
                !(try await oauth.recordSessionUsage(
                    id: created.id,
                    usedAt: first.addingTimeInterval(1),
                    sourceIP: "198.51.100.2",
                    staleBefore: first.addingTimeInterval(-899)
                ))
            )

            let reloaded = try #require(
                try await oauth.session(accessTokenHash: created.accessTokenHash)
            )
            #expect(reloaded.lastUsedIP == "198.51.100.1")
            #expect(try #require(reloaded.lastUsedAt) < first.addingTimeInterval(0.1))
        }
    }

    private func approvedAuthorization(
        _ oauth: OAuthDeviceSessionsPersistence,
        userID: UUID
    ) async throws -> OAuthDeviceAuthorizationSnapshot {
        let created = try await oauth.createAuthorization(
            OAuthDeviceAuthorizationWrite(
                deviceCodeHash: "device-\(UUID().uuidString)",
                userCode: "ABCD-EFGH",
                clientName: "strato-cli",
                restriction: unrestricted,
                requestIP: "198.51.100.10",
                expiresAt: Date().addingTimeInterval(600),
                pollInterval: 5
            )
        )
        return try await oauth.approve(
            authorizationID: created.id,
            userID: userID,
            restriction: unrestricted,
            now: Date()
        )
    }

    private func sessionWrite(userID: UUID, suffix: String) -> CLISessionWrite {
        CLISessionWrite(
            userID: userID,
            clientName: "strato-cli",
            restriction: unrestricted,
            accessTokenHash: "access-\(suffix)",
            accessTokenPrefix: "st_\(suffix)...",
            accessTokenExpiresAt: Date().addingTimeInterval(3_600),
            refreshTokenHash: "refresh-\(suffix)",
            refreshTokenExpiresAt: Date().addingTimeInterval(86_400)
        )
    }

    private func withOAuthDatabase(
        maximumConnections: Int = 1,
        _ test: (
            PostgresDatabase,
            OAuthDeviceSessionsPersistence
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(
            maximumConnections: maximumConnections
        ) { database in
            try await database.withSession(operation: "test.oauth.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE oauth_device_authorizations (
                        id UUID PRIMARY KEY,
                        device_code_hash TEXT NOT NULL UNIQUE,
                        user_code TEXT NOT NULL UNIQUE,
                        client_name TEXT NOT NULL,
                        restriction_actions TEXT[] NOT NULL,
                        restriction_node_type TEXT,
                        restriction_node_id UUID,
                        status TEXT NOT NULL,
                        user_id UUID,
                        request_ip TEXT,
                        expires_at TIMESTAMPTZ NOT NULL,
                        last_polled_at TIMESTAMPTZ,
                        poll_interval BIGINT NOT NULL,
                        created_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.oauth.schema.authorizations"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE cli_sessions (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL,
                        client_name TEXT NOT NULL,
                        restriction_actions TEXT[] NOT NULL,
                        restriction_node_type TEXT,
                        restriction_node_id UUID,
                        access_token_hash TEXT NOT NULL UNIQUE,
                        access_token_prefix TEXT NOT NULL,
                        access_token_expires_at TIMESTAMPTZ NOT NULL,
                        refresh_token_hash TEXT NOT NULL UNIQUE,
                        previous_refresh_token_hash TEXT,
                        refresh_token_expires_at TIMESTAMPTZ NOT NULL,
                        revoked_at TIMESTAMPTZ,
                        last_used_at TIMESTAMPTZ,
                        last_used_ip TEXT,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.oauth.schema.sessions"
                )
            }

            try await test(
                database,
                ControlPlanePersistence(database: database).oauthDeviceSessions
            )
        }
    }
}
