import Fluent

/// Scopes logical networks to projects so users can manage their own networks.
/// Both fields are nullable: networks with no project are global (the seeded
/// "default" network), and the seeded network has no creator.
struct AddProjectToLogicalNetwork: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Add fields one at a time for SQLite compatibility
        try await database.schema("logical_networks")
            .field("project_id", .uuid, .references("projects", "id", onDelete: .cascade))
            .update()

        try await database.schema("logical_networks")
            .field("created_by_id", .uuid, .references("users", "id", onDelete: .setNull))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("logical_networks")
            .deleteField("created_by_id")
            .update()

        try await database.schema("logical_networks")
            .deleteField("project_id")
            .update()
    }
}
