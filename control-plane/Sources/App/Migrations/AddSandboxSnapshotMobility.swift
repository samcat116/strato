import Fluent

/// Snapshot mobility columns (issue #428).
///
/// `sandbox_snapshots` gains the export record — `exported_at` plus the
/// per-artifact `exported_artifacts` integrity JSON — and two compatibility
/// constraints a cross-agent restore must match: the CPU template the guest
/// was captured under, and the source host's CPU model (the fallback identity
/// check for un-templated snapshots). `sandboxes` gains `cpu_template`, the
/// create-time decision those snapshot rows inherit.
///
/// Each column is its own `.update()` — SQLite cannot combine multiple
/// ALTER TABLE actions in one statement.
struct AddSandboxSnapshotMobility: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SandboxSnapshot.schema)
            .field("exported_at", .datetime)
            .update()
        try await database.schema(SandboxSnapshot.schema)
            .field("exported_artifacts", .json)
            .update()
        try await database.schema(SandboxSnapshot.schema)
            .field("cpu_template", .string)
            .update()
        try await database.schema(SandboxSnapshot.schema)
            .field("source_cpu_model", .string)
            .update()
        try await database.schema(Sandbox.schema)
            .field("cpu_template", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(SandboxSnapshot.schema)
            .deleteField("exported_at")
            .update()
        try await database.schema(SandboxSnapshot.schema)
            .deleteField("exported_artifacts")
            .update()
        try await database.schema(SandboxSnapshot.schema)
            .deleteField("cpu_template")
            .update()
        try await database.schema(SandboxSnapshot.schema)
            .deleteField("source_cpu_model")
            .update()
        try await database.schema(Sandbox.schema)
            .deleteField("cpu_template")
            .update()
    }
}
