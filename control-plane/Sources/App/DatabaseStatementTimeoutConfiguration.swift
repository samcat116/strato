import Fluent
import FluentPostgresDriver
import Foundation
import Logging
@preconcurrency import NIOCore
import PostgresNIO
@preconcurrency import SQLKit
import Vapor

/// A server-enforced upper bound for statements issued through control-plane
/// PostgreSQL connections.
struct DatabaseStatementTimeout: Equatable, Sendable {
    static let environmentKey = "DATABASE_STATEMENT_TIMEOUT_MS"
    static let migrationEnvironmentKey = "DATABASE_MIGRATION_STATEMENT_TIMEOUT_MS"
    static let defaultMilliseconds = 300_000
    static let maximumMilliseconds = Int(Int32.max)

    let milliseconds: Int

    init(milliseconds: Int) throws {
        try self.init(milliseconds: milliseconds, environmentKey: Self.environmentKey)
    }

    private init(milliseconds: Int, environmentKey: String) throws {
        guard (1...Self.maximumMilliseconds).contains(milliseconds) else {
            throw DatabaseStatementTimeoutConfigurationError.invalidValue(
                environmentKey: environmentKey,
                raw: String(milliseconds)
            )
        }
        self.milliseconds = milliseconds
    }

    static func fromEnvironment() throws -> DatabaseStatementTimeout {
        try resolve(Environment.get(environmentKey))
    }

    static func migrationFromEnvironment(
        defaultingTo normalTimeout: DatabaseStatementTimeout
    ) throws -> DatabaseStatementTimeout {
        try resolve(
            Environment.get(migrationEnvironmentKey),
            environmentKey: migrationEnvironmentKey,
            defaultMilliseconds: normalTimeout.milliseconds
        )
    }

    /// Resolve an explicit environment value, or the documented five-minute
    /// default when it is absent. Split out so tests do not mutate the process
    /// environment while other suites read it concurrently.
    static func resolve(_ raw: String?) throws -> DatabaseStatementTimeout {
        try resolve(
            raw,
            environmentKey: environmentKey,
            defaultMilliseconds: defaultMilliseconds
        )
    }

    static func resolveMigration(
        _ raw: String?,
        defaultingTo normalTimeout: DatabaseStatementTimeout
    ) throws -> DatabaseStatementTimeout {
        try resolve(
            raw,
            environmentKey: migrationEnvironmentKey,
            defaultMilliseconds: normalTimeout.milliseconds
        )
    }

    private static func resolve(
        _ raw: String?,
        environmentKey: String,
        defaultMilliseconds: Int
    ) throws -> DatabaseStatementTimeout {
        guard let raw else {
            return try DatabaseStatementTimeout(
                milliseconds: defaultMilliseconds,
                environmentKey: environmentKey
            )
        }
        guard let milliseconds = Int(raw), (1...maximumMilliseconds).contains(milliseconds) else {
            throw DatabaseStatementTimeoutConfigurationError.invalidValue(
                environmentKey: environmentKey,
                raw: raw
            )
        }
        return try DatabaseStatementTimeout(
            milliseconds: milliseconds,
            environmentKey: environmentKey
        )
    }

    /// Wrap a PostgreSQL Fluent configuration so each physical connection is
    /// initialized with SQL after authentication. PgBouncer rejects unknown
    /// startup-packet parameters by default, whereas a session-level
    /// `set_config` is ordinary PostgreSQL traffic and survives for the life of
    /// a directly connected or session-pooled connection.
    func applying(to base: DatabaseConfigurationFactory) -> DatabaseConfigurationFactory {
        DatabaseConfigurationFactory {
            StatementTimeoutDatabaseConfiguration(
                base: base.make(),
                timeout: self
            )
        }
    }

    /// Set this budget on an already pinned connection. Schema migration uses
    /// this to raise the budget temporarily and then restore the serving value.
    func apply(on database: any Database) -> EventLoopFuture<Void> {
        guard let sql = database as? any SQLDatabase else {
            return database.eventLoop.makeFailedFuture(
                DatabaseStatementTimeoutConfigurationError.postgresRequired
            )
        }
        return apply(on: sql)
    }

    fileprivate func apply(on database: any SQLDatabase) -> EventLoopFuture<Void> {
        database.raw(
            "SELECT set_config('statement_timeout', \(bind: String(milliseconds)), false)"
        ).run()
    }
}

enum DatabaseStatementTimeoutConfigurationError: Error, CustomStringConvertible {
    case invalidValue(environmentKey: String, raw: String)
    case postgresRequired
    case pinnedConnectionRequired

    var description: String {
        switch self {
        case .invalidValue(let environmentKey, let raw):
            return
                "Invalid \(environmentKey) value \"\(raw)\"; "
                + "expected an integer from 1 through "
                + "\(DatabaseStatementTimeout.maximumMilliseconds) milliseconds"
        case .postgresRequired:
            return "Database statement timeouts require a PostgreSQL SQL connection"
        case .pinnedConnectionRequired:
            return "Transaction control requires a pinned PostgreSQL connection"
        }
    }
}

// MARK: - Fluent connection initialization

/// Decorates Fluent's PostgreSQL driver without copying its internal driver or
/// connection-pool implementation. Every operation first checks out the same
/// connection it will use for the real statement; only the first checkout of a
/// physical connection pays the `set_config` round trip.
private struct StatementTimeoutDatabaseConfiguration: DatabaseConfiguration {
    var middleware: [any AnyModelMiddleware]
    let base: any DatabaseConfiguration
    let timeout: DatabaseStatementTimeout

    init(base: any DatabaseConfiguration, timeout: DatabaseStatementTimeout) {
        self.middleware = base.middleware
        self.base = base
        self.timeout = timeout
    }

    func makeDriver(for databases: Databases) -> any DatabaseDriver {
        StatementTimeoutDatabaseDriver(
            base: base.makeDriver(for: databases),
            initializer: StatementTimeoutConnectionInitializer(timeout: timeout)
        )
    }
}

private struct StatementTimeoutDatabaseDriver: DatabaseDriver {
    let base: any DatabaseDriver
    let initializer: StatementTimeoutConnectionInitializer

    func makeDatabase(with context: DatabaseContext) -> any Database {
        StatementTimeoutDatabase(
            base: base.makeDatabase(with: context),
            initializer: initializer,
            isPinned: false,
            isInTransaction: false
        )
    }

    func shutdown() {
        base.shutdown()
    }

    func shutdownAsync() async {
        await base.shutdownAsync()
    }
}

private final class StatementTimeoutConnectionInitializer: @unchecked Sendable {
    private let timeout: DatabaseStatementTimeout
    private let lock = NSLock()
    private var configuredConnectionIDs: Set<PostgresConnection.ID> = []

    init(timeout: DatabaseStatementTimeout) {
        self.timeout = timeout
    }

    func configure(_ database: any Database) -> EventLoopFuture<Void> {
        guard
            let postgres = database as? any PostgresDatabase,
            let sql = database as? any SQLDatabase
        else {
            return database.eventLoop.makeFailedFuture(
                DatabaseStatementTimeoutConfigurationError.postgresRequired
            )
        }

        return postgres.withConnection { connection in
            if self.isConfigured(connection.id) {
                return connection.eventLoop.makeSucceededFuture(())
            }
            return self.timeout.apply(on: sql).map {
                self.markConfigured(connection.id)
            }
        }
    }

    func configure(_ database: any SQLDatabase) async throws {
        // SQLDatabase.withSession does not promise the PostgresDatabase
        // refinement, so initialize this explicitly. It is an uncommon API and
        // a redundant SET is preferable to an unbounded session.
        try await timeout.apply(on: database).get()
    }

    private func isConfigured(_ id: PostgresConnection.ID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return configuredConnectionIDs.contains(id)
    }

    private func markConfigured(_ id: PostgresConnection.ID) {
        lock.lock()
        defer { lock.unlock() }
        configuredConnectionIDs.insert(id)
    }
}

/// PostgresNIO's legacy request and connection callback protocols predate
/// `Sendable`. They are still confined to the connection's event loop; this box
/// only lets the Fluent wrapper carry them through its newer `@Sendable` API.
private struct StatementTimeoutUncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// Preserves Fluent, SQLKit, and PostgresNIO refinements while ensuring that a
/// checked-out physical connection has its statement budget before application
/// work runs on it.
private struct StatementTimeoutDatabase: Database {
    let base: any Database
    let initializer: StatementTimeoutConnectionInitializer
    let isPinned: Bool
    let isInTransaction: Bool

    var context: DatabaseContext { base.context }
    var inTransaction: Bool { isInTransaction }

    private func withConfiguredConnection<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        if isPinned {
            return closure(base)
        }
        let boxed = base.withConnection { connection in
            initializer.configure(connection).flatMap {
                closure(connection).map {
                    StatementTimeoutUncheckedSendable(value: $0)
                }
            }
        }
        return boxed.map(\.value)
    }

    func execute(
        query: DatabaseQuery,
        onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        withConfiguredConnection { database in
            database.execute(query: query, onOutput: onOutput)
        }
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        withConfiguredConnection { database in
            database.execute(schema: schema)
        }
    }

    func execute(enum databaseEnum: DatabaseEnum) -> EventLoopFuture<Void> {
        withConfiguredConnection { database in
            database.execute(enum: databaseEnum)
        }
    }

    func transaction<T: Sendable>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        guard !isInTransaction else { return closure(self) }

        return withConfiguredConnection { connection in
            guard let control = connection as? any TransactionControlDatabase else {
                return connection.eventLoop.makeFailedFuture(
                    DatabaseStatementTimeoutConfigurationError.pinnedConnectionRequired
                )
            }
            let transactionDatabase = StatementTimeoutDatabase(
                base: connection,
                initializer: initializer,
                isPinned: true,
                isInTransaction: true
            )
            return control.beginTransaction().flatMap {
                closure(transactionDatabase).flatMap { result in
                    control.commitTransaction().map { result }
                }.flatMapError { error in
                    control.rollbackTransaction().flatMapThrowing { throw error }
                }
            }
        }
    }

    func withConnection<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        withConfiguredConnection { connection in
            closure(
                StatementTimeoutDatabase(
                    base: connection,
                    initializer: initializer,
                    isPinned: true,
                    isInTransaction: isInTransaction
                )
            )
        }
    }
}

extension StatementTimeoutDatabase: TransactionControlDatabase {
    func beginTransaction() -> EventLoopFuture<Void> {
        transactionControl { $0.beginTransaction() }
    }

    func commitTransaction() -> EventLoopFuture<Void> {
        transactionControl { $0.commitTransaction() }
    }

    func rollbackTransaction() -> EventLoopFuture<Void> {
        transactionControl { $0.rollbackTransaction() }
    }

    private func transactionControl(
        _ operation: (any TransactionControlDatabase) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        guard isPinned, let control = base as? any TransactionControlDatabase else {
            return eventLoop.makeFailedFuture(
                DatabaseStatementTimeoutConfigurationError.pinnedConnectionRequired
            )
        }
        return operation(control)
    }
}

extension StatementTimeoutDatabase: SQLDatabase {
    var version: (any SQLDatabaseReportedVersion)? { sqlBase.version }
    var dialect: any SQLDialect { sqlBase.dialect }
    var queryLogLevel: Logger.Level? { sqlBase.queryLogLevel }

    private var sqlBase: any SQLDatabase {
        guard let sql = base as? any SQLDatabase else {
            fatalError(DatabaseStatementTimeoutConfigurationError.postgresRequired.description)
        }
        return sql
    }

    func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) -> EventLoopFuture<Void> {
        withConfiguredConnection { database in
            guard let sql = database as? any SQLDatabase else {
                return database.eventLoop.makeFailedFuture(
                    DatabaseStatementTimeoutConfigurationError.postgresRequired
                )
            }
            return sql.execute(sql: query, onRow)
        }
    }

    func execute(
        sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) async throws {
        try await execute(sql: query, onRow).get()
    }
}

extension StatementTimeoutDatabase {
    nonisolated(nonsending) func withSession<R>(
        _ closure: @escaping @Sendable (any SQLDatabase) async throws -> R
    ) async throws -> R {
        try await sqlBase.withSession { session in
            try await initializer.configure(session)
            return try await closure(session)
        }
    }
}

extension StatementTimeoutDatabase: PostgresDatabase {
    func send(
        _ request: any PostgresRequest,
        logger: Logger
    ) -> EventLoopFuture<Void> {
        let request = StatementTimeoutUncheckedSendable(value: request)
        return withConfiguredConnection { database in
            guard let postgres = database as? any PostgresDatabase else {
                return database.eventLoop.makeFailedFuture(
                    DatabaseStatementTimeoutConfigurationError.postgresRequired
                )
            }
            return postgres.send(request.value, logger: logger)
        }
    }

    func withConnection<T>(
        _ closure: @escaping (PostgresConnection) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        let closure = StatementTimeoutUncheckedSendable(value: closure)
        return withConfiguredConnection { database in
            guard let postgres = database as? any PostgresDatabase else {
                return database.eventLoop.makeFailedFuture(
                    DatabaseStatementTimeoutConfigurationError.postgresRequired
                )
            }
            return postgres.withConnection(closure.value)
        }
    }
}
