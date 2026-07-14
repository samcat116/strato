import Fluent

/// Adds the `use_nonce` flag to `oidc_providers`. When true (the default and
/// the OIDC-compliant behavior) Strato sends a `nonce` on the authorization
/// request and requires the ID token to echo it. Some IdPs — notably Discord —
/// accept the nonce but never return it, which would fail every login, so the
/// flag can be turned off per provider to skip sending and validating it.
/// The authorization-code flow protections (PKCE S256 + `state`) remain in
/// force. Existing rows default to true, preserving current behavior.
struct AddUseNonceToOIDCProvider: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .field("use_nonce", .bool, .required, .custom("DEFAULT true"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("oidc_providers")
            .deleteField("use_nonce")
            .update()
    }
}
