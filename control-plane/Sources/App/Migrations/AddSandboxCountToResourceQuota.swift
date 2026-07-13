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
///
/// Both count columns are then recomputed from the workload rows actually in
/// each quota's scope. Sandboxes created before this migration were reserved
/// through the VM-shaped path (they may sit in `vm_count`), so leaving
/// `sandbox_count` at zero — and `vm_count` inflated — would make quota
/// displays and the update/delete floor checks wrong until some later
/// reserve/release happens to resync the quota. The scope subquery mirrors
/// `ResourceQuota.calculateActualUsage`: the quota's own project, its OU's
/// projects, or all of its organization's projects (direct and via OUs),
/// intersected with the quota's environment when one is set. Byte-accurate
/// reserved vCPU/memory/storage figures are untouched: sandboxes belong in
/// those pools either way, so the interim path left them correct.
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
            try await sql.raw(SQLQueryString(Self.recountSQL(workloadTable: "sandboxes", countColumn: "sandbox_count")))
                .run()
            try await sql.raw(SQLQueryString(Self.recountSQL(workloadTable: "vms", countColumn: "vm_count"))).run()
        }
    }

    /// Correlated-subquery recount of one workload table into one counter
    /// column, portable across SQLite and Postgres.
    static func recountSQL(workloadTable: String, countColumn: String) -> String {
        """
        UPDATE resource_quotas SET \(countColumn) = (
            SELECT COUNT(*) FROM \(workloadTable) w
            WHERE (resource_quotas.environment IS NULL OR w.environment = resource_quotas.environment)
            AND w.project_id IN (
                SELECT p.id FROM projects p
                WHERE (resource_quotas.project_id IS NOT NULL
                       AND p.id = resource_quotas.project_id)
                   OR (resource_quotas.organizational_unit_id IS NOT NULL
                       AND p.organizational_unit_id = resource_quotas.organizational_unit_id)
                   OR (resource_quotas.organization_id IS NOT NULL
                       AND (p.organization_id = resource_quotas.organization_id
                            OR p.organizational_unit_id IN (
                                SELECT ou.id FROM organizational_units ou
                                WHERE ou.organization_id = resource_quotas.organization_id)))
            )
        )
        """
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
