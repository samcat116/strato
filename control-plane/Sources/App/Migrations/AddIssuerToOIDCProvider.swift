import Fluent
import SQLKit

/// Adds the `issuer` column to `oidc_providers`. It holds the expected OIDC
/// issuer (the `iss` claim), populated from the provider's discovery document,
/// so the login flow can reject ID tokens minted by a different issuer.
struct AddIssuerToOIDCProvider: AsyncMigration {
    /// The well-known suffix that a discovery URL appends to the issuer
    /// (OpenID Connect Discovery 1.0 §4). Stripping it recovers the issuer.
    private static let wellKnownSuffix = "/.well-known/openid-configuration"

    func prepare(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .field("issuer", .string)
            .update()

        // Backfill existing discovery-configured providers so the `iss` check
        // applies on upgrade rather than staying off until an admin re-tests each
        // one. A spec-compliant discovery URL is `issuer + wellKnownSuffix`, so
        // stripping that suffix yields the issuer without any network fetch.
        // `replace()` is available on both Postgres and SQLite. Rows whose
        // discovery URL doesn't carry the suffix are left NULL (validation stays
        // skipped for them, i.e. the prior behavior) rather than guessing wrong.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                UPDATE oidc_providers
                SET issuer = replace(discovery_url, \(bind: Self.wellKnownSuffix), '')
                WHERE issuer IS NULL
                  AND discovery_url IS NOT NULL
                  AND discovery_url LIKE \(bind: "%\(Self.wellKnownSuffix)%")
                """
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .deleteField("issuer")
            .update()
    }
}
