import Foundation
import PostgresNIO

public struct PasskeyWrite: Sendable {
    public let id: UUID
    public let credentialID: Data
    public let publicKey: Data
    public let signCount: Int32
    public let transports: [String]
    public let backupEligible: Bool
    public let backupState: Bool
    public let deviceType: String
    public let name: String?

    public init(
        id: UUID = UUID(),
        credentialID: Data,
        publicKey: Data,
        signCount: Int32 = 0,
        transports: [String] = [],
        backupEligible: Bool = false,
        backupState: Bool = false,
        deviceType: String = "unknown",
        name: String? = nil
    ) {
        self.id = id
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.signCount = signCount
        self.transports = transports
        self.backupEligible = backupEligible
        self.backupState = backupState
        self.deviceType = deviceType
        self.name = name
    }
}

public struct PasskeyAuthenticationUpdate: Sendable {
    public let signCount: Int32
    public let backupState: Bool
    public let deviceType: String
    public let usedAt: Date

    public init(
        signCount: Int32,
        backupState: Bool,
        deviceType: String,
        usedAt: Date
    ) {
        self.signCount = signCount
        self.backupState = backupState
        self.deviceType = deviceType
        self.usedAt = usedAt
    }
}

public struct PasskeySnapshot: Equatable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let credentialID: Data
    public let publicKey: Data
    public let signCount: Int32
    public let transports: [String]
    public let backupEligible: Bool
    public let backupState: Bool
    public let deviceType: String
    public let name: String?
    public let createdAt: Date?
    public let lastUsedAt: Date?
}

public struct AuthenticationChallengeSnapshot: Equatable, Sendable {
    public let id: UUID
    public let challenge: String
    public let userID: UUID?
    public let operation: String
    public let createdAt: Date?
    public let expiresAt: Date?

    public func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.map { now >= $0 } ?? false
    }
}

public enum PasskeyPersistenceError: Error, Equatable, Sendable {
    case challengeNotFound
    case challengeOwnerMismatch
    case claimUnavailable
    case credentialAlreadyRegistered
    case credentialLimitReached(maximum: Int)
    case credentialNotFound
    case lastCredential
    case pendingAccountClaim
    case userNotFound
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Owns WebAuthn challenge consumption and credential lifecycle invariants.
///
/// Cryptographic WebAuthn verification stays in the application service. Only
/// verified credential material crosses this interface, and challenge or claim
/// consumption is committed atomically with the resulting credential row.
public struct PasskeysPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func credentials(userID: UUID) async throws -> [PasskeySnapshot] {
        try await database.withSession(operation: "passkeys.list") { session in
            try await session.execute(
                ListPasskeys(userID: userID),
                operation: "passkeys.list.query"
            ).map(\.snapshot)
        }
    }

    public func credential(credentialID: Data) async throws -> PasskeySnapshot? {
        try await database.withSession(operation: "passkeys.lookup_credential") { session in
            try oneOrNone(
                await session.execute(
                    FindPasskeyByCredentialID(credentialID: credentialID),
                    operation: "passkeys.lookup_credential.query"
                )
            )
        }
    }

    public func credentialExists(credentialID: Data) async throws -> Bool {
        try await credential(credentialID: credentialID) != nil
    }

    public func challenge(
        _ challenge: String,
        operation: String
    ) async throws -> AuthenticationChallengeSnapshot? {
        try await database.withSession(operation: "passkeys.lookup_challenge") { session in
            try oneOrNone(
                await session.execute(
                    FindChallenge(challenge: challenge, operation: operation),
                    operation: "passkeys.lookup_challenge.query"
                )
            )
        }
    }

    @discardableResult
    public func storeChallenge(
        _ challenge: String,
        userID: UUID? = nil,
        operation: String,
        expiresAt: Date = Date().addingTimeInterval(300)
    ) async throws -> AuthenticationChallengeSnapshot {
        let write = AuthenticationChallengeWrite(
            id: UUID(),
            challenge: challenge,
            userID: userID,
            operation: operation,
            expiresAt: expiresAt
        )
        return try await database.withSession(operation: "passkeys.store_challenge") { session in
            try only(
                await session.execute(
                    InsertChallenge(write: write),
                    operation: "passkeys.store_challenge.query"
                )
            ).snapshot
        }
    }

    /// Atomically consume an unexpired authentication challenge. Consumption
    /// precedes signature verification by design, preserving replay protection
    /// even for authenticators whose signature counter is always zero.
    public func consumeAuthenticationChallenge(_ challenge: String) async throws {
        try await database.withSession(operation: "passkeys.consume_authentication_challenge") {
            session in
            let consumed = try await session.execute(
                ConsumeAuthenticationChallenge(challenge: challenge),
                operation: "passkeys.consume_authentication_challenge.query"
            )
            guard consumed.count == 1 else {
                throw PasskeyPersistenceError.challengeNotFound
            }
        }
    }

    /// Persist a verified credential and consume the challenge in one
    /// transaction. The target user is derived from the locked challenge row.
    public func registerCredential(
        challenge: String,
        operation: String,
        expectedUserID: UUID? = nil,
        credential: PasskeyWrite,
        maximumCredentialsPerUser: Int? = nil,
        rejectPendingAccountClaim: Bool = false
    ) async throws -> PasskeySnapshot {
        do {
            return try await database.withTransaction(operation: "passkeys.register") { session in
                try await registerCredential(
                    session: session,
                    challenge: challenge,
                    operation: operation,
                    expectedUserID: expectedUserID,
                    credential: credential,
                    maximumCredentialsPerUser: maximumCredentialsPerUser,
                    rejectPendingAccountClaim: rejectPendingAccountClaim
                )
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            throw PasskeyPersistenceError.credentialAlreadyRegistered
        }
    }

    /// Consume a one-time account claim and enroll its verified credential in
    /// the same transaction, so either both changes commit or neither does.
    public func claimAccountAndRegisterCredential(
        claimID: UUID,
        expectedUserID: UUID,
        challenge: String,
        operation: String,
        credential: PasskeyWrite,
        maximumCredentialsPerUser: Int? = nil
    ) async throws -> PasskeySnapshot {
        do {
            return try await database.withTransaction(operation: "passkeys.claim_and_register") {
                session in
                // Account recovery also locks the user before replacing claim
                // rows. Keep the same ordering here so a concurrent recovery
                // cannot deadlock with claim completion.
                try await lockUser(expectedUserID, session: session)
                let claims = try await session.execute(
                    ConsumeAccountClaim(claimID: claimID, userID: expectedUserID),
                    operation: "passkeys.claim_and_register.consume_claim"
                )
                guard claims.count == 1 else {
                    throw PasskeyPersistenceError.claimUnavailable
                }

                return try await registerCredential(
                    session: session,
                    challenge: challenge,
                    operation: operation,
                    expectedUserID: expectedUserID,
                    credential: credential,
                    maximumCredentialsPerUser: maximumCredentialsPerUser,
                    rejectPendingAccountClaim: false
                )
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            throw PasskeyPersistenceError.credentialAlreadyRegistered
        }
    }

    public func updateAfterAuthentication(
        id: UUID,
        update: PasskeyAuthenticationUpdate
    ) async throws -> PasskeySnapshot? {
        try await database.withSession(operation: "passkeys.record_authentication") { session in
            try oneOrNone(
                await session.execute(
                    UpdatePasskeyAfterAuthentication(id: id, update: update),
                    operation: "passkeys.record_authentication.query"
                )
            )
        }
    }

    public func renameOwnedCredential(
        id: UUID,
        userID: UUID,
        name: String?
    ) async throws -> PasskeySnapshot? {
        try await database.withSession(operation: "passkeys.rename_owned") { session in
            try oneOrNone(
                await session.execute(
                    RenameOwnedPasskey(id: id, userID: userID, name: name),
                    operation: "passkeys.rename_owned.query"
                )
            )
        }
    }

    /// Delete an owned credential while serializing the last-credential check
    /// against concurrent deletions and enrollments for the same user.
    public func deleteOwnedCredential(
        id: UUID,
        userID: UUID,
        allowsDeletingLastCredential: Bool
    ) async throws -> PasskeySnapshot {
        try await database.withTransaction(operation: "passkeys.delete_owned") { session in
            try await lockUser(userID, session: session)

            let owned = try oneOrNone(
                await session.execute(
                    FindOwnedPasskey(id: id, userID: userID),
                    operation: "passkeys.delete_owned.lookup"
                )
            )
            guard owned != nil else {
                throw PasskeyPersistenceError.credentialNotFound
            }

            if !allowsDeletingLastCredential {
                let counts = try await session.execute(
                    CountPasskeys(userID: userID),
                    operation: "passkeys.delete_owned.count"
                )
                guard counts.count == 1, let count = counts.first else {
                    throw PasskeyPersistenceError.unexpectedRowCount(
                        expected: 1,
                        actual: counts.count
                    )
                }
                guard count > 1 else {
                    throw PasskeyPersistenceError.lastCredential
                }
            }

            return try only(
                await session.execute(
                    DeleteOwnedPasskey(id: id, userID: userID),
                    operation: "passkeys.delete_owned.delete"
                )
            ).snapshot
        }
    }

    private func registerCredential(
        session: PostgresSession,
        challenge: String,
        operation: String,
        expectedUserID: UUID?,
        credential: PasskeyWrite,
        maximumCredentialsPerUser: Int?,
        rejectPendingAccountClaim: Bool
    ) async throws -> PasskeySnapshot {
        let challenges = try await session.execute(
            LockUnexpiredChallenge(challenge: challenge, operation: operation),
            operation: "passkeys.register.lock_challenge"
        )
        guard challenges.count == 1, let storedChallenge = challenges.first,
            let userID = storedChallenge.userID
        else {
            throw PasskeyPersistenceError.challengeNotFound
        }
        if let expectedUserID, expectedUserID != userID {
            throw PasskeyPersistenceError.challengeOwnerMismatch
        }

        try await lockUser(userID, session: session)
        if rejectPendingAccountClaim {
            let claims = try await session.execute(
                CountUnclaimedAccountClaims(userID: userID),
                operation: "passkeys.register.count_unclaimed_claims"
            )
            guard claims.count == 1, let claimCount = claims.first else {
                throw PasskeyPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: claims.count
                )
            }
            guard claimCount == 0 else {
                throw PasskeyPersistenceError.pendingAccountClaim
            }
        }
        if let maximumCredentialsPerUser {
            let counts = try await session.execute(
                CountPasskeys(userID: userID),
                operation: "passkeys.register.count"
            )
            guard counts.count == 1, let count = counts.first else {
                throw PasskeyPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: counts.count
                )
            }
            guard count < maximumCredentialsPerUser else {
                throw PasskeyPersistenceError.credentialLimitReached(
                    maximum: maximumCredentialsPerUser
                )
            }
        }

        let inserted = try only(
            await session.execute(
                InsertPasskey(userID: userID, write: credential),
                operation: "passkeys.register.insert"
            )
        )
        let deleted = try await session.execute(
            DeleteChallenge(id: storedChallenge.id),
            operation: "passkeys.register.consume_challenge"
        )
        guard deleted.count == 1 else {
            throw PasskeyPersistenceError.challengeNotFound
        }
        return inserted.snapshot
    }

    private func lockUser(_ userID: UUID, session: PostgresSession) async throws {
        let users = try await session.execute(
            LockUser(id: userID),
            operation: "passkeys.lock_user"
        )
        guard users.count == 1 else {
            throw PasskeyPersistenceError.userNotFound
        }
    }

    private func oneOrNone(_ rows: [PasskeyRecord]) throws -> PasskeySnapshot? {
        guard rows.count <= 1 else {
            throw PasskeyPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first?.snapshot
    }

    private func oneOrNone(
        _ rows: [AuthenticationChallengeRecord]
    ) throws -> AuthenticationChallengeSnapshot? {
        guard rows.count <= 1 else {
            throw PasskeyPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return rows.first?.snapshot
    }

    private func only(_ rows: [PasskeyRecord]) throws -> PasskeyRecord {
        guard rows.count == 1, let row = rows.first else {
            throw PasskeyPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row
    }

    private func only(
        _ rows: [AuthenticationChallengeRecord]
    ) throws -> AuthenticationChallengeRecord {
        guard rows.count == 1, let row = rows.first else {
            throw PasskeyPersistenceError.unexpectedRowCount(expected: 1, actual: rows.count)
        }
        return row
    }
}

private struct AuthenticationChallengeWrite: Sendable {
    let id: UUID
    let challenge: String
    let userID: UUID?
    let operation: String
    let expiresAt: Date
}

private struct PasskeyRecord: Sendable {
    let id: UUID
    let userID: UUID
    let credentialID: Data
    let publicKey: Data
    let signCount: Int32
    let transportsJSON: String
    let backupEligible: Bool
    let backupState: Bool
    let deviceType: String
    let name: String?
    let createdAt: Date?
    let lastUsedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, userID, credentialID, publicKey, signCount, transportsJSON,
            backupEligible, backupState, deviceType, name, createdAt, lastUsedAt
        ) = try row.decode(
            (
                UUID, UUID, Data, Data, Int32, String,
                Bool, Bool, String, String?, Date?, Date?
            ).self
        )
    }

    var snapshot: PasskeySnapshot {
        PasskeySnapshot(
            id: id,
            userID: userID,
            credentialID: credentialID,
            publicKey: publicKey,
            signCount: signCount,
            transports: decodeTransports(transportsJSON),
            backupEligible: backupEligible,
            backupState: backupState,
            deviceType: deviceType,
            name: name,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )
    }
}

private struct AuthenticationChallengeRecord: Sendable {
    let id: UUID
    let challenge: String
    let userID: UUID?
    let operation: String
    let createdAt: Date?
    let expiresAt: Date?

    init(row: PostgresRow) throws {
        (id, challenge, userID, operation, createdAt, expiresAt) = try row.decode(
            (UUID, String, UUID?, String, Date?, Date?).self
        )
    }

    var snapshot: AuthenticationChallengeSnapshot {
        AuthenticationChallengeSnapshot(
            id: id,
            challenge: challenge,
            userID: userID,
            operation: operation,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }
}

private func encodeTransports(_ transports: [String]) -> String {
    guard let data = try? JSONEncoder().encode(transports),
        let value = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }
    return value
}

private func decodeTransports(_ value: String) -> [String] {
    guard let data = value.data(using: .utf8),
        let transports = try? JSONDecoder().decode([String].self, from: data)
    else {
        return []
    }
    return transports
}

private protocol PasskeyRecordStatement: PostgresPreparedStatement where Row == PasskeyRecord {}

private extension PasskeyRecordStatement {
    func decodeRow(_ row: PostgresRow) throws -> PasskeyRecord {
        try PasskeyRecord(row: row)
    }
}

private protocol ChallengeRecordStatement: PostgresPreparedStatement
where Row == AuthenticationChallengeRecord {}

private extension ChallengeRecordStatement {
    func decodeRow(_ row: PostgresRow) throws -> AuthenticationChallengeRecord {
        try AuthenticationChallengeRecord(row: row)
    }
}

private struct ListPasskeys: PasskeyRecordStatement {
    static let sql = """
        SELECT id, user_id, credential_id, public_key, sign_count, transports,
               backup_eligible, backup_state, device_type, name, created_at, last_used_at
        FROM user_credentials
        WHERE user_id = $1
        ORDER BY created_at ASC, id ASC
        """

    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(userID)
        return bindings
    }
}

private struct FindPasskeyByCredentialID: PasskeyRecordStatement {
    static let sql = """
        SELECT id, user_id, credential_id, public_key, sign_count, transports,
               backup_eligible, backup_state, device_type, name, created_at, last_used_at
        FROM user_credentials
        WHERE credential_id = $1
        """

    let credentialID: Data

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        try bindings.append(credentialID)
        return bindings
    }
}

private struct FindOwnedPasskey: PasskeyRecordStatement {
    static let sql = """
        SELECT id, user_id, credential_id, public_key, sign_count, transports,
               backup_eligible, backup_state, device_type, name, created_at, last_used_at
        FROM user_credentials
        WHERE id = $1 AND user_id = $2
        """

    let id: UUID
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(userID)
        return bindings
    }
}

private struct InsertPasskey: PasskeyRecordStatement {
    static let sql = """
        INSERT INTO user_credentials (
            id, user_id, credential_id, public_key, sign_count, transports,
            backup_eligible, backup_state, device_type, name, created_at, last_used_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, CURRENT_TIMESTAMP, NULL)
        RETURNING id, user_id, credential_id, public_key, sign_count, transports,
                  backup_eligible, backup_state, device_type, name, created_at, last_used_at
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .uuid, .bytea, .bytea, .int4, .text, .bool, .bool, .text, .text,
    ]

    let userID: UUID
    let write: PasskeyWrite

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 10)
        bindings.append(write.id)
        bindings.append(userID)
        try bindings.append(write.credentialID)
        try bindings.append(write.publicKey)
        bindings.append(write.signCount)
        bindings.append(encodeTransports(write.transports))
        bindings.append(write.backupEligible)
        bindings.append(write.backupState)
        bindings.append(write.deviceType)
        bindings.append(write.name)
        return bindings
    }
}

private struct UpdatePasskeyAfterAuthentication: PasskeyRecordStatement {
    static let sql = """
        UPDATE user_credentials
        SET sign_count = $2, backup_state = $3, device_type = $4, last_used_at = $5
        WHERE id = $1
        RETURNING id, user_id, credential_id, public_key, sign_count, transports,
                  backup_eligible, backup_state, device_type, name, created_at, last_used_at
        """

    let id: UUID
    let update: PasskeyAuthenticationUpdate

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(update.signCount)
        bindings.append(update.backupState)
        bindings.append(update.deviceType)
        bindings.append(update.usedAt)
        return bindings
    }
}

private struct RenameOwnedPasskey: PasskeyRecordStatement {
    static let sql = """
        UPDATE user_credentials
        SET name = $3
        WHERE id = $1 AND user_id = $2
        RETURNING id, user_id, credential_id, public_key, sign_count, transports,
                  backup_eligible, backup_state, device_type, name, created_at, last_used_at
        """
    static let bindingDataTypes: [PostgresDataType] = [.uuid, .uuid, .text]

    let id: UUID
    let userID: UUID
    let name: String?

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(id)
        bindings.append(userID)
        bindings.append(name)
        return bindings
    }
}

private struct DeleteOwnedPasskey: PasskeyRecordStatement {
    static let sql = """
        DELETE FROM user_credentials
        WHERE id = $1 AND user_id = $2
        RETURNING id, user_id, credential_id, public_key, sign_count, transports,
                  backup_eligible, backup_state, device_type, name, created_at, last_used_at
        """

    let id: UUID
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(userID)
        return bindings
    }
}

private struct CountPasskeys: PostgresPreparedStatement {
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

private struct CountUnclaimedAccountClaims: PostgresPreparedStatement {
    typealias Row = Int
    static let sql = """
        SELECT COUNT(*)::bigint
        FROM account_claim_tokens
        WHERE user_id = $1 AND claimed_at IS NULL
        """

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

private struct LockUser: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = "SELECT id FROM users WHERE id = $1 FOR UPDATE"

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}

private struct FindChallenge: ChallengeRecordStatement {
    static let sql = """
        SELECT id, challenge, user_id, operation, created_at, expires_at
        FROM authentication_challenges
        WHERE challenge = $1 AND operation = $2
        ORDER BY created_at ASC NULLS FIRST, id ASC
        LIMIT 1
        """

    let challenge: String
    let operation: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(challenge)
        bindings.append(operation)
        return bindings
    }
}

private struct LockUnexpiredChallenge: ChallengeRecordStatement {
    static let sql = """
        SELECT id, challenge, user_id, operation, created_at, expires_at
        FROM authentication_challenges
        WHERE challenge = $1
          AND operation = $2
          AND (expires_at > CURRENT_TIMESTAMP OR expires_at IS NULL)
        ORDER BY created_at ASC NULLS FIRST, id ASC
        LIMIT 1
        FOR UPDATE
        """

    let challenge: String
    let operation: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(challenge)
        bindings.append(operation)
        return bindings
    }
}

private struct InsertChallenge: ChallengeRecordStatement {
    static let sql = """
        INSERT INTO authentication_challenges (
            id, challenge, user_id, operation, created_at, expires_at
        ) VALUES ($1, $2, $3, $4, CURRENT_TIMESTAMP, $5)
        RETURNING id, challenge, user_id, operation, created_at, expires_at
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .text, .uuid, .text, .timestamptz,
    ]

    let write: AuthenticationChallengeWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(write.id)
        bindings.append(write.challenge)
        bindings.append(write.userID)
        bindings.append(write.operation)
        bindings.append(write.expiresAt)
        return bindings
    }
}

private struct ConsumeAuthenticationChallenge: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        DELETE FROM authentication_challenges
        WHERE id = (
            SELECT id
            FROM authentication_challenges
            WHERE challenge = $1
              AND operation = 'authentication'
              AND (expires_at > CURRENT_TIMESTAMP OR expires_at IS NULL)
            ORDER BY created_at ASC NULLS FIRST, id ASC
            LIMIT 1
            FOR UPDATE
        )
        RETURNING id
        """

    let challenge: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(challenge)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}

private struct DeleteChallenge: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = "DELETE FROM authentication_challenges WHERE id = $1 RETURNING id"

    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}

private struct ConsumeAccountClaim: PostgresPreparedStatement {
    typealias Row = UUID
    static let sql = """
        UPDATE account_claim_tokens
        SET claimed_at = CURRENT_TIMESTAMP
        WHERE id = $1
          AND user_id = $2
          AND claimed_at IS NULL
          AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP)
        RETURNING id
        """

    let claimID: UUID
    let userID: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(claimID)
        bindings.append(userID)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID {
        try row.decode(UUID.self)
    }
}
