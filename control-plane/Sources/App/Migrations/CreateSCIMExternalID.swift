import Fluent

struct CreateSCIMExternalID: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("scim_external_ids")
            .id()
            .field("organization_id", .uuid, .required, .references("organizations", "id", onDelete: .cascade))
            .field("resource_type", .string, .required)
            .field("external_id", .string, .required)
            .field("internal_id", .uuid, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "organization_id", "resource_type", "external_id")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("scim_external_ids").delete()
    }
}
