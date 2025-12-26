import Fluent

struct AddSCIMFieldsToGroup: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("groups")
            .field("scim_provisioned", .bool, .required, .custom("DEFAULT FALSE"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("groups")
            .deleteField("scim_provisioned")
            .update()
    }
}
