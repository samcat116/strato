import AppTestSupport
import Fluent
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Reserved storage pool configuration migration", .serialized, .postgresFixture)
struct StoragePoolConfigurationMigrationTests {
    @Test("Upgrade preserves local membership, rejects retired values, and is repeatable")
    func upgradeAndRollback() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let migration = RemoveReservedStoragePoolConfiguration()
            try await migration.revert(on: app.db)
            try await sql.raw(
                "UPDATE storage_pools SET member_agent_ids = ARRAY['eligible-agent'] WHERE name = 'default'"
            ).run()
            try await migration.prepare(on: app.db)
            try await migration.prepare(on: app.db)

            let pool = try await StoragePool.defaultPool(on: app.db)
            #expect(pool.mode == .local)
            #expect(pool.backing == .filesystem)
            #expect(pool.memberAgentIds == ["eligible-agent"])
            let retiredColumns = try await sql.raw(
                """
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'storage_pools'
                    AND column_name = 'replication_factor'
                """
            ).all()
            #expect(retiredColumns.isEmpty)
            for assignment in ["mode = 'replicated'", "backing = 'zfs'"] {
                await #expect(throws: (any Error).self) {
                    try await sql.raw("UPDATE storage_pools SET \(unsafeRaw: assignment) WHERE name = 'default'").run()
                }
            }

            try await migration.revert(on: app.db)
            let factor = try await sql.raw("SELECT replication_factor FROM storage_pools WHERE name = 'default'")
                .first(decodingColumn: "replication_factor", as: Int.self)
            #expect(factor == 1)
            try await migration.prepare(on: app.db)
            #expect(try await StoragePool.defaultPool(on: app.db).memberAgentIds == ["eligible-agent"])
        }
    }

    @Test("Upgrade refuses unsupported historical rows atomically", arguments: ["mode", "backing"])
    func unsupportedHistoricalRows(column: String) async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let migration = RemoveReservedStoragePoolConfiguration()
            try await migration.revert(on: app.db)
            let value = column == "mode" ? "replicated" : "zfs"
            try await sql.raw(
                "UPDATE storage_pools SET \(unsafeRaw: column) = \(bind: value) WHERE name = 'default'"
            ).run()
            await #expect(throws: (any Error).self) {
                try await migration.prepare(on: app.db)
            }
            let preserved = try await sql.raw(
                "SELECT \(unsafeRaw: column) AS value FROM storage_pools WHERE name = 'default'"
            ).first(decodingColumn: "value", as: String.self)
            #expect(preserved == value)
            let factor = try await sql.raw("SELECT replication_factor FROM storage_pools WHERE name = 'default'")
                .first(decodingColumn: "replication_factor", as: Int.self)
            #expect(factor == 1)

            // No partial DDL: both historical constraints still allow the
            // reserved values after the failed attempt.
            try await sql.raw("UPDATE storage_pools SET mode = 'replicated', backing = 'zfs' WHERE name = 'default'")
                .run()
            try await sql.raw("UPDATE storage_pools SET mode = 'local', backing = 'filesystem' WHERE name = 'default'")
                .run()
            try await migration.prepare(on: app.db)
            #expect(try await StoragePool.defaultPool(on: app.db).mode == .local)
        }
    }
}
