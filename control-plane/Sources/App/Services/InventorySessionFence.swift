import Fluent
import Foundation
import NIOCore
import SQLKit
import Vapor

/// PostgreSQL is the source of truth for observed-inventory ownership. Valkey
/// routes may expire or be refreshed by an old socket; neither grants a write.
enum InventorySessionExpectation: Sendable {
    case matches(UUID?)
}

enum InventorySessionFence {
    static func withLock<Value: Sendable>(
        agentID: UUID, on db: any Database, logger: Logger,
        operation: @escaping @Sendable (any Database) async throws -> Value
    ) async throws -> Value {
        try await AdvisoryLock.withSessionLock(
            .object(.agentInventory, id: agentID), on: db,
            timeout: .seconds(30), pollInterval: .milliseconds(25), logger: logger,
            operation: { connection in
                guard let sql = connection as? any SQLDatabase else { throw Abort(.internalServerError) }
                return try await operation(InventoryFenceConnection(connection: connection, sql: sql))
            })
    }

    static func current(agentID: UUID, on db: any Database) async throws -> UUID? {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        guard
            let row = try await sql.raw(
                "SELECT inventory_session_id FROM agents WHERE id = \(bind: agentID)"
            ).first()
        else { throw Abort(.notFound, reason: "Inventory session agent no longer exists") }
        return try row.decode(column: "inventory_session_id", as: UUID?.self)
    }

    static func replace(_ session: UUID, agentID: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw(
            "UPDATE agents SET inventory_session_id = \(bind: session) WHERE id = \(bind: agentID)"
        ).run()
    }
}

/// Fluent's pinned connection advertises inTransaction=true even without a
/// BEGIN. Restore ordinary transaction semantics without borrowing a second
/// connection: report transactions must retain their row locks and rollback.
private struct InventoryFenceConnection: Database, SQLDatabase {
    let connection: any Database
    let sql: any SQLDatabase
    var context: DatabaseContext { connection.context }
    var inTransaction: Bool { false }
    var logger: Logger { connection.logger }
    var eventLoop: any EventLoop { connection.eventLoop }
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
        sql.raw("BEGIN").run().flatMap {
            closure(connection).flatMap { value in
                sql.raw("COMMIT").run().map { value }
            }.flatMapError { error in
                sql.raw("ROLLBACK").run().flatMapThrowing { throw error }
            }
        }
    }
}
