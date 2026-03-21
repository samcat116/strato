import Fluent

struct CreateImage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("images")
            .id()

            // Basic metadata
            .field("name", .string, .required)
            .field("description", .string, .required)

            // Project ownership
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))

            // File information
            .field("filename", .string, .required)
            .field("size", .int64, .required, .sql(.default("0")))
            .field("format", .string, .required, .sql(.default("'qcow2'")))
            .field("checksum", .string)

            // Storage location
            .field("storage_path", .string)

            // Status tracking
            .field("status", .string, .required, .sql(.default("'pending'")))
            .field("source_url", .string)
            .field("download_progress", .int)
            .field("error_message", .string)

            // Default VM configuration
            .field("default_cpu", .int)
            .field("default_memory", .int64)
            .field("default_disk", .int64)
            .field("default_cmdline", .string)

            // Upload tracking
            .field("uploaded_by_id", .uuid, .required, .references("users", "id", onDelete: .cascade))

            // Timestamps
            .field("created_at", .datetime)
            .field("updated_at", .datetime)

            // Unique constraint on name within project
            .unique(on: "project_id", "name")

            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("images").delete()
    }
}
