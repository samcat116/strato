import Fluent

struct CreateOrganizationalUnit: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("organizational_units")
            .id()
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("organization_id", .uuid, .required, .references("organizations", "id", onDelete: .cascade))
            .field("parent_ou_id", .uuid, .references("organizational_units", "id", onDelete: .cascade))
            .field("path", .string, .required)
            .field("depth", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "organization_id", "parent_ou_id", "name")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("organizational_units").delete()
    }
}