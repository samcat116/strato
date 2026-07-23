import Fluent
import Vapor
import Foundation

/// Manages project-level role grants for users and groups. Role bindings are the
/// source of truth for authorization; the `ProjectMember` / `ProjectGroupGrant`
/// tables mirror the grants so the members list renders from a fast relational query.
///
/// Listing requires `view_project`; all mutations require `manage_project` (enforced
/// via `OrganizationAccessService`, which delegates to the Cedar evaluator).
///
/// A grant whose principal is outside the project's organization additionally
/// requires `iam:grantExternal` on the project side and is recorded with a
/// distinct audit event — cross-org access is explicit-only and loud
/// (issue #485, `CrossOrgBindingGate`).
struct ProjectMemberController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let members = routes.grouped("api", "projects", ":projectID", "members")
        members.get(use: list)
        members.post(use: grant)
        members.patch(":userID", use: updateRole)
        members.delete(":userID", use: revoke)

        let groups = routes.grouped("api", "projects", ":projectID", "groups")
        groups.post(use: grantGroup)
        groups.delete(":groupID", use: revokeGroup)
    }

    // MARK: - DTOs

    struct ProjectMemberResponse: Content {
        let userId: UUID?
        let username: String
        let displayName: String
        let email: String
        /// The role's `iam_roles` id as a string. Legacy rows that still store a
        /// relational name are normalized to their seeded id here (issue #608).
        let role: String
        /// The role's human-readable name, batch-loaded; a UUID naming no
        /// surviving row renders as "(deleted role)".
        let roleDisplayName: String
        let joinedAt: Date?
        /// The user is not a member of the project's organization — cross-org
        /// access, which is deliberately prominent wherever grants are listed
        /// (issue #485).
        let external: Bool
    }

    struct ProjectGroupGrantResponse: Content {
        let groupId: UUID?
        let name: String
        /// The role's `iam_roles` id as a string (issue #608).
        let role: String
        /// The role's human-readable name; "(deleted role)" for a dangling id.
        let roleDisplayName: String
        let grantedAt: Date?
        /// The group belongs to another organization (issue #485).
        let external: Bool
    }

    struct ProjectMembersResponse: Content {
        let users: [ProjectMemberResponse]
        let groups: [ProjectGroupGrantResponse]
    }

    struct GrantMemberRequest: Content {
        let userEmail: String?
        let userID: UUID?
        let role: String
    }

    struct UpdateMemberRoleRequest: Content {
        let role: String
    }

    struct GrantGroupRequest: Content {
        let groupID: UUID
        let role: String
    }

    // MARK: - Handlers

    /// GET /api/projects/:projectID/members — user members + group grants.
    func list(req: Request) async throws -> ProjectMembersResponse {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)
        let projectID = try project.requireID()

        let members = try await ProjectMember.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .with(\.$user)
            .all()

        let groupGrants = try await ProjectGroupGrant.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .with(\.$group)
            .all()

        // Mark cross-org principals so the UI can make them prominent
        // (issue #485). One bulk membership read; no root org means nothing
        // to be external to.
        let rootOrgID = try await project.getRootOrganizationId(on: req.db)
        var internalUserIDs: Set<UUID> = []
        if let rootOrgID {
            let memberUserIDs = members.compactMap { $0.user.id }
            if !memberUserIDs.isEmpty {
                internalUserIDs = Set(
                    try await UserOrganization.query(on: req.db)
                        .filter(\.$organization.$id == rootOrgID)
                        .filter(\.$user.$id ~~ memberUserIDs)
                        .all()
                        .map { $0.$user.id }
                )
            }
        }

        // Role display names, batch-loaded once across users and groups. The
        // stored `role` may be a UUID (going forward) or a legacy relational
        // name (older rows); both normalize to a canonical id for `role` and a
        // name for `roleDisplayName` (issue #608).
        let displayNames = try await RoleDisplayNames.forProjectRoles(
            members.map(\.role) + groupGrants.map(\.role), on: req.db)

        return ProjectMembersResponse(
            users: members.map { member in
                ProjectMemberResponse(
                    userId: member.user.id,
                    username: member.user.username,
                    displayName: member.user.displayName,
                    email: member.user.email,
                    role: canonicalRoleID(member.role),
                    roleDisplayName: displayNames.projectDisplayName(forStored: member.role),
                    joinedAt: member.createdAt,
                    external: rootOrgID != nil && member.user.id.map { !internalUserIDs.contains($0) } ?? false
                )
            },
            groups: groupGrants.map { grant in
                ProjectGroupGrantResponse(
                    groupId: grant.group.id,
                    name: grant.group.name,
                    role: canonicalRoleID(grant.role),
                    roleDisplayName: displayNames.projectDisplayName(forStored: grant.role),
                    grantedAt: grant.createdAt,
                    external: rootOrgID != nil && grant.group.$organization.id != rootOrgID
                )
            }
        )
    }

    /// POST /api/projects/:projectID/members — grant a user a role on the project.
    func grant(req: Request) async throws -> HTTPStatus {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let projectID = try project.requireID()

        let body = try req.content.decode(GrantMemberRequest.self)
        let node = IAMNode(type: .project, id: projectID)
        let role = try await MemberRoleResolver.resolve(
            body.role, scopeNode: node, acceptsLegacyProjectRoles: true, on: req.db)
        let targetUser = try await resolveUser(body, on: req)
        let userID = try targetUser.requireID()

        let existing = try await ProjectMember.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$user.$id == userID)
            .first()
        if existing != nil {
            throw Abort(.conflict, reason: "User already has a role on this project")
        }

        // A principal outside the project's org needs the dedicated
        // resource-side permission — cross-org grants are explicit-only and
        // gated at write time (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, req: req)

        // A ceiling in force on this project (or above it) may forbid what
        // this grant would reach — refuse now, with the reason, rather than
        // leaving it to be discovered as a denial days later (#484).
        try await GuardrailWriteCheck.requireNoViolation(
            ProposedBinding(
                principalType: .user,
                principalID: userID,
                roleActions: role.actions,
                roleLabel: role.displayName,
                node: node
            ), req: req)

        // The role binding lands in the same transaction as the mirror row.
        // The mirror stores the resolved role id going forward (issue #608).
        let actorID = req.auth.get(User.self)?.id
        try await req.db.transaction { db in
            try await ProjectMember(projectID: projectID, userID: userID, role: role.id.uuidString).save(on: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: userID,
                roleID: role.id,
                nodeType: .project,
                nodeID: projectID,
                createdBy: actorID,
                on: db
            )
        }
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .user, principalID: userID,
                role: role.displayName, node: node, req: req)
        }
        return .created
    }

    /// PATCH /api/projects/:projectID/members/:userID — change a user's role.
    func updateRole(req: Request) async throws -> HTTPStatus {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let projectID = try project.requireID()

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        let body = try req.content.decode(UpdateMemberRoleRequest.self)
        let node = IAMNode(type: .project, id: projectID)
        let role = try await MemberRoleResolver.resolve(
            body.role, scopeNode: node, acceptsLegacyProjectRoles: true, on: req.db)

        guard
            let membership = try await ProjectMember.query(on: req.db)
                .filter(\.$project.$id == projectID)
                .filter(\.$user.$id == userID)
                .first()
        else {
            throw Abort(.notFound, reason: "User has no role on this project")
        }

        // A role change for an external principal is a new cross-org grant —
        // same gate as the initial one (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, req: req)

        // Checked even though the user already holds a role here: the new role
        // is a different grant, and widening viewer to editor is exactly the
        // move a ceiling exists to stop.
        try await GuardrailWriteCheck.requireNoViolation(
            ProposedBinding(
                principalType: .user,
                principalID: userID,
                roleActions: role.actions,
                roleLabel: role.displayName,
                node: node
            ), req: req)

        let previousRole = membership.role
        let actorID = req.auth.get(User.self)?.id
        membership.role = role.id.uuidString
        try await req.db.transaction { db in
            try await membership.save(on: db)
            // Replace the old role's binding with the new one atomically with
            // the mirror-row update. The previously stored value may be a UUID
            // (going forward) or a legacy relational name (issue #608).
            if let previousRoleID = Self.storedRoleID(previousRole) {
                try await RoleBindingService.revoke(
                    principalType: .user,
                    principalID: userID,
                    roleID: previousRoleID,
                    nodeType: .project,
                    nodeID: projectID,
                    on: db
                )
            }
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: userID,
                roleID: role.id,
                nodeType: .project,
                nodeID: projectID,
                createdBy: actorID,
                on: db
            )
        }
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .user, principalID: userID,
                role: role.displayName, node: node, req: req)
        }
        return .ok
    }

    /// DELETE /api/projects/:projectID/members/:userID — revoke a user's role.
    func revoke(req: Request) async throws -> HTTPStatus {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let projectID = try project.requireID()

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        guard
            let membership = try await ProjectMember.query(on: req.db)
                .filter(\.$project.$id == projectID)
                .filter(\.$user.$id == userID)
                .first()
        else {
            throw Abort(.notFound, reason: "User has no role on this project")
        }

        let node = IAMNode(type: .project, id: projectID)
        let crossOrg = try await CrossOrgBindingGate.isCrossOrg(
            principalType: .user, principalID: userID, node: node, on: req.db)

        try await req.db.transaction { db in
            try await membership.delete(on: db)
            try await RoleBindingService.revoke(
                principalType: .user,
                principalID: userID,
                nodeType: .project,
                nodeID: projectID,
                on: db
            )
        }
        if crossOrg {
            // Revokes need no gate — taking cross-org access away is always
            // allowed — but they stay loud, so external access has a visible
            // end in the trail (issue #485).
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgRevoke, principalType: .user, principalID: userID,
                role: Self.storedRoleAuditLabel(membership.role),
                node: node, req: req)
        }
        return .noContent
    }

    /// POST /api/projects/:projectID/groups — grant a group a role on the project.
    func grantGroup(req: Request) async throws -> HTTPStatus {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let projectID = try project.requireID()

        let body = try req.content.decode(GrantGroupRequest.self)
        let node = IAMNode(type: .project, id: projectID)
        let role = try await MemberRoleResolver.resolve(
            body.role, scopeNode: node, acceptsLegacyProjectRoles: true, on: req.db)

        guard try await Group.find(body.groupID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Group not found")
        }

        let existing = try await ProjectGroupGrant.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$group.$id == body.groupID)
            .first()
        if existing != nil {
            throw Abort(.conflict, reason: "Group already has a role on this project")
        }

        // A group from another organization is grantable — cross-org access is
        // explicit-bindings-only, so it passes the same write-time gate as an
        // external user rather than being flatly refused (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .group, principalID: body.groupID, node: node, req: req)

        // A group grant reaches every member, so the ceiling check asks
        // whether it covers the group or anyone in it (#484).
        try await GuardrailWriteCheck.requireNoViolation(
            ProposedBinding(
                principalType: .group,
                principalID: body.groupID,
                roleActions: role.actions,
                roleLabel: role.displayName,
                node: node
            ), req: req)

        let actorID = req.auth.get(User.self)?.id
        try await req.db.transaction { db in
            try await ProjectGroupGrant(projectID: projectID, groupID: body.groupID, role: role.id.uuidString)
                .save(on: db)
            try await RoleBindingService.grant(
                principalType: .group,
                principalID: body.groupID,
                roleID: role.id,
                nodeType: .project,
                nodeID: projectID,
                createdBy: actorID,
                on: db
            )
        }
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .group, principalID: body.groupID,
                role: role.displayName, node: node, req: req)
        }
        return .created
    }

    /// DELETE /api/projects/:projectID/groups/:groupID — revoke a group's role.
    func revokeGroup(req: Request) async throws -> HTTPStatus {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let projectID = try project.requireID()

        guard let groupID = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }

        guard
            let grant = try await ProjectGroupGrant.query(on: req.db)
                .filter(\.$project.$id == projectID)
                .filter(\.$group.$id == groupID)
                .first()
        else {
            throw Abort(.notFound, reason: "Group has no role on this project")
        }

        let node = IAMNode(type: .project, id: projectID)
        let crossOrg = try await CrossOrgBindingGate.isCrossOrg(
            principalType: .group, principalID: groupID, node: node, on: req.db)

        try await req.db.transaction { db in
            try await grant.delete(on: db)
            try await RoleBindingService.revoke(
                principalType: .group,
                principalID: groupID,
                nodeType: .project,
                nodeID: projectID,
                on: db
            )
        }
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgRevoke, principalType: .group, principalID: groupID,
                role: Self.storedRoleAuditLabel(grant.role),
                node: node, req: req)
        }
        return .noContent
    }

    // MARK: - Helpers

    private func loadProject(_ req: Request) async throws -> Project {
        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }
        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }

    /// The canonical role id string for a stored mirror value — a UUID as-is,
    /// or a legacy relational name mapped to its seeded id — so the response's
    /// `role` field is a UUID string regardless of when the row was written
    /// (issue #608).
    private func canonicalRoleID(_ stored: String) -> String {
        RoleDisplayNames.projectRoleID(forStored: stored)?.uuidString ?? stored
    }

    /// The role id a previously stored mirror value names, for revoking its
    /// binding: a UUID directly, or a legacy relational name via its seeded id.
    private static func storedRoleID(_ stored: String) -> UUID? {
        RoleDisplayNames.projectRoleID(forStored: stored)
    }

    /// A best-effort role label for the cross-org audit trail. The binding
    /// revoke keys on the principal, not the role, so this is metadata only —
    /// a UUID string, a legacy name mapped to its IAM role, or the raw value.
    private static func storedRoleAuditLabel(_ stored: String) -> String {
        if UUID(uuidString: stored) != nil { return stored }
        if let projectRole = ProjectRole(rawValue: stored) { return IAMRole.fromProjectRole(projectRole).rawValue }
        return stored
    }

    private func resolveUser(_ body: GrantMemberRequest, on req: Request) async throws -> User {
        if let userID = body.userID {
            guard let user = try await User.find(userID, on: req.db) else {
                throw Abort(.notFound, reason: "User not found")
            }
            return user
        }
        if let email = body.userEmail {
            guard
                let user = try await User.query(on: req.db)
                    .filter(\.$email == email)
                    .first()
            else {
                throw Abort(.notFound, reason: "User not found")
            }
            return user
        }
        throw Abort(.badRequest, reason: "Provide userID or userEmail")
    }
}
