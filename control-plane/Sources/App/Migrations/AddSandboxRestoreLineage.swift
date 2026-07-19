import Fluent
import SQLKit

/// Records which checkpoint created a sandbox fork (issue #427). The value is
/// deliberately not a foreign key: the controller enforces the conservative
/// source/snapshot lifetime policy explicitly, without cascade semantics that
/// could erase a fork or its audit lineage.
struct AddSandboxRestoreLineage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Sandbox.schema)
            .field("restored_from_snapshot_id", .uuid)
            .update()
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_sandboxes_restored_from_snapshot_id ON sandboxes (restored_from_snapshot_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_sandboxes_restored_from_snapshot_id").run()
        }
        try await database.schema(Sandbox.schema)
            .deleteField("restored_from_snapshot_id")
            .update()
    }
}
