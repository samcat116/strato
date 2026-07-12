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

        // 2. Everything else with a well-known suffix → exact issuer (the URL
        //    minus the suffix). For most IdPs the stripped URL *is* the token
        //    issuer, including non-Microsoft providers whose issuer path happens
        //    to contain a `/common/` etc. segment — those must be backfilled, not
        //    skipped. The only exact-strip exclusion is Microsoft's own alias
        //    endpoints: the v2.0 ones were templated above (already non-NULL), and
        //    any non-v2.0 Microsoft alias (e.g. the v1.0 `common` endpoint, whose
        //    real issuer lives on a different host) can't be derived from the URL,
        //    so it's left NULL until a refresh stores the metadata issuer.
        try await sql.raw(
            """
            UPDATE oidc_providers
            SET issuer = replace(discovery_url, \(bind: wellKnownSuffix), '')
            WHERE issuer IS NULL
              AND discovery_url IS NOT NULL
              AND discovery_url LIKE \(bind: "%\(wellKnownSuffix)%")
              AND NOT (
                discovery_url LIKE \(bind: "%login.microsoftonline.%")
                AND (
                  discovery_url LIKE \(bind: "%/common/%")
                  OR discovery_url LIKE \(bind: "%/organizations/%")
                  OR discovery_url LIKE \(bind: "%/consumers/%")
                )
              )
            """
        ).run()
    }
}
