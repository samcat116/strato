import Fluent
import SQLKit

/// The table behind tombstone-confirmed teardown (STR-98).
///
/// An agent reports the workloads it holds that its last sync did not list; the
/// control plane decides once per workload and records the verdict here. Sync
/// assembly reads the `tombstoned` rows back out as the tombstones that
/// authorize teardown, and the `held` rows are the standing evidence that
/// something is wrong — a scoping bug, or a node whose workloads are still
/// pointed at a superseded agent row.
///
/// `resource_id` deliberately carries no foreign key: the whole point of a
/// tombstoned claim is that no row exists for that id, which an FK would
/// forbid. The unique `(agent_id, resource_kind, resource_id)` is what makes
/// the applier's per-report upsert idempotent.
struct CreateAgentWorkloadClaim: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agent_workload_claims")
            .id()
            .field("agent_id", .string, .required)
            .field("resource_kind", .string, .required)
            .field("resource_id", .uuid, .required)
            .field("disposition", .string, .required)
            .field("tombstone_generation", .int64)
            .field("reason", .string)
            .field("observed_generation", .int64, .required, .sql(.default(0)))
            .field("observed_status", .string)
            .field("first_seen_at", .datetime)
            .field("last_seen_at", .datetime)
            .unique(on: "agent_id", "resource_kind", "resource_id")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        // Sync assembly asks "which tombstones does this agent have?" on every
        // assembly, and the composite unique above is leftmost on agent_id but
        // carries the resource columns it doesn't need. Raw SQL: Fluent's
        // schema builder has no partial-index support.
        try await sql.raw(
            "CREATE INDEX ix_agent_workload_claims_tombstoned "
                + "ON agent_workload_claims (agent_id) WHERE disposition = 'tombstoned'"
        ).run()

        // FluentKit force-unwraps `RawRepresentable.init(rawValue:)` on enum
        // columns, so an unexpected value traps the process rather than
        // failing a request. Same posture as `EnforcePersistedEnumValues`,
        // applied here because this table postdates it.
        try await sql.raw(
            "ALTER TABLE agent_workload_claims ADD CONSTRAINT ck_agent_workload_claims_resource_kind_enum "
                + "CHECK (resource_kind IN ('virtual_machine', 'sandbox'))"
        ).run()
        try await sql.raw(
            "ALTER TABLE agent_workload_claims ADD CONSTRAINT ck_agent_workload_claims_disposition_enum "
                + "CHECK (disposition IN ('tombstoned', 'held'))"
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agent_workload_claims").delete()
    }
}
