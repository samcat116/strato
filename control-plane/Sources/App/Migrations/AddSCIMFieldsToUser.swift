import Fluent

struct AddSCIMFieldsToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        // SQLite doesn't support multiple ADD clauses in a single ALTER TABLE statement
        try await database.schema("users")
            .field("scim_provisioned", .bool, .required, .custom("DEFAULT FALSE"))
            .update()

        try await database.schema("users")
            .field("scim_active", .bool, .required, .custom("DEFAULT TRUE"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("scim_provisioned")
            .update()

        try await database.schema("users")
            .deleteField("scim_active")
            .update()
    }
}
