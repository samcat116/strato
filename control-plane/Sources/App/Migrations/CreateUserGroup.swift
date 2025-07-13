import Fluent

struct CreateUserGroup: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("user_groups")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("group_id", .uuid, .required, .references("groups", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "user_id", "group_id") // Prevent duplicate memberships
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("user_groups").delete()
    }
}