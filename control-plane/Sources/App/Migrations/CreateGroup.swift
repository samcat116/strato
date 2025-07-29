import Fluent

struct CreateGroup: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("groups")
            .id()
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("organization_id", .uuid, .required, .references("organizations", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name", "organization_id") // Group names must be unique within organization
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("groups").delete()
    }
}
