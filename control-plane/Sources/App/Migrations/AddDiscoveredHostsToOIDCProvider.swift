import Fluent
import Foundation

/// Adds `discovered_hosts` to `oidc_providers`: the JSON array of hosts a
/// provider's own discovery document named as its server-fetched endpoints
/// (token, userinfo, JWKS).
///
/// The SSRF allow-list now covers those fetches, not just discovery, and an
/// IdP is free to serve them from a different domain than its discovery URL —
/// Google's discovery is on `accounts.google.com` while its JWKS is on
/// `www.googleapis.com`. Rather than make every operator hand-maintain
/// `OIDC_DISCOVERY_ALLOWED_HOSTS`, an allow-listed discovery document vouches
/// for the hosts it names, per provider.
///
/// Existing rows are backfilled from their stored endpoints when they have a
/// discovery URL, so deployments keep working across the upgrade instead of
/// failing every SSO login until an admin re-saves the provider. That does
/// grandfather any endpoint an admin had previously overridden by hand to an
/// internal host — pre-upgrade nothing stopped them, and the alternative is
/// breaking working logins on deploy. Providers configured entirely by hand
/// (no discovery URL) get an empty set and stay gated by the global
/// allow-list, which is where the new protection actually bites.
struct AddDiscoveredHostsToOIDCProvider: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .field("discovered_hosts", .string, .required, .custom("DEFAULT '[]'"))
            .update()

        for provider in try await ProviderRow.query(on: database).all() {
            guard let discoveryURL = provider.discoveryURL, !discoveryURL.isEmpty else { continue }
            let hosts = [provider.tokenEndpoint, provider.userinfoEndpoint, provider.jwksURI]
                .compactMap { $0 }
                .compactMap { URL(string: $0)?.host }
            guard !hosts.isEmpty else { continue }
            guard let encoded = try? JSONEncoder().encode(Array(Set(hosts)).sorted()),
                let json = String(data: encoded, encoding: .utf8)
            else { continue }
            provider.discoveredHosts = json
            try await provider.update(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .deleteField("discovered_hosts")
            .update()
    }
}

/// Column snapshot frozen at this migration. The live `OIDCProvider` model
/// gains and loses fields over time; querying it here would break this
/// migration the moment the schema moves on.
private final class ProviderRow: Model, @unchecked Sendable {
    static let schema = "oidc_providers"

    @ID(key: .id)
    var id: UUID?

    @OptionalField(key: "discovery_url")
    var discoveryURL: String?

    @OptionalField(key: "token_endpoint")
    var tokenEndpoint: String?

    @OptionalField(key: "userinfo_endpoint")
    var userinfoEndpoint: String?

    @OptionalField(key: "jwks_uri")
    var jwksURI: String?

    @Field(key: "discovered_hosts")
    var discoveredHosts: String

    init() {}
}
