import Fluent
import SQLKit

/// The sandbox NIC ↔ security group join (STR-34), mirroring the
/// `vm_interface_security_groups` half of `CreateSecurityGroup` field for
/// field — same FK semantics, same composite unique, same group-id index.
///
/// FK semantics carry the API's lifecycle rules into the schema:
/// - `interface_id` CASCADEs — deleting a sandbox cascades its NIC row, which
///   cascades these, so a delete detaches from every group.
/// - `security_group_id` has no cascade (RESTRICT): an attached group cannot
///   be deleted; 409 from the API, exactly as for a VM attachment.
///
/// The backfill joins every existing sandbox NIC to its project's `default`
/// group, so the ≥1-group invariant holds for sandboxes the moment the column
/// exists rather than only for sandboxes created afterwards. Every project has
/// a default group by this point (`SeedDefaultSecurityGroups` for the
/// pre-existing ones, `SecurityGroupService.ensureDefaultGroup` at project
/// create), and the `NOT EXISTS` guard keeps a re-run idempotent.
///
/// Note that none of this is enforced yet: sandbox NICs are still omitted from
/// the wire entirely (`SandboxSpecBuilder.guestNetworkingSupported`). See
/// `SandboxInterfaceSecurityGroup`.
struct CreateSandboxInterfaceSecurityGroups: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("sandbox_interface_security_groups")
            .id()
            .field(
                "interface_id", .uuid, .required,
                .references("sandbox_network_interfaces", "id", onDelete: .cascade)
            )
            .field(
                "security_group_id", .uuid, .required,
                .references("security_groups", "id")
            )
            .field("created_at", .datetime)
            .unique(on: "interface_id", "security_group_id")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        // Attachment counts and delete guards key on the group id; the
        // composite unique above is leftmost on interface_id, so it doesn't
        // serve them. Raw SQL: Fluent's schema builder has no plain-index
        // support.
        try await sql.raw(
            "CREATE INDEX ix_sandbox_interface_security_groups_group "
                + "ON sandbox_interface_security_groups (security_group_id)"
        ).run()

        try await Self.backfillDefaultGroups(on: sql)
    }

    /// Joins every sandbox NIC with no groups to its project's default group.
    /// Split out so it can be exercised directly by tests — the table create
    /// above is not repeatable, and an untested backfill is exactly the kind
    /// of thing that silently does nothing.
    static func backfillDefaultGroups(on sql: any SQLDatabase) async throws {
        try await sql.raw(
            """
            INSERT INTO sandbox_interface_security_groups (id, interface_id, security_group_id, created_at)
            SELECT gen_random_uuid(), ni.id, sg.id, now()
            FROM sandbox_network_interfaces ni
            JOIN sandboxes s ON s.id = ni.sandbox_id
            JOIN security_groups sg ON sg.project_id = s.project_id AND sg.is_default
            WHERE NOT EXISTS (
                SELECT 1 FROM sandbox_interface_security_groups m WHERE m.interface_id = ni.id
            )
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        try await database.schema("sandbox_interface_security_groups").delete()
    }
}
