import Fluent

struct AddDurableResourceAdmissions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AgentResourceAdmission.schema)
            .field("id", .uuid, .identifier(auto: false), .references("agents", "id", onDelete: .cascade))
            .field("state", .json, .required)
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(AgentResourceAdmission.schema).delete()
    }
}
