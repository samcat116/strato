import Fluent

/// Records the wire protocol version each agent last registered with, so sync
/// assembly can key version-dependent shapes on it — specifically, never
/// sending the site non-authoritative sync (`networks: []` +
/// `networksAuthoritative: false`) to a pre-v4 agent that would misread it as
/// an authoritative teardown of its L3 topology (issue #343). Nullable: rows
/// that predate the column read as "old" until the agent re-registers.
struct AddWireProtocolVersionToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("wire_protocol_version", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("wire_protocol_version")
            .update()
    }
}
