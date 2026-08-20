import Fluent
import Foundation
import Vapor

/// The org-departure offboarding sweep (issue #485).
///
/// When a user leaves an organization — removed by an admin, or offboarded by
/// the IdP through SCIM — everything they held *inside* that org goes with the
/// membership: their memberships in the org's groups and their role bindings
/// on any node rooted in the org.
/// Sweeping the whole subtree matters because bindings need no membership to
/// grant (cross-org bindings are supported by design): a project binding left
/// behind would silently keep working as external access nobody gated through
/// `iam:grantExternal`.
///
/// Grants the user holds in *other* organizations are deliberately untouched.
/// They are those orgs' explicit (and explicitly gated) grants to revoke —
/// a user's bindings do not live only in their own org, and one org's
/// offboarding must neither leak into another's grants nor assume they don't
/// exist.
enum OffboardingSweep {
    /// Run inside the same transaction that deletes the organization-membership
    /// membership row.
    static func userLeftOrganization(userID: UUID, organizationID: UUID, on db: Database) async throws {
        // Keep this delete on the caller's existing transaction. Moving it to
        // the native pool before organization memberships migrate would let
        // one half commit without the other.
        try await LegacyGroupSQLBridge.removeMemberships(
            userID: userID, inOrganization: organizationID, on: db)

        try await RoleBindingService.revokeAll(
            principalType: .user,
            principalID: userID,
            rootedInOrganization: organizationID,
            on: db
        )
    }
}
