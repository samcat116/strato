import Fluent

struct AddCurrentProjectToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("current_project_id", .uuid, .references("projects", "id", onDelete: .setNull))
            .update()
    }
    
    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("current_project_id")
            .update()
    }
}