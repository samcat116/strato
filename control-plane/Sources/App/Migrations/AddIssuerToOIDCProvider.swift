import Fluent
import Foundation

/// Adds the `issuer` column to `oidc_providers`. It holds the expected OIDC
/// issuer (the `iss` claim), populated from the provider's discovery document,
/// so the login flow can reject ID tokens minted by a different issuer.
struct AddIssuerToOIDCProvider: AsyncMigration {
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
    /// `iss` check applies on upgrade rather than staying off (or, with the
    /// fail-closed branch, blocking every login) until an admin re-tests each
    /// one. The issuer is derived from the discovery URL without a network fetch
    /// by ``OIDCValidation/discoveryIssuer(forDiscoveryURL:)``, which handles
    /// standard IdPs (exact), Microsoft Entra v2.0 multi-tenant aliases
    /// (templated) and v1 endpoints (the `sts.windows.net` issuer). Rows whose
    /// issuer can't be derived confidently are left NULL — validation stays off
    /// for them until a refresh stores the metadata issuer.
    static func backfillIssuers(on database: Database) async throws {
        let rows = try await OIDCProviderIssuerBackfillRow.query(on: database).all()
        for row in rows {
            guard row.issuer == nil,
                let discoveryURL = row.discoveryURL, !discoveryURL.isEmpty,
                let issuer = OIDCValidation.discoveryIssuer(forDiscoveryURL: discoveryURL)
            else {
                continue
            }
            row.issuer = issuer
            try await row.save(on: database)
        }
    }
}

/// A column-snapshot model pinned to just the fields the backfill touches, so it
/// doesn't depend on the live `OIDCProvider` model (whose schema may drift in
/// later migrations).
final class OIDCProviderIssuerBackfillRow: Model, @unchecked Sendable {
    static let schema = "oidc_providers"

    @ID(key: .id) var id: UUID?
    @OptionalField(key: "discovery_url") var discoveryURL: String?
    @OptionalField(key: "issuer") var issuer: String?

    init() {}
}
