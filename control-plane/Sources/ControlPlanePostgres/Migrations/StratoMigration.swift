public enum StratoMigrationTransactionMode: Sendable {
    /// The migration and its ledger insert commit atomically.
    case required
    /// PostgreSQL forbids the migration inside a transaction. Implementations
    /// must make every statement explicitly re-runnable.
    case untransacted
}

public protocol StratoMigration: Sendable {
    /// Stable `_fluent_migrations.name`; reflection-derived names are forbidden.
    var name: String { get }
    var transactionMode: StratoMigrationTransactionMode { get }

    func apply(on session: PostgresSession) async throws
    func revert(on session: PostgresSession) async throws
}

extension StratoMigration {
    public var transactionMode: StratoMigrationTransactionMode { .required }

    public func revert(on session: PostgresSession) async throws {
        throw StratoMigrationError.irreversible(name: name)
    }
}

public enum StratoMigrationError: Error, Sendable {
    case irreversible(name: String)
}
