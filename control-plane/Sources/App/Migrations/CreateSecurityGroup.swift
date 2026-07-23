import Fluent
import SQLKit

/// Security groups: project-scoped, NIC-attached firewall rule sets realized
/// agent-side as OVN ACLs on port groups.
///
/// Three tables in one feature migration (the `CreateFloatingIP` pattern):
/// the groups, their rules, and the NIC↔group membership join.
///
/// FK semantics carry the API's lifecycle rules into the schema:
/// - `security_group_rules.security_group_id` CASCADEs — rules die with the
///   group.
/// - `security_group_rules.remote_group_id` has no cascade (RESTRICT): a
///   group referenced by another group's rule cannot be deleted out from
///   under it; the API surfaces the conflict as a 409.
/// - `vm_interface_security_groups.interface_id` CASCADEs — deleting a VM
///   (its NIC rows cascade away) detaches it from all groups.
/// - `vm_interface_security_groups.security_group_id` has no cascade
///   (RESTRICT): an attached group cannot be deleted; 409 from the API.
struct CreateSecurityGroup: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("security_groups")
            .id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("description", .string)
            .field("is_default", .bool, .required)
            .field("generation", .int64, .required)
            .field("created_by_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "project_id", "name")
            .create()

        try await database.schema("security_group_rules")
            .id()
            .field(
                "security_group_id", .uuid, .required,
                .references("security_groups", "id", onDelete: .cascade)
            )
            .field("direction", .string, .required)
            .field("ethertype", .string, .required)
            .field("protocol", .string)
            .field("port_range_min", .int)
            .field("port_range_max", .int)
            .field("remote_cidr", .string)
            .field("remote_group_id", .uuid, .references("security_groups", "id"))
            .field("description", .string)
            .field("created_at", .datetime)
            .create()

        try await database.schema("vm_interface_security_groups")
            .id()
            .field(
                "interface_id", .uuid, .required,
                .references("vm_network_interfaces", "id", onDelete: .cascade)
            )
            .field(
                "security_group_id", .uuid, .required,
                .references("security_groups", "id")
            )
            .field("created_at", .datetime)
            .unique(on: "interface_id", "security_group_id")
            .create()

        // At most one default group per project, enforced in the schema: the
        // ensure-default path reads then writes, so two concurrent creators
        // could both see "no default" and commit — the partial unique index
        // makes the second insert fail instead. Raw SQL: Fluent's schema
        // builder has no partial-index support (nor plain indexes, below).
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                CREATE UNIQUE INDEX uq_security_groups_default
                ON security_groups (project_id) WHERE is_default
                """
            ).run()
            // Hot lookup paths that would otherwise seq-scan: attachment
            // counts and delete guards key on the join's group id (the
            // composite unique above is leftmost on interface_id, so it
            // doesn't serve them), rule fetches key on the owning group, and
            // the sync-time reference closure walks remote_group_id.
            try await sql.raw(
                "CREATE INDEX ix_vm_interface_security_groups_group ON vm_interface_security_groups (security_group_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX ix_security_group_rules_group ON security_group_rules (security_group_id)"
            ).run()
            try await sql.raw(
                "CREATE INDEX ix_security_group_rules_remote_group ON security_group_rules (remote_group_id)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("vm_interface_security_groups").delete()
        try await database.schema("security_group_rules").delete()
        try await database.schema("security_groups").delete()
    }
}
