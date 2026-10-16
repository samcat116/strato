import Fluent
import NIOCore
import SQLKit
import Vapor

/// Fluent marks a plain pinned connection inTransaction even before BEGIN.
/// Session-lock holders need real commit/rollback on the same connection.
/// Delegate transaction control to the underlying driver (including the
/// production timeout wrapper), and track nested transactions explicitly.
struct PinnedTransactionConnection: Database, SQLDatabase {
    let connection: any Database
    let sql: any SQLDatabase
    let control: any TransactionControlDatabase
    let inTransaction: Bool

    init(_ connection: any Database) throws {
        guard let sql = connection as? any SQLDatabase,
            let control = connection as? any TransactionControlDatabase
        else { throw Abort(.internalServerError, reason: "Transaction fencing requires a pinned SQL connection") }
        self.init(connection: connection, sql: sql, control: control, inTransaction: false)
    }

    private init(
        connection: any Database, sql: any SQLDatabase,
        control: any TransactionControlDatabase, inTransaction: Bool
    ) {
        self.connection = connection
        self.sql = sql
        self.control = control
        self.inTransaction = inTransaction
    }

    var context: DatabaseContext { connection.context }
    var dialect: any SQLDialect { sql.dialect }
    var version: (any SQLDatabaseReportedVersion)? { sql.version }
    var queryLogLevel: Logger.Level? { sql.queryLogLevel }

    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<
        Void
    > {
        connection.execute(query: query, onOutput: onOutput)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { connection.execute(schema: schema) }
    func execute(enum schema: DatabaseEnum) -> EventLoopFuture<Void> { connection.execute(enum: schema) }
    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<
        Void
    > {
        sql.execute(sql: query, onRow)
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }
    func transaction<T: Sendable>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        guard !inTransaction else { return closure(self) }
        let transaction = Self(connection: connection, sql: sql, control: control, inTransaction: true)
        return control.beginTransaction().flatMap {
            closure(transaction).flatMap { value in
                control.commitTransaction().map { value }
            }.flatMapError { error in
                control.rollbackTransaction().flatMapThrowing { throw error }
            }
        }
    }
}
