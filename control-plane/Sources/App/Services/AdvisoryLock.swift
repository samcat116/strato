import Crypto
import Fluent
import Foundation
import Logging
import Metrics
import SQLKit

/// Every PostgreSQL advisory-lock namespace the control plane owns, in global
/// acquisition order. A transaction may acquire the same key again, or move
/// forward through this declaration, but must never move backwards: that is
/// the edge which can close a deadlock cycle with another transaction.
///
/// The raw value is PostgreSQL's first `int4` advisory-lock key (`classid` in
/// `pg_locks`). Keep values stable once shipped so dashboards and operator
/// queries continue to name the same subsystem.
enum AdvisoryLockNamespace: Int32, CaseIterable, Sendable {
    case schemaMigration = 1
    case userRegistration = 2
    case projectNetwork = 3
    // Fork admission and snapshot export take lineage before reserving quota.
    case sandboxSnapshotLineage = 4
    case quota = 5
    case ipam = 6
    case floatingIPPool = 7
    case resolverIndex = 8
    case dnsZone = 9
    case volumeAttachment = 10
    case securityGroupMembership = 11
    case agentEnrollment = 12

    /// Stable, bounded label used in logs, metrics, and operator tooling.
    var name: String {
        switch self {
        case .schemaMigration: "schema_migration"
        case .userRegistration: "user_registration"
        case .projectNetwork: "project_network"
        case .sandboxSnapshotLineage: "sandbox_snapshot_lineage"
        case .quota: "quota"
        case .ipam: "ipam"
        case .floatingIPPool: "floating_ip_pool"
        case .resolverIndex: "resolver_index"
        case .dnsZone: "dns_zone"
        case .volumeAttachment: "volume_attachment"
        case .securityGroupMembership: "security_group_membership"
        case .agentEnrollment: "agent_enrollment"
        }
    }
}

/// A typed key in PostgreSQL's documented two-`int4` advisory-lock space.
///
/// UUID keys use the first four SHA-256 bytes, interpreted as a big-endian
/// signed `Int32`. Singleton namespaces use zero. The original UUID is retained
/// only for diagnostics; it never becomes a metric dimension.
struct AdvisoryLockKey: Hashable, Sendable {
    let namespace: AdvisoryLockNamespace
    let objectDigest: Int32
    let objectID: UUID?

    static func object(_ namespace: AdvisoryLockNamespace, id: UUID) -> Self {
        Self(namespace: namespace, objectDigest: digest(id), objectID: id)
    }

    static func singleton(_ namespace: AdvisoryLockNamespace) -> Self {
        Self(namespace: namespace, objectDigest: 0, objectID: nil)
    }

    /// Internal seam for collision/isolation tests. Production callers create
    /// keys from UUIDs or `singleton(_:)` instead of supplying a digest.
    static func digest(_ namespace: AdvisoryLockNamespace, _ objectDigest: Int32) -> Self {
        Self(namespace: namespace, objectDigest: objectDigest, objectID: nil)
    }

    static func digest(_ id: UUID) -> Int32 {
        let uuid = id.uuid
        let bytes: [UInt8] = [
            uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11, uuid.12, uuid.13, uuid.14, uuid.15,
        ]
        let hash = SHA256.hash(data: Data(bytes))
        let unsigned = hash.prefix(4).reduce(UInt32.zero) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        return Int32(bitPattern: unsigned)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.namespace == rhs.namespace && lhs.objectDigest == rhs.objectDigest
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(namespace)
        hasher.combine(objectDigest)
    }
}

extension AdvisoryLockKey: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.namespace.rawValue != rhs.namespace.rawValue {
            return lhs.namespace.rawValue < rhs.namespace.rawValue
        }
        return UInt32(bitPattern: lhs.objectDigest) < UInt32(bitPattern: rhs.objectDigest)
    }
}

enum AdvisoryLockError: Error, CustomStringConvertible {
    case postgresRequired(actualDialect: String?)
    case transactionRequired(key: AdvisoryLockKey)
    case acquisitionTimedOut(key: AdvisoryLockKey, seconds: Double)
    case releaseFailed(key: AdvisoryLockKey, reason: String)

    var description: String {
        switch self {
        case .postgresRequired(let actualDialect):
            let actual = actualDialect.map { "'\($0)'" } ?? "a non-SQL database"
            return "PostgreSQL advisory locks require PostgreSQL, but the database reports \(actual)"
        case .transactionRequired(let key):
            return "The \(key.namespace.name) transaction advisory lock must be acquired inside a database transaction"
        case .acquisitionTimedOut(let key, let seconds):
            return "Timed out after \(seconds)s waiting for the \(key.namespace.name) advisory lock"
        case .releaseFailed(let key, let reason):
            return "Failed to release the \(key.namespace.name) advisory lock (digest \(key.objectDigest)): \(reason)"
        }
    }
}

/// The only module that emits PostgreSQL advisory-lock SQL.
///
/// Its interface centralizes the documented two-`int4` key space, stable
/// hashing, global acquisition order, wait telemetry, bounded session-lock
/// polling, and release diagnostics. Transaction locks remain owned by the
/// surrounding database transaction; session locks pin one connection until
/// the body finishes and the checked unlock runs.
enum AdvisoryLock {
    private enum SessionAttempt<Value: Sendable>: Sendable {
        case busy
        case completed(Value)
    }

    private struct HeldLockRow: Decodable {
        let namespace: Int64
        let object_digest: Int64
    }

    /// Acquire one transaction-scoped lock. PostgreSQL is required: silently
    /// skipping a correctness lock on another dialect would make the caller's
    /// invariant configuration-dependent.
    static func acquireTransactionLock(
        _ key: AdvisoryLockKey,
        on db: any Database,
        metricsFactory: (any MetricsFactory)? = nil
    ) async throws {
        guard db.inTransaction else {
            throw AdvisoryLockError.transactionRequired(key: key)
        }
        let sql = try postgresDatabase(db)

        #if DEBUG
        try await assertAcquisitionOrder(for: key, on: sql)
        #endif

        let clock = ContinuousClock()
        let started = clock.now
        try await sql.raw(
            "SELECT pg_advisory_xact_lock(\(bind: key.namespace.rawValue)::int4, \(bind: key.objectDigest)::int4)"
        ).run()
        Telemetry.advisoryLockAcquired(
            namespace: key.namespace,
            waitSeconds: started.duration(to: clock.now).seconds,
            factory: metricsFactory)
    }

    /// Acquire a same-namespace set in one deterministic order. Digest
    /// collisions are de-duplicated because they already name the same
    /// PostgreSQL lock.
    static func acquireTransactionLocks(
        _ namespace: AdvisoryLockNamespace,
        objectIDs: some Sequence<UUID>,
        on db: any Database,
        metricsFactory: (any MetricsFactory)? = nil
    ) async throws {
        let keys = Set(objectIDs.map { AdvisoryLockKey.object(namespace, id: $0) }).sorted()
        for key in keys {
            try await acquireTransactionLock(key, on: db, metricsFactory: metricsFactory)
        }
    }

    /// Run `operation` while holding one session-scoped lock on a pinned
    /// PostgreSQL connection. Busy attempts return their connection to the
    /// pool before sleeping. Acquisition stops at the monotonic deadline.
    static func withSessionLock<Value: Sendable>(
        _ key: AdvisoryLockKey,
        on db: any Database,
        timeout: Duration,
        pollInterval: Duration,
        logger: Logger,
        metricsFactory: (any MetricsFactory)? = nil,
        operation: @escaping @Sendable (any Database) async throws -> Value
    ) async throws -> Value {
        let clock = ContinuousClock()
        let started = clock.now
        let deadline = started.advanced(by: timeout)

        while true {
            let attempt: SessionAttempt<Value> = try await db.withConnection { connection in
                let sql = try postgresDatabase(connection)
                let attemptStarted = clock.now
                guard attemptStarted < deadline else {
                    throw AdvisoryLockError.acquisitionTimedOut(
                        key: key, seconds: started.duration(to: attemptStarted).seconds)
                }

                #if DEBUG
                try await assertAcquisitionOrder(for: key, on: sql)
                #endif

                let acquired =
                    try await sql.raw(
                        "SELECT pg_try_advisory_lock(\(bind: key.namespace.rawValue)::int4, \(bind: key.objectDigest)::int4) AS acquired"
                    ).first(decodingColumn: "acquired", as: Bool.self) ?? false
                guard acquired else { return .busy }

                Telemetry.advisoryLockAcquired(
                    namespace: key.namespace,
                    waitSeconds: started.duration(to: clock.now).seconds,
                    factory: metricsFactory)

                var operationValue: Value?
                var operationError: (any Error)?
                do {
                    operationValue = try await operation(connection)
                } catch {
                    operationError = error
                }

                let releaseError = await releaseSessionLock(key, on: sql)
                if let releaseError {
                    logger.critical(
                        "Failed to release a PostgreSQL advisory session lock",
                        metadata: releaseFailureMetadata(key: key, error: releaseError))
                    Telemetry.advisoryLockReleaseFailed(
                        namespace: key.namespace, factory: metricsFactory)
                }

                if let operationError { throw operationError }
                if let releaseError { throw releaseError }
                return .completed(operationValue!)
            }

            switch attempt {
            case .completed(let value):
                return value
            case .busy:
                let now = clock.now
                guard now < deadline else {
                    throw AdvisoryLockError.acquisitionTimedOut(
                        key: key, seconds: started.duration(to: now).seconds)
                }
                try await Task.sleep(for: min(pollInterval, now.duration(to: deadline)))
            }
        }
    }

    /// Test seam used to simulate a cleanup reporting `false`. Production
    /// release always flows through `withSessionLock`.
    static func releaseSessionLockForTesting(
        _ key: AdvisoryLockKey,
        on db: any Database
    ) async throws -> Bool {
        let sql = try postgresDatabase(db)
        return try await unlock(key, on: sql)
    }

    /// Pure half of the debug assertion, exposed to unit tests so the process
    /// need not crash to prove the ordering rule.
    static func acquisitionOrderViolation(
        held: some Sequence<AdvisoryLockKey>,
        acquiring key: AdvisoryLockKey
    ) -> String? {
        let held = Array(held)
        if held.contains(key) { return nil }  // Re-entrant acquisition cannot wait.
        guard let latest = held.max(), latest > key else { return nil }
        return "Advisory lock order violation: attempted \(key.namespace.name)/\(key.objectDigest) "
            + "while holding \(latest.namespace.name)/\(latest.objectDigest)"
    }

    private static func postgresDatabase(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw AdvisoryLockError.postgresRequired(actualDialect: nil)
        }
        guard sql.dialect.name == "postgresql" else {
            throw AdvisoryLockError.postgresRequired(actualDialect: sql.dialect.name)
        }
        return sql
    }

    #if DEBUG
    /// Use PostgreSQL itself as the debug/test lock ledger. That follows the
    /// pinned transaction connection across async task boundaries and also
    /// catches any lock a future caller takes before entering this helper.
    private static func assertAcquisitionOrder(
        for key: AdvisoryLockKey,
        on sql: any SQLDatabase
    ) async throws {
        let rows = try await sql.raw(
            """
            SELECT classid::bigint AS namespace,
                   CASE WHEN objid::bigint > 2147483647
                        THEN objid::bigint - 4294967296
                        ELSE objid::bigint
                   END AS object_digest
            FROM pg_locks
            WHERE locktype = 'advisory'
              AND pid = pg_backend_pid()
              AND granted
              AND objsubid = 2
            """
        ).all(decoding: HeldLockRow.self)
        let held = rows.compactMap { row -> AdvisoryLockKey? in
            guard let namespace = Int32(exactly: row.namespace).flatMap(AdvisoryLockNamespace.init(rawValue:)),
                let digest = Int32(exactly: row.object_digest)
            else { return nil }
            return .digest(namespace, digest)
        }
        if let violation = acquisitionOrderViolation(held: held, acquiring: key) {
            assertionFailure(violation)
        }
    }
    #endif

    private static func releaseSessionLock(
        _ key: AdvisoryLockKey,
        on sql: any SQLDatabase
    ) async -> AdvisoryLockError? {
        do {
            guard try await unlock(key, on: sql) else {
                return .releaseFailed(key: key, reason: "PostgreSQL reported that this session did not hold the lock")
            }
            return nil
        } catch let error as AdvisoryLockError {
            return error
        } catch {
            return .releaseFailed(key: key, reason: String(reflecting: error))
        }
    }

    private static func unlock(
        _ key: AdvisoryLockKey,
        on sql: any SQLDatabase
    ) async throws -> Bool {
        try await sql.raw(
            "SELECT pg_advisory_unlock(\(bind: key.namespace.rawValue)::int4, \(bind: key.objectDigest)::int4) AS released"
        ).first(decodingColumn: "released", as: Bool.self) ?? false
    }

    private static func releaseFailureMetadata(
        key: AdvisoryLockKey,
        error: AdvisoryLockError
    ) -> Logger.Metadata {
        [
            "namespace": .string(key.namespace.name),
            "objectId": .string(key.objectID?.uuidString.lowercased() ?? "singleton"),
            "objectDigest": .stringConvertible(key.objectDigest),
            "error": .string(error.description),
        ]
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
