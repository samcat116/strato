import Foundation
import PostgresNIO

public struct BootstrapInstallationWrite: Sendable {
    public let userID: UUID
    public let username: String
    public let email: String
    public let organizationID: UUID
    public let organizationName: String
    public let projectID: UUID
    public let projectName: String
    public let siteID: UUID
    public let siteName: String
    public let adminRoleID: UUID
    public let claim: AccountClaimIssue?
    public let apiKey: APIKeyWrite?

    public init(
        userID: UUID = UUID(),
        username: String,
        email: String,
        organizationID: UUID = UUID(),
        organizationName: String,
        projectID: UUID = UUID(),
        projectName: String,
        siteID: UUID = UUID(),
        siteName: String,
        adminRoleID: UUID,
        claim: AccountClaimIssue?,
        apiKey: APIKeyWrite?
    ) {
        self.userID = userID
        self.username = username
        self.email = email
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.projectID = projectID
        self.projectName = projectName
        self.siteID = siteID
        self.siteName = siteName
        self.adminRoleID = adminRoleID
        self.claim = claim
        self.apiKey = apiKey
    }
}

public struct BootstrapInstallationSnapshot: Equatable, Sendable {
    public let userID: UUID
    public let organizationID: UUID
    public let projectID: UUID
    public let siteID: UUID
    public let claimID: UUID?
    public let apiKeyID: UUID?
}

public enum BootstrapPersistenceError: Error, Equatable, Sendable {
    case alreadyInitialized
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns the trust-on-first-use bootstrap invariant as one native transaction.
/// All identifiers are application-generated so project paths and bindings can
/// be written in their final form without mutable intermediate records.
public struct BootstrapPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func hasUsers() async throws -> Bool {
        try await database.withSession(operation: "bootstrap.has_users") { session in
            try only(
                await session.execute(
                    BootstrapHasUsers(),
                    operation: "bootstrap.has_users.query"
                )
            )
        }
    }

    public func createInstallation(
        _ write: BootstrapInstallationWrite
    ) async throws -> BootstrapInstallationSnapshot {
        try await database.withTransaction(operation: "bootstrap.create_installation") { session in
            _ = try only(
                await session.execute(
                    LockBootstrapRegistration(),
                    operation: "bootstrap.lock_registration"
                )
            )
            guard
                !(try only(
                    await session.execute(
                        BootstrapHasUsers(),
                        operation: "bootstrap.recheck_users"
                    )
                ))
            else {
                throw BootstrapPersistenceError.alreadyInitialized
            }

            try await expectOne(
                session.execute(
                    InsertBootstrapUser(write: write),
                    operation: "bootstrap.insert_user"
                )
            )
            if let claim = write.claim {
                try await expectOne(
                    session.execute(
                        InsertBootstrapClaim(userID: write.userID, claim: claim),
                        operation: "bootstrap.insert_claim"
                    )
                )
            }
            try await expectOne(
                session.execute(
                    InsertBootstrapOrganization(write: write),
                    operation: "bootstrap.insert_organization"
                )
            )
            try await expectOne(
                session.execute(
                    InsertBootstrapMembership(write: write),
                    operation: "bootstrap.insert_membership"
                )
            )
            try await expectOne(
                session.execute(
                    InsertBootstrapRoleBinding(
                        principalID: write.userID,
                        roleID: write.adminRoleID,
                        nodeType: "organization",
                        nodeID: write.organizationID,
                        createdBy: write.userID
                    ),
                    operation: "bootstrap.insert_organization_binding"
                )
            )
            try await expectOne(
                session.execute(
                    SetBootstrapCurrentOrganization(
                        userID: write.userID,
                        organizationID: write.organizationID
                    ),
                    operation: "bootstrap.set_current_organization"
                )
            )
            try await expectOne(
                session.execute(
                    InsertBootstrapProject(write: write),
                    operation: "bootstrap.insert_project"
                )
            )
            try await expectOne(
                session.execute(
                    InsertBootstrapRoleBinding(
                        principalID: write.userID,
                        roleID: write.adminRoleID,
                        nodeType: "project",
                        nodeID: write.projectID,
                        createdBy: write.userID
                    ),
                    operation: "bootstrap.insert_project_binding"
                )
            )
            try await expectOne(
                session.execute(
                    InsertBootstrapSite(write: write),
                    operation: "bootstrap.insert_site"
                )
            )
            if let apiKey = write.apiKey {
                try await expectOne(
                    session.execute(
                        InsertBootstrapAPIKey(write: apiKey),
                        operation: "bootstrap.insert_api_key"
                    )
                )
            }

            return BootstrapInstallationSnapshot(
                userID: write.userID,
                organizationID: write.organizationID,
                projectID: write.projectID,
                siteID: write.siteID,
                claimID: write.claim?.id,
                apiKeyID: write.apiKey?.id
            )
        }
    }

    private func only<T>(_ rows: [T]) throws -> T {
        guard rows.count == 1, let value = rows.first else {
            throw BootstrapPersistenceError.unexpectedRowCount(
                expected: 1,
                actual: rows.count
            )
        }
        return value
    }

    private func expectOne<T>(_ rows: [T]) throws {
        guard rows.count == 1 else {
            throw BootstrapPersistenceError.unexpectedRowCount(
                expected: 1,
                actual: rows.count
            )
        }
    }
}

private struct LockBootstrapRegistration: PostgresPreparedStatement {
    typealias Row = Bool
    static let sql = """
        SELECT TRUE
        FROM (SELECT pg_advisory_xact_lock(hashtext($1))) AS acquired
        """

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append("user-registration")
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Bool {
        try row.decode(Bool.self)
    }
}

private struct BootstrapHasUsers: PostgresPreparedStatement {
    typealias Row = Bool
    static let sql = "SELECT EXISTS(SELECT 1 FROM users)"

    func makeBindings() -> PostgresBindings { PostgresBindings() }

    func decodeRow(_ row: PostgresRow) throws -> Bool {
        try row.decode(Bool.self)
    }
}

private struct InsertBootstrapUser: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO users (
            id, username, email, display_name, is_system_admin, source,
            scim_provisioned, scim_active, session_epoch, created_at, updated_at
        )
        VALUES ($1, $2, $3, $2, TRUE, 'local', FALSE, TRUE, 0,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """

    let write: BootstrapInstallationWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(write.userID)
        bindings.append(write.username)
        bindings.append(write.email)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertBootstrapClaim: PostgresPreparedStatement {
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

private struct InsertBootstrapOrganization: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO organizations (id, name, description, created_at, updated_at)
        VALUES ($1, $2, 'Created by `App bootstrap`', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """

    let write: BootstrapInstallationWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(write.organizationID)
        bindings.append(write.organizationName)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertBootstrapMembership: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO user_organizations (
            id, user_id, organization_id, role_id, created_at
        )
        VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
        RETURNING id
        """

    let write: BootstrapInstallationWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(UUID())
        bindings.append(write.userID)
        bindings.append(write.organizationID)
        bindings.append(write.adminRoleID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertBootstrapRoleBinding: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        )
        VALUES ($1, 'user', $2, $3, $4, $5, NULL, NULL, $6, CURRENT_TIMESTAMP)
        RETURNING id
        """

    let id = UUID()
    let principalID: UUID
    let roleID: UUID
    let nodeType: String
    let nodeID: UUID
    let createdBy: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(id)
        bindings.append(principalID)
        bindings.append(roleID)
        bindings.append(nodeType)
        bindings.append(nodeID)
        bindings.append(createdBy)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct SetBootstrapCurrentOrganization: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        UPDATE users
        SET current_organization_id = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """

    let userID: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertBootstrapProject: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO projects (
            id, name, description, organization_id, organizational_unit_id,
            path, default_environment, environments, created_at, updated_at
        )
        VALUES ($1, $2, 'Created by `App bootstrap`', $3, NULL, $4,
                'development', $5, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """

    let write: BootstrapInstallationWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(write.projectID)
        bindings.append(write.projectName)
        bindings.append(write.organizationID)
        bindings.append("/\(write.organizationID.uuidString)/\(write.projectID.uuidString)")
        bindings.append(["development", "staging", "production"])
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertBootstrapSite: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO sites (
            id, name, description, organization_id, organizational_unit_id,
            status, labels, created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, NULL, 'active', '{}'::jsonb,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """

    let write: BootstrapInstallationWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(write.siteID)
        bindings.append(write.siteName)
        bindings.append("Default availability zone for \(write.organizationName)")
        bindings.append(write.organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertBootstrapAPIKey: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO api_keys (
            id, user_id, name, key_hash, key_prefix, restriction_actions,
            restriction_node_type, restriction_node_id, is_active, expires_at,
            created_at, updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .text, .text, .textArray,
        .text, .uuid, .bool, .timestamptz,
    ]

    let write: APIKeyWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 10)
        bindings.append(write.id)
        bindings.append(write.userID)
        bindings.append(write.name)
        bindings.append(write.keyHash)
        bindings.append(write.keyPrefix)
        bindings.append(write.restriction.actions)
        bindings.append(write.restriction.nodeType)
        bindings.append(write.restriction.nodeID)
        bindings.append(write.isActive)
        bindings.append(write.expiresAt)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
