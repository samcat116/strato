import Fluent

struct AddSystemAdminToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("users")
            .field("is_system_admin", .bool, .required, .custom("DEFAULT FALSE"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("is_system_admin")
            .update()
    }
}
