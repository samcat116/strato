import AppTestSupport
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Agent inventory session migration", .serialized)
struct AddAgentInventorySessionTests {
    @Test("Existing agents have no invented generation; migration is reversible")
    func roundTrip() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE TABLE agents (id uuid PRIMARY KEY)").run()
            let id = UUID()
            try await sql.raw("INSERT INTO agents (id) VALUES (\(bind: id))").run()
            let migration = AddAgentInventorySession()
            try await migration.prepare(on: app.db)
            #expect(try await InventorySessionFence.current(agentID: id, on: app.db) == nil)
            // Fencing pins a connection, but nested report transactions still
            // need real BEGIN/ROLLBACK rather than Fluent's pinned no-op.
            try await InventorySessionFence.withLock(agentID: id, on: app.db, logger: app.logger) { db in
                await #expect(throws: Abort.self) {
                    try await db.transaction { tx in
                        try await InventorySessionFence.replace(UUID(), agentID: id, on: tx)
                        throw Abort(.conflict)
                    }
                }
                let rolledBack = try await InventorySessionFence.current(agentID: id, on: db)
                #expect(rolledBack == nil)
            }
            let session = UUID()
            try await InventorySessionFence.replace(session, agentID: id, on: app.db)
            #expect(try await InventorySessionFence.current(agentID: id, on: app.db) == session)
            try await migration.revert(on: app.db)
            let count = try await sql.raw(
                "SELECT count(*)::bigint AS count FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'agents' AND column_name = 'inventory_session_id'"
            ).first(decodingColumn: "count", as: Int64.self)
            #expect(count == 0)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
