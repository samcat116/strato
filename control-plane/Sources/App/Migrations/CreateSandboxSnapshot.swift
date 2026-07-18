import Fluent
import SQLKit

/// Creates the `sandbox_snapshots` table (issue #426): checkpoints of a
/// sandbox — Firecracker memory/vmstate + a consistent rootfs copy — with
/// status lifecycle, size, agent placement, and the compatibility constraints
/// (Firecracker version, architecture) a restore must match.
///
/// `sandbox_id` cascades: v1 snapshots live in agent-owned storage beside the
/// sandbox and restore only in place, so they are meaningless — and already
/// removed from disk by the agent's sandbox teardown — once the sandbox row
/// goes. Operation records referencing a cascaded snapshot are untouched
/// (`resource_operations` deliberately has no FK).
struct CreateSandboxSnapshot: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("sandbox_snapshots")
            .id()
            .field("name", .string, .required)
            .field(
                "sandbox_id", .uuid, .required,
                .references("sandboxes", "id", onDelete: .cascade)
            )
            .field("project_id", .uuid, .required, .references("projects", "id"))
            .field("environment", .string, .required)
            .field("status", .string, .required)
            .field("size", .int64)
            .field("agent_id", .string)
            .field("storage_path", .string)
            .field("firecracker_version", .string)
            .field("architecture", .string)
            .field("error_message", .string)
            .field("created_by_id", .uuid, .required, .references("users", "id"))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        // Listing a sandbox's snapshots, and quota resync summing ready
        // snapshot sizes per project scope, are the two read paths.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_sandbox_snapshots_sandbox_id ON sandbox_snapshots (sandbox_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_sandbox_snapshots_project_id ON sandbox_snapshots (project_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_sandbox_snapshots_sandbox_id").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_sandbox_snapshots_project_id").run()
        }
        try await database.schema("sandbox_snapshots").delete()
    }
}
