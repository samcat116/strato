import Fluent

struct CreateProjectGroupGrant: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("project_group_grants")
            .id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "project_id", "group_id")  // One role per group per project
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("project_group_grants").delete()
    }
}
