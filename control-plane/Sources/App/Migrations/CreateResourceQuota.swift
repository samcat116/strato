import Fluent

struct CreateResourceQuota: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("resource_quotas")
            .id()
            .field("name", .string, .required)
            .field("organization_id", .uuid, .references("organizations", "id", onDelete: .cascade))
            .field("organizational_unit_id", .uuid, .references("organizational_units", "id", onDelete: .cascade))
            .field("project_id", .uuid, .references("projects", "id", onDelete: .cascade))
            // CPU limits
            .field("max_vcpus", .int, .required)
            .field("reserved_vcpus", .int, .required, .sql(.default(0)))
            // Memory limits (in bytes)
            .field("max_memory", .int64, .required)
            .field("reserved_memory", .int64, .required, .sql(.default(0)))
            // Storage limits (in bytes)
            .field("max_storage", .int64, .required)
            .field("reserved_storage", .int64, .required, .sql(.default(0)))
            // VM count limits
            .field("max_vms", .int, .required)
            .field("vm_count", .int, .required, .sql(.default(0)))
            // Network limits
            .field("max_networks", .int, .required, .sql(.default(10)))
            .field("network_count", .int, .required, .sql(.default(0)))
            // Other fields
            .field("is_enabled", .bool, .required, .sql(.default(true)))
            .field("environment", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "organization_id", "name", "environment")
            .unique(on: "organizational_unit_id", "name", "environment")
            .unique(on: "project_id", "name", "environment")
            .create()
        
        // Note: Check constraints would be added in a separate step if needed
    }

    func revert(on database: Database) async throws {
        try await database.schema("resource_quotas").delete()
    }
}