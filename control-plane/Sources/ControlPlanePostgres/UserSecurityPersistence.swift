import Foundation
import PostgresNIO

public struct UserSecuritySnapshot: Equatable, Sendable {
    public let id: UUID
    public let username: String
    public let email: String
    public let sessionEpoch: Int
    public let disabledAt: Date?
}

public struct OIDCUserSecurityCandidate: Equatable, Sendable {
    public let user: UserSecuritySnapshot
    public let discoveryURL: String?
    public let authorizationEndpoint: String?
    public let tokenEndpoint: String?
    public let jwksURI: String?
}

public enum UserSecurityPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns user lookup and atomic security-state transitions driven by external
/// identity signals.
public struct UserSecurityPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func organizationMember(
        email: String,
        organizationID: UUID
    ) async throws -> UserSecuritySnapshot? {
        try await database.withSession(operation: "user_security.member_by_email") { session in
            try oneOrNone(
                await session.execute(
                    FindOrganizationMemberByEmail(
                        email: email,
                        organizationID: organizationID
                    ),
                    operation: "user_security.member_by_email.query"
                )
            )
        }
    }

    public func organizationMember(
        id: UUID,
        organizationID: UUID
    ) async throws -> UserSecuritySnapshot? {
        try await database.withSession(operation: "user_security.member_by_id") { session in
            try oneOrNone(
                await session.execute(
                    FindOrganizationMemberByID(
                        id: id,
                        organizationID: organizationID
                    ),
                    operation: "user_security.member_by_id.query"
                )
            )
        }
    }

    public func oidcOrganizationMembers(
        subject: String,
        organizationID: UUID
    ) async throws -> [OIDCUserSecurityCandidate] {
        try await database.withSession(operation: "user_security.oidc_members") { session in
            try await session.execute(
                FindOIDCOrganizationMembers(
                    subject: subject,
                    organizationID: organizationID
                ),
                operation: "user_security.oidc_members.query"
            )
        }
    }

    /// Increment the session epoch in PostgreSQL so concurrent revocations are
    /// never collapsed into one mutable read-modify-write cycle.
    public func revokeSessions(userID: UUID) async throws -> UserSecuritySnapshot? {
        try await database.withSession(operation: "user_security.revoke_sessions") { session in
            try oneOrNone(
                await session.execute(
                    RevokeUserSessions(userID: userID),
                    operation: "user_security.revoke_sessions.query"
                )
            )
        }
    }

    /// Disable an account and revoke all sessions. An existing disabled time is
    /// retained while every signal still advances the session epoch.
    public func disable(
        userID: UUID,
        disabledAt: Date
    ) async throws -> UserSecuritySnapshot? {
        try await database.withSession(operation: "user_security.disable") { session in
            try oneOrNone(
                await session.execute(
                    DisableUser(userID: userID, disabledAt: disabledAt),
                    operation: "user_security.disable.query"
                )
            )
        }
    }

    /// Re-enable a disabled account. Returns nil if the user is missing or was
    /// already enabled, matching the signal processor's no-op behavior.
    public func enable(userID: UUID) async throws -> UserSecuritySnapshot? {
        try await database.withSession(operation: "user_security.enable") { session in
            try oneOrNone(
                await session.execute(
                    EnableUser(userID: userID),
                    operation: "user_security.enable.query"
                )
            )
        }
    }

    private func oneOrNone(_ rows: [UserSecurityRecord]) throws -> UserSecuritySnapshot? {
        guard rows.count <= 1 else {
            throw UserSecurityPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first?.snapshot
    }
}

private struct UserSecurityRecord: Sendable {
    let id: UUID
    let username: String
    let email: String
    let sessionEpoch: Int
    let disabledAt: Date?

    init(row: PostgresRow) throws {
        (id, username, email, sessionEpoch, disabledAt) = try row.decode(
            (UUID, String, String, Int, Date?).self
        )
    }

    var snapshot: UserSecuritySnapshot {
        UserSecuritySnapshot(
            id: id,
            username: username,
            email: email,
            sessionEpoch: sessionEpoch,
            disabledAt: disabledAt
        )
    }
}

private let userSecurityColumns = "id, username, email, session_epoch, disabled_at"

private protocol UserSecurityRecordStatement: PostgresPreparedStatement
where Row == UserSecurityRecord {}

private extension UserSecurityRecordStatement {
    func decodeRow(_ row: PostgresRow) throws -> UserSecurityRecord {
        try UserSecurityRecord(row: row)
    }
}

private struct FindOrganizationMemberByEmail: UserSecurityRecordStatement {
    static let sql = """
        SELECT u.id, u.username, u.email, u.session_epoch, u.disabled_at
        FROM users AS u
        WHERE u.email = $1
          AND EXISTS (
              SELECT 1
              FROM user_organizations AS membership
              WHERE membership.user_id = u.id
                AND membership.organization_id = $2
          )
        """

    let email: String
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(email)
        bindings.append(organizationID)
        return bindings
    }
}

private struct FindOrganizationMemberByID: UserSecurityRecordStatement {
    static let sql = """
        SELECT u.id, u.username, u.email, u.session_epoch, u.disabled_at
        FROM users AS u
        WHERE u.id = $1
          AND EXISTS (
              SELECT 1
              FROM user_organizations AS membership
              WHERE membership.user_id = u.id
                AND membership.organization_id = $2
          )
        """

    let id: UUID
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(organizationID)
        return bindings
    }
}

private struct FindOIDCOrganizationMembers: PostgresPreparedStatement {
    typealias Row = OIDCUserSecurityCandidate
    static let sql = """
        SELECT u.id, u.username, u.email, u.session_epoch, u.disabled_at,
               provider.discovery_url, provider.authorization_endpoint,
               provider.token_endpoint, provider.jwks_uri
        FROM users AS u
        JOIN oidc_providers AS provider ON provider.id = u.oidc_provider_id
        WHERE u.oidc_subject = $1
          AND EXISTS (
              SELECT 1
              FROM user_organizations AS membership
              WHERE membership.user_id = u.id
                AND membership.organization_id = $2
          )
        ORDER BY u.id
        """

    let subject: String
    let organizationID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(subject)
        bindings.append(organizationID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> OIDCUserSecurityCandidate {
        let (
            id, username, email, sessionEpoch, disabledAt,
            discoveryURL, authorizationEndpoint, tokenEndpoint, jwksURI
        ) = try row.decode(
            (
                UUID, String, String, Int, Date?,
                String?, String?, String?, String?
            ).self
        )
        return OIDCUserSecurityCandidate(
            user: UserSecuritySnapshot(
                id: id,
                username: username,
                email: email,
                sessionEpoch: sessionEpoch,
                disabledAt: disabledAt
            ),
            discoveryURL: discoveryURL,
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: tokenEndpoint,
            jwksURI: jwksURI
        )
    }
}

private struct RevokeUserSessions: UserSecurityRecordStatement {
    static let sql = """
        UPDATE users
        SET session_epoch = session_epoch + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(userSecurityColumns)
        """
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }
}

private struct DisableUser: UserSecurityRecordStatement {
    static let sql = """
        UPDATE users
        SET disabled_at = COALESCE(disabled_at, $2),
            session_epoch = session_epoch + 1,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING \(userSecurityColumns)
        """

    let userID: UUID
    let disabledAt: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(userID)
        bindings.append(disabledAt)
        return bindings
    }
}

private struct EnableUser: UserSecurityRecordStatement {
    static let sql = """
        UPDATE users
        SET disabled_at = NULL,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1 AND disabled_at IS NOT NULL
        RETURNING \(userSecurityColumns)
        """

    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }
}
