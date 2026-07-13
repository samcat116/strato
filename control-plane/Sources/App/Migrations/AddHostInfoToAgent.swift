import Fluent

/// Adds the descriptive host-info blob each agent reports at registration
/// (`AgentRegisterMessage.hostInfo`): CPU model/vendor, physical core count,
/// kernel version, OS distribution, machine model, boot time. Purely
/// informational for operator display — nothing in scheduling reads it.
///
/// Stored as a single JSON object (`HostInfo` is one struct, not an array, so
/// this is a scalar `.json` column — contrast `hypervisors`, a `jsonb[]`).
/// Nullable: rows that predate the column read as "unknown" until the agent
/// re-registers with a build that reports it.
struct AddHostInfoToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("host_info", .json)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("host_info")
            .update()
    }
}
