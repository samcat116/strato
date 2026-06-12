import Fluent

struct AddStatusChangedAtToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Tracks when a VM's status last changed, so the reconciliation sweep can
        // detect VMs stuck in a transitional state. Nullable: existing rows are in
        // terminal states and are ignored by the sweep until they next transition.
        try await database.schema("vms")
            .field("status_changed_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("vms")
            .deleteField("status_changed_at")
            .update()
    }
}
