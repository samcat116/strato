import Fluent

struct CreateLoadBalancerBackend: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(LoadBalancerBackend.schema)
            .id()
            .field(
                "load_balancer_id", .uuid, .required,
                .references(LoadBalancer.schema, "id", onDelete: .cascade)
            )
            .field(
                "interface_id", .uuid,
                .references(VMNetworkInterface.schema, "id", onDelete: .setNull)
            )
            .field("address", .string)
            .field("health_status", .string, .required)
            .field("last_health_check_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(
                on: "load_balancer_id", "interface_id",
                name: "uq_lb_backend_interface"
            )
            .unique(
                on: "load_balancer_id", "address",
                name: "uq_lb_backend_address"
            )
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(LoadBalancerBackend.schema).delete()
    }
}
