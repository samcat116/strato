import Fluent
import SQLKit

struct AddVMGuestConfig: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(VM.schema).field("guest_config", .json).update()
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            """
            ALTER TABLE resource_events DROP CONSTRAINT ck_resource_events_mutation_enum,
              ADD CONSTRAINT ck_resource_events_mutation_enum CHECK (mutation IN (
                'create', 'boot', 'shutdown', 'reboot', 'pause', 'resume', 'run',
                'delete', 'resize', 'snapshot', 'snapshot_delete', 'restore',
                'snapshot_export', 'attach', 'detach', 'throttle', 'guest_config'
              ))
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema(VM.schema).deleteField("guest_config").update()
        // Append-only event history can contain guest_config after this feature
        // is used. Retain the compatible constraint rather than deleting history.
    }
}
