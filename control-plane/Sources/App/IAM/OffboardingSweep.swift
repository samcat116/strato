import Fluent
import Foundation
import Vapor

/// The org-departure offboarding sweep (issue #485).
///
/// When a user leaves an organization — removed by an admin, or offboarded by
/// the IdP through SCIM — everything they held *inside* that org goes with the
/// membership: their memberships in the org's groups, their project-member
/// mirror rows, and their role bindings on any node rooted in the org.
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
    /// Run inside the same transaction that deletes the `UserOrganization`
    /// membership row.
    static func userLeftOrganization(userID: UUID, organizationID: UUID, on db: Database) async throws {
        // Memberships in the org's groups: group-derived grants must not
        // outlive the org membership. Two steps deliberately — Fluent drops
        // joins from DELETE statements, so a joined delete emits SQL Postgres
        // rejects (`missing FROM-clause entry`).
        let orgGroupIDs = try await Group.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .all()
            .compactMap(\.id)
        if !orgGroupIDs.isEmpty {
            try await UserGroup.query(on: db)
                .filter(\.$user.$id == userID)
                .filter(\.$group.$id ~~ orgGroupIDs)
                .delete()
        }

        // Project-member mirror rows in the org's projects. The bindings they
        // mirror are swept below; the members list renders from these rows and
        // has to agree with what enforcement sees.
        let projectMemberships = try await ProjectMember.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
        for row in projectMemberships {
            let chain = try await IAMResourceTree.ancestors(
                of: IAMNode(type: .project, id: row.$project.id), on: db)
            if let root = chain.last, root.type == .organization, root.id == organizationID {
                try await row.delete(on: db)
            }
        }

        try await RoleBindingService.revokeAll(
            principalType: .user,
            principalID: userID,
            rootedInOrganization: organizationID,
            on: db
        )
    }
}
