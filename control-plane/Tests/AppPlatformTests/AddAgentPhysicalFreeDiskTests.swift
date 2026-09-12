import AppTestSupport
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Add agent physical free disk migration", .serialized)
struct AddAgentPhysicalFreeDiskTests {
    @Test("Existing agents preserve their old free-space observation during the wire upgrade")
    func backfillsExistingAgents() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                CREATE TABLE agents (
                    id uuid PRIMARY KEY,
                    available_disk bigint NOT NULL
                )
                """
            ).run()
            let agentID = UUID()
            try await sql.raw(
                """
                INSERT INTO agents (id, available_disk)
                VALUES (\(bind: agentID), \(bind: Int64(42)))
                """
            ).run()

            let migration = AddAgentPhysicalFreeDisk()
            try await migration.prepare(on: app.db)

            let physical = try await sql.raw(
                "SELECT physical_free_disk FROM agents WHERE id = \(bind: agentID)"
            ).first(decodingColumn: "physical_free_disk", as: Int64.self)
            #expect(physical == 42)

            try await migration.revert(on: app.db)
            let remaining = try await sql.raw(
                """
                SELECT count(*)::bigint AS count
                FROM information_schema.columns
                WHERE table_schema = current_schema()
                  AND table_name = 'agents'
                  AND column_name = 'physical_free_disk'
                """
            ).first(decodingColumn: "count", as: Int64.self)
            #expect(remaining == 0)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
