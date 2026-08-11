import Fluent
import SQLKit

struct CreateLoadBalancer: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(LoadBalancer.schema)
            .id()
            .field("name", .string, .required)
            .field("project_id", .uuid, .required, .references(Project.schema, "id", onDelete: .cascade))
            .field(
                "logical_network_id", .uuid, .required,
                .references(LogicalNetwork.schema, "id", onDelete: .cascade))
            .field("vip", .string, .required)
            .field("protocol", .string, .required)
            .field("desired_state", .string, .required)
            .field("observed_state", .string, .required)
            .field("generation", .int64, .required)
            .field("observed_generation", .int64, .required)
            .field("last_error", .string)
            .field("health_check_enabled", .bool, .required)
            .field("health_check_interval_seconds", .int, .required)
            .field("health_check_timeout_seconds", .int, .required)
            .field("health_check_success_threshold", .int, .required)
            .field("health_check_failure_threshold", .int, .required)
            .field("created_by_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "project_id", "name")
            .unique(on: "logical_network_id", "vip")
            .create()

        // A floating IP may target either a VM NIC or a load-balancer VIP.
        // SET NULL preserves the reserved external address when either target
        // is deleted, matching the existing interface attachment semantics.
        try await database.schema(FloatingIP.schema)
            .field(
                "load_balancer_id", .uuid,
                .references(LoadBalancer.schema, "id", onDelete: .setNull))
            .update()

        if let sql = database as? any SQLDatabase {
            try await sql.raw(
                "ALTER TABLE load_balancers ADD CONSTRAINT ck_load_balancers_protocol CHECK (protocol IN ('tcp', 'udp'))"
            ).run()
            try await sql.raw(
                "ALTER TABLE floating_ips ADD CONSTRAINT ck_floating_ips_one_target CHECK (NOT (interface_id IS NOT NULL AND load_balancer_id IS NOT NULL))"
            ).run()
            try await sql.raw(
                "CREATE UNIQUE INDEX uq_floating_ips_load_balancer_id ON floating_ips (load_balancer_id) WHERE load_balancer_id IS NOT NULL"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(FloatingIP.schema).deleteField("load_balancer_id").update()
        try await database.schema(LoadBalancer.schema).delete()
    }
}
