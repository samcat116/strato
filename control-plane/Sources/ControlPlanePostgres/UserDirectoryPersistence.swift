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
