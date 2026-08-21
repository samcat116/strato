import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native account-recovery persistence", .serialized)
struct AccountRecoveryPersistenceTests {
    @Test("promotion replaces only unclaimed invitations")
    func promotionReplacesUnclaimedInvitations() async throws {
        try await withRecoveryDatabase { database, persistence in
            let userID = UUID()
            let claimedID = UUID()
            let staleID = UUID()
            try await seedRecoveryUser(userID, database: database)
            try await seedRecoveryClaim(
                claimedID,
                userID: userID,
                claimed: true,
                database: database
            )
            try await seedRecoveryClaim(
                staleID,
                userID: userID,
                claimed: false,
                database: database
            )

            #expect(try await persistence.account(email: "recovery@example.com")?.id == userID)
            #expect(try await persistence.account(username: "recovery-user")?.id == userID)

            let replacement = AccountClaimIssue(
                tokenHash: "new-hash",
                tokenPrefix: "new-prefix",
                expiresAt: Date().addingTimeInterval(3600),
                createdByID: userID
            )
            let result = try await persistence.grantPlatformAdmin(
                userID: userID,
                claim: replacement
            )

            #expect(!result.wasAlreadySystemAdmin)
            #expect(result.account.isSystemAdmin)
            #expect(result.claimID == replacement.id)
            let claimIDs = try await recoveryClaimIDs(userID: userID, database: database)
            #expect(claimIDs == [claimedID, replacement.id].sorted { $0.uuidString < $1.uuidString })

            let repeated = try await persistence.grantPlatformAdmin(userID: userID, claim: nil)
            #expect(repeated.wasAlreadySystemAdmin)
        }
    }

    @Test("an enrolled account is not partially promoted")
    func enrolledAccountRollsBack() async throws {
        try await withRecoveryDatabase { database, persistence in
            let userID = UUID()
            try await seedRecoveryUser(userID, database: database)
            try await seedRecoveryCredential(userID: userID, database: database)

            await #expect(throws: AccountRecoveryPersistenceError.alreadyEnrolled) {
                try await persistence.grantPlatformAdmin(
                    userID: userID,
                    claim: AccountClaimIssue(
                        tokenHash: "hash",
                        tokenPrefix: "prefix",
                        expiresAt: nil,
                        createdByID: userID
                    )
                )
            }

            #expect(
                try await persistence.account(username: "recovery-user")?.isSystemAdmin
                    == false
            )
            #expect(try await recoveryClaimIDs(userID: userID, database: database).isEmpty)
        }
    }

    @Test("claim issuance rechecks source and disabled state under the account lock")
    func claimEligibilityIsRechecked() async throws {
        try await withRecoveryDatabase { database, persistence in
            let disabledID = UUID()
            let oidcID = UUID()
            try await seedRecoveryUser(
                disabledID,
                username: "disabled",
                email: "disabled@example.com",
                disabledAt: Date(),
                database: database
            )
            try await seedRecoveryUser(
                oidcID,
                username: "oidc",
                email: "oidc@example.com",
                source: "oidc",
                database: database
            )
            let issue = AccountClaimIssue(
                tokenHash: "hash",
                tokenPrefix: "prefix",
                expiresAt: nil,
                createdByID: nil
            )

            await #expect(throws: AccountRecoveryPersistenceError.accountDisabled) {
                try await persistence.grantPlatformAdmin(userID: disabledID, claim: issue)
            }
            await #expect(throws: AccountRecoveryPersistenceError.accountIsNotLocal(source: "oidc")) {
                try await persistence.grantPlatformAdmin(userID: oidcID, claim: issue)
            }
        }
    }

    private func withRecoveryDatabase(
        _ test: (
            ControlPlanePostgres.PostgresDatabase,
            AccountRecoveryPersistence
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.account_recovery.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE users (
                        id UUID PRIMARY KEY,
                        username TEXT NOT NULL UNIQUE,
                        email TEXT NOT NULL UNIQUE,
                        is_system_admin BOOLEAN NOT NULL DEFAULT FALSE,
                        source TEXT NOT NULL,
                        disabled_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.account_recovery.schema.users"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE user_credentials (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL REFERENCES users(id),
                        credential_id BYTEA NOT NULL UNIQUE
                    )
                    """,
                    operation: "test.account_recovery.schema.credentials"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE account_claim_tokens (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL REFERENCES users(id),
                        token_hash TEXT NOT NULL UNIQUE,
                        token_prefix TEXT NOT NULL,
                        expires_at TIMESTAMPTZ,
                        claimed_at TIMESTAMPTZ,
                        created_by_id UUID,
                        created_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.account_recovery.schema.claims"
                )
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).accountRecovery
            )
        }
    }
}

private func seedRecoveryUser(
    _ id: UUID,
    username: String = "recovery-user",
    email: String = "recovery@example.com",
    source: String = "local",
    disabledAt: Date? = nil,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.account_recovery.seed_user") { session in
        _ = try await session.execute(
            InsertRecoveryTestUser(
                id: id,
                username: username,
                email: email,
                source: source,
                disabledAt: disabledAt
            ),
            operation: "test.account_recovery.seed_user.query"
        )
    }
}

private func seedRecoveryClaim(
    _ id: UUID,
    userID: UUID,
    claimed: Bool,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.account_recovery.seed_claim") { session in
        _ = try await session.execute(
            InsertRecoveryTestClaim(id: id, userID: userID, claimed: claimed),
            operation: "test.account_recovery.seed_claim.query"
        )
    }
}

private func seedRecoveryCredential(
    userID: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.account_recovery.seed_credential") { session in
        _ = try await session.execute(
            InsertRecoveryTestCredential(id: UUID(), userID: userID),
            operation: "test.account_recovery.seed_credential.query"
        )
    }
}

private func recoveryClaimIDs(
    userID: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws -> [UUID] {
    try await database.withSession(operation: "test.account_recovery.claim_ids") { session in
        try await session.execute(
            FindRecoveryTestClaimIDs(userID: userID),
            operation: "test.account_recovery.claim_ids.query"
        )
    }
}

private struct InsertRecoveryTestUser: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = """
        INSERT INTO users (
            id, username, email, is_system_admin, source, disabled_at, updated_at
        ) VALUES ($1, $2, $3, FALSE, $4, $5, NULL)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .text, .text, .text, .timestamptz,
    ]

    let id: UUID
    let username: String
    let email: String
    let source: String
    let disabledAt: Date?

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(username)
        bindings.append(email)
        bindings.append(source)
        bindings.append(disabledAt)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct InsertRecoveryTestClaim: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = """
        INSERT INTO account_claim_tokens (
            id, user_id, token_hash, token_prefix, expires_at,
            claimed_at, created_by_id, created_at
        ) VALUES ($1, $2, $3, 'prefix', NULL, $4, NULL, CURRENT_TIMESTAMP)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .timestamptz,
    ]

    let id: UUID
    let userID: UUID
    let claimed: Bool

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(userID)
        bindings.append("hash-\(id)")
        bindings.append(claimed ? Date() : nil)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct InsertRecoveryTestCredential: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = "INSERT INTO user_credentials (id, user_id, credential_id) VALUES ($1, $2, $3)"

    let id: UUID
    let userID: UUID

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(userID)
        try bindings.append(Data(id.uuidString.utf8))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private struct FindRecoveryTestClaimIDs: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = "SELECT id FROM account_claim_tokens WHERE user_id = $1 ORDER BY id"

    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}
