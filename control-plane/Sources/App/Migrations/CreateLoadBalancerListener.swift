import Fluent

struct CreateLoadBalancerListener: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(LoadBalancerListener.schema)
            .id()
            .field(
                "load_balancer_id", .uuid, .required,
                .references(LoadBalancer.schema, "id", onDelete: .cascade))
            .field("port", .int, .required)
            .field("backend_port", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "load_balancer_id", "port")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(LoadBalancerListener.schema).delete()
    }
}
