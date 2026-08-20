import Foundation
import PostgresNIO

/// Immutable view of a one-time passkey enrollment claim and the small user
/// projection needed by the public claim endpoints.
public struct AccountClaimSnapshot: Equatable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let tokenHash: String
    public let tokenPrefix: String
    public let expiresAt: Date?
    public let claimedAt: Date?
    public let createdByID: UUID?
    public let createdAt: Date?
    public let username: String
    public let displayName: String

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return date > expiresAt
    }

    public func isValid(at date: Date = Date()) -> Bool {
        claimedAt == nil && !isExpired(at: date)
    }
}

public struct AccountInvitationWrite: Sendable {
    public let userID: UUID
    public let membershipID: UUID
    public let roleBindingID: UUID
    public let username: String
    public let email: String
    public let displayName: String
    public let isSystemAdmin: Bool
    public let organizationID: UUID?
    public let roleID: UUID?
    public let claim: AccountClaimIssue

    public init(
        userID: UUID = UUID(),
        membershipID: UUID = UUID(),
        roleBindingID: UUID = UUID(),
        username: String,
        email: String,
        displayName: String,
        isSystemAdmin: Bool,
        organizationID: UUID?,
        roleID: UUID?,
        claim: AccountClaimIssue
    ) {
        self.userID = userID
        self.membershipID = membershipID
        self.roleBindingID = roleBindingID
        self.username = username
        self.email = email
        self.displayName = displayName
        self.isSystemAdmin = isSystemAdmin
        self.organizationID = organizationID
        self.roleID = roleID
        self.claim = claim
    }
}

public struct InvitedAccountSnapshot: Equatable, Sendable {
    public let id: UUID
    public let username: String
    public let email: String
    public let displayName: String
    public let currentOrganizationID: UUID?
    public let isSystemAdmin: Bool
    public let source: String
    public let createdAt: Date?
    public let claimID: UUID
    public let claimExpiresAt: Date?
}

public enum AccountClaimsPersistenceError: Error, Equatable, Sendable {
    case usernameOrEmailExists
    case organizationNotFound
    case roleNotFound(id: UUID)
    case roleOutOfScope(
        roleName: String,
        ownerType: String,
        ownerID: UUID,
        organizationID: UUID
    )
    case unknownRoleOwnerType(String)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns account invitation state. Token hashing remains in the application
/// layer so this module receives only the stored digest, never the bearer
/// secret. Creating the user, claim, membership, and optional role binding is
/// one transaction so an unclaimed account is never visible without its claim.
public struct AccountClaimsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func inviteUser(_ write: AccountInvitationWrite) async throws
        -> InvitedAccountSnapshot
    {
        do {
            return try await database.withTransaction(operation: "account_claims.invite_user") {
                session in
                let existing = try only(
                    await session.execute(
                        InvitationUserExists(username: write.username, email: write.email),
                        operation: "account_claims.invite_user.check_identity"
                    )
                )
                guard !existing else {
                    throw AccountClaimsPersistenceError.usernameOrEmailExists
                }

                if let organizationID = write.organizationID {
                    let organizationExists = try only(
                        await session.execute(
                            InvitationOrganizationExists(id: organizationID),
                            operation: "account_claims.invite_user.check_organization"
                        )
                    )
                    guard organizationExists else {
                        throw AccountClaimsPersistenceError.organizationNotFound
                    }

                    if let roleID = write.roleID {
                        let roles = try await session.execute(
                            FindInvitationRole(id: roleID),
                            operation: "account_claims.invite_user.check_role"
                        )
                        guard let role = roles.first, roles.count == 1 else {
                            throw AccountClaimsPersistenceError.roleNotFound(id: roleID)
                        }
                        switch role.ownerType {
                        case "platform":
                            break
                        case "organization" where role.ownerID == organizationID:
                            break
                        case "organization", "project":
                            throw AccountClaimsPersistenceError.roleOutOfScope(
                                roleName: role.name,
                                ownerType: role.ownerType,
                                ownerID: role.ownerID,
                                organizationID: organizationID
                            )
                        default:
                            throw AccountClaimsPersistenceError.unknownRoleOwnerType(
                                role.ownerType
                            )
                        }
                    }
                }

                let user = try only(
                    await session.execute(
                        InsertInvitedAccount(write: write),
                        operation: "account_claims.invite_user.insert_user"
                    )
                )
                _ = try only(
                    await session.execute(
                        InsertInvitationClaim(userID: write.userID, claim: write.claim),
                        operation: "account_claims.invite_user.insert_claim"
                    )
                )

                if let organizationID = write.organizationID {
                    _ = try only(
                        await session.execute(
                            InsertInvitationMembership(
                                id: write.membershipID,
                                userID: write.userID,
                                organizationID: organizationID,
                                roleID: write.roleID
                            ),
                            operation: "account_claims.invite_user.insert_membership"
                        )
                    )
                    if let roleID = write.roleID {
                        _ = try only(
                            await session.execute(
                                InsertInvitationRoleBinding(
                                    id: write.roleBindingID,
                                    userID: write.userID,
                                    roleID: roleID,
                                    organizationID: organizationID,
                                    createdByID: write.claim.createdByID
                                ),
                                operation: "account_claims.invite_user.insert_role_binding"
                            )
                        )
                    }
                }

                return InvitedAccountSnapshot(
                    id: user.id,
                    username: user.username,
                    email: user.email,
                    displayName: user.displayName,
                    currentOrganizationID: user.currentOrganizationID,
                    isSystemAdmin: user.isSystemAdmin,
                    source: user.source,
                    createdAt: user.createdAt,
                    claimID: write.claim.id,
                    claimExpiresAt: write.claim.expiresAt
                )
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            guard let constraint = error.serverInfo?[.constraintName],
                ["uq:users.username", "uq:users.email"].contains(constraint)
            else {
                throw error
            }
            throw AccountClaimsPersistenceError.usernameOrEmailExists
        }
    }

    public func claim(tokenHash: String) async throws -> AccountClaimSnapshot? {
        try await database.withSession(operation: "account_claims.lookup") { session in
            let rows = try await session.execute(
                FindAccountClaim(tokenHash: tokenHash),
                operation: "account_claims.lookup.query"
            )
            guard rows.count <= 1 else {
                throw AccountClaimsPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: rows.count
                )
            }
            return rows.first?.snapshot
        }
    }

    /// An unconsumed invitation reserves first enrollment even after expiry;
    /// administrators must explicitly replace or recover it. This preserves
    /// the existing takeover-prevention behavior.
    public func hasUnclaimedClaim(userID: UUID) async throws -> Bool {
        try await database.withSession(operation: "account_claims.has_unclaimed") { session in
            let rows = try await session.execute(
                HasUnclaimedAccountClaim(userID: userID),
                operation: "account_claims.has_unclaimed.query"
            )
            guard rows.count == 1, let result = rows.first else {
                throw AccountClaimsPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: rows.count
                )
            }
            return result
        }
    }

    private func only<T>(_ rows: [T]) throws -> T {
        guard rows.count == 1, let value = rows.first else {
            throw AccountClaimsPersistenceError.unexpectedRowCount(
                expected: 1,
                actual: rows.count
            )
        }
        return value
    }
}

private struct InvitedAccountRecord: Sendable {
    let id: UUID
    let username: String
    let email: String
    let displayName: String
    let currentOrganizationID: UUID?
    let isSystemAdmin: Bool
    let source: String
    let createdAt: Date?

    init(row: PostgresRow) throws {
        (
            id, username, email, displayName, currentOrganizationID,
            isSystemAdmin, source, createdAt
        ) = try row.decode(
            (UUID, String, String, String, UUID?, Bool, String, Date?).self
        )
    }
}

private struct InvitationRoleRecord: Sendable {
    let name: String
    let ownerType: String
    let ownerID: UUID

    init(row: PostgresRow) throws {
        (name, ownerType, ownerID) = try row.decode((String, String, UUID).self)
    }
}

private struct InvitationUserExists: PostgresPreparedStatement {
    typealias Row = Bool
    static let sql = "SELECT EXISTS(SELECT 1 FROM users WHERE username = $1 OR email = $2)"

    let username: String
    let email: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(username)
        bindings.append(email)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct InvitationOrganizationExists: PostgresPreparedStatement {
    typealias Row = Bool
    static let sql = "SELECT EXISTS(SELECT 1 FROM organizations WHERE id = $1)"

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct FindInvitationRole: PostgresPreparedStatement {
    typealias Row = InvitationRoleRecord
    static let sql = "SELECT name, owner_type, owner_id FROM iam_roles WHERE id = $1"

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> InvitationRoleRecord {
        try InvitationRoleRecord(row: row)
    }
}

private struct InsertInvitedAccount: PostgresPreparedStatement {
    typealias Row = InvitedAccountRecord
    static let sql = """
        INSERT INTO users (
            id, username, email, display_name, current_organization_id,
            is_system_admin, source, scim_provisioned, scim_active,
            session_epoch, created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, 'local', FALSE, TRUE, 0,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING
            id, username, email, display_name, current_organization_id,
            is_system_admin, source, created_at
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .text, .text, .text, .uuid, .bool,
    ]

    let write: AccountInvitationWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(write.userID)
        bindings.append(write.username)
        bindings.append(write.email)
        bindings.append(write.displayName)
        bindings.append(write.organizationID)
        bindings.append(write.isSystemAdmin)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> InvitedAccountRecord {
        try InvitedAccountRecord(row: row)
    }
}

private struct InsertInvitationClaim: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO account_claim_tokens (
            id, user_id, token_hash, token_prefix, expires_at, claimed_at,
            created_by_id, created_at
        )
        VALUES ($1, $2, $3, $4, $5, NULL, $6, CURRENT_TIMESTAMP)
        RETURNING id
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .text, .timestamptz, .uuid,
    ]

    let userID: UUID
    let claim: AccountClaimIssue

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(claim.id)
        bindings.append(userID)
        bindings.append(claim.tokenHash)
        bindings.append(claim.tokenPrefix)
        bindings.append(claim.expiresAt)
        bindings.append(claim.createdByID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertInvitationMembership: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO user_organizations (
            id, user_id, organization_id, role_id, created_at
        )
        VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
        RETURNING id
        """
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .uuid, .uuid, .uuid]

    let id: UUID
    let userID: UUID
    let organizationID: UUID
    let roleID: UUID?

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(organizationID)
        bindings.append(roleID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertInvitationRoleBinding: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        )
        VALUES ($1, 'user', $2, $3, 'organization', $4,
                NULL, NULL, $5, CURRENT_TIMESTAMP)
        RETURNING id
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .uuid, .uuid, .uuid,
    ]

    let id: UUID
    let userID: UUID
    let roleID: UUID
    let organizationID: UUID
    let createdByID: UUID?

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(roleID)
        bindings.append(organizationID)
        bindings.append(createdByID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct AccountClaimRecord: Sendable {
    let id: UUID
    let userID: UUID
    let tokenHash: String
    let tokenPrefix: String
    let expiresAt: Date?
    let claimedAt: Date?
    let createdByID: UUID?
    let createdAt: Date?
    let username: String
    let displayName: String

    init(row: PostgresRow) throws {
        (
            id, userID, tokenHash, tokenPrefix, expiresAt, claimedAt,
            createdByID, createdAt, username, displayName
        ) = try row.decode(
            (
                UUID, UUID, String, String, Date?, Date?,
                UUID?, Date?, String, String
            ).self
        )
    }

    var snapshot: AccountClaimSnapshot {
        AccountClaimSnapshot(
            id: id,
            userID: userID,
            tokenHash: tokenHash,
            tokenPrefix: tokenPrefix,
            expiresAt: expiresAt,
            claimedAt: claimedAt,
            createdByID: createdByID,
            createdAt: createdAt,
            username: username,
            displayName: displayName
        )
    }
}

private struct FindAccountClaim: PostgresPreparedStatement {
    typealias Row = AccountClaimRecord
    static let sql = """
        SELECT
            claims.id,
            claims.user_id,
            claims.token_hash,
            claims.token_prefix,
            claims.expires_at,
            claims.claimed_at,
            claims.created_by_id,
            claims.created_at,
            users.username,
            users.display_name
        FROM account_claim_tokens AS claims
        INNER JOIN users ON users.id = claims.user_id
        WHERE claims.token_hash = $1
        """

    let tokenHash: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(tokenHash)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> AccountClaimRecord {
        try AccountClaimRecord(row: row)
    }
}

private struct HasUnclaimedAccountClaim: PostgresPreparedStatement {
    typealias Row = Bool
    static let sql = """
        SELECT EXISTS(
            SELECT 1
            FROM account_claim_tokens
            WHERE user_id = $1 AND claimed_at IS NULL
        )
        """

    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Bool {
        try row.decode(Bool.self)
    }
}
