import Foundation
import PostgresNIO

public struct StoredCredentialRestriction: Equatable, Sendable {
    public let actions: [String]
    public let nodeType: String?
    public let nodeID: UUID?

    public init(actions: [String], nodeType: String?, nodeID: UUID?) {
        self.actions = actions
        self.nodeType = nodeType
        self.nodeID = nodeID
    }
}

public enum OAuthDeviceAuthorizationStatus: String, Sendable {
    case pending
    case approved
    case denied
    case redeemed
}

public struct OAuthDeviceAuthorizationWrite: Sendable {
    public let id: UUID
    public let deviceCodeHash: String
    public let userCode: String
    public let clientName: String
    public let restriction: StoredCredentialRestriction
    public let requestIP: String?
    public let expiresAt: Date
    public let pollInterval: Int

    public init(
        id: UUID = UUID(),
        deviceCodeHash: String,
        userCode: String,
        clientName: String,
        restriction: StoredCredentialRestriction,
        requestIP: String?,
        expiresAt: Date,
        pollInterval: Int
    ) {
        self.id = id
        self.deviceCodeHash = deviceCodeHash
        self.userCode = userCode
        self.clientName = clientName
        self.restriction = restriction
        self.requestIP = requestIP
        self.expiresAt = expiresAt
        self.pollInterval = pollInterval
    }
}

public struct OAuthDeviceAuthorizationSnapshot: Equatable, Sendable {
    public let id: UUID
    public let deviceCodeHash: String
    public let userCode: String
    public let clientName: String
    public let restriction: StoredCredentialRestriction
    public let status: OAuthDeviceAuthorizationStatus
    public let userID: UUID?
    public let requestIP: String?
    public let expiresAt: Date
    public let lastPolledAt: Date?
    public let pollInterval: Int
    public let createdAt: Date?

    public func isExpired(at now: Date = Date()) -> Bool { now > expiresAt }
}

public struct CLISessionWrite: Sendable {
    public let id: UUID
    public let userID: UUID
    public let clientName: String
    public let restriction: StoredCredentialRestriction
    public let accessTokenHash: String
    public let accessTokenPrefix: String
    public let accessTokenExpiresAt: Date
    public let refreshTokenHash: String
    public let refreshTokenExpiresAt: Date

    public init(
        id: UUID = UUID(),
        userID: UUID,
        clientName: String,
        restriction: StoredCredentialRestriction,
        accessTokenHash: String,
        accessTokenPrefix: String,
        accessTokenExpiresAt: Date,
        refreshTokenHash: String,
        refreshTokenExpiresAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.clientName = clientName
        self.restriction = restriction
        self.accessTokenHash = accessTokenHash
        self.accessTokenPrefix = accessTokenPrefix
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenHash = refreshTokenHash
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

public struct CLISessionRotation: Sendable {
    public let accessTokenHash: String
    public let accessTokenPrefix: String
    public let accessTokenExpiresAt: Date
    public let refreshTokenHash: String
    public let refreshTokenExpiresAt: Date

    public init(
        accessTokenHash: String,
        accessTokenPrefix: String,
        accessTokenExpiresAt: Date,
        refreshTokenHash: String,
        refreshTokenExpiresAt: Date
    ) {
        self.accessTokenHash = accessTokenHash
        self.accessTokenPrefix = accessTokenPrefix
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenHash = refreshTokenHash
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }
}

public struct CLISessionSnapshot: Equatable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let clientName: String
    public let restriction: StoredCredentialRestriction
    public let accessTokenHash: String
    public let accessTokenPrefix: String
    public let accessTokenExpiresAt: Date
    public let refreshTokenHash: String
    public let previousRefreshTokenHash: String?
    public let refreshTokenExpiresAt: Date
    public let revokedAt: Date?
    public let lastUsedAt: Date?
    public let lastUsedIP: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    public var isRevoked: Bool { revokedAt != nil }
    public func isAccessTokenExpired(at now: Date = Date()) -> Bool {
        now > accessTokenExpiresAt
    }
    public func isRefreshTokenExpired(at now: Date = Date()) -> Bool {
        now > refreshTokenExpiresAt
    }
}

public enum OAuthDeviceSessionsPersistenceError: Error, Equatable, Sendable {
    case invalidAuthorizationStatus(String)
    case authorizationNoLongerPending(UUID)
    case deviceCodeAlreadyRedeemed(UUID)
    case refreshTokenChanged(UUID)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns the OAuth device-code lifecycle and the CLI sessions it mints.
public struct OAuthDeviceSessionsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    @discardableResult
    public func purgeExpiredAuthorizations(before: Date) async throws -> Int {
        try await database.withSession(operation: "oauth_device.purge_expired") { session in
            try await session.execute(
                PurgeExpiredDeviceAuthorizations(before: before),
                operation: "oauth_device.purge_expired.query"
            ).count
        }
    }

    public func userCodeIsTaken(_ userCode: String) async throws -> Bool {
        try await database.withSession(operation: "oauth_device.user_code_taken") { session in
            let rows = try await session.execute(
                DeviceUserCodeExists(userCode: userCode),
                operation: "oauth_device.user_code_taken.query"
            )
            guard rows.count == 1, let taken = rows.first else {
                throw OAuthDeviceSessionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return taken
        }
    }

    public func createAuthorization(
        _ write: OAuthDeviceAuthorizationWrite
    ) async throws -> OAuthDeviceAuthorizationSnapshot {
        try await database.withSession(operation: "oauth_device.create") { session in
            try await session.execute(
                InsertDeviceAuthorization(write: write),
                operation: "oauth_device.create.query"
            ).onlyOAuthAuthorization()
        }
    }

    public func authorization(
        deviceCodeHash: String
    ) async throws -> OAuthDeviceAuthorizationSnapshot? {
        try await database.withSession(operation: "oauth_device.lookup") { session in
            let rows = try await session.execute(
                LookupDeviceAuthorization(deviceCodeHash: deviceCodeHash),
                operation: "oauth_device.lookup.query"
            )
            guard rows.count <= 1 else {
                throw OAuthDeviceSessionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return try rows.first?.snapshot()
        }
    }

    public func pendingAuthorization(
        userCode: String,
        now: Date
    ) async throws -> OAuthDeviceAuthorizationSnapshot? {
        try await database.withSession(operation: "oauth_device.pending") { session in
            let rows = try await session.execute(
                LookupPendingDeviceAuthorization(userCode: userCode, now: now),
                operation: "oauth_device.pending.query"
            )
            guard rows.count <= 1 else {
                throw OAuthDeviceSessionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return try rows.first?.snapshot()
        }
    }

    public func recordPoll(
        authorizationID: UUID,
        at polledAt: Date
    ) async throws -> OAuthDeviceAuthorizationSnapshot? {
        try await database.withSession(operation: "oauth_device.record_poll") { session in
            let rows = try await session.execute(
                UpdateDeviceAuthorizationPoll(id: authorizationID, polledAt: polledAt),
                operation: "oauth_device.record_poll.query"
            )
            guard rows.count <= 1 else {
                throw OAuthDeviceSessionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return try rows.first?.snapshot()
        }
    }

    public func approve(
        authorizationID: UUID,
        userID: UUID,
        restriction: StoredCredentialRestriction,
        now: Date
    ) async throws -> OAuthDeviceAuthorizationSnapshot {
        try await database.withSession(operation: "oauth_device.approve") { session in
            let rows = try await session.execute(
                ApproveDeviceAuthorization(
                    id: authorizationID,
                    userID: userID,
                    restriction: restriction,
                    now: now
                ),
                operation: "oauth_device.approve.query"
            )
            guard let row = rows.first, rows.count == 1 else {
                throw OAuthDeviceSessionsPersistenceError.authorizationNoLongerPending(
                    authorizationID)
            }
            return try row.snapshot()
        }
    }

    public func deny(
        authorizationID: UUID,
        now: Date
    ) async throws -> OAuthDeviceAuthorizationSnapshot {
        try await database.withSession(operation: "oauth_device.deny") { session in
            let rows = try await session.execute(
                DenyDeviceAuthorization(id: authorizationID, now: now),
                operation: "oauth_device.deny.query"
            )
            guard let row = rows.first, rows.count == 1 else {
                throw OAuthDeviceSessionsPersistenceError.authorizationNoLongerPending(
                    authorizationID)
            }
            return try row.snapshot()
        }
    }

    public func redeemAndCreateSession(
        authorizationID: UUID,
        session write: CLISessionWrite
    ) async throws -> CLISessionSnapshot {
        try await database.withTransaction(operation: "oauth_device.redeem") { session in
            let consumed = try await session.execute(
                RedeemDeviceAuthorization(id: authorizationID),
                operation: "oauth_device.redeem.consume"
            )
            guard consumed.count == 1 else {
                throw OAuthDeviceSessionsPersistenceError.deviceCodeAlreadyRedeemed(
                    authorizationID)
            }
            return try await session.execute(
                InsertCLISession(write: write),
                operation: "oauth_device.redeem.create_session"
            ).onlyCLISession()
        }
    }

    public func createSession(_ write: CLISessionWrite) async throws -> CLISessionSnapshot {
        try await database.withSession(operation: "cli_sessions.create") { session in
            try await session.execute(
                InsertCLISession(write: write),
                operation: "cli_sessions.create.query"
            ).onlyCLISession()
        }
    }

    public func session(accessTokenHash: String) async throws -> CLISessionSnapshot? {
        try await lookupSession(
            operation: "cli_sessions.lookup_access",
            statement: LookupCLISessionByAccessToken(hash: accessTokenHash)
        )
    }

    public func session(refreshTokenHash: String) async throws -> CLISessionSnapshot? {
        try await lookupSession(
            operation: "cli_sessions.lookup_refresh",
            statement: LookupCLISessionByRefreshToken(hash: refreshTokenHash)
        )
    }

    public func session(previousRefreshTokenHash: String) async throws -> CLISessionSnapshot? {
        try await lookupSession(
            operation: "cli_sessions.lookup_previous_refresh",
            statement: LookupCLISessionByPreviousRefreshToken(hash: previousRefreshTokenHash)
        )
    }

    private func lookupSession<Statement: PostgresPreparedStatement>(
        operation: PostgresOperation,
        statement: Statement
    ) async throws -> CLISessionSnapshot?
    where Statement.Row == CLISessionRecord {
        try await database.withSession(operation: operation) { session in
            let rows = try await session.execute(statement, operation: operation)
            guard rows.count <= 1 else {
                throw OAuthDeviceSessionsPersistenceError.unexpectedRowCount(
                    expected: 1, actual: rows.count)
            }
            return rows.first?.snapshot
        }
    }

    public func rotateSession(
        sessionID: UUID,
        presentedRefreshTokenHash: String,
        rotation: CLISessionRotation
    ) async throws -> CLISessionSnapshot {
        try await database.withSession(operation: "cli_sessions.rotate") { session in
            let rows = try await session.execute(
                RotateCLISession(
                    id: sessionID,
                    presentedRefreshTokenHash: presentedRefreshTokenHash,
                    rotation: rotation
                ),
                operation: "cli_sessions.rotate.query"
            )
            guard let row = rows.first, rows.count == 1 else {
                throw OAuthDeviceSessionsPersistenceError.refreshTokenChanged(sessionID)
            }
            return row.snapshot
        }
    }

    @discardableResult
    public func revokeSession(id: UUID, at revokedAt: Date) async throws -> Bool {
        try await database.withSession(operation: "cli_sessions.revoke") { session in
            try await session.execute(
                RevokeCLISession(id: id, revokedAt: revokedAt),
                operation: "cli_sessions.revoke.query"
            ).count == 1
        }
    }

    @discardableResult
    public func revokeSession(
        matchingTokenHash tokenHash: String,
        at revokedAt: Date
    ) async throws -> Bool {
        try await database.withSession(operation: "cli_sessions.revoke_token") { session in
            try await session.execute(
                RevokeCLISessionByToken(hash: tokenHash, revokedAt: revokedAt),
                operation: "cli_sessions.revoke_token.query"
            ).count == 1
        }
    }

    @discardableResult
    public func revokeOwnedSession(
        id: UUID,
        userID: UUID,
        at revokedAt: Date
    ) async throws -> Bool {
        try await database.withSession(operation: "cli_sessions.revoke_owned") { session in
            try await session.execute(
                RevokeOwnedCLISession(id: id, userID: userID, revokedAt: revokedAt),
                operation: "cli_sessions.revoke_owned.query"
            ).count == 1
        }
    }

    public func activeSessions(userID: UUID, now: Date) async throws -> [CLISessionSnapshot] {
        try await database.withSession(operation: "cli_sessions.list_active") { session in
            try await session.execute(
                ListActiveCLISessions(userID: userID, now: now),
                operation: "cli_sessions.list_active.query"
            ).map(\.snapshot)
        }
    }

    @discardableResult
    public func recordSessionUsage(
        id: UUID,
        usedAt: Date,
        sourceIP: String?,
        staleBefore: Date
    ) async throws -> Bool {
        try await database.withSession(operation: "cli_sessions.record_usage") { session in
            try await session.execute(
                RecordCLISessionUsage(
                    id: id,
                    usedAt: usedAt,
                    sourceIP: sourceIP,
                    staleBefore: staleBefore
                ),
                operation: "cli_sessions.record_usage.query"
            ).count == 1
        }
    }
}

private struct OAuthDeviceAuthorizationRecord: Sendable {
    let id: UUID
    let deviceCodeHash: String
    let userCode: String
    let clientName: String
    let restrictionActions: [String]
    let restrictionNodeType: String?
    let restrictionNodeID: UUID?
    let status: String
    let userID: UUID?
    let requestIP: String?
    let expiresAt: Date
    let lastPolledAt: Date?
    let pollInterval: Int
    let createdAt: Date?

    init(row: PostgresRow) throws {
        (
            id, deviceCodeHash, userCode, clientName, restrictionActions,
            restrictionNodeType, restrictionNodeID, status, userID, requestIP,
            expiresAt, lastPolledAt, pollInterval, createdAt
        ) = try row.decode(
            (
                UUID, String, String, String, [String], String?, UUID?, String,
                UUID?, String?, Date, Date?, Int, Date?
            ).self)
    }

    func snapshot() throws -> OAuthDeviceAuthorizationSnapshot {
        guard let status = OAuthDeviceAuthorizationStatus(rawValue: status) else {
            throw OAuthDeviceSessionsPersistenceError.invalidAuthorizationStatus(status)
        }
        return OAuthDeviceAuthorizationSnapshot(
            id: id,
            deviceCodeHash: deviceCodeHash,
            userCode: userCode,
            clientName: clientName,
            restriction: StoredCredentialRestriction(
                actions: restrictionActions,
                nodeType: restrictionNodeType,
                nodeID: restrictionNodeID
            ),
            status: status,
            userID: userID,
            requestIP: requestIP,
            expiresAt: expiresAt,
            lastPolledAt: lastPolledAt,
            pollInterval: pollInterval,
            createdAt: createdAt
        )
    }
}

private struct CLISessionRecord: Sendable {
    let id: UUID
    let userID: UUID
    let clientName: String
    let restrictionActions: [String]
    let restrictionNodeType: String?
    let restrictionNodeID: UUID?
    let accessTokenHash: String
    let accessTokenPrefix: String
    let accessTokenExpiresAt: Date
    let refreshTokenHash: String
    let previousRefreshTokenHash: String?
    let refreshTokenExpiresAt: Date
    let revokedAt: Date?
    let lastUsedAt: Date?
    let lastUsedIP: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, userID, clientName, restrictionActions, restrictionNodeType,
            restrictionNodeID, accessTokenHash, accessTokenPrefix,
            accessTokenExpiresAt, refreshTokenHash, previousRefreshTokenHash,
            refreshTokenExpiresAt, revokedAt, lastUsedAt, lastUsedIP, createdAt,
            updatedAt
        ) = try row.decode(
            (
                UUID, UUID, String, [String], String?, UUID?, String, String, Date,
                String, String?, Date, Date?, Date?, String?, Date?, Date?
            ).self)
    }

    var snapshot: CLISessionSnapshot {
        CLISessionSnapshot(
            id: id,
            userID: userID,
            clientName: clientName,
            restriction: StoredCredentialRestriction(
                actions: restrictionActions,
                nodeType: restrictionNodeType,
                nodeID: restrictionNodeID
            ),
            accessTokenHash: accessTokenHash,
            accessTokenPrefix: accessTokenPrefix,
            accessTokenExpiresAt: accessTokenExpiresAt,
            refreshTokenHash: refreshTokenHash,
            previousRefreshTokenHash: previousRefreshTokenHash,
            refreshTokenExpiresAt: refreshTokenExpiresAt,
            revokedAt: revokedAt,
            lastUsedAt: lastUsedAt,
            lastUsedIP: lastUsedIP,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private extension Array where Element == OAuthDeviceAuthorizationRecord {
    func onlyOAuthAuthorization() throws -> OAuthDeviceAuthorizationSnapshot {
        guard count == 1, let row = first else {
            throw OAuthDeviceSessionsPersistenceError.unexpectedRowCount(
                expected: 1, actual: count)
        }
        return try row.snapshot()
    }
}

private extension Array where Element == CLISessionRecord {
    func onlyCLISession() throws -> CLISessionSnapshot {
        guard count == 1, let row = first else {
            throw OAuthDeviceSessionsPersistenceError.unexpectedRowCount(
                expected: 1, actual: count)
        }
        return row.snapshot
    }
}

private let oauthDeviceAuthorizationColumns = """
    id, device_code_hash, user_code, client_name, restriction_actions,
    restriction_node_type, restriction_node_id, status, user_id, request_ip,
    expires_at, last_polled_at, poll_interval, created_at
    """

private let cliSessionColumns = """
    id, user_id, client_name, restriction_actions, restriction_node_type,
    restriction_node_id, access_token_hash, access_token_prefix,
    access_token_expires_at, refresh_token_hash, previous_refresh_token_hash,
    refresh_token_expires_at, revoked_at, last_used_at, last_used_ip,
    created_at, updated_at
    """

private struct PurgeExpiredDeviceAuthorizations: PostgresPreparedStatement {
    static let sql = "DELETE FROM oauth_device_authorizations WHERE expires_at < $1 RETURNING id"
    typealias Row = UUID
    let before: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(before)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeviceUserCodeExists: PostgresPreparedStatement {
    static let sql = "SELECT EXISTS(SELECT 1 FROM oauth_device_authorizations WHERE user_code = $1)"
    typealias Row = Bool
    let userCode: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userCode)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct InsertDeviceAuthorization: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO oauth_device_authorizations (
            id, device_code_hash, user_code, client_name, restriction_actions,
            restriction_node_type, restriction_node_id, status, user_id,
            request_ip, expires_at, last_polled_at, poll_interval, created_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, 'pending', NULL,
            $8, $9, NULL, $10, CURRENT_TIMESTAMP
        )
        RETURNING \(oauthDeviceAuthorizationColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .text, .text, .text, .textArray, .text, .uuid, .text,
        .timestamptz, .int8,
    ]
    typealias Row = OAuthDeviceAuthorizationRecord
    let write: OAuthDeviceAuthorizationWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 10)
        bindings.append(write.id)
        bindings.append(write.deviceCodeHash)
        bindings.append(write.userCode)
        bindings.append(write.clientName)
        bindings.append(write.restriction.actions)
        bindings.append(write.restriction.nodeType)
        bindings.append(write.restriction.nodeID)
        bindings.append(write.requestIP)
        bindings.append(write.expiresAt)
        bindings.append(write.pollInterval)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> OAuthDeviceAuthorizationRecord {
        try OAuthDeviceAuthorizationRecord(row: row)
    }
}

private struct LookupDeviceAuthorization: PostgresPreparedStatement {
    static let sql = """
        SELECT \(oauthDeviceAuthorizationColumns)
        FROM oauth_device_authorizations
        WHERE device_code_hash = $1
        """
    typealias Row = OAuthDeviceAuthorizationRecord
    let deviceCodeHash: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(deviceCodeHash)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> OAuthDeviceAuthorizationRecord {
        try OAuthDeviceAuthorizationRecord(row: row)
    }
}

private struct LookupPendingDeviceAuthorization: PostgresPreparedStatement {
    static let sql = """
        SELECT \(oauthDeviceAuthorizationColumns)
        FROM oauth_device_authorizations
        WHERE user_code = $1 AND status = 'pending' AND expires_at > $2
        """
    typealias Row = OAuthDeviceAuthorizationRecord
    let userCode: String
    let now: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userCode)
        bindings.append(now)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> OAuthDeviceAuthorizationRecord {
        try OAuthDeviceAuthorizationRecord(row: row)
    }
}

private struct UpdateDeviceAuthorizationPoll: PostgresPreparedStatement {
    static let sql = """
        UPDATE oauth_device_authorizations SET last_polled_at = $2
        WHERE id = $1
        RETURNING \(oauthDeviceAuthorizationColumns)
        """
    typealias Row = OAuthDeviceAuthorizationRecord
    let id: UUID
    let polledAt: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(polledAt)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> OAuthDeviceAuthorizationRecord {
        try OAuthDeviceAuthorizationRecord(row: row)
    }
}

private struct ApproveDeviceAuthorization: PostgresPreparedStatement {
    static let sql = """
        UPDATE oauth_device_authorizations
        SET status = 'approved', user_id = $2, restriction_actions = $3,
            restriction_node_type = $4, restriction_node_id = $5
        WHERE id = $1 AND status = 'pending' AND expires_at > $6
        RETURNING \(oauthDeviceAuthorizationColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .textArray, .text, .uuid, .timestamptz,
    ]
    typealias Row = OAuthDeviceAuthorizationRecord
    let id: UUID
    let userID: UUID
    let restriction: StoredCredentialRestriction
    let now: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(restriction.actions)
        bindings.append(restriction.nodeType)
        bindings.append(restriction.nodeID)
        bindings.append(now)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> OAuthDeviceAuthorizationRecord {
        try OAuthDeviceAuthorizationRecord(row: row)
    }
}

private struct DenyDeviceAuthorization: PostgresPreparedStatement {
    static let sql = """
        UPDATE oauth_device_authorizations SET status = 'denied'
        WHERE id = $1 AND status = 'pending' AND expires_at > $2
        RETURNING \(oauthDeviceAuthorizationColumns)
        """
    typealias Row = OAuthDeviceAuthorizationRecord
    let id: UUID
    let now: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(now)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> OAuthDeviceAuthorizationRecord {
        try OAuthDeviceAuthorizationRecord(row: row)
    }
}

private struct RedeemDeviceAuthorization: PostgresPreparedStatement {
    static let sql = """
        UPDATE oauth_device_authorizations SET status = 'redeemed'
        WHERE id = $1 AND status = 'approved'
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertCLISession: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO cli_sessions (
            id, user_id, client_name, restriction_actions,
            restriction_node_type, restriction_node_id, access_token_hash,
            access_token_prefix, access_token_expires_at, refresh_token_hash,
            previous_refresh_token_hash, refresh_token_expires_at, revoked_at,
            last_used_at, last_used_ip, created_at, updated_at
        ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
            NULL, $11, NULL, NULL, NULL, CURRENT_TIMESTAMP, NULL
        )
        RETURNING \(cliSessionColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .textArray, .text, .uuid, .text, .text,
        .timestamptz, .text, .timestamptz,
    ]
    typealias Row = CLISessionRecord
    let write: CLISessionWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 11)
        bindings.append(write.id)
        bindings.append(write.userID)
        bindings.append(write.clientName)
        bindings.append(write.restriction.actions)
        bindings.append(write.restriction.nodeType)
        bindings.append(write.restriction.nodeID)
        bindings.append(write.accessTokenHash)
        bindings.append(write.accessTokenPrefix)
        bindings.append(write.accessTokenExpiresAt)
        bindings.append(write.refreshTokenHash)
        bindings.append(write.refreshTokenExpiresAt)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> CLISessionRecord {
        try CLISessionRecord(row: row)
    }
}

private protocol CLISessionLookupStatement: PostgresPreparedStatement
where Row == CLISessionRecord {
    var hash: String { get }
}

private extension CLISessionLookupStatement {
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(hash)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> CLISessionRecord {
        try CLISessionRecord(row: row)
    }
}

private struct LookupCLISessionByAccessToken: CLISessionLookupStatement {
    static let sql = "SELECT \(cliSessionColumns) FROM cli_sessions WHERE access_token_hash = $1"
    let hash: String
}

private struct LookupCLISessionByRefreshToken: CLISessionLookupStatement {
    static let sql = "SELECT \(cliSessionColumns) FROM cli_sessions WHERE refresh_token_hash = $1"
    let hash: String
}

private struct LookupCLISessionByPreviousRefreshToken: CLISessionLookupStatement {
    static let sql = """
        SELECT \(cliSessionColumns)
        FROM cli_sessions
        WHERE previous_refresh_token_hash = $1
        """
    let hash: String
}

private struct RotateCLISession: PostgresPreparedStatement {
    static let sql = """
        UPDATE cli_sessions
        SET previous_refresh_token_hash = refresh_token_hash,
            access_token_hash = $3,
            access_token_prefix = $4,
            access_token_expires_at = $5,
            refresh_token_hash = $6,
            refresh_token_expires_at = $7,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND refresh_token_hash = $2 AND revoked_at IS NULL
        RETURNING \(cliSessionColumns)
        """
    typealias Row = CLISessionRecord
    let id: UUID
    let presentedRefreshTokenHash: String
    let rotation: CLISessionRotation

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 7)
        bindings.append(id)
        bindings.append(presentedRefreshTokenHash)
        bindings.append(rotation.accessTokenHash)
        bindings.append(rotation.accessTokenPrefix)
        bindings.append(rotation.accessTokenExpiresAt)
        bindings.append(rotation.refreshTokenHash)
        bindings.append(rotation.refreshTokenExpiresAt)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> CLISessionRecord {
        try CLISessionRecord(row: row)
    }
}

private struct RevokeCLISession: PostgresPreparedStatement {
    static let sql = """
        UPDATE cli_sessions SET revoked_at = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND revoked_at IS NULL
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let revokedAt: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(revokedAt)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct RevokeCLISessionByToken: PostgresPreparedStatement {
    static let sql = """
        UPDATE cli_sessions SET revoked_at = $2, updated_at = CURRENT_TIMESTAMP
        WHERE (access_token_hash = $1 OR refresh_token_hash = $1) AND revoked_at IS NULL
        RETURNING id
        """
    typealias Row = UUID
    let hash: String
    let revokedAt: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(hash)
        bindings.append(revokedAt)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct RevokeOwnedCLISession: PostgresPreparedStatement {
    static let sql = """
        UPDATE cli_sessions SET revoked_at = $3, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let userID: UUID
    let revokedAt: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(revokedAt)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct ListActiveCLISessions: PostgresPreparedStatement {
    static let sql = """
        SELECT \(cliSessionColumns)
        FROM cli_sessions
        WHERE user_id = $1 AND revoked_at IS NULL AND refresh_token_expires_at > $2
        ORDER BY created_at DESC, id DESC
        """
    typealias Row = CLISessionRecord
    let userID: UUID
    let now: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(now)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> CLISessionRecord {
        try CLISessionRecord(row: row)
    }
}

private struct RecordCLISessionUsage: PostgresPreparedStatement {
    static let sql = """
        UPDATE cli_sessions
        SET last_used_at = $2, last_used_ip = $3, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND (last_used_at IS NULL OR last_used_at < $4)
        RETURNING id
        """
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .timestamptz, .text, .timestamptz]
    typealias Row = UUID
    let id: UUID
    let usedAt: Date
    let sourceIP: String?
    let staleBefore: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(usedAt)
        bindings.append(sourceIP)
        bindings.append(staleBefore)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}
