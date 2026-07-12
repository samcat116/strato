import Fluent
import SQLKit

/// Adds the `issuer` column to `oidc_providers`. It holds the expected OIDC
/// issuer (the `iss` claim), populated from the provider's discovery document,
/// so the login flow can reject ID tokens minted by a different issuer.
struct AddIssuerToOIDCProvider: AsyncMigration {
    /// The well-known suffix that a discovery URL appends to the issuer
    /// (OpenID Connect Discovery 1.0 §4). Stripping it recovers the issuer.
    static let wellKnownSuffix = "/.well-known/openid-configuration"

    func prepare(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .field("issuer", .string)
            .update()

        try await Self.backfillIssuers(on: database)
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .deleteField("issuer")
            .update()
    }

    /// Backfills `issuer` for existing discovery-configured providers so the
    /// `iss` check applies on upgrade rather than staying off until an admin
    /// re-tests each one. Derives the issuer from the discovery URL without a
    /// network fetch (`replace()` is available on both Postgres and SQLite):
    ///
    ///  1. Microsoft Entra multi-tenant endpoints (`login.microsoftonline.*`,
    ///     segment `common`/`organizations`/`consumers`, `/v2.0`) advertise a
    ///     *templated* issuer `.../{tenantid}/v2.0` in their metadata, while
    ///     tokens carry the concrete tenant. Rewrite the alias segment to
    ///     `{tenantid}` so `OIDCValidation.issuerMatches` validates real tokens.
    ///     Scoped to Microsoft hosts so a literal `common` segment on another
    ///     IdP is never turned into a wildcard.
    ///  2. Every other spec-compliant discovery URL is `issuer + wellKnownSuffix`,
    ///     so stripping the suffix yields the issuer exactly.
    ///
    /// A discovery URL that carries an unresolvable alias segment (a `/common/`
    /// etc. that isn't a recognized Microsoft `/v2.0` endpoint) is left NULL —
    /// validation stays skipped for it (prior behavior, never a false rejection)
    /// until a test/refresh stores the metadata issuer.
    static func backfillIssuers(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { return }

        // 1. Microsoft Entra multi-tenant v2.0 endpoints → templated issuer.
        for alias in ["/common/v2.0", "/organizations/v2.0", "/consumers/v2.0"] {
            try await sql.raw(
                """
                UPDATE oidc_providers
                SET issuer = replace(replace(discovery_url, \(bind: wellKnownSuffix), ''), \(bind: alias), \(bind: "/{tenantid}/v2.0"))
                WHERE issuer IS NULL
                  AND discovery_url IS NOT NULL
                  AND discovery_url LIKE \(bind: "%login.microsoftonline.%")
                  AND discovery_url LIKE \(bind: "%\(alias)/%")
                """
            ).run()
        }

        // 2. Everything else with a well-known suffix → exact issuer. Multi-tenant
        //    alias segments we didn't template above are excluded (left NULL)
        //    rather than stored as a literal that no token would carry.
        try await sql.raw(
            """
            UPDATE oidc_providers
            SET issuer = replace(discovery_url, \(bind: wellKnownSuffix), '')
            WHERE issuer IS NULL
              AND discovery_url IS NOT NULL
              AND discovery_url LIKE \(bind: "%\(wellKnownSuffix)%")
              AND discovery_url NOT LIKE \(bind: "%/common/%")
              AND discovery_url NOT LIKE \(bind: "%/organizations/%")
              AND discovery_url NOT LIKE \(bind: "%/consumers/%")
            """
        ).run()
    }
}
