import Fluent
import SQLKit

/// Floating IPs (issue #344): external address pools plus per-address
/// allocations attached to VM NICs, realized agent-side as OVN
/// `dnat_and_snat` rules.
///
/// `floating_ips.interface_id` is `SET NULL` on delete so removing a VM (its
/// NIC rows cascade away) detaches the address rather than releasing it —
/// the project keeps its possibly DNS-published address. `pool_id` has no
/// cascade: pool deletion is refused by the API while addresses exist, and a
/// dangling allocation losing its pool silently would leak the address.
struct CreateFloatingIP: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("floating_ip_pools")
            .id()
            .field("name", .string, .required)
            .field("cidr", .string, .required)
            .field("gateway", .string)
            .field("site_id", .uuid, .references("sites", "id", onDelete: .setNull))
            .field("organization_id", .uuid, .references("organizations", "id", onDelete: .setNull))
            .field(
                "organizational_unit_id", .uuid,
                .references("organizational_units", "id", onDelete: .setNull)
            )
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()

        try await database.schema("floating_ips")
            .id()
            .field("pool_id", .uuid, .required, .references("floating_ip_pools", "id"))
            .field("address", .string, .required)
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field(
                "interface_id", .uuid,
                .references("vm_network_interfaces", "id", onDelete: .setNull)
            )
            .field("created_by_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "pool_id", "address")
            .create()

        // One floating IP per NIC, enforced in the schema: the controller's
        // pre-check reads then writes, so two concurrent attaches could both
        // see the NIC as free and commit — the partial unique index makes the
        // second insert/update fail instead. Partial (NULLs excluded) because
        // detached rows all share interface_id = NULL. Raw SQL: Fluent's
        // schema builder has no partial-index support; the syntax is common to
        // both SQLite and Postgres.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                CREATE UNIQUE INDEX uq_floating_ips_interface
                ON floating_ips (interface_id) WHERE interface_id IS NOT NULL
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("floating_ips").delete()
        try await database.schema("floating_ip_pools").delete()
    }
}
