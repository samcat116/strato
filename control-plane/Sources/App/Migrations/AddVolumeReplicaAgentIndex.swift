import Fluent
import SQLKit

/// Serves the per-agent replica lookups used by desired-state assembly and
/// observed-state application. The existing unique index starts with
/// `volume_id`, so PostgreSQL cannot use it for these `agent_id`/`state`
/// filters.
struct AddVolumeReplicaAgentIndex: AsyncMigration {
    static let index = (
        name: "idx_volume_replicas_agent_state",
        definition: "volume_replicas (agent_id, state)"
    )

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS \(unsafeRaw: Self.index.name) "
                + "ON \(unsafeRaw: Self.index.definition)"
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: Self.index.name)").run()
    }
}
