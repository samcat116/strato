import Fluent

/// Adds the `end_session_endpoint` column to `oidc_providers` for RP-initiated
/// logout (OIDC RP-Initiated Logout 1.0). Populated from the provider's
/// discovery document or set manually; NULL means app-local logout only.
struct AddEndSessionEndpointToOIDCProvider: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .field("end_session_endpoint", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .deleteField("end_session_endpoint")
            .update()
    }
}
