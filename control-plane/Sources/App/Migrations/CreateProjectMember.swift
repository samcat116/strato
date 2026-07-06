import Fluent

struct CreateProjectMember: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("project_members")
            .id()
            .field("project_id", .uuid, .required, .references("projects", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "project_id", "user_id")  // One role per user per project
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("project_members").delete()
    }
}
