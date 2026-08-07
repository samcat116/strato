import Fluent

/// The agent-reported state of its durable workload manifest (STR-138), on the
/// row where the UI can show it.
///
/// An agent that cannot read the manifest cannot enumerate its own workloads.
/// It quarantines itself — no advertised capacity, no convergence — and that is
/// a standing condition an operator has to act on, not an event: it repeats on
/// every report until the file is repaired or removed. So it belongs beside
/// `teardown_refusal_reason`, which is surfaced the same way and for the same
/// reason.
///
/// `manifest_inventory_complete` is the load-bearing half. It is false only
/// while the agent is blind, and it is what tells reconciliation to read no
/// absence from that agent's reports.
struct AddManifestStatusToAgent: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("manifest_status_reason", .string)
            .field("manifest_status_at", .datetime)
            .field("manifest_inventory_complete", .bool)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("manifest_status_reason")
            .deleteField("manifest_status_at")
            .deleteField("manifest_inventory_complete")
            .update()
    }
}
