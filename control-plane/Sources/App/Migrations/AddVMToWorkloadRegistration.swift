import Fluent
import SQLKit

/// Links a `workload_registrations` row to the VM whose instance identity it is
/// (STR-55).
///
/// `ON DELETE CASCADE`, not `SET NULL`: the registration exists *because* the VM
/// does. A row outliving its VM would be an identity naming nothing, and its
/// `spiffe_id` would then keep a VM recreated on the same id out of the identity
/// it is supposed to own.
struct AddVMToWorkloadRegistration: AsyncMigration {

    /// One partial **unique** index, doing two jobs, declared here so
    /// `MigrationRoundTripTests` can read it back off the migrated schema — raw
    /// index SQL otherwise fails silently as a sequential scan in production.
    ///
    /// *Unique*, because "one registration per VM" is the invariant the whole
    /// feature rests on: a second row would give one VM two principals and make
    /// `GuestIdentity.spiffeIDs(forVMs:)` non-deterministic about which one a
    /// guest is told it is.
    ///
    /// *Partial*, because every agent and service-account row has a NULL
    /// `vm_id` and belongs in no index that exists to answer `WHERE vm_id IN
    /// (…)` — the desired-state assembly's per-sync lookup. Postgres can still
    /// use it for that predicate, since `vm_id IN (…)` implies `vm_id IS NOT
    /// NULL`.
    static let indexes: [(name: String, definition: String)] = [
        (
            "idx_workload_registrations_vm_id",
            "workload_registrations (vm_id) WHERE vm_id IS NOT NULL"
        )
    ]

    func prepare(on database: Database) async throws {
        try await database.schema("workload_registrations")
            .field("vm_id", .uuid, .references("vms", "id", onDelete: .cascade))
            .update()

        guard let sql = database as? SQLDatabase else { return }
        // Plain (non-concurrent) creates, matching `AddHotPathIndexes`: Fluent
        // runs migrations inside a transaction, which `CREATE INDEX
        // CONCURRENTLY` cannot join.
        for index in Self.indexes {
            try await sql.raw(
                "CREATE UNIQUE INDEX IF NOT EXISTS \(unsafeRaw: index.name) ON \(unsafeRaw: index.definition)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            for index in Self.indexes {
                try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
            }
        }

        try await database.schema("workload_registrations")
            .deleteField("vm_id")
            .update()
    }
}
