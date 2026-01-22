import Fluent

struct CreateVolume: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Create volumes table
        try await database.schema("volumes")
            .id()

            // Basic metadata
            .field("name", .string, .required)
            .field("description", .string, .required)

            // Project ownership
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))

            // Volume specifications
            .field("size", .int64, .required)
            .field("format", .string, .required, .sql(.default("'qcow2'")))
            .field("type", .string, .required, .sql(.default("'data'")))

            // Status tracking
            .field("status", .string, .required, .sql(.default("'creating'")))
            .field("error_message", .string)

            // Storage location
            .field("storage_path", .string)
            .field("hypervisor_id", .string)

            // VM attachment (null when detached)
            .field("vm_id", .uuid, .references("vms", "id", onDelete: .setNull))
            .field("device_name", .string)
            .field("boot_order", .int)

            // Source tracking
            .field("source_image_id", .uuid, .references("images", "id", onDelete: .setNull))
            .field("source_volume_id", .uuid, .references("volumes", "id", onDelete: .setNull))

            // Owner tracking
            .field("created_by_id", .uuid, .required, .references("users", "id", onDelete: .cascade))

            // Timestamps
            .field("created_at", .datetime)
            .field("updated_at", .datetime)

            // Unique constraint on name within project
            .unique(on: "project_id", "name")

            .create()

        // Create volume_snapshots table
        try await database.schema("volume_snapshots")
            .id()

            // Basic metadata
            .field("name", .string, .required)
            .field("description", .string, .required)

            // Parent volume
            .field("volume_id", .uuid, .required, .references("volumes", "id", onDelete: .cascade))

            // Project ownership (denormalized)
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))

            // Snapshot specifications
            .field("size", .int64, .required)

            // Status tracking
            .field("status", .string, .required, .sql(.default("'creating'")))
            .field("error_message", .string)

            // Storage location
            .field("storage_path", .string)

            // Owner tracking
            .field("created_by_id", .uuid, .required, .references("users", "id", onDelete: .cascade))

            // Timestamp
            .field("created_at", .datetime)

            // Unique constraint on name within volume
            .unique(on: "volume_id", "name")

            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("volume_snapshots").delete()
        try await database.schema("volumes").delete()
    }
}
