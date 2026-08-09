import Fluent
import FluentPostgresDriver
import Foundation
import Logging
import PostgresNIO
import SQLKit
import Vapor

/// Runs the schema migration phase of `configure()`.
///
/// This replaces `app.autoMigrate()`, which is unsafe for a deployment that
/// runs more than one control-plane replica (STR-183). Fluent's migrator
/// (fluent-kit's `DatabaseMigrator`) takes no lock, elects no leader, and wraps
/// no transaction around a migration and the `_fluent_migrations` row that
/// records it — literally `migration.prepare(on:).flatMap { MigrationLog(...).save(on:) }`.
/// Two failures follow from that, and the schema is the one piece of state where
/// "fail open, converge later" is not available as a fallback:
///
///  1. **Concurrent boots run the same migration.** Every pod of a `helm upgrade`
///     reads the same unapplied list and executes it; the losers get
///     `relation "…" already exists` and the process exits.
///  2. **A crash between the DDL and the log row is unrecoverable.** The schema
///     change commits, the log insert never runs, and every subsequent boot
///     recomputes the migration as unapplied, re-runs it, and fails the same way.
///     There is no retry that gets past it — the deployment is down until
///     someone hand-writes an `INSERT INTO _fluent_migrations`.
///
/// Two properties fix that, and both come from doing the whole phase on **one
/// pinned connection**:
///
///  - **Serialization.** A session-scoped `pg_advisory_lock` is held for the
///    duration. It cannot be `pg_advisory_xact_lock` (the idiom
///    `IPAMService.lockAllocations` and `QuotaEnforcementService.lockQuotas`
///    use): the phase is many transactions, so an xact-scoped lock would
///    release at the first statement boundary. A session-scoped lock lives on
///    its connection, which is why the connection has to be pinned.
///  - **Atomicity.** Each migration's `prepare` and its `MigrationLog` row commit
///    in one transaction, so a crash leaves a state the next boot can either
///    re-run cleanly or skip — never the half-state of failure 2.
///
/// Pinning also keeps the connection budget at **one**. A migrator that drew its
/// own connections while the lock sat on a pinned one would need a pool of at
/// least 2 *per event loop*, and Vapor's Postgres pool defaults to exactly 1 —
/// so that shape can deadlock against itself. Everything here rides the single
/// pinned connection instead, and nothing has to be assumed about pool sizing.
///
/// The read-only halves of Fluent's migrator are still Fluent's: `Migrator` is
/// public and takes a `databaseFactory`, so it is pointed at the pinned
/// connection for `setupIfNeeded()` (whose `CREATE TABLE` is already
/// `IF NOT EXISTS` and whose unstable-migration-name check is worth keeping) and
/// `previewPrepareBatch()` (the unapplied list, read *under the lock*, so it
/// cannot be stale). Only `prepareBatch()` — the part with no atomicity — is
/// replaced.
enum SchemaMigrator {

    /// The advisory lock every control-plane process takes before touching the
    /// schema. Hashed with `hashtext` at the call site, matching the string-keyed
    /// idiom the IPAM and quota locks use.
    static let lockName = "strato:schema-migrations"

    /// Whether this process migrates at all. Defaults to true, so compose,
    /// local development and the test harness are untouched; a deployment that
    /// gates migrations behind a separate job (a Helm `pre-upgrade` hook) sets it
    /// to false on the serving replicas.
    static let runMigrationsKey = "STRATO_RUN_MIGRATIONS"

    /// How long to wait for the lock before giving up. A losing replica *should*
    /// wait — it acquires the lock once the winner commits, finds nothing
    /// unapplied and proceeds — but it must not wait forever behind a wedged
    /// migration with the readiness gate shut and no explanation.
    static let lockTimeoutKey = "STRATO_MIGRATION_LOCK_TIMEOUT_SECONDS"
    static let lockPollKey = "STRATO_MIGRATION_LOCK_POLL_SECONDS"

    /// Kept one minute inside the Helm chart's five-minute startup-probe
    /// budget, so the named timeout reaches the logs before kubelet restarts the
    /// process. Keep this coupled to `startupProbe` in the chart values.
    private static let defaultLockTimeout: Double = 240
    private static let defaultLockPoll: Double = 2

    /// Resolved once at the call site rather than read from the environment
    /// where each value is used, so tests can drive every path without mutating
    /// the process environment out from under a parallel suite.
    struct Options: Sendable {
        var runMigrations: Bool = true
        var lockTimeout: Double = SchemaMigrator.defaultLockTimeout
        var lockPoll: Double = SchemaMigrator.defaultLockPoll

        static func fromEnvironment() -> Options {
            Options(
                runMigrations: Environment.get(runMigrationsKey).flatMap(Bool.init) ?? true,
                lockTimeout: Environment.get(lockTimeoutKey).flatMap(Double.init) ?? defaultLockTimeout,
                lockPoll: Environment.get(lockPollKey).flatMap(Double.init) ?? defaultLockPoll
            )
        }
    }

    // MARK: - Entry point

    /// Applies every unapplied migration, or verifies that none are outstanding
    /// when this process is not the one that migrates.
    static func run(on app: Application, options: Options = .fromEnvironment()) async throws {
        let logger = app.logger
        let migrations = app.migrations

        logger.info(
            "[SchemaMigrator] Resolved migration options",
            metadata: [
                "runMigrations": .stringConvertible(options.runMigrations),
                "lockTimeoutSeconds": .stringConvertible(options.lockTimeout),
                "lockPollSeconds": .stringConvertible(options.lockPoll),
            ]
        )

        try await app.db.withConnection { connection in
            let migrator = Migrator(
                databaseFactory: { _ in connection },
                migrations: migrations,
                on: connection.eventLoop
            )

            guard options.runMigrations else {
                try await verifyNothingPending(migrator: migrator, logger: logger)
                return
            }

            let lock = try await acquireLock(
                on: connection,
                timeout: options.lockTimeout,
                poll: options.lockPoll,
                logger: logger
            )

            try await whileHolding(lock, logger: logger) {
                // Under the lock: create `_fluent_migrations` if it is missing,
                // then read the unapplied list. Both have to happen here rather
                // than before the lock — a list read outside it is exactly the
                // stale read every replica acts on today.
                try await migrator.setupIfNeeded().get()
                let pending = try await migrator.previewPrepareBatch().get().map(\.0)
                if pending.isEmpty {
                    logger.info("[SchemaMigrator] Schema is up to date")
                } else {
                    let batch = try await nextBatchNumber(on: connection)
                    logger.info(
                        "[SchemaMigrator] Applying \(pending.count) migration(s)",
                        metadata: ["batch": .stringConvertible(batch)]
                    )
                    try await applyBatch(pending, batch: batch, on: connection, logger: logger)
                }
            }
        }
    }

    /// The `STRATO_RUN_MIGRATIONS=false` path: this process does not migrate, so
    /// the most useful thing it can do is refuse to serve against a schema it
    /// does not expect. Whoever turned migrations off owns running the gate that
    /// replaces them; a pod that boots anyway would fail later, further from the
    /// cause.
    ///
    /// `setupIfNeeded()` still runs, because `previewPrepareBatch()` cannot read a
    /// log table that does not exist yet. Its DDL is `IF NOT EXISTS`, so on a
    /// database that has ever been migrated this writes nothing.
    static func verifyNothingPending(migrator: Migrator, logger: Logger) async throws {
        try await migrator.setupIfNeeded().get()
        let pending = try await migrator.previewPrepareBatch().get().map(\.0.name)
        guard pending.isEmpty else {
            let error = SchemaMigrationError.migrationsPendingButDisabled(names: pending)
            logger.critical("\(error.description)")
            throw error
        }
        logger.info(
            "[SchemaMigrator] Migrations disabled for this process; schema is up to date",
            metadata: ["setting": .string(runMigrationsKey)]
        )
    }

    // MARK: - Applying a batch

    /// Applies `migrations` in order, each one atomic with the row that records
    /// it. `internal` so tests can drive a batch without doctoring
    /// `app.migrations`.
    static func applyBatch(
        _ migrations: [any Migration],
        batch: Int,
        on connection: any Database,
        logger: Logger
    ) async throws {
        // `connection.transaction { … }` would be a **silent no-op** here.
        // fluent-postgres-driver's `withConnection` hands back a database marked
        // `inTransaction: true` — the flag really means "pinned to one
        // connection" — and `transaction(_:)` short-circuits on it without ever
        // issuing a `BEGIN`. `TransactionControlDatabase` is the public API for
        // exactly this case, and it is what actually opens the transaction.
        guard let control = connection as? any TransactionControlDatabase else {
            let error = SchemaMigrationError.transactionControlUnavailable
            logger.critical("\(error.description)")
            throw error
        }

        for migration in migrations {
            logger.info("[SchemaMigrator] Starting prepare", metadata: ["migration": .string(migration.name)])
            let transactional = !(migration is any UntransactedMigration)
            do {
                // The opt-out: DDL first, row second, with the crash window
                // back between them. See `UntransactedMigration`.
                if transactional {
                    try await control.beginTransaction().get()
                    do {
                        try await migration.prepare(on: connection).get()
                        try await MigrationLog(name: migration.name, batch: batch).save(on: connection)
                        try await control.commitTransaction().get()
                    } catch {
                        try? await control.rollbackTransaction().get()
                        throw error
                    }
                } else {
                    try await migration.prepare(on: connection).get()
                    try await MigrationLog(name: migration.name, batch: batch).save(on: connection)
                }
            } catch {
                let wrapped = SchemaMigrationError.migrationFailed(
                    name: migration.name,
                    batch: batch,
                    transactional: transactional,
                    underlying: error
                )
                logger.error(
                    "[SchemaMigrator] Failed prepare",
                    metadata: [
                        "migration": .string(migration.name),
                        "error": .string(String(reflecting: error)),
                    ]
                )
                throw wrapped
            }
            logger.info("[SchemaMigrator] Finished prepare", metadata: ["migration": .string(migration.name)])
        }
    }

    /// The batch number a new batch gets, computed the same way fluent-kit's
    /// `DatabaseMigrator.lastBatchNumber()` does.
    static func nextBatchNumber(on connection: any Database) async throws -> Int {
        let last = try await MigrationLog.query(on: connection).sort(\.$batch, .descending).first()?.batch ?? 0
        return last + 1
    }

    // MARK: - The advisory lock

    /// A held advisory lock.
    struct LockHandle {
        let release: @Sendable () async throws -> Void
    }

    /// Runs `body`, then releases `lock` exactly once on either outcome. When
    /// both fail, the migration error stays primary and the cleanup failure is
    /// logged alongside it.
    private static func whileHolding(
        _ lock: LockHandle,
        logger: Logger,
        body: () async throws -> Void
    ) async throws {
        var bodyError: (any Error)?
        do {
            try await body()
        } catch {
            bodyError = error
        }

        do {
            try await lock.release()
        } catch {
            guard let bodyError else { throw error }
            logger.error(
                "[SchemaMigrator] Failed to release the migration lock after the migration phase failed",
                metadata: [
                    "migrationError": .string(String(reflecting: bodyError)),
                    "releaseError": .string(String(reflecting: error)),
                ]
            )
        }

        if let bodyError { throw bodyError }
    }

    /// Takes the migration lock, polling `pg_try_advisory_lock` rather than
    /// blocking in `pg_advisory_lock`, so a wedged migration on another replica
    /// surfaces as a named error instead of a readiness gate that never opens.
    ///
    /// Postgres has been the only supported backend since the SQLite removal.
    /// Fail hard if that contract changes under us: silently skipping the lock
    /// would restore the cross-replica migration race this type exists to stop.
    static func acquireLock(
        on connection: any Database,
        timeout: Double,
        poll: Double,
        logger: Logger
    ) async throws -> LockHandle {
        guard let sql = connection as? any SQLDatabase else {
            let error = SchemaMigrationError.postgresRequired(actualDialect: nil)
            logger.critical("\(error.description)")
            throw error
        }
        guard sql.dialect.name == "postgresql" else {
            let error = SchemaMigrationError.postgresRequired(actualDialect: sql.dialect.name)
            logger.critical("\(error.description)")
            throw error
        }

        let name = lockName
        let started = Date()
        var attempt = 0

        while true {
            attempt += 1
            let acquired =
                try await sql.raw("SELECT pg_try_advisory_lock(hashtext(\(bind: name))) AS acquired")
                .first(decodingColumn: "acquired", as: Bool.self) ?? false
            if acquired {
                if attempt > 1 {
                    logger.notice(
                        "[SchemaMigrator] Acquired the migration lock",
                        metadata: [
                            "lock": .string(name),
                            "waitedSeconds": .stringConvertible(Int(Date().timeIntervalSince(started))),
                        ]
                    )
                }
                return LockHandle(release: {
                    // Must actually run: the connection goes back to the pool
                    // afterwards, and a session-scoped lock rides the session,
                    // not the transaction.
                    _ = try await sql.raw("SELECT pg_advisory_unlock(hashtext(\(bind: name)))").all()
                })
            }

            let elapsed = Date().timeIntervalSince(started)
            guard elapsed < timeout else {
                throw SchemaMigrationError.lockTimeout(lockName: name, seconds: timeout)
            }
            logger.notice(
                "[SchemaMigrator] Waiting for the migration lock; another replica is migrating",
                metadata: [
                    "lock": .string(name),
                    "attempt": .stringConvertible(attempt),
                    "elapsedSeconds": .stringConvertible(Int(elapsed)),
                    "timeoutSeconds": .stringConvertible(Int(timeout)),
                ]
            )
            try await Task.sleep(for: .seconds(poll))
        }
    }
}

// MARK: - Opting out of the transaction

/// A migration that must run *outside* a transaction.
///
/// The one real case is `CREATE INDEX CONCURRENTLY`, which Postgres forbids
/// inside a transaction block. No production migration conforms today —
/// `AddHotPathIndexes` deliberately uses plain creates — but the escape hatch
/// exists before a table gets large enough to need one, because discovering it
/// is missing while writing that migration is the wrong time.
///
/// **Opting out gives up the atomicity this migrator exists for.** A crash
/// between the DDL and the `_fluent_migrations` row is the unrecoverable
/// half-state again (STR-183 failure mode 2), so an untransacted migration must
/// be written to be re-runnable — `CREATE INDEX CONCURRENTLY IF NOT EXISTS`,
/// `DROP … IF EXISTS`, and no read-then-write over live rows.
protocol UntransactedMigration {}

// MARK: - Errors

enum SchemaMigrationError: Error, CustomStringConvertible {
    /// The lock is held by another process past the deadline.
    case lockTimeout(lockName: String, seconds: Double)

    /// The configured database cannot provide Postgres advisory locks.
    case postgresRequired(actualDialect: String?)

    /// The driver cannot open explicit transactions on a pinned connection.
    case transactionControlUnavailable

    /// A migration's `prepare` (or its log row) failed. `transactional` records
    /// whether the migrator attempted to roll the schema change and log row
    /// back together; an opted-out migration may have left changes behind.
    case migrationFailed(name: String, batch: Int, transactional: Bool, underlying: any Error)

    /// This process does not migrate, and the schema is behind the binary.
    case migrationsPendingButDisabled(names: [String])

    var description: String {
        switch self {
        case .lockTimeout(let lockName, let seconds):
            return """
                Timed out after \(Int(seconds))s waiting for the schema migration advisory lock \
                '\(lockName)'. Another control-plane process is holding it — either a migration is \
                still running, or one is wedged. Check the other replicas' logs before raising \
                \(SchemaMigrator.lockTimeoutKey).
                """

        case .postgresRequired(let actualDialect):
            let actual = actualDialect.map { "'\($0)'" } ?? "a non-SQL database"
            return """
                Schema migrations require PostgreSQL, but the configured database reports \(actual). \
                Refusing to run without the Postgres advisory lock that serializes replicas.
                """

        case .transactionControlUnavailable:
            return """
                The database driver does not expose TransactionControlDatabase on its pinned \
                connection. Refusing to run migrations without atomic schema changes and migration \
                log rows.
                """

        case .migrationFailed(let name, let batch, let transactional, let underlying):
            var message = "Migration '\(name)' failed: \(String(reflecting: underlying))"
            if transactional {
                message += """
                    \n\nThe migration was run transactionally, and the migrator requested a rollback \
                    before reporting this error.
                    """
            } else {
                message += """
                    \n\nThis migration opted out of transactions. Its schema changes may already be \
                    present even though no migration log row was written; inspect the schema before retrying.
                    """
            }
            if isDuplicateObject(underlying) {
                let provenance =
                    transactional
                    ? "The row was either lost by an older build crashing mid-migration or removed by hand"
                    : "An earlier untransacted attempt may have changed the schema before it failed to write the row"
                message += """
                    \n\nThe objects this migration creates already exist, but no '\(name)' row is in \
                    _fluent_migrations — the schema and the migration log disagree. \(provenance). To recover, confirm \
                    the schema change is fully present, then record it: \
                    INSERT INTO _fluent_migrations (id, name, batch, created_at, updated_at) \
                    VALUES (gen_random_uuid(), '\(name)', \(batch), now(), now());
                    """
            }
            return message

        case .migrationsPendingButDisabled(let names):
            return """
                \(SchemaMigrator.runMigrationsKey) is false, so this process does not migrate, but \
                \(names.count) migration(s) are unapplied: \(names.joined(separator: ", ")). Refusing \
                to serve against a schema this build does not expect — run the migration job for this \
                release first, or unset \(SchemaMigrator.runMigrationsKey).
                """
        }
    }

    /// Whether `error` is Postgres complaining that something already exists.
    /// Read off the SQLSTATE where one is available, with a text fallback for
    /// errors the driver has wrapped past recognition.
    private func isDuplicateObject(_ error: any Error) -> Bool {
        // 42P07 duplicate_table, 42701 duplicate_column, 42710 duplicate_object,
        // 42P06 duplicate_schema.
        let duplicateStates: Set<String> = ["42P07", "42701", "42710", "42P06"]
        if let psql = error as? PSQLError, let state = psql.serverInfo?[.sqlState] {
            return duplicateStates.contains(state)
        }
        return String(reflecting: error).contains("already exists")
    }
}
