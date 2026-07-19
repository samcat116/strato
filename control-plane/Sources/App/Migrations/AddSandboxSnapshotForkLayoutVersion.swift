import Fluent

/// Records whether a checkpoint uses the jailed, chroot-relative artifact
/// layout required to restore it under a distinct sandbox identity. Nil keeps
/// legacy and unjailed snapshots eligible for in-place restore only.
struct AddSandboxSnapshotForkLayoutVersion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SandboxSnapshot.schema)
            .field("fork_layout_version", .int)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(SandboxSnapshot.schema)
            .deleteField("fork_layout_version")
            .update()
    }
}
