import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native account-claim persistence", .serialized)
struct AccountClaimsPersistenceTests {
    @Test("inviting a user commits its claim, membership, and role binding together")
    func inviteUser() async throws {
        try await withAccountClaimsDatabase { database, claims in
            let creatorID = UUID()
            let organizationID = UUID()
            let roleID = UUID()
            try await seedAccountClaimUser(creatorID, database: database)
            try await seedInvitationOrganization(organizationID, database: database)
            try await seedInvitationRole(
                roleID,
                ownerType: "platform",
                ownerID: UUID(),
                database: database
            )
            let claim = AccountClaimIssue(
                tokenHash: "invite-digest",
                tokenPrefix: "claim_invite",
                expiresAt: Date().addingTimeInterval(60),
                createdByID: creatorID
            )
            let write = AccountInvitationWrite(
                username: "new-invitee",
                email: "new-invitee@example.com",
                displayName: "New Invitee",
                isSystemAdmin: false,
                organizationID: organizationID,
                roleID: roleID,
                claim: claim
            )

            let invited = try await claims.inviteUser(write)

            #expect(invited.id == write.userID)
            #expect(invited.currentOrganizationID == organizationID)
            #expect(invited.createdAt != nil)
            #expect(invited.claimID == claim.id)
            #expect(try await claims.claim(tokenHash: "invite-digest")?.userID == write.userID)
            #expect(try await invitationMembershipCount(database: database) == 1)
            #expect(try await invitationBindingCount(database: database) == 1)
        }
    }

    @Test("an out-of-scope role leaves no partial invitation")
    func outOfScopeRoleRollsBack() async throws {
        try await withAccountClaimsDatabase { database, claims in
            let organizationID = UUID()
            let roleID = UUID()
            let roleOwnerID = UUID()
            try await seedInvitationOrganization(organizationID, database: database)
            try await seedInvitationRole(
                roleID,
                ownerType: "organization",
                ownerID: roleOwnerID,
                database: database
            )
            let write = AccountInvitationWrite(
                username: "rejected-invitee",
                email: "rejected@example.com",
                displayName: "Rejected Invitee",
                isSystemAdmin: false,
                organizationID: organizationID,
                roleID: roleID,
                claim: AccountClaimIssue(
                    tokenHash: "rejected-digest",
                    tokenPrefix: "claim_rejected",
                    expiresAt: nil,
                    createdByID: nil
                )
            )

            await #expect(
                throws: AccountClaimsPersistenceError.roleOutOfScope(
                    roleName: "invitation-role",
                    ownerType: "organization",
                    ownerID: roleOwnerID,
                    organizationID: organizationID
                )
            ) {
                try await claims.inviteUser(write)
            }

            #expect(try await claims.claim(tokenHash: "rejected-digest") == nil)
            #expect(!(try await invitationUserExists(id: write.userID, database: database)))
        }
    }

    @Test("lookup returns an immutable claim and its user projection")
    func lookup() async throws {
        try await withAccountClaimsDatabase { database, claims in
            let userID = UUID()
            let claimID = UUID()
            let now = Date()
            let expiresAt = now.addingTimeInterval(60)
            try await seedAccountClaimUser(userID, database: database)
            try await seedAccountClaim(
                claimID,
                userID: userID,
                tokenHash: "digest",
                expiresAt: expiresAt,
                database: database
            )

            let claim = try #require(try await claims.claim(tokenHash: "digest"))
            #expect(claim.id == claimID)
            #expect(claim.userID == userID)
            #expect(claim.username == "invited-user")
            #expect(claim.displayName == "Invited User")
            #expect(claim.isValid(at: now))
            #expect(!claim.isExpired(at: now))
            #expect(try await claims.hasUnclaimedClaim(userID: userID))
            #expect(try await claims.claim(tokenHash: "unknown") == nil)
        }
    }

    @Test("expired unconsumed claims still reserve first enrollment")
    func expiredClaimStillReservesEnrollment() async throws {
        try await withAccountClaimsDatabase { database, claims in
            let userID = UUID()
            try await seedAccountClaimUser(userID, database: database)
            try await seedAccountClaim(
                UUID(),
                userID: userID,
                tokenHash: "expired",
                expiresAt: Date().addingTimeInterval(-60),
                database: database
            )

            let claim = try #require(try await claims.claim(tokenHash: "expired"))
            #expect(claim.isExpired())
            #expect(!claim.isValid())
            #expect(try await claims.hasUnclaimedClaim(userID: userID))
        }
    }

    @Test("consumed claims no longer reserve enrollment")
    func consumedClaimDoesNotReserveEnrollment() async throws {
        try await withAccountClaimsDatabase { database, claims in
            let userID = UUID()
            try await seedAccountClaimUser(userID, database: database)
            try await seedAccountClaim(
                UUID(),
                userID: userID,
                tokenHash: "consumed",
                claimedAt: Date(),
                database: database
            )

            let claim = try #require(try await claims.claim(tokenHash: "consumed"))
            #expect(!claim.isValid())
            #expect(!(try await claims.hasUnclaimedClaim(userID: userID)))
        }
    }

    private func withAccountClaimsDatabase(
        _ test: (
            ControlPlanePostgres.PostgresDatabase,
            AccountClaimsPersistence
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            try await database.withSession(operation: "test.account_claims.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE users (
                        id UUID PRIMARY KEY,
                        username TEXT NOT NULL UNIQUE,
                        email TEXT NOT NULL UNIQUE,
                        display_name TEXT NOT NULL,
                        current_organization_id UUID,
                        is_system_admin BOOLEAN NOT NULL DEFAULT FALSE,
                        source TEXT NOT NULL DEFAULT 'local',
                        scim_provisioned BOOLEAN NOT NULL DEFAULT FALSE,
                        scim_active BOOLEAN NOT NULL DEFAULT TRUE,
                        session_epoch BIGINT NOT NULL DEFAULT 0,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.account_claims.schema.users"
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
                    operation: "test.account_claims.schema.claims"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE organizations (
                        id UUID PRIMARY KEY,
                        name TEXT NOT NULL
                    )
                    """,
                    operation: "test.account_claims.schema.organizations"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE iam_roles (
                        id UUID PRIMARY KEY,
                        name TEXT NOT NULL,
                        owner_type TEXT NOT NULL,
                        owner_id UUID NOT NULL
                    )
                    """,
                    operation: "test.account_claims.schema.roles"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE user_organizations (
                        id UUID PRIMARY KEY,
                        user_id UUID NOT NULL,
                        organization_id UUID NOT NULL,
                        role_id UUID,
                        created_at TIMESTAMPTZ,
                        UNIQUE(user_id, organization_id)
                    )
                    """,
                    operation: "test.account_claims.schema.memberships"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE role_bindings (
                        id UUID PRIMARY KEY,
                        principal_type TEXT NOT NULL,
                        principal_id UUID NOT NULL,
                        role_id UUID NOT NULL,
                        node_type TEXT NOT NULL,
                        node_id UUID NOT NULL,
                        condition TEXT,
                        expires_at TIMESTAMPTZ,
                        created_by UUID,
                        created_at TIMESTAMPTZ,
                        UNIQUE(principal_type, principal_id, role_id, node_type, node_id)
                    )
                    """,
                    operation: "test.account_claims.schema.bindings"
                )
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).accountClaims
            )
        }
    }
}

private func seedAccountClaimUser(
    _ id: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.account_claims.seed_user") { session in
        _ = try await session.execute(
            InsertAccountClaimTestUser(id: id),
            operation: "test.account_claims.seed_user.query"
        )
    }
}

private func seedAccountClaim(
    _ id: UUID,
    userID: UUID,
    tokenHash: String,
    expiresAt: Date? = nil,
    claimedAt: Date? = nil,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.account_claims.seed_claim") { session in
        _ = try await session.execute(
            InsertAccountClaimTestClaim(
                id: id,
                userID: userID,
                tokenHash: tokenHash,
                expiresAt: expiresAt,
                claimedAt: claimedAt
            ),
            operation: "test.account_claims.seed_claim.query"
        )
    }
}

private struct InsertAccountClaimTestUser: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = """
        INSERT INTO users (id, username, email, display_name)
        VALUES ($1, 'invited-user', $2, 'Invited User')
        """

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append("\(id.uuidString)@example.com")
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}

private func seedInvitationOrganization(
    _ id: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.account_claims.seed_organization") { session in
        _ = try await session.execute(
            InsertInvitationTestOrganization(id: id),
            operation: "test.account_claims.seed_organization.query"
        )
    }
}

private func seedInvitationRole(
    _ id: UUID,
    ownerType: String,
    ownerID: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws {
    try await database.withSession(operation: "test.account_claims.seed_role") { session in
        _ = try await session.execute(
            InsertInvitationTestRole(
                id: id,
                ownerType: ownerType,
                ownerID: ownerID
            ),
            operation: "test.account_claims.seed_role.query"
        )
    }
}

private func invitationMembershipCount(
    database: ControlPlanePostgres.PostgresDatabase
) async throws -> Int64 {
    try await database.withSession(operation: "test.account_claims.count_memberships") { session in
        try #require(
            await session.execute(
                CountInvitationMemberships(),
                operation: "test.account_claims.count_memberships.query"
            ).first
        )
    }
}

private func invitationBindingCount(
    database: ControlPlanePostgres.PostgresDatabase
) async throws -> Int64 {
    try await database.withSession(operation: "test.account_claims.count_bindings") { session in
        try #require(
            await session.execute(
                CountInvitationBindings(),
                operation: "test.account_claims.count_bindings.query"
            ).first
        )
    }
}

private func invitationUserExists(
    id: UUID,
    database: ControlPlanePostgres.PostgresDatabase
) async throws -> Bool {
    try await database.withSession(operation: "test.account_claims.user_exists") { session in
        let rows = try await session.execute(
            InvitationTestUserExists(id: id),
            operation: "test.account_claims.user_exists.query"
        )
        return try #require(rows.first as Bool?)
    }
}

private struct InsertInvitationTestOrganization: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = "INSERT INTO organizations (id, name) VALUES ($1, 'invitation-org')"
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct InsertInvitationTestRole: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = """
        INSERT INTO iam_roles (id, name, owner_type, owner_id)
        VALUES ($1, 'invitation-role', $2, $3)
        """
    let id: UUID
    let ownerType: String
    let ownerID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(ownerType)
        bindings.append(ownerID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private protocol InvitationCountStatement: PostgresPreparedStatement where Row == Int64 {}
private extension InvitationCountStatement {
    func makeBindings() -> PostgresBindings { PostgresBindings() }
    func decodeRow(_ row: PostgresRow) throws -> Int64 { try row.decode(Int64.self) }
}
private struct CountInvitationMemberships: InvitationCountStatement {
    static let sql = "SELECT COUNT(*) FROM user_organizations"
}
private struct CountInvitationBindings: InvitationCountStatement {
    static let sql = "SELECT COUNT(*) FROM role_bindings"
}

private struct InvitationTestUserExists: PostgresPreparedStatement {
    typealias Row = Bool
    static let sql = "SELECT EXISTS(SELECT 1 FROM users WHERE id = $1)"
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}


private struct InsertAccountClaimTestClaim: PostgresPreparedStatement {
    typealias Row = Void
    static let sql = """
        INSERT INTO account_claim_tokens (
            id, user_id, token_hash, token_prefix, expires_at, claimed_at,
            created_by_id, created_at
        )
        VALUES ($1, $2, $3, 'claim_prefix', $4, $5, NULL, CURRENT_TIMESTAMP)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .timestamptz, .timestamptz,
    ]

    let id: UUID
    let userID: UUID
    let tokenHash: String
    let expiresAt: Date?
    let claimedAt: Date?

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(tokenHash)
        bindings.append(expiresAt)
        bindings.append(claimedAt)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws {}
}
