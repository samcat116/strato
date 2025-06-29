import Fluent

struct CreateOrganization: AsyncMigration {
    func prepare(on database: Database) async throws {
        // Create organizations table
        try await database.schema("organizations")
            .id()
            .field("name", .string, .required)
            .field("description", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "name")
            .create()
        
        // Create user_organizations pivot table for many-to-many relationship
        try await database.schema("user_organizations")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("organization_id", .uuid, .required, .references("organizations", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "organization_id")
            .create()
    }
    
    func revert(on database: Database) async throws {
        try await database.schema("user_organizations").delete()
        try await database.schema("organizations").delete()
    }
}