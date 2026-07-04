import Fluent

/// Replaces the single `hypervisor_type` scalar on agents with the structured
/// capability data reported at registration (issue #208): host architecture, a
/// probed per-hypervisor availability/capability list, and network capability.
///
/// Existing rows get an empty hypervisor list; it is repopulated the next time
/// the agent registers (agents re-register on every reconnect).
///
/// Each schema change runs as its own ALTER TABLE because SQLite doesn't
/// support multiple clauses in one statement.
struct ReplaceAgentHypervisorTypeWithHypervisors: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("architecture", .string)
            .update()

        try await database.schema("agents")
            .field("hypervisors", .json, .required, .custom("DEFAULT '[]'"))
            .update()

        try await database.schema("agents")
            .field("network_capability", .string)
            .update()

        try await database.schema("agents")
            .deleteField("hypervisor_type")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .field("hypervisor_type", .string, .required, .custom("DEFAULT 'qemu'"))
            .update()

        try await database.schema("agents")
            .deleteField("architecture")
            .update()

        try await database.schema("agents")
            .deleteField("hypervisors")
            .update()

        try await database.schema("agents")
            .deleteField("network_capability")
            .update()
    }
}
