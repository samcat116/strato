import Fluent
import SQLKit

/// Removes the registration version column now that the handshake is an exact
/// match and no runtime gate reads a persisted value.
struct DropAgentWireProtocolVersion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("DropAgentWireProtocolVersion requires SQLKit")
        }
        // Fresh baselines already omit the column; preserved databases still
        // have it. The migration must be valid for both starting points.
        try await sql.raw(
            "ALTER TABLE agents DROP COLUMN IF EXISTS wire_protocol_version"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("DropAgentWireProtocolVersion requires SQLKit")
        }
        try await sql.raw(
            "ALTER TABLE agents ADD COLUMN IF NOT EXISTS wire_protocol_version bigint"
        ).run()
    }
}
