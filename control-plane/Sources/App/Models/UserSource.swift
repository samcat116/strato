import Foundation

/// How a user account came into existence. This is a lifecycle/provenance
/// marker, distinct from how the user authenticates: a `.local` user is one an
/// admin created (or who self-registered) and is managed in Strato directly,
/// while `.scim` and `.oidc` users are provisioned/owned by an external IdP.
///
/// Persisted as the raw string in `users.source`. Backfilled for pre-existing
/// rows from `scim_provisioned` / `oidc_provider_id` by `AddSourceToUser`.
enum UserSource: String, Codable, Sendable, CaseIterable {
    /// Created in Strato — self-registered via passkey or added by an admin.
    case local
    /// Provisioned by a SCIM identity provider.
    case scim
    /// Just-in-time provisioned on first OIDC/SSO login.
    case oidc
}
