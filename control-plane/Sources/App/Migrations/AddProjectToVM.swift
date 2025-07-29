import Fluent

struct AddProjectToVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Add fields one at a time for SQLite compatibility
        try await database.schema("vms")
            .field("project_id", .uuid, .references("projects", "id", onDelete: .cascade))
            .update()

        try await database.schema("vms")
            .field("environment", .string, .sql(.default("'development'")))
            .update()

        // Add unique constraint if needed later
        // Index creation will be handled automatically by Fluent for foreign keys

        // NOTE: We'll need a separate data migration to populate project_id
        // for existing VMs. This will be handled in a separate migration
        // that creates default projects for each organization.
    }

    func revert(on database: Database) async throws {
        // Delete fields one at a time for SQLite compatibility
        try await database.schema("vms")
            .deleteField("project_id")
            .update()

        try await database.schema("vms")
            .deleteField("environment")
            .update()
    }
}
