import Fluent

struct CreateAgentRegistrationToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agent_registration_tokens")
            .id()
            .field("token", .string, .required)
            .field("agent_name", .string, .required)
            .field("is_used", .bool, .required)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("used_at", .datetime)
            .unique(on: "token")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agent_registration_tokens").delete()
    }
}