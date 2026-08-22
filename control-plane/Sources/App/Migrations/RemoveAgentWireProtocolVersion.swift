import Fluent
import SQLKit

/// Removes a dead registration value now that every admitted agent must speak
/// exactly `WireProtocol.currentVersion` (STR-277).
struct RemoveAgentWireProtocolVersion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw(
                "ALTER TABLE agents DROP COLUMN IF EXISTS wire_protocol_version"
            ).run()
            return
        }
        try await database.schema(Agent.schema)
            .deleteField("wire_protocol_version")
            .update()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" {
            try await sql.raw(
                "ALTER TABLE agents ADD COLUMN IF NOT EXISTS wire_protocol_version BIGINT"
            ).run()
            return
        }
        try await database.schema(Agent.schema)
            .field("wire_protocol_version", .int)
            .update()
    }
}
