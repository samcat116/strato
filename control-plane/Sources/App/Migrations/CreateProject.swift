import Fluent

struct CreateProject: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("projects")
            .id()
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("organization_id", .uuid, .references("organizations", "id", onDelete: .cascade))
            .field("organizational_unit_id", .uuid, .references("organizational_units", "id", onDelete: .cascade))
            .field("path", .string, .required)
            .field("default_environment", .string, .required)
            .field("environments", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "organization_id", "name")
            .unique(on: "organizational_unit_id", "name")
            .create()

        // Note: Check constraints would be added in a separate step if needed
    }

    func revert(on database: Database) async throws {
        try await database.schema("projects").delete()
    }
}
