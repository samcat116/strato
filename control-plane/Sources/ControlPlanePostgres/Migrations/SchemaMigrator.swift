import Foundation
import Logging
import PostgresNIO

/// Applies Strato migrations through one initialized PostgresNIO connection.
public struct SchemaMigrator: Sendable {
    public static let lockName = "strato:schema-migrations"

    public struct Options: Sendable {
        public var runMigrations: Bool
        public var lockTimeout: Duration
        public var lockPollInterval: Duration
        public var servingStatementTimeoutMilliseconds: Int
        public var migrationStatementTimeoutMilliseconds: Int

        public init(
            runMigrations: Bool = true,
            lockTimeout: Duration = .seconds(240),
            lockPollInterval: Duration = .seconds(2),
            servingStatementTimeoutMilliseconds: Int,
            migrationStatementTimeoutMilliseconds: Int
        ) {
            self.runMigrations = runMigrations
            self.lockTimeout = lockTimeout
            self.lockPollInterval = lockPollInterval
            self.servingStatementTimeoutMilliseconds = servingStatementTimeoutMilliseconds
            self.migrationStatementTimeoutMilliseconds = migrationStatementTimeoutMilliseconds
        }
    }

    private let database: PostgresDatabase
    private let migrations: [any StratoMigration]
    private let logger: Logger

    public init(
        database: PostgresDatabase,
        migrations: [any StratoMigration],
        logger: Logger
    ) throws {
        let names = migrations.map(\.name)
        guard Set(names).count == names.count else {
            throw SchemaMigrationError.duplicateMigrationNames(names)
        }
        self.database = database
        self.migrations = migrations
        self.logger = logger
    }

    public func run(options: Options) async throws {
        try await database.withSession(operation: "schema_migrations.run") { session in
            if !options.runMigrations {
                try await setupLedger(on: session)
                let pending = try await pendingMigrations(on: session)
                guard pending.isEmpty else {
                    throw SchemaMigrationError.migrationsPendingButDisabled(
                        names: pending.map(\.name))
                }
                logger.info("[SchemaMigrator] Migrations disabled; schema is up to date")
                return
            }

            try await withStatementTimeouts(options: options, on: session) {
                try await withMigrationLock(options: options, on: session) {
                    try await setupLedger(on: session)
                    let pending = try await pendingMigrations(on: session)
                    guard !pending.isEmpty else {
                        logger.info("[SchemaMigrator] Schema is up to date")
                        return
                    }
                    let batch = try await nextBatchNumber(on: session)
                    try await apply(pending, batch: batch, on: session)
                }
            }
        }
    }

    private func setupLedger(on session: PostgresSession) async throws {
        try await session.command(
            """
            CREATE TABLE IF NOT EXISTS _fluent_migrations (
                id UUID PRIMARY KEY,
                name TEXT NOT NULL,
                batch BIGINT NOT NULL,
                created_at TIMESTAMPTZ,
                updated_at TIMESTAMPTZ,
                CONSTRAINT "uq:_fluent_migrations.name" UNIQUE (name)
            )
            """,
            operation: "schema_migrations.setup_ledger"
        )
    }

    private func pendingMigrations(on session: PostgresSession) async throws -> [any StratoMigration] {
        let rows = try await session.query(
            "SELECT name FROM _fluent_migrations ORDER BY batch, created_at, name",
            operation: "schema_migrations.read_ledger"
        )
        let applied = try Set(rows.map { try $0.decode(String.self) })
        return migrations.filter { !applied.contains($0.name) }
    }

    private func nextBatchNumber(on session: PostgresSession) async throws -> Int {
        let rows = try await session.query(
            "SELECT COALESCE(MAX(batch), 0)::bigint AS batch FROM _fluent_migrations",
            operation: "schema_migrations.next_batch"
        )
        return (try rows.first?.decode(Int.self) ?? 0) + 1
    }

    private func apply(
        _ pending: [any StratoMigration],
        batch: Int,
        on session: PostgresSession
    ) async throws {
        for migration in pending {
            logger.info(
                "[SchemaMigrator] Starting apply",
                metadata: ["migration": .string(migration.name)]
            )
            do {
                switch migration.transactionMode {
                case .required:
                    try await session.withTransaction { transaction in
                        try await migration.apply(on: transaction)
                        try await record(migration: migration, batch: batch, on: transaction)
                    }
                case .untransacted:
                    try await migration.apply(on: session)
                    try await record(migration: migration, batch: batch, on: session)
                }
            } catch {
                logger.error(
                    "[SchemaMigrator] Migration failed",
                    metadata: [
                        "migration": .string(migration.name),
                        "errorType": .string(String(reflecting: type(of: error))),
                        "sqlState": .string(sqlState(of: error) ?? "unknown"),
                    ]
                )
                throw SchemaMigrationError.migrationFailed(
                    name: migration.name,
                    batch: batch,
                    transactional: migration.transactionMode == .required,
                    underlying: error
                )
            }
            logger.info(
                "[SchemaMigrator] Finished apply",
                metadata: ["migration": .string(migration.name)]
            )
        }
    }

    private func record(
        migration: any StratoMigration,
        batch: Int,
        on session: PostgresSession
    ) async throws {
        let id = UUID()
        let name = migration.name
        let rows = try await session.query(
            """
            INSERT INTO _fluent_migrations (id, name, batch, created_at, updated_at)
            VALUES (\(id), \(name), \(batch), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            RETURNING id
            """,
            operation: "schema_migrations.record"
        )
        guard rows.count == 1 else {
            throw SchemaMigrationError.ledgerInsertReturnedUnexpectedRows(rows.count)
        }
    }

    private func withStatementTimeouts(
        options: Options,
        on session: PostgresSession,
        body: () async throws -> Void
    ) async throws {
        try await setStatementTimeout(
            options.migrationStatementTimeoutMilliseconds,
            on: session,
            operation: "schema_migrations.set_migration_timeout"
        )

        var primary: (any Error)?
        do {
            try await body()
        } catch {
            primary = error
        }

        do {
            try await setStatementTimeout(
                options.servingStatementTimeoutMilliseconds,
                on: session,
                operation: "schema_migrations.restore_serving_timeout"
            )
        } catch {
            if let primary {
                throw SchemaMigrationCleanupFailure(primary: primary, cleanup: error)
            }
            throw error
        }
        if let primary { throw primary }
    }

    private func setStatementTimeout(
        _ milliseconds: Int,
        on session: PostgresSession,
        operation: PostgresOperation
    ) async throws {
        let value = String(milliseconds)
        let rows = try await session.query(
            "SELECT set_config('statement_timeout', \(value), false)",
            operation: operation
        )
        guard rows.count == 1 else {
            throw SchemaMigrationError.timeoutConfigurationReturnedUnexpectedRows(rows.count)
        }
    }

    private func withMigrationLock(
        options: Options,
        on session: PostgresSession,
        body: () async throws -> Void
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: options.lockTimeout)
        while true {
            let rows = try await session.query(
                "SELECT pg_try_advisory_lock(hashtext(\(Self.lockName))) AS acquired",
                operation: "schema_migrations.acquire_lock"
            )
            if try rows.first?.decode(Bool.self) == true { break }
            guard clock.now < deadline else {
                throw SchemaMigrationError.lockTimeout(
                    lockName: Self.lockName,
                    timeout: options.lockTimeout
                )
            }
            try await Task.sleep(for: options.lockPollInterval)
        }

        var primary: (any Error)?
        do {
            try await body()
        } catch {
            primary = error
        }
        do {
            let rows = try await session.query(
                "SELECT pg_advisory_unlock(hashtext(\(Self.lockName))) AS released",
                operation: "schema_migrations.release_lock"
            )
            guard try rows.first?.decode(Bool.self) == true else {
                throw SchemaMigrationError.lockWasNotHeld(lockName: Self.lockName)
            }
        } catch {
            if let primary {
                throw SchemaMigrationCleanupFailure(primary: primary, cleanup: error)
            }
            throw error
        }
        if let primary { throw primary }
    }

    private func sqlState(of error: any Error) -> String? {
        if let error = error as? PSQLError {
            return error.serverInfo?[.sqlState]
        }
        if let error = error as? PostgresTransactionFailure {
            return sqlState(of: error.primary)
        }
        return nil
    }
}

public struct SchemaMigrationCleanupFailure: Error, Sendable {
    public let primary: any Error
    public let cleanup: any Error
}

public enum SchemaMigrationError: Error, CustomStringConvertible, Sendable {
    case duplicateMigrationNames([String])
    case migrationsPendingButDisabled(names: [String])
    case lockTimeout(lockName: String, timeout: Duration)
    case lockWasNotHeld(lockName: String)
    case ledgerInsertReturnedUnexpectedRows(Int)
    case timeoutConfigurationReturnedUnexpectedRows(Int)
    case migrationFailed(
        name: String,
        batch: Int,
        transactional: Bool,
        underlying: any Error
    )

    public var description: String {
        switch self {
        case .duplicateMigrationNames(let names):
            "Migration names must be unique and explicit; received duplicates in \(names)"
        case .migrationsPendingButDisabled(let names):
            "STRATO_RUN_MIGRATIONS is false, but migrations are pending: \(names.joined(separator: ", "))"
        case .lockTimeout(let name, let timeout):
            "Timed out after \(timeout) waiting for schema migration lock '\(name)'"
        case .lockWasNotHeld(let name):
            "Schema migration lock '\(name)' was not held when release was attempted"
        case .ledgerInsertReturnedUnexpectedRows(let count):
            "Migration ledger insert returned \(count) rows instead of one"
        case .timeoutConfigurationReturnedUnexpectedRows(let count):
            "Statement-timeout configuration returned \(count) rows instead of one"
        case .migrationFailed(let name, let batch, let transactional, let underlying):
            "Migration '\(name)' failed in batch \(batch) (transactional: \(transactional), error type: \(String(reflecting: type(of: underlying)))): \(String(describing: underlying))"
        }
    }
}
