import Fluent

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
    }

    func revert(on database: Database) async throws {
        try await database.schema("floating_ips").delete()
        try await database.schema("floating_ip_pools").delete()
    }
}
