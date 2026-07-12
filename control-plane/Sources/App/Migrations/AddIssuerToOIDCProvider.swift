import Fluent

/// Adds the `issuer` column to `oidc_providers`. It holds the expected OIDC
/// issuer (the `iss` claim), populated from the provider's discovery document,
/// so the login flow can reject ID tokens minted by a different issuer.
struct AddIssuerToOIDCProvider: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .field("issuer", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .deleteField("issuer")
            .update()
    }
}
