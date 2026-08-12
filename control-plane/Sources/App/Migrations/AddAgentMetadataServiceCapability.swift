import Fluent

/// Persists whether an agent initialized its instance metadata service
/// (STR-64). Existing rows default false and become eligible for IMDS-backed
/// placement only after their agent re-registers with an explicit capability.
struct AddAgentMetadataServiceCapability: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(Agent.schema)
            .field("metadata_service_capable", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(Agent.schema)
            .deleteField("metadata_service_capable")
            .update()
    }
}
