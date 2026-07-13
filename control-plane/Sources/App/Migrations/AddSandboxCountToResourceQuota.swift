import Fluent
import SQLKit

/// Sandbox count limits on resource quotas (issue #415). Sandbox vCPUs and
/// memory draw from the same pools as VMs (`max_vcpus`/`max_memory`), but the
/// *count* limit gets its own pair — counting sandboxes against `max_vms`
/// would silently shrink a limit whose name and existing semantics say VMs.
///
/// `max_sandboxes` backfills from each row's `max_vms`: a quota sized for N
/// machines admits up to N sandboxes besides, with the shared vCPU/memory
/// pools remaining the real ceiling. Each column is added in its own step —
/// SQLite cannot combine multiple ALTER TABLE actions.
struct AddSandboxCountToResourceQuota: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("resource_quotas")
            .field("max_sandboxes", .int, .required, .sql(.default(0)))
            .update()
        try await database.schema("resource_quotas")
            .field("sandbox_count", .int, .required, .sql(.default(0)))
            .update()

        if let sql = database as? SQLDatabase {
            try await sql.raw("UPDATE resource_quotas SET max_sandboxes = max_vms").run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("resource_quotas")
            .deleteField("max_sandboxes")
            .update()
        try await database.schema("resource_quotas")
            .deleteField("sandbox_count")
            .update()
    }
}
