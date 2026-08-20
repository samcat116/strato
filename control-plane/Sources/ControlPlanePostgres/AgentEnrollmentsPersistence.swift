import Foundation
import PostgresNIO

public struct AgentEnrollmentWrite: Sendable {
    public let id: UUID
    public let agentName: String
    public let trustDomain: String
    public let spiffeID: String
    public let bootstrapTokenHash: String?
    public let siteID: UUID?
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        agentName: String,
        trustDomain: String,
        spiffeID: String,
        bootstrapTokenHash: String?,
        siteID: UUID?,
        organizationID: UUID?,
        organizationalUnitID: UUID?,
        expiresAt: Date
    ) {
        self.id = id
        self.agentName = agentName
        self.trustDomain = trustDomain
        self.spiffeID = spiffeID
        self.bootstrapTokenHash = bootstrapTokenHash
        self.siteID = siteID
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
        self.expiresAt = expiresAt
    }
}

/// Immutable durable enrollment state. The raw bootstrap token never enters
/// this target; callers hash it before persistence and receive it only once.
public struct AgentEnrollmentSnapshot: Equatable, Sendable {
    public let id: UUID
    public let agentName: String
    public let trustDomain: String
    public let spiffeID: String
    public let hasBootstrapToken: Bool
    public let isUsed: Bool
    public let siteID: UUID?
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let expiresAt: Date
    public let createdAt: Date?
    public let usedAt: Date?

    public func isValid(at now: Date = Date()) -> Bool {
        hasBootstrapToken && !isUsed && expiresAt > now
    }
}

public struct AgentEnrollmentListFilter: Sendable {
    public let organizationID: UUID
    public let organizationalUnitIDs: [UUID]

    public init(organizationID: UUID, organizationalUnitIDs: [UUID]) {
        self.organizationID = organizationID
        self.organizationalUnitIDs = organizationalUnitIDs
    }
}

public enum AgentEnrollmentPersistenceError: Error, Equatable, Sendable {
    case duplicateAgentName(trustDomain: String, agentName: String)
    case invalidBootstrapToken
    case notFound(id: UUID)
    case operationLockWasNotHeld(id: UUID)
    case unexpectedRowCount(expected: Int, actual: Int)
}

/// Covers the interval where this process has durably consumed a bootstrap
/// bearer but still holds the only pooled connection while minting with SPIRE.
/// Other replicas observe the consumed row in PostgreSQL; this fast path lets a
/// same-process replay fail without waiting for a pool lease (test deployments
/// intentionally cap the native pool at one connection).
private actor ActiveAgentEnrollmentClaims {
    private var tokenHashes: Set<String> = []

    func contains(_ tokenHash: String) -> Bool {
        tokenHashes.contains(tokenHash)
    }

    func insert(_ tokenHash: String) {
        tokenHashes.insert(tokenHash)
    }

    func remove(_ tokenHash: String) {
        tokenHashes.remove(tokenHash)
    }
}

/// Owns the enrollment row and its cross-replica serialization boundary.
///
/// The advisory lock is session scoped because SPIRE calls can take longer
/// than a database transaction should remain open. The supplied operation is
/// allowed to await external work but never receives the pinned connection.
public struct AgentEnrollmentsPersistence: Sendable {
    private let database: PostgresDatabase
    private let activeClaims: ActiveAgentEnrollmentClaims

    init(database: PostgresDatabase) {
        self.database = database
        self.activeClaims = ActiveAgentEnrollmentClaims()
    }

    public func create(_ write: AgentEnrollmentWrite) async throws -> AgentEnrollmentSnapshot {
        do {
            return try await database.withSession(operation: "agent_enrollments.create") { session in
                try only(
                    await session.execute(
                        InsertAgentEnrollment(write: write),
                        operation: "agent_enrollments.create.insert"
                    )
                ).snapshot
            }
        } catch let error as PSQLError where error.serverInfo?[.sqlState] == "23505" {
            guard
                error.serverInfo?[.constraintName]
                    == "uq:agent_enrollments.trust_domain+agent_enrollments.agent_name"
            else { throw error }
            throw AgentEnrollmentPersistenceError.duplicateAgentName(
                trustDomain: write.trustDomain,
                agentName: write.agentName
            )
        }
    }

    public func find(id: UUID) async throws -> AgentEnrollmentSnapshot? {
        try await database.withSession(operation: "agent_enrollments.find") { session in
            try oneOrNone(
                await session.execute(
                    FindAgentEnrollment(id: id),
                    operation: "agent_enrollments.find.query"
                )
            )
        }
    }

    public func latest(trustDomain: String, agentName: String) async throws
        -> AgentEnrollmentSnapshot?
    {
        try await database.withSession(operation: "agent_enrollments.latest") { session in
            try oneOrNone(
                await session.execute(
                    FindLatestAgentEnrollment(
                        trustDomain: trustDomain,
                        agentName: agentName
                    ),
                    operation: "agent_enrollments.latest.query"
                )
            )
        }
    }

    public func exists(trustDomain: String, agentName: String) async throws -> Bool {
        try await latest(trustDomain: trustDomain, agentName: agentName) != nil
    }

    public func list(filter: AgentEnrollmentListFilter? = nil) async throws
        -> [AgentEnrollmentSnapshot]
    {
        try await database.withSession(operation: "agent_enrollments.list") { session in
            let records: [AgentEnrollmentRecord]
            if let filter {
                records = try await session.execute(
                    ListScopedAgentEnrollments(filter: filter),
                    operation: "agent_enrollments.list.scoped_query"
                )
            } else {
                records = try await session.execute(
                    ListAgentEnrollments(),
                    operation: "agent_enrollments.list.query"
                )
            }
            return records.map(\.snapshot)
        }
    }

    /// Atomically consumes a bearer, then runs the external mint while the
    /// enrollment's session advisory lock is held. A mint failure deliberately
    /// does not restore the bearer.
    public func redeemBootstrapToken<Result: Sendable>(
        tokenHash: String,
        now: Date = Date(),
        operation: @escaping @Sendable (AgentEnrollmentSnapshot) async throws -> Result
    ) async throws -> Result {
        try await redeemBootstrapToken(
            tokenHash: tokenHash,
            now: now,
            prepare: { _ in () },
            operation: { enrollment, _ in
                try await operation(enrollment)
            }
        )
    }

    /// The preparation step runs under the enrollment lock but before the
    /// bearer is consumed. Use it for availability checks whose failure must
    /// leave the credential retryable. The operation runs only after the
    /// conditional claim succeeds.
    public func redeemBootstrapToken<Preparation: Sendable, Result: Sendable>(
        tokenHash: String,
        now: Date = Date(),
        prepare: @escaping @Sendable (AgentEnrollmentSnapshot) async throws -> Preparation,
        operation:
            @escaping @Sendable (
                AgentEnrollmentSnapshot,
                Preparation
            ) async throws -> Result
    ) async throws -> Result {
        guard await !activeClaims.contains(tokenHash) else {
            throw AgentEnrollmentPersistenceError.invalidBootstrapToken
        }

        let enrollment = try await database.withSession(
            operation: "agent_enrollments.redeem.lookup"
        ) { session in
            try oneOrNone(
                await session.execute(
                    FindAgentEnrollmentByBootstrapHash(tokenHash: tokenHash),
                    operation: "agent_enrollments.redeem.lookup.query"
                )
            )
        }
        guard let enrollment, enrollment.isValid(at: now) else {
            throw AgentEnrollmentPersistenceError.invalidBootstrapToken
        }

        return try await withOperationLock(id: enrollment.id) { session in
            let locked = try oneOrNone(
                await session.execute(
                    FindAgentEnrollmentByBootstrapHash(tokenHash: tokenHash),
                    operation: "agent_enrollments.redeem.locked_lookup"
                )
            )
            guard let locked, locked.id == enrollment.id, locked.isValid(at: now) else {
                throw AgentEnrollmentPersistenceError.invalidBootstrapToken
            }

            let preparation = try await prepare(locked)

            let claimed = try await session.execute(
                ClaimAgentEnrollmentBootstrapToken(tokenHash: tokenHash, now: now),
                operation: "agent_enrollments.redeem.claim"
            )
            guard claimed.count == 1, let claimedRecord = claimed.first else {
                throw AgentEnrollmentPersistenceError.invalidBootstrapToken
            }
            await activeClaims.insert(tokenHash)
            do {
                let result = try await operation(claimedRecord.snapshot, preparation)
                await activeClaims.remove(tokenHash)
                return result
            } catch {
                await activeClaims.remove(tokenHash)
                throw error
            }
        }
    }

    /// Holds the enrollment lock across external deprovisioning and deletes
    /// the row only after that work succeeds. `ownsExternalGrant` is resolved
    /// from the live agents table on the same pinned session.
    public func revoke<Result: Sendable>(
        id: UUID,
        operation:
            @escaping @Sendable (
                AgentEnrollmentSnapshot,
                _ ownsExternalGrant: Bool
            ) async throws -> Result
    ) async throws -> Result {
        try await withOperationLock(id: id) { session in
            guard
                let enrollment = try oneOrNone(
                    await session.execute(
                        FindAgentEnrollment(id: id),
                        operation: "agent_enrollments.revoke.find"
                    )
                )
            else {
                throw AgentEnrollmentPersistenceError.notFound(id: id)
            }
            let registered = try only(
                await session.execute(
                    AgentIsRegistered(
                        trustDomain: enrollment.trustDomain,
                        agentName: enrollment.agentName
                    ),
                    operation: "agent_enrollments.revoke.agent_exists"
                )
            )
            let ownsExternalGrant = !registered
            let result = try await operation(enrollment, ownsExternalGrant)
            let deleted = try await session.execute(
                DeleteAgentEnrollment(id: id),
                operation: "agent_enrollments.revoke.delete"
            )
            guard deleted == [id] else {
                throw AgentEnrollmentPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: deleted.count
                )
            }
            return result
        }
    }

    public func markUsed(id: UUID, usedAt: Date = Date()) async throws -> Bool {
        try await database.withSession(operation: "agent_enrollments.mark_used") { session in
            try await session.execute(
                MarkAgentEnrollmentUsed(id: id, usedAt: usedAt),
                operation: "agent_enrollments.mark_used.update"
            ).count == 1
        }
    }

    @discardableResult
    public func delete(trustDomain: String, agentName: String) async throws -> [UUID] {
        try await database.withSession(operation: "agent_enrollments.delete_for_agent") { session in
            try await session.execute(
                DeleteAgentEnrollmentForAgent(
                    trustDomain: trustDomain,
                    agentName: agentName
                ),
                operation: "agent_enrollments.delete_for_agent.delete"
            )
        }
    }

    private enum LockAttempt<Value: Sendable>: Sendable {
        case busy
        case completed(Value)
    }

    private func withOperationLock<Result: Sendable>(
        id: UUID,
        operation: @escaping @Sendable (PostgresSession) async throws -> Result
    ) async throws -> Result {
        let key = "agent-enrollment:\(id.uuidString.lowercased())"
        while true {
            try Task.checkCancellation()
            let attempt: LockAttempt<Result> = try await database.withSession(
                operation: "agent_enrollments.operation_lock"
            ) { session in
                let acquired = try only(
                    await session.execute(
                        TryAgentEnrollmentOperationLock(key: key),
                        operation: "agent_enrollments.operation_lock.acquire"
                    )
                )
                guard acquired else { return .busy }

                do {
                    let result = try await operation(session)
                    let released = try only(
                        await session.execute(
                            ReleaseAgentEnrollmentOperationLock(key: key),
                            operation: "agent_enrollments.operation_lock.release"
                        )
                    )
                    guard released else {
                        throw AgentEnrollmentPersistenceError.operationLockWasNotHeld(id: id)
                    }
                    return .completed(result)
                } catch {
                    let primary = error
                    _ = try? await session.execute(
                        ReleaseAgentEnrollmentOperationLock(key: key),
                        operation: "agent_enrollments.operation_lock.release_after_error"
                    )
                    throw primary
                }
            }

            switch attempt {
            case .busy:
                try await Task.sleep(for: .milliseconds(25))
            case .completed(let value):
                return value
            }
        }
    }

    private func oneOrNone(_ rows: [AgentEnrollmentRecord]) throws
        -> AgentEnrollmentSnapshot?
    {
        guard rows.count <= 1 else {
            throw AgentEnrollmentPersistenceError.unexpectedRowCount(
                expected: 1,
                actual: rows.count
            )
        }
        return rows.first?.snapshot
    }

    private func only<T>(_ rows: [T]) throws -> T {
        guard rows.count == 1, let value = rows.first else {
            throw AgentEnrollmentPersistenceError.unexpectedRowCount(
                expected: 1,
                actual: rows.count
            )
        }
        return value
    }
}

private struct AgentEnrollmentRecord: Sendable {
    let id: UUID
    let agentName: String
    let trustDomain: String
    let spiffeID: String
    let bootstrapTokenHash: String?
    let isUsed: Bool
    let siteID: UUID?
    let organizationID: UUID?
    let organizationalUnitID: UUID?
    let expiresAt: Date
    let createdAt: Date?
    let usedAt: Date?

    init(row: PostgresRow) throws {
        (
            id, agentName, trustDomain, spiffeID, bootstrapTokenHash,
            isUsed, siteID, organizationID, organizationalUnitID,
            expiresAt, createdAt, usedAt
        ) = try row.decode(
            (
                UUID, String, String, String, String?,
                Bool, UUID?, UUID?, UUID?, Date, Date?, Date?
            ).self
        )
    }

    var snapshot: AgentEnrollmentSnapshot {
        AgentEnrollmentSnapshot(
            id: id,
            agentName: agentName,
            trustDomain: trustDomain,
            spiffeID: spiffeID,
            hasBootstrapToken: bootstrapTokenHash != nil,
            isUsed: isUsed,
            siteID: siteID,
            organizationID: organizationID,
            organizationalUnitID: organizationalUnitID,
            expiresAt: expiresAt,
            createdAt: createdAt,
            usedAt: usedAt
        )
    }
}

private let agentEnrollmentColumns = """
    id, agent_name, trust_domain, spiffe_id, bootstrap_token_hash, is_used,
    site_id, organization_id, organizational_unit_id, expires_at, created_at, used_at
    """

private protocol AgentEnrollmentRecordStatement: PostgresPreparedStatement
where Row == AgentEnrollmentRecord {}

private extension AgentEnrollmentRecordStatement {
    func decodeRow(_ row: PostgresRow) throws -> AgentEnrollmentRecord {
        try AgentEnrollmentRecord(row: row)
    }
}

private struct InsertAgentEnrollment: AgentEnrollmentRecordStatement {
    static let sql = """
        INSERT INTO agent_enrollments (
            id, agent_name, trust_domain, spiffe_id, bootstrap_token_hash, is_used,
            site_id, organization_id, organizational_unit_id, expires_at, created_at, used_at
        ) VALUES (
            $1, $2, $3, $4, $5, FALSE, $6, $7, $8, $9, CURRENT_TIMESTAMP, NULL
        )
        RETURNING \(agentEnrollmentColumns)
        """
    static let bindingDataTypes: [PostgresDataType] = [
        .uuid, .text, .text, .text, .text, .uuid, .uuid, .uuid, .timestamptz,
    ]
    let write: AgentEnrollmentWrite

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 9)
        bindings.append(write.id)
        bindings.append(write.agentName)
        bindings.append(write.trustDomain)
        bindings.append(write.spiffeID)
        bindings.append(write.bootstrapTokenHash)
        bindings.append(write.siteID)
        bindings.append(write.organizationID)
        bindings.append(write.organizationalUnitID)
        bindings.append(write.expiresAt)
        return bindings
    }
}

private struct FindAgentEnrollment: AgentEnrollmentRecordStatement {
    static let sql = "SELECT \(agentEnrollmentColumns) FROM agent_enrollments WHERE id = $1"
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindLatestAgentEnrollment: AgentEnrollmentRecordStatement {
    static let sql = """
        SELECT \(agentEnrollmentColumns)
        FROM agent_enrollments
        WHERE trust_domain = $1 AND agent_name = $2
        ORDER BY created_at DESC, id DESC
        LIMIT 1
        """
    let trustDomain: String
    let agentName: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(trustDomain)
        bindings.append(agentName)
        return bindings
    }
}

private struct FindAgentEnrollmentByBootstrapHash: AgentEnrollmentRecordStatement {
    static let sql = """
        SELECT \(agentEnrollmentColumns)
        FROM agent_enrollments
        WHERE bootstrap_token_hash = $1
        """
    let tokenHash: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(tokenHash)
        return bindings
    }
}

private struct ListAgentEnrollments: AgentEnrollmentRecordStatement {
    static let sql = """
        SELECT \(agentEnrollmentColumns)
        FROM agent_enrollments
        ORDER BY created_at DESC, id DESC
        """

    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ListScopedAgentEnrollments: AgentEnrollmentRecordStatement {
    static let sql = """
        SELECT \(agentEnrollmentColumns)
        FROM agent_enrollments
        WHERE organization_id = $1 OR organizational_unit_id = ANY($2)
        ORDER BY created_at DESC, id DESC
        """
    let filter: AgentEnrollmentListFilter

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(filter.organizationID)
        bindings.append(filter.organizationalUnitIDs)
        return bindings
    }
}

private struct ClaimAgentEnrollmentBootstrapToken: AgentEnrollmentRecordStatement {
    static let sql = """
        UPDATE agent_enrollments
        SET bootstrap_token_hash = NULL
        WHERE bootstrap_token_hash = $1
          AND is_used = FALSE
          AND expires_at > $2
        RETURNING \(agentEnrollmentColumns)
        """
    let tokenHash: String
    let now: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(tokenHash)
        bindings.append(now)
        return bindings
    }
}

private struct AgentIsRegistered: PostgresPreparedStatement {
    static let sql = """
        SELECT EXISTS (
            SELECT 1 FROM agents WHERE trust_domain = $1 AND name = $2
        )
        """
    typealias Row = Bool
    let trustDomain: String
    let agentName: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(trustDomain)
        bindings.append(agentName)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct MarkAgentEnrollmentUsed: PostgresPreparedStatement {
    static let sql = """
        UPDATE agent_enrollments
        SET is_used = TRUE, used_at = $2, bootstrap_token_hash = NULL
        WHERE id = $1 AND is_used = FALSE
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let usedAt: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(usedAt)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteAgentEnrollment: PostgresPreparedStatement {
    static let sql = "DELETE FROM agent_enrollments WHERE id = $1 RETURNING id"
    typealias Row = UUID
    let id: UUID

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DeleteAgentEnrollmentForAgent: PostgresPreparedStatement {
    static let sql = """
        DELETE FROM agent_enrollments
        WHERE trust_domain = $1 AND agent_name = $2
        RETURNING id
        """
    typealias Row = UUID
    let trustDomain: String
    let agentName: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(trustDomain)
        bindings.append(agentName)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct TryAgentEnrollmentOperationLock: PostgresPreparedStatement {
    static let sql = "SELECT pg_try_advisory_lock(hashtext($1))"
    typealias Row = Bool
    let key: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(key)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}

private struct ReleaseAgentEnrollmentOperationLock: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_unlock(hashtext($1))"
    typealias Row = Bool
    let key: String

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(key)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> Bool { try row.decode(Bool.self) }
}
