import Fluent

/// Records the operating system each agent reports at registration (issue
/// #432), so the agent-update endpoint can resolve the right release artifact
/// — assets are published per OS/arch pair (`strato-<os>-<arch>.tar.gz`).
/// Nullable: rows read as "unknown" until the agent re-registers with a build
/// that reports it, and the update endpoint refuses to guess for those.
struct AddOperatingSystemToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("operating_system", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("operating_system")
            .update()
    }
}
