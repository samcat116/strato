import Fluent

struct AddCurrentOrganizationToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("current_organization_id", .uuid, .references("organizations", "id", onDelete: .setNull))
            .update()
    }
    
    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("current_organization_id")
            .update()
    }
}