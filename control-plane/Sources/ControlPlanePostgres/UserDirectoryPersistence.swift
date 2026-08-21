import Foundation
import PostgresNIO

public struct UserDirectorySnapshot: Equatable, Sendable {
    public let id: UUID
    public let username: String
    public let email: String
    public let displayName: String
    public let currentOrganizationID: UUID?
    public let isSystemAdmin: Bool
    public let source: String
    public let oidcProviderID: UUID?
    public let oidcSubject: String?
    public let scimProvisioned: Bool
    public let scimActive: Bool
    public let sessionEpoch: Int
    public let disabledAt: Date?
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct UserDirectoryWrite: Equatable, Sendable {
    public let id: UUID
    public let username: String
    public let email: String
    public let displayName: String
    public let currentOrganizationID: UUID?
    public let isSystemAdmin: Bool
    public let source: String
    public let oidcProviderID: UUID?
    public let oidcSubject: String?
    public let scimProvisioned: Bool
    public let scimActive: Bool
    public let sessionEpoch: Int
    public let disabledAt: Date?

    public init(
        id: UUID = UUID(),
        username: String,
        email: String,
        displayName: String,
        currentOrganizationID: UUID? = nil,
        isSystemAdmin: Bool = false,
        source: String = "local",
        oidcProviderID: UUID? = nil,
        oidcSubject: String? = nil,
        scimProvisioned: Bool = false,
        scimActive: Bool = true,
        sessionEpoch: Int = 0,
        disabledAt: Date? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.displayName = displayName
        self.currentOrganizationID = currentOrganizationID
        self.isSystemAdmin = isSystemAdmin
        self.source = source
        self.oidcProviderID = oidcProviderID
        self.oidcSubject = oidcSubject
        self.scimProvisioned = scimProvisioned
        self.scimActive = scimActive
        self.sessionEpoch = sessionEpoch
        self.disabledAt = disabledAt
    }
}

public struct UserDirectoryFilter: Equatable, Sendable {
    public var ids: [UUID]?
    public var username: String?
    public var email: String?
    public var oidcProviderID: UUID?
    public var oidcSubject: String?
    public var currentOrganizationID: UUID?
    public var isSystemAdmin: Bool?
    public var disabled: Bool?
    public var excludingID: UUID?
    public var orderByUsername: Bool

    public init(
        ids: [UUID]? = nil,
        username: String? = nil,
        email: String? = nil,
        oidcProviderID: UUID? = nil,
        oidcSubject: String? = nil,
        currentOrganizationID: UUID? = nil,
        isSystemAdmin: Bool? = nil,
        disabled: Bool? = nil,
        excludingID: UUID? = nil,
        orderByUsername: Bool = false
    ) {
        self.ids = ids
        self.username = username
        self.email = email
        self.oidcProviderID = oidcProviderID
        self.oidcSubject = oidcSubject
        self.currentOrganizationID = currentOrganizationID
        self.isSystemAdmin = isSystemAdmin
        self.disabled = disabled
        self.excludingID = excludingID
        self.orderByUsername = orderByUsername
    }
}

public enum UserRegistrationResult: Equatable, Sendable {
    case created(UserDirectorySnapshot)
    case registrationDisabled
    case identifierConflict
}

public enum SCIMUserWriteResult: Equatable, Sendable {
    case saved(UserDirectorySnapshot)
    case identifierConflict
    case notMember
}

public enum OIDCJITProvisionResult: Equatable, Sendable {
    case created(UserDirectorySnapshot)
    case identifierConflict
}

/// Owns account directory state. Credential material, enrollment challenges,
/// and security-event mutations remain in their dedicated identity modules.
public struct UserDirectoryPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func user(id: UUID) async throws -> UserDirectorySnapshot? {
        try await database.withSession(operation: "users.directory.lookup") { session in
            try oneOrNone(
                await session.execute(
                    FindDirectoryUser(id: id),
                    operation: "users.directory.lookup.query"
                )
            )
        }
    }

    public func user(email: String) async throws -> UserDirectorySnapshot? {
        try await database.withSession(operation: "users.directory.lookup_email") { session in
            try oneOrNone(
                await session.execute(
                    FindDirectoryUserByEmail(email: email),
                    operation: "users.directory.lookup_email.query"
                )
            )
        }
    }

    public func user(username: String) async throws -> UserDirectorySnapshot? {
        try await users(filter: UserDirectoryFilter(username: username)).first
    }

    public func users(ids: [UUID]) async throws -> [UserDirectorySnapshot] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "users.directory.lookup_many") { session in
            try await session.execute(
                FindDirectoryUsers(ids: Array(Set(ids))),
                operation: "users.directory.lookup_many.query"
            )
        }
    }

    public func users(filter: UserDirectoryFilter = UserDirectoryFilter()) async throws
        -> [UserDirectorySnapshot]
    {
        if filter.ids?.isEmpty == true { return [] }
        return try await database.withSession(operation: "users.directory.list") { session in
            try await users(filter: filter, session: session)
        }
    }

    public func conflictingUser(
        username: String,
        email: String,
        excludingID: UUID? = nil
    ) async throws -> UserDirectorySnapshot? {
        try await database.withSession(operation: "users.directory.conflict") { session in
            try await conflictingUser(
                username: username,
                email: email,
                excludingID: excludingID,
                session: session
            )
        }
    }

    public func count() async throws -> Int {
        try await database.withSession(operation: "users.directory.count") { session in
            try only(
                await session.execute(
                    CountDirectoryUsers(), operation: "users.directory.count.query"))
        }
    }

    public func isEmpty() async throws -> Bool { try await count() == 0 }

    public func save(_ write: UserDirectoryWrite) async throws -> UserDirectorySnapshot {
        try await database.withSession(operation: "users.directory.save") { session in
            try await save(write, session: session)
        }
    }

    /// Creates the OIDC account, organization membership, and optional
    /// organization role in one transaction. A failed grant cannot leave an
    /// authenticatable account without its authorization state.
    public func provisionOIDCUser(
        _ write: UserDirectoryWrite,
        organizationID: UUID,
        roleID: UUID?
    ) async throws -> OIDCJITProvisionResult {
        try await database.withTransaction(operation: "users.directory.provision_oidc") { session in
            guard try await conflictingUser(
                username: write.username,
                email: write.email,
                excludingID: nil,
                session: session) == nil
            else { return .identifierConflict }

            let user = try await save(write, session: session)
            _ = try await session.execute(
                InsertOIDCOrganizationMembership(
                    id: UUID(), userID: user.id, organizationID: organizationID, roleID: roleID),
                operation: "users.directory.provision_oidc.membership")
            if let roleID {
                _ = try await session.execute(
                    InsertOIDCOrganizationBinding(
                        id: UUID(), userID: user.id, roleID: roleID,
                        organizationID: organizationID),
                    operation: "users.directory.provision_oidc.binding")
            }
            return .created(user)
        }
    }

    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        try await database.withSession(operation: "users.directory.delete") { session in
            try await session.execute(
                DeleteDirectoryUser(id: id), operation: "users.directory.delete.query"
            ).count == 1
        }
    }

    /// Removes the principal's non-FK IAM bindings and the account in one
    /// transaction. Membership and group pivots continue to cascade from the
    /// user row exactly as they did under Fluent.
    @discardableResult
    public func deleteAccount(id: UUID) async throws -> Bool {
        try await database.withTransaction(operation: "users.directory.delete_account") { session in
            _ = try await session.execute(
                DeleteUserRoleBindings(userID: id),
                operation: "users.directory.delete_account.bindings")
            return try await session.execute(
                DeleteDirectoryUser(id: id),
                operation: "users.directory.delete_account.user"
            ).count == 1
        }
    }

    /// Serializes the first-account decision across replicas, then creates the
    /// account in the same transaction that observed the installation state.
    public func register(
        _ write: UserDirectoryWrite,
        selfRegistrationEnabled: Bool
    ) async throws -> UserRegistrationResult {
        try await database.withTransaction(operation: "users.directory.register") { session in
            _ = try await session.execute(
                LockUserRegistration(), operation: "users.directory.register.lock")
            let count = try only(
                await session.execute(
                    CountDirectoryUsers(), operation: "users.directory.register.count"))
            let bootstrapRequired = count == 0
            guard selfRegistrationEnabled || bootstrapRequired else {
                return .registrationDisabled
            }
            guard try await conflictingUser(
                username: write.username,
                email: write.email,
                excludingID: nil,
                session: session
            ) == nil else {
                return .identifierConflict
            }
            var effective = write
            if bootstrapRequired, !write.isSystemAdmin {
                effective = UserDirectoryWrite(
                    id: write.id,
                    username: write.username,
                    email: write.email,
                    displayName: write.displayName,
                    currentOrganizationID: write.currentOrganizationID,
                    isSystemAdmin: true,
                    source: write.source,
                    oidcProviderID: write.oidcProviderID,
                    oidcSubject: write.oidcSubject,
                    scimProvisioned: write.scimProvisioned,
                    scimActive: write.scimActive,
                    sessionEpoch: write.sessionEpoch,
                    disabledAt: write.disabledAt
                )
            }
            return .created(try await save(effective, session: session))
        }
    }

    public func organizationMemberIDs(
        organizationID: UUID,
        among userIDs: [UUID]
    ) async throws -> Set<UUID> {
        guard !userIDs.isEmpty else { return [] }
        return try await database.withSession(operation: "users.directory.organization_members") { session in
            Set(
                try await session.execute(
                    FindOrganizationMemberIDs(
                        organizationID: organizationID,
                        userIDs: Array(Set(userIDs))
                    ),
                    operation: "users.directory.organization_members.query"
                )
            )
        }
    }

    public func scimUsers(organizationID: UUID) async throws -> [UserDirectorySnapshot] {
        try await database.withSession(operation: "users.scim.list") { session in
            try await session.execute(
                ListOrganizationDirectoryUsers(organizationID: organizationID),
                operation: "users.scim.list.query")
        }
    }

    public func scimUser(id: UUID, organizationID: UUID) async throws -> UserDirectorySnapshot? {
        try await database.withSession(operation: "users.scim.lookup") { session in
            try oneOrNone(await session.execute(
                FindOrganizationDirectoryUser(id: id, organizationID: organizationID),
                operation: "users.scim.lookup.query"))
        }
    }

    public func createSCIMUser(
        _ write: UserDirectoryWrite,
        organizationID: UUID
    ) async throws -> SCIMUserWriteResult {
        do {
            return try await database.withTransaction(operation: "users.scim.create") { session in
                guard try await conflictingUser(
                    username: write.username,
                    email: write.email,
                    excludingID: nil,
                    session: session) == nil
                else { return .identifierConflict }
                let user = try await save(write, session: session)
                _ = try only(await session.execute(
                    InsertSCIMOrganizationMembership(
                        id: UUID(), userID: user.id, organizationID: organizationID),
                    operation: "users.scim.create.membership"))
                return .saved(user)
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            return .identifierConflict
        }
    }

    public func updateSCIMUser(
        _ write: UserDirectoryWrite,
        organizationID: UUID
    ) async throws -> SCIMUserWriteResult {
        do {
            return try await database.withTransaction(operation: "users.scim.update") { session in
                let membership = try await session.execute(
                    LockSCIMOrganizationMembership(
                        userID: write.id, organizationID: organizationID),
                    operation: "users.scim.update.membership")
                guard membership.count == 1 else { return .notMember }
                guard try await conflictingUser(
                    username: write.username,
                    email: write.email,
                    excludingID: write.id,
                    session: session) == nil
                else { return .identifierConflict }
                return .saved(try await save(write, session: session))
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            return .identifierConflict
        }
    }

    /// Applies the IdP offboarding signal and removes only access rooted in
    /// this organization. The security-state mutation, membership removal,
    /// group cleanup, and grant cleanup share one pinned transaction.
    public func offboardSCIMUser(
        id: UUID,
        organizationID: UUID,
        disabledAt: Date = Date()
    ) async throws -> UserDirectorySnapshot? {
        try await database.withTransaction(operation: "users.scim.offboard") { session in
            let memberships = try await session.execute(
                LockSCIMOrganizationMembership(userID: id, organizationID: organizationID),
                operation: "users.scim.offboard.membership")
            guard memberships.count == 1 else { return nil }
            let user = try oneOrNone(await session.execute(
                DisableSCIMDirectoryUser(id: id, disabledAt: disabledAt),
                operation: "users.scim.offboard.user"))
            guard let user else { return nil }
            _ = try await session.execute(
                DeleteSCIMOrganizationMembership(userID: id, organizationID: organizationID),
                operation: "users.scim.offboard.organization_membership")
            _ = try await session.execute(
                DeleteSCIMGroupMemberships(userID: id, organizationID: organizationID),
                operation: "users.scim.offboard.group_memberships")
            _ = try await session.execute(
                DeleteSCIMOrganizationRoleBindings(userID: id, organizationID: organizationID),
                operation: "users.scim.offboard.role_bindings")
            return user
        }
    }

    private func users(
        filter: UserDirectoryFilter,
        session: PostgresSession
    ) async throws -> [UserDirectorySnapshot] {
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: directoryUserColumns) FROM users AS u WHERE TRUE"
        if let ids = filter.ids { query += " AND u.id = ANY(\(bind: ids))" }
        if let username = filter.username { query += " AND u.username = \(bind: username)" }
        if let email = filter.email { query += " AND u.email = \(bind: email)" }
        if let oidcProviderID = filter.oidcProviderID {
            query += " AND u.oidc_provider_id = \(bind: oidcProviderID)"
        }
        if let oidcSubject = filter.oidcSubject {
            query += " AND u.oidc_subject = \(bind: oidcSubject)"
        }
        if let currentOrganizationID = filter.currentOrganizationID {
            query += " AND u.current_organization_id = \(bind: currentOrganizationID)"
        }
        if let isSystemAdmin = filter.isSystemAdmin {
            query += " AND u.is_system_admin = \(bind: isSystemAdmin)"
        }
        if let disabled = filter.disabled {
            query += disabled ? " AND u.disabled_at IS NOT NULL" : " AND u.disabled_at IS NULL"
        }
        if let excludingID = filter.excludingID { query += " AND u.id <> \(bind: excludingID)" }
        query += filter.orderByUsername
            ? " ORDER BY u.username, u.id"
            : " ORDER BY u.created_at, u.id"
        return try await session.query(
            query.postgresQuery(), operation: "users.directory.list.query"
        ).map { try PostgresRecordDecoder.decode(UserDirectoryRecord.self, from: $0).snapshot }
    }

    private func conflictingUser(
        username: String,
        email: String,
        excludingID: UUID?,
        session: PostgresSession
    ) async throws -> UserDirectorySnapshot? {
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: directoryUserColumns) FROM users AS u "
        query += "WHERE (u.username = \(bind: username) OR u.email = \(bind: email))"
        if let excludingID { query += " AND u.id <> \(bind: excludingID)" }
        query += " ORDER BY u.created_at, u.id LIMIT 1"
        return try await session.query(
            query.postgresQuery(), operation: "users.directory.conflict.query"
        ).first.map { try PostgresRecordDecoder.decode(UserDirectoryRecord.self, from: $0).snapshot }
    }

    private func save(
        _ write: UserDirectoryWrite,
        session: PostgresSession
    ) async throws -> UserDirectorySnapshot {
        try only(
            await session.execute(
                UpsertDirectoryUser(write: write), operation: "users.directory.save.query"))
    }

    private func oneOrNone(_ rows: [UserDirectorySnapshot]) throws -> UserDirectorySnapshot? {
        guard rows.count <= 1 else {
            throw UserDirectoryPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func only<Value>(_ rows: [Value]) throws -> Value {
        guard rows.count == 1, let row = rows.first else {
            throw UserDirectoryPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row
    }
}

public enum UserDirectoryPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

private let directoryUserColumns = """
    u.id, u.username, u.email, u.display_name AS "displayName",
    u.current_organization_id AS "currentOrganizationID",
    u.is_system_admin AS "isSystemAdmin", u.source,
    u.oidc_provider_id AS "oidcProviderID", u.oidc_subject AS "oidcSubject",
    u.scim_provisioned AS "scimProvisioned", u.scim_active AS "scimActive",
    u.session_epoch AS "sessionEpoch", u.disabled_at AS "disabledAt",
    u.created_at AS "createdAt", u.updated_at AS "updatedAt"
    """

private let returningDirectoryUserColumns = """
    id, username, email, display_name AS "displayName",
    current_organization_id AS "currentOrganizationID",
    is_system_admin AS "isSystemAdmin", source,
    oidc_provider_id AS "oidcProviderID", oidc_subject AS "oidcSubject",
    scim_provisioned AS "scimProvisioned", scim_active AS "scimActive",
    session_epoch AS "sessionEpoch", disabled_at AS "disabledAt",
    created_at AS "createdAt", updated_at AS "updatedAt"
    """

private struct UserDirectoryRecord: Decodable {
    let id: UUID
    let username: String
    let email: String
    let displayName: String
    let currentOrganizationID: UUID?
    let isSystemAdmin: Bool
    let source: String
    let oidcProviderID: UUID?
    let oidcSubject: String?
    let scimProvisioned: Bool
    let scimActive: Bool
    let sessionEpoch: Int
    let disabledAt: Date?
    let createdAt: Date?
    let updatedAt: Date?

    var snapshot: UserDirectorySnapshot {
        UserDirectorySnapshot(
            id: id,
            username: username,
            email: email,
            displayName: displayName,
            currentOrganizationID: currentOrganizationID,
            isSystemAdmin: isSystemAdmin,
            source: source,
            oidcProviderID: oidcProviderID,
            oidcSubject: oidcSubject,
            scimProvisioned: scimProvisioned,
            scimActive: scimActive,
            sessionEpoch: sessionEpoch,
            disabledAt: disabledAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private protocol DirectoryUserStatement: PostgresPreparedStatement
    where Row == UserDirectorySnapshot {}

private extension DirectoryUserStatement {
    func decodeRow(_ row: PostgresRow) throws -> UserDirectorySnapshot {
        try PostgresRecordDecoder.decode(UserDirectoryRecord.self, from: row).snapshot
    }
}

private struct FindDirectoryUser: DirectoryUserStatement {
    static let sql = "SELECT \(directoryUserColumns) FROM users AS u WHERE u.id = $1"
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindOrganizationDirectoryUser: DirectoryUserStatement {
    static var sql: String {
        """
        SELECT \(directoryUserColumns)
        FROM users AS u
        JOIN user_organizations AS membership ON membership.user_id = u.id
        WHERE u.id = $1 AND membership.organization_id = $2
        """
    }
    let id: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
}

private struct ListOrganizationDirectoryUsers: DirectoryUserStatement {
    static var sql: String {
        """
        SELECT \(directoryUserColumns)
        FROM users AS u
        JOIN user_organizations AS membership ON membership.user_id = u.id
        WHERE membership.organization_id = $1
        ORDER BY u.username, u.id
        """
    }
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationID)
        return bindings
    }
}

private struct InsertSCIMOrganizationMembership: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO user_organizations (id, user_id, organization_id, created_at)
        VALUES ($1, $2, $3, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct LockSCIMOrganizationMembership: PostgresPreparedStatement {
    static let sql = """
        SELECT id FROM user_organizations
        WHERE user_id = $1 AND organization_id = $2
        FOR UPDATE
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct DisableSCIMDirectoryUser: DirectoryUserStatement {
    static var sql: String {
        """
        WITH updated AS (
            UPDATE users
            SET scim_active = FALSE,
                disabled_at = COALESCE(disabled_at, $2),
                session_epoch = session_epoch + 1,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = $1
            RETURNING *
        )
        SELECT \(directoryUserColumns) FROM updated AS u
        """
    }
    let id: UUID
    let disabledAt: Date
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(disabledAt)
        return bindings
    }
}

private struct DeleteSCIMOrganizationMembership: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM user_organizations
        WHERE user_id = $1 AND organization_id = $2
        RETURNING id
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct DeleteSCIMGroupMemberships: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM user_groups
        WHERE user_id = $1
          AND group_id IN (SELECT id FROM groups WHERE organization_id = $2)
        RETURNING id
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct DeleteSCIMOrganizationRoleBindings: PostgresPreparedStatement {
    static let sql = """
        WITH RECURSIVE edges(node_type, node_id, parent_type, parent_id) AS (
            SELECT 'organizational_unit', id,
                   CASE WHEN parent_ou_id IS NULL THEN 'organization' ELSE 'organizational_unit' END,
                   COALESCE(parent_ou_id, organization_id) FROM organizational_units
            UNION ALL SELECT 'project', id,
                   CASE WHEN organizational_unit_id IS NOT NULL THEN 'organizational_unit' ELSE 'organization' END,
                   COALESCE(organizational_unit_id, organization_id) FROM projects
            UNION ALL SELECT 'virtual_machine', id, 'project', project_id FROM vms
            UNION ALL SELECT 'sandbox', id, 'project', project_id FROM sandboxes
            UNION ALL SELECT 'image', id, 'project', project_id FROM images
            UNION ALL SELECT 'network', id, 'project', project_id FROM logical_networks
            UNION ALL SELECT 'floating_ip', id, 'project', project_id FROM floating_ips
            UNION ALL SELECT 'load_balancer', id, 'project', project_id FROM load_balancers
            UNION ALL SELECT 'security_group', id, 'project', project_id FROM security_groups
            UNION ALL SELECT 'dns_zone', id, 'project', project_id FROM dns_zones
            UNION ALL SELECT 'dns_record', id, 'dns_zone', zone_id FROM dns_records
            UNION ALL SELECT 'volume', id, 'project', project_id FROM volumes
            UNION ALL SELECT 'volume_snapshot', id, 'project', project_id FROM volume_snapshots
            UNION ALL SELECT 'sandbox_snapshot', id, 'project', project_id FROM sandbox_snapshots
            UNION ALL SELECT 'vm_snapshot', id, 'project', project_id FROM vm_snapshots
            UNION ALL SELECT 'site', id,
                   CASE WHEN organizational_unit_id IS NOT NULL THEN 'organizational_unit' ELSE 'organization' END,
                   COALESCE(organizational_unit_id, organization_id) FROM sites
            UNION ALL SELECT 'agent', id,
                   CASE WHEN organizational_unit_id IS NOT NULL THEN 'organizational_unit' ELSE 'organization' END,
                   COALESCE(organizational_unit_id, organization_id) FROM agents
            UNION ALL SELECT 'service_account', id, 'project', project_id FROM service_accounts
        ), walk(binding_id, node_type, node_id) AS (
            SELECT id, node_type, node_id
            FROM role_bindings
            WHERE principal_type = 'user' AND principal_id = $1
            UNION ALL
            SELECT walk.binding_id, edges.parent_type, edges.parent_id
            FROM walk
            JOIN edges ON edges.node_type = walk.node_type AND edges.node_id = walk.node_id
        )
        DELETE FROM role_bindings
        WHERE id IN (
            SELECT binding_id FROM walk
            WHERE node_type = 'organization' AND node_id = $2
        )
        RETURNING id
        """
    typealias Row = UUID
    let userID: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.makeRandomAccess()["id"].decode(UUID.self)
    }
}

private struct FindDirectoryUserByEmail: DirectoryUserStatement {
    static let sql = "SELECT \(directoryUserColumns) FROM users AS u WHERE u.email = $1"
    let email: String
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(email)
        return bindings
    }
}

private struct FindDirectoryUsers: DirectoryUserStatement {
    static let sql = "SELECT \(directoryUserColumns) FROM users AS u WHERE u.id = ANY($1) ORDER BY u.username, u.id"
    let ids: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(ids)
        return bindings
    }
}

private struct CountDirectoryUsers: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM users"
    typealias Row = Int
    func makeBindings() -> PostgresBindings { PostgresBindings(capacity: 0) }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct LockUserRegistration: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_xact_lock(hashtext('user-registration'))"
    typealias Row = Void
    func makeBindings() -> PostgresBindings { PostgresBindings(capacity: 0) }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct UpsertDirectoryUser: DirectoryUserStatement {
    static let sql = """
        INSERT INTO users (
            id, username, email, display_name, current_organization_id,
            is_system_admin, source, oidc_provider_id, oidc_subject,
            scim_provisioned, scim_active, session_epoch, disabled_at,
            created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        )
        ON CONFLICT (id) DO UPDATE SET
            username = EXCLUDED.username,
            email = EXCLUDED.email,
            display_name = EXCLUDED.display_name,
            current_organization_id = EXCLUDED.current_organization_id,
            is_system_admin = EXCLUDED.is_system_admin,
            source = EXCLUDED.source,
            oidc_provider_id = EXCLUDED.oidc_provider_id,
            oidc_subject = EXCLUDED.oidc_subject,
            scim_provisioned = EXCLUDED.scim_provisioned,
            scim_active = EXCLUDED.scim_active,
            session_epoch = EXCLUDED.session_epoch,
            disabled_at = EXCLUDED.disabled_at,
            updated_at = CURRENT_TIMESTAMP
        RETURNING \(returningDirectoryUserColumns)
        """
    let write: UserDirectoryWrite

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 13)
        bindings.append(write.id)
        bindings.append(write.username)
        bindings.append(write.email)
        bindings.append(write.displayName)
        bindings.append(write.currentOrganizationID)
        bindings.append(write.isSystemAdmin)
        bindings.append(write.source)
        bindings.append(write.oidcProviderID)
        bindings.append(write.oidcSubject)
        bindings.append(write.scimProvisioned)
        bindings.append(write.scimActive)
        bindings.append(write.sessionEpoch)
        bindings.append(write.disabledAt)
        return bindings
    }
}

private struct DeleteDirectoryUser: PostgresPreparedStatement {
    static let sql = "DELETE FROM users WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertOIDCOrganizationMembership: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO user_organizations (id, user_id, organization_id, role_id, created_at)
        VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
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

private struct InsertOIDCOrganizationBinding: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        ) VALUES ($1, 'user', $2, $3, 'organization', $4, NULL, NULL, NULL, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let userID: UUID
    let roleID: UUID
    let organizationID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(roleID)
        bindings.append(organizationID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteUserRoleBindings: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM role_bindings
        WHERE principal_type = 'user' AND principal_id = $1
        RETURNING id
        """
    typealias Row = UUID
    let userID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FindOrganizationMemberIDs: PostgresPreparedStatement {
    static let sql = """
        SELECT user_id
        FROM user_organizations
        WHERE organization_id = $1 AND user_id = ANY($2)
        ORDER BY user_id
        """
    typealias Row = UUID
    let organizationID: UUID
    let userIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(organizationID)
        bindings.append(userIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
