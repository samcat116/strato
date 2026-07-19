import Fluent
import SQLKit

/// Reconciliation phase 2 (issue #260): split VM state into desired and observed.
///
/// * `desired_status` — the goal state set by API mutations (`DesiredVMStatus`).
///   The existing `status` column becomes purely observed: written only from
///   agent reports and sweeps.
/// * `generation` — bumped on every desired-status or spec change; carried on
///   desired-state syncs so agents can reject stale ones.
/// * `observed_generation` — the last generation an agent confirmed converging
///   to. Pending operations complete when it catches up to `generation`.
///
/// SQLite cannot combine multiple ALTER TABLE actions in one step, so each
/// column is added with its own `.update()` call.
struct AddDesiredStateToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("vms")
            .field("desired_status", .string, .required, .sql(.default("Shutdown")))
            .update()
        try await database.schema("vms")
            .field("generation", .int64, .required, .sql(.default(0)))
            .update()
        try await database.schema("vms")
            .field("observed_generation", .int64, .required, .sql(.default(0)))
            .update()

        // Backfill desired state from the current (previously conflated) status:
        // a VM that is or was asked to be running should stay running; likewise
        // paused. Everything else (created/shutdown/stopping/error/unknown)
        // rests at shutdown — for in-flight transitions this re-asserts the
        // pre-migration behavior that an unconfirmed operation does not survive
        // a restart.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                UPDATE vms SET desired_status = CASE
                    WHEN status IN ('Running', 'Starting') THEN 'Running'
                    WHEN status = 'Paused' THEN 'Paused'
                    ELSE 'Shutdown'
                END
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("desired_status")
            .update()
        try await database.schema("vms")
            .deleteField("generation")
            .update()
        try await database.schema("vms")
            .deleteField("observed_generation")
            .update()
    }
}
