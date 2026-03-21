import Fluent

struct CreateAppSetting: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("app_settings")
            .id()
            .field("key", .string, .required)
            .field("value", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "key")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("app_settings").delete()
    }
}
