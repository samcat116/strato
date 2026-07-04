import Fluent
import SQLKit

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

        // `Agent.hypervisors` is `[HypervisorSupport]`, and Fluent binds a Swift
        // array as a native SQL array — so on Postgres the value arrives as
        // `jsonb[]`. The column must match (mirroring `capabilities: [String]` →
        // `.array(of: .string)`); declaring it a scalar `.json` made writes fail
        // with "column is of type jsonb but expression is of type jsonb[]".
        //
        // The empty-array default that backfills existing rows is engine-specific:
        // Postgres spells an empty array `'{}'`, while SQLite stores arrays as JSON
        // text where it is `'[]'`.
        let emptyArrayDefault = (database as? SQLDatabase)?.dialect.name == "postgresql"
            ? "DEFAULT '{}'"
            : "DEFAULT '[]'"
        try await database.schema("agents")
            .field("hypervisors", .array(of: .json), .required, .custom(emptyArrayDefault))
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
