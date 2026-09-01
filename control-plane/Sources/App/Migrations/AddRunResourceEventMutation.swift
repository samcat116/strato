import Fluent
import SQLKit

/// Keeps the resource-event mutation constraint aligned with
/// `VMOperationKind.run` for guest command execution.
struct AddRunResourceEventMutation: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await replaceConstraint(on: database, includingRun: true)
    }

    func revert(on database: Database) async throws {
        try await replaceConstraint(on: database, includingRun: false)
    }

    private func replaceConstraint(on database: Database, includingRun: Bool) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("AddRunResourceEventMutation requires SQLKit")
        }
        let run = includingRun ? "'run', " : ""
        try await sql.raw(
            """
            ALTER TABLE resource_events
              DROP CONSTRAINT ck_resource_events_mutation_enum,
              ADD CONSTRAINT ck_resource_events_mutation_enum
                CHECK (mutation IN (
                  'create', 'boot', 'shutdown', 'reboot', 'pause', 'resume',
                  \(unsafeRaw: run)'delete', 'resize', 'snapshot', 'snapshot_delete',
                  'restore', 'snapshot_export', 'attach', 'detach', 'throttle'
                ))
            """
        ).run()
    }
}
