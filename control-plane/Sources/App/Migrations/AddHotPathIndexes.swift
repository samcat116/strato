import Fluent
import FluentPostgresDriver
import SQLKit

/// Indexes the remaining hot query paths found by the 2026-07-23 control-plane
/// performance audit (issue #693).
///
/// Fluent creates a foreign key's referencing column without an index — the
/// same gap `AddVMHotColumnIndexes` closed for `vms` — so every filter below
/// was a sequential scan that grows with the table. The 30s background sweeps
/// and the per-create quota check are the paths that pay for it continuously,
/// which is why they lead the list.
///
/// Partial indexes are used where the matching set is a small, stable slice of
/// the table (transitional volumes, OIDC-backed users, non-pending
/// deliveries): they cost close to nothing to maintain and stay small.
///
/// Not here: the `organizational_units.path` index the audit also called for.
/// `OrganizationalUnit.descendants()` still matches with a leading-wildcard
/// `LIKE '%<uuid>%'`, which no index can serve; the index only becomes useful
/// once issue #692 rewrites that to a prefix match, and belongs with it.
struct AddHotPathIndexes: AsyncMigration {
    /// `(index name, CREATE INDEX body)`. Kept as one list so `revert` drops
    /// exactly what `prepare` created, and so a test can assert the migrated
    /// schema carries all of them.
    static let indexes: [(name: String, definition: String)] = [
        // Eager-loaded on every desired-state sync for every agent
        // (`DesiredStateAssembler`) and on the volume attach path.
        ("idx_volumes_vm_id", "volumes (vm_id)"),

        // Quota accounting on every VM/sandbox create, sandbox listing, and
        // project stats.
        ("idx_sandboxes_project_id", "sandboxes (project_id)"),

        // Three 30s sweeps filter sandboxes by status: the transitional
        // backstop (`starting`/`stopping`) and the TTL/retention sweeps, whose
        // terminal (`exited`/`error`) rows are exactly what accumulates.
        ("idx_sandboxes_status", "sandboxes (status)"),

        // Stuck-volume backstop every 30s. In steady state almost no row is
        // transitional, so the partial index is near-free to maintain and
        // turns the scan into a handful of tuples.
        (
            "idx_volumes_transitional",
            """
            volumes (status)
            WHERE status IN ('creating', 'attaching', 'detaching', 'resizing', 'snapshotting', 'cloning')
            """
        ),

        // Recursive child walk over the folder tree (`parent_ou_id = ?`). The
        // existing `unique (organization_id, parent_ou_id, name)` cannot serve
        // it — wrong leftmost column.
        ("idx_organizational_units_parent_ou_id", "organizational_units (parent_ou_id)"),

        // Agent delete/reassign guards ("does this agent still hold volumes?").
        ("idx_volumes_hypervisor_id", "volumes (hypervisor_id)"),

        // OIDC login lookup and the SSF signal processor. Partial: local and
        // WebAuthn-only users carry no subject.
        ("idx_users_oidc_subject", "users (oidc_subject) WHERE oidc_subject IS NOT NULL"),

        // Logical-network delete/rename in-use guards.
        ("idx_vm_network_interfaces_network", "vm_network_interfaces (network)"),

        // Group-side membership lookups (members of a group, guardrail write
        // checks). The existing unique is `(user_id, group_id)` — again the
        // wrong leftmost column.
        ("idx_user_groups_group_id", "user_groups (group_id)"),

        // Project-scoped floating-IP lists and counts.
        ("idx_floating_ips_project_id", "floating_ips (project_id)"),

        // Webhook history pruning: `status <> 'pending' AND created_at < cutoff`.
        // The existing `(status, next_attempt_at)` index serves the delivery
        // claim query, not this one. Deliberately not partial on
        // `status <> 'pending'`: that column is a plain string, so Fluent binds
        // the value as a parameter rather than inlining it, and the planner
        // cannot always prove a bind implies the index predicate. Pending rows
        // are transient anyway, so the partial index would have excluded
        // almost nothing.
        ("idx_webhook_deliveries_created_at", "webhook_deliveries (created_at)"),
    ]

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        // Plain (non-concurrent) creates: Fluent runs migrations inside a
        // transaction, which `CREATE INDEX CONCURRENTLY` cannot join. At
        // current table sizes the brief write lock is acceptable.
        for index in Self.indexes {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS \(unsafeRaw: index.name) ON \(unsafeRaw: index.definition)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        for index in Self.indexes {
            try await sql.raw("DROP INDEX IF EXISTS \(unsafeRaw: index.name)").run()
        }
    }
}
