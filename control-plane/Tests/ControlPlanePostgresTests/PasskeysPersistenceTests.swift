import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native passkey persistence", .serialized)
struct PasskeysPersistenceTests {
    @Test("registration consumes its challenge and preserves credential representation")
    func registerCredential() async throws {
        try await withPasskeyDatabase { database, passkeys in
            let userID = UUID()
            try await seedUser(userID, database: database)
            let challenge = "register-\(UUID())"
            _ = try await passkeys.storeChallenge(
                challenge,
                userID: userID,
                operation: "registration"
            )

            let credentialID = Data([0x00, 0x7f, 0x80, 0xff])
            let registered = try await passkeys.registerCredential(
                challenge: challenge,
                operation: "registration",
                expectedUserID: userID,
                credential: PasskeyWrite(
                    credentialID: credentialID,
                    publicKey: Data([0x01, 0x02, 0x03]),
                    signCount: 7,
                    transports: ["hybrid", "internal"],
                    backupEligible: true,
                    backupState: true,
                    deviceType: "multiDevice",
                    name: "Phone"
                )
            )

            #expect(registered.userID == userID)
            #expect(registered.credentialID == credentialID)
            #expect(registered.transports == ["hybrid", "internal"])
            #expect(registered.createdAt != nil)
            #expect(
                try await passkeys.challenge(challenge, operation: "registration") == nil
            )
            #expect(try await passkeys.credential(credentialID: credentialID) == registered)
        }
    }

    @Test("owner mismatch rolls back without consuming the challenge")
    func ownerMismatchRollsBack() async throws {
        try await withPasskeyDatabase { database, passkeys in
            let userID = UUID()
            try await seedUser(userID, database: database)
            let challenge = "owner-\(UUID())"
            _ = try await passkeys.storeChallenge(
                challenge,
                userID: userID,
                operation: "add_passkey"
            )

            await #expect(throws: PasskeyPersistenceError.challengeOwnerMismatch) {
                try await passkeys.registerCredential(
                    challenge: challenge,
                    operation: "add_passkey",
                    expectedUserID: UUID(),
                    credential: testCredential()
                )
            }

            #expect(
                try await passkeys.challenge(challenge, operation: "add_passkey")?.userID
                    == userID
            )
            #expect(try await passkeys.credentials(userID: userID).isEmpty)
        }
    }

    @Test("authentication challenges are consumed exactly once under concurrency")
    func authenticationChallengeIsSingleUse() async throws {
        try await withPasskeyDatabase(maximumConnections: 2) { _, passkeys in
            let challenge = "authentication-\(UUID())"
            _ = try await passkeys.storeChallenge(
                challenge,
                operation: "authentication"
            )

            let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            try await passkeys.consumeAuthenticationChallenge(challenge)
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                var values: [Bool] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }

            #expect(outcomes.filter { $0 }.count == 1)
            #expect(outcomes.filter { !$0 }.count == 1)
        }
    }

    @Test("claim consumption rolls back when registration fails")
    func claimAndRegistrationAreAtomic() async throws {
        try await withPasskeyDatabase { database, passkeys in
            let userID = UUID()
            let claimID = UUID()
            try await seedUser(userID, database: database)
            try await seedClaim(claimID, userID: userID, database: database)

            await #expect(throws: PasskeyPersistenceError.challengeNotFound) {
                try await passkeys.claimAccountAndRegisterCredential(
                    claimID: claimID,
                    expectedUserID: userID,
                    challenge: "missing",
                    operation: "claim",
                    credential: testCredential()
                )
            }
            #expect(!(try await claimWasConsumed(claimID, database: database)))

            let challenge = "claim-\(UUID())"
            _ = try await passkeys.storeChallenge(
                challenge,
                userID: userID,
                operation: "claim"
            )
            let registered = try await passkeys.claimAccountAndRegisterCredential(
                claimID: claimID,
                expectedUserID: userID,
                challenge: challenge,
                operation: "claim",
                credential: testCredential()
            )
            #expect(registered.userID == userID)
            #expect(try await claimWasConsumed(claimID, database: database))

            await #expect(throws: PasskeyPersistenceError.claimUnavailable) {
                try await passkeys.claimAccountAndRegisterCredential(
                    claimID: claimID,
                    expectedUserID: userID,
                    challenge: "anything",
                    operation: "claim",
                    credential: testCredential()
                )
            }
        }
    }

    @Test("standard registration cannot bypass a pending account claim")
    func pendingClaimBlocksStandardRegistration() async throws {
        try await withPasskeyDatabase { database, passkeys in
            let userID = UUID()
            let claimID = UUID()
            try await seedUser(userID, database: database)
            try await seedClaim(claimID, userID: userID, database: database)
            let challenge = "pending-claim-\(UUID())"
            _ = try await passkeys.storeChallenge(
                challenge,
                userID: userID,
                operation: "registration"
            )

            await #expect(throws: PasskeyPersistenceError.pendingAccountClaim) {
                try await passkeys.registerCredential(
                    challenge: challenge,
                    operation: "registration",
                    expectedUserID: userID,
                    credential: testCredential(),
                    rejectPendingAccountClaim: true
                )
            }

            #expect(try await passkeys.credentials(userID: userID).isEmpty)
            #expect(
                try await passkeys.challenge(challenge, operation: "registration") != nil
            )
            #expect(!(try await claimWasConsumed(claimID, database: database)))
        }
    }

    @Test("expired claims cannot be consumed at credential commit time")
    func expiredClaimCannotBeConsumed() async throws {
        try await withPasskeyDatabase { database, passkeys in
            let userID = UUID()
            let claimID = UUID()
            try await seedUser(userID, database: database)
            try await seedClaim(claimID, userID: userID, database: database)
            try await expireClaim(claimID, database: database)
            let challenge = "expired-claim-\(UUID())"
            _ = try await passkeys.storeChallenge(
                challenge,
                userID: userID,
                operation: "claim"
            )

            await #expect(throws: PasskeyPersistenceError.claimUnavailable) {
                try await passkeys.claimAccountAndRegisterCredential(
                    claimID: claimID,
                    expectedUserID: userID,
                    challenge: challenge,
                    operation: "claim",
                    credential: testCredential()
                )
            }

            #expect(!(try await claimWasConsumed(claimID, database: database)))
            #expect(try await passkeys.credentials(userID: userID).isEmpty)
            #expect(try await passkeys.challenge(challenge, operation: "claim") != nil)
        }
    }

    @Test("concurrent deletion cannot remove a user's final credential")
    func lastCredentialInvariantIsSerialized() async throws {
        try await withPasskeyDatabase(maximumConnections: 2) { database, passkeys in
            let userID = UUID()
            try await seedUser(userID, database: database)
            let first = try await registerFixture(userID: userID, passkeys: passkeys)
            let second = try await registerFixture(userID: userID, passkeys: passkeys)

            let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
                for id in [first.id, second.id] {
                    group.addTask {
                        do {
                            _ = try await passkeys.deleteOwnedCredential(
                                id: id,
                                userID: userID,
                                allowsDeletingLastCredential: false
                            )
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                var values: [Bool] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }

            #expect(outcomes.filter { $0 }.count == 1)
            #expect(outcomes.filter { !$0 }.count == 1)
            #expect(try await passkeys.credentials(userID: userID).count == 1)
        }
    }

    private func withPasskeyDatabase(
        maximumConnections: Int = 1,
        _ test: (ControlPlanePostgres.PostgresDatabase, PasskeysPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(maximumConnections: maximumConnections) { database in
            try await database.withSession(operation: "test.passkeys.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE users (
                        id UUID PRIMARY KEY,
                        username TEXT NOT NULL
                    )
                    """,
                    operation: "test.passkeys.schema.users"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE authentication_challenges (
                        id UUID PRIMARY KEY,
                        challenge TEXT NOT NULL,
                        user_id UUID,
                        operation TEXT NOT NULL,
                        created_at TIMESTAMPTZ,
                        expires_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.passkeys.schema.challenges"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE user_credentials (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                        credential_id BYTEA NOT NULL UNIQUE,
                        public_key BYTEA NOT NULL,
                        sign_count INTEGER NOT NULL,
                        transports TEXT NOT NULL,
                        backup_eligible BOOLEAN NOT NULL,
                        backup_state BOOLEAN NOT NULL,
                        device_type TEXT NOT NULL,
                        name TEXT,
                        created_at TIMESTAMPTZ,
                        last_used_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.passkeys.schema.credentials"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE account_claim_tokens (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                        expires_at TIMESTAMPTZ,
                        claimed_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.passkeys.schema.claims"
                )
            }
            try await test(database, ControlPlanePersistence(database: database).passkeys)
        }
    }
}

private func testCredential() -> PasskeyWrite {
    PasskeyWrite(
        credentialID: Data(UUID().uuidString.utf8),
        publicKey: Data("test-public-key".utf8),
        transports: ["internal"],
        deviceType: "singleDevice"
    )
}

private func registerFixture(
    userID: UUID,
    passkeys: PasskeysPersistence
) async throws -> PasskeySnapshot {
    let challenge = "fixture-\(UUID())"
    _ = try await passkeys.storeChallenge(
        challenge,
        userID: userID,
        operation: "fixture"
    )
    return try await passkeys.registerCredential(
        challenge: challenge,
        operation: "fixture",
        expectedUserID: userID,
        credential: testCredential()
    )
}

private func seedUser(
    _ id: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.passkeys.seed_user") { session in
        _ = try await session.execute(
            InsertPasskeyTestUser(id: id),
            operation: "test.passkeys.seed_user.query"
        )
    }
}

private func seedClaim(
    _ id: UUID,
    userID: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.passkeys.seed_claim") { session in
        _ = try await session.execute(
            InsertPasskeyTestClaim(id: id, userID: userID),
            operation: "test.passkeys.seed_claim.query"
        )
    }
}

private func claimWasConsumed(
    _ id: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws -> Bool {
    try await database.withSession(operation: "test.passkeys.claim_state") { session in
        let values = try await session.execute(
            FindPasskeyTestClaimState(id: id),
            operation: "test.passkeys.claim_state.query"
        )
        return try #require(values.first as Bool?)
    }
}

private func expireClaim(
    _ id: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.passkeys.expire_claim") { session in
        _ = try await session.execute(
            ExpirePasskeyTestClaim(id: id),
            operation: "test.passkeys.expire_claim.query"
        )
    }
}

private struct InsertPasskeyTestUser: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = "INSERT INTO users (id, username) VALUES ($1, $2)"

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append("user-\(id)")
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct InsertPasskeyTestClaim: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = "INSERT INTO account_claim_tokens (id, user_id, claimed_at) VALUES ($1, $2, NULL)"

    let id: UUID
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct FindPasskeyTestClaimState: PostgresPreparedStatement {
    typealias Row = Bool
    static let sql = "SELECT claimed_at IS NOT NULL FROM account_claim_tokens WHERE id = $1"

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Bool {
        try row.decode(Bool.self)
    }
}

private struct ExpirePasskeyTestClaim: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = """
        UPDATE account_claim_tokens
        SET expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second'
        WHERE id = $1
        """

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}
