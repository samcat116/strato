import Fluent
import Foundation
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
                return try await operation(try PinnedTransactionConnection(connection))
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
