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
        // `replace()` is available on both Postgres and SQLite.
        //
        // Deliberately conservative: rows are left NULL (validation stays skipped,
        // i.e. prior behavior — never a false rejection) rather than guessing wrong
        // whenever the URL can't be turned into the token's literal issuer:
        //   * URLs without the well-known suffix.
        //   * Multi-tenant endpoints whose discovery metadata advertises a
        //     *templated* issuer (e.g. Microsoft Entra `common`/`organizations`/
        //     `consumers` → `.../{tenantid}/v2.0`). The URL strips to a literal
        //     `.../common/v2.0`, which no real token carries, so storing it would
        //     reject every login. These are picked up correctly on the next
        //     provider test/refresh, which stores the templated issuer from
        //     metadata (matched by OIDCValidation.issuerMatches).
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                """
                UPDATE oidc_providers
                SET issuer = replace(discovery_url, \(bind: Self.wellKnownSuffix), '')
                WHERE issuer IS NULL
                  AND discovery_url IS NOT NULL
                  AND discovery_url LIKE \(bind: "%\(Self.wellKnownSuffix)%")
                  AND discovery_url NOT LIKE \(bind: "%/common/%")
                  AND discovery_url NOT LIKE \(bind: "%/organizations/%")
                  AND discovery_url NOT LIKE \(bind: "%/consumers/%")
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
