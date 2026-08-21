import Foundation
import PostgresNIO

public struct RecoverableAccountSnapshot: Equatable, Sendable {
    public let id: UUID
    public let username: String
    public let email: String
    public let isSystemAdmin: Bool
    public let source: String
    public let disabledAt: Date?
}

public struct AccountClaimIssue: Sendable {
    public let id: UUID
    public let tokenHash: String
    public let tokenPrefix: String
    public let expiresAt: Date?
    public let createdByID: UUID?

    public init(
        id: UUID = UUID(),
        tokenHash: String,
        tokenPrefix: String,
        expiresAt: Date?,
        createdByID: UUID?
    ) {
        self.id = id
        self.tokenHash = tokenHash
        self.tokenPrefix = tokenPrefix
        self.expiresAt = expiresAt
        self.createdByID = createdByID
    }
}

public struct PlatformAdminRecoveryResult: Equatable, Sendable {
    public let account: RecoverableAccountSnapshot
    public let wasAlreadySystemAdmin: Bool
    public let claimID: UUID?
}

public enum AccountRecoveryPersistenceError: Error, Equatable, Sendable {
    case accountNotFound
    case accountDisabled
    case accountIsNotLocal(source: String)
    case alreadyEnrolled
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns the break-glass account recovery transition used by the control-plane
/// command. The credential check, administrator promotion, stale-claim
/// invalidation, and replacement claim insert are one locked transaction.
public struct AccountRecoveryPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func account(email: String) async throws -> RecoverableAccountSnapshot? {
        try await database.withSession(operation: "account_recovery.lookup_email") { session in
            try oneOrNone(
                await session.execute(
                    FindRecoverableAccountByEmail(email: email),
                    operation: "account_recovery.lookup_email.query"
                )
            )
        }
    }

    public func account(username: String) async throws -> RecoverableAccountSnapshot? {
        try await database.withSession(operation: "account_recovery.lookup_username") { session in
            try oneOrNone(
                await session.execute(
                    FindRecoverableAccountByUsername(username: username),
                    operation: "account_recovery.lookup_username.query"
                )
            )
        }
    }

    /// Promote an account, optionally replacing its one-time passkey claim.
    /// When a claim is requested, the locked account must still be local,
    /// enabled, and have no passkey at the instant the replacement is written.
    public func grantPlatformAdmin(
        userID: UUID,
        claim: AccountClaimIssue?
    ) async throws -> PlatformAdminRecoveryResult {
        try await database.withTransaction(operation: "account_recovery.grant_platform_admin") {
            session in
            let lockedRows = try await session.execute(
                LockRecoverableAccount(id: userID),
                operation: "account_recovery.grant_platform_admin.lock_account"
            )
            guard lockedRows.count == 1, let locked = lockedRows.first else {
                throw AccountRecoveryPersistenceError.accountNotFound
            }

            if claim != nil {
                guard locked.disabledAt == nil else {
                    throw AccountRecoveryPersistenceError.accountDisabled
                }
                guard locked.source == "local" else {
                    throw AccountRecoveryPersistenceError.accountIsNotLocal(source: locked.source)
                }
                let counts = try await session.execute(
                    CountRecoveryPasskeys(userID: userID),
                    operation: "account_recovery.grant_platform_admin.count_passkeys"
                )
                guard counts.count == 1, let count = counts.first else {
                    throw AccountRecoveryPersistenceError.unexpectedRowCount(
                        expected: 1,
                        actual: counts.count
                    )
                }
                guard count == 0 else {
                    throw AccountRecoveryPersistenceError.alreadyEnrolled
                }
            }

            let updatedRows = try await session.execute(
                PromoteRecoverableAccount(id: userID),
                operation: "account_recovery.grant_platform_admin.promote"
            )
            guard updatedRows.count == 1, let updated = updatedRows.first else {
                throw AccountRecoveryPersistenceError.accountNotFound
            }

            if let claim {
                _ = try await session.execute(
                    DeleteUnclaimedRecoveryClaims(userID: userID),
                    operation: "account_recovery.grant_platform_admin.delete_stale_claims"
                )
                let inserted = try await session.execute(
                    InsertRecoveryClaim(userID: userID, issue: claim),
                    operation: "account_recovery.grant_platform_admin.insert_claim"
                )
                guard inserted.count == 1 else {
                    throw AccountRecoveryPersistenceError.unexpectedRowCount(
                        expected: 1,
                        actual: inserted.count
                    )
                }
            }

            return PlatformAdminRecoveryResult(
                account: updated.snapshot,
                wasAlreadySystemAdmin: locked.isSystemAdmin,
                claimID: claim?.id
            )
        }
    }

    private func oneOrNone(
        _ rows: [RecoverableAccountRecord]
    ) throws -> RecoverableAccountSnapshot? {
        guard rows.count <= 1 else {
            throw AccountRecoveryPersistenceError.unexpectedRowCount(
                expected: 1,
                actual: rows.count
            )
        }
        return rows.first?.snapshot
    }
}

private struct RecoverableAccountRecord: Sendable {
    let id: UUID
    let username: String
    let email: String
    let isSystemAdmin: Bool
    let source: String
    let disabledAt: Date?

    init(row: PostgresRow) throws {
        (id, username, email, isSystemAdmin, source, disabledAt) = try row.decode(
            (UUID, String, String, Bool, String, Date?).self
        )
    }

    var snapshot: RecoverableAccountSnapshot {
        RecoverableAccountSnapshot(
            id: id,
            username: username,
            email: email,
            isSystemAdmin: isSystemAdmin,
            source: source,
            disabledAt: disabledAt
        )
    }
}

private protocol RecoverableAccountStatement: PostgresPreparedStatement
where Row == RecoverableAccountRecord {}

private extension RecoverableAccountStatement {
    func decodeRow(_ row: PostgresRow) throws -> RecoverableAccountRecord {
        try RecoverableAccountRecord(row: row)
    }
}

private struct FindRecoverableAccountByEmail: RecoverableAccountStatement {
    static let sql = """
        SELECT id, username, email, is_system_admin, source, disabled_at
        FROM users
        WHERE email = $1
        """

    let email: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(email)
        return bindings
    }
}

private struct FindRecoverableAccountByUsername: RecoverableAccountStatement {
    static let sql = """
        SELECT id, username, email, is_system_admin, source, disabled_at
        FROM users
        WHERE username = $1
        """

    let username: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(username)
        return bindings
    }
}

private struct LockRecoverableAccount: RecoverableAccountStatement {
    static let sql = """
        SELECT id, username, email, is_system_admin, source, disabled_at
        FROM users
        WHERE id = $1
        FOR UPDATE
        """

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct PromoteRecoverableAccount: RecoverableAccountStatement {
    static let sql = """
        UPDATE users
        SET is_system_admin = TRUE, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id, username, email, is_system_admin, source, disabled_at
        """

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct CountRecoveryPasskeys: PostgresPreparedStatement {
    typealias Row = Int
    static let sql = "SELECT COUNT(*)::bigint FROM user_credentials WHERE user_id = $1"

    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Int {
        try row.decode(Int.self)
    }
}

private struct DeleteUnclaimedRecoveryClaims: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        DELETE FROM account_claim_tokens
        WHERE user_id = $1 AND claimed_at IS NULL
        RETURNING id
        """

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

private struct InsertRecoveryClaim: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        INSERT INTO account_claim_tokens (
            id, user_id, token_hash, token_prefix, expires_at,
            claimed_at, created_by_id, created_at
        ) VALUES ($1, $2, $3, $4, $5, NULL, $6, CURRENT_TIMESTAMP)
        RETURNING id
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .text, .text, .timestamptz, .uuid,
    ]

    let userID: UUID
    let issue: AccountClaimIssue

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 6)
        bindings.append(issue.id)
        bindings.append(userID)
        bindings.append(issue.tokenHash)
        bindings.append(issue.tokenPrefix)
        bindings.append(issue.expiresAt)
        bindings.append(issue.createdByID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}
