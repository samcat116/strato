import Fluent

/// Adds the hashed credential for the one-token agent bootstrap flow.
/// Existing enrollment rows deliberately receive NULL: their already-issued
/// long bootstrap commands remain usable, but there is no raw secret from
/// which the new hash could be reconstructed or silently migrated.
struct AddAgentEnrollmentBootstrapTokens: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(AgentEnrollment.schema)
            .field("bootstrap_token_hash", .string)
            .unique(on: "bootstrap_token_hash")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(AgentEnrollment.schema)
            .deleteUnique(on: "bootstrap_token_hash")
            .deleteField("bootstrap_token_hash")
            .update()
    }
}
