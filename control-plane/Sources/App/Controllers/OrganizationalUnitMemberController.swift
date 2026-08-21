import ControlPlanePostgres
import Foundation
import Vapor

/// Manages folder-level role grants for users and groups (STR-109) — the write
/// path for the binding scope the design has always evaluated but no endpoint
/// could author.
///
/// Folder bindings are what "this team administers everything under
/// `engineering`" is supposed to mean: one grant that inherits down every
/// project and resource beneath it, and keeps inheriting as projects are added.
/// The evaluator has handled `node_type = 'organizational_unit'` since the Cedar
/// cutover; before this controller the only ways to express the intent were an
/// org-wide grant (too broad) or one grant per project (drifts, and records the
/// wrong scope).
///
/// Like project grants, this surface reads and writes `role_bindings` directly.
/// It is gated on `iam:setPolicy` / `iam:readPolicy` at the folder rather than
///    a `manage_*` permission. A grant is policy, so it sits with roles,
///    authored policies, and guardrails — and, unlike `folder:update`, it can be
///    withheld from a custom role or ceilinged on its own.
///
/// The rest carries over unchanged: `MemberRoleResolver` for the role
/// id validator, `CrossOrgBindingGate` for external principals, and
/// `GuardrailWriteReport` for the write-time ceiling report.
struct OrganizationalUnitMemberController: RouteCollection {
    private let groupStore: GroupsPersistence
    private let hierarchy: HierarchyPersistence
    private let iam: IAMPersistence
    private let projects: ProjectsPersistence
    private let users: UserDirectoryPersistence

    init(
        groups: GroupsPersistence,
        hierarchy: HierarchyPersistence,
        iam: IAMPersistence,
        projects: ProjectsPersistence,
        users: UserDirectoryPersistence
    ) {
        self.groupStore = groups
        self.hierarchy = hierarchy
        self.iam = iam
        self.projects = projects
        self.users = users
    }

    func boot(routes: RoutesBuilder) throws {
        let folder = routes.grouped("api", "organizations", ":organizationID", "ous", ":ouID")

        let members = folder.grouped("members")
        members.get(use: list)
        members.post(use: grant)
        members.patch(":userID", use: updateRole)
        members.delete(":userID", use: revoke)

        let groups = folder.grouped("groups")
        groups.post(use: grantGroup)
        groups.delete(":groupID", use: revokeGroup)
    }

    // MARK: - DTOs

    struct FolderMemberResponse: Content {
        let userId: UUID?
        let username: String
        let displayName: String
        let email: String
        /// The granted role's `iam_roles` id.
        let role: UUID
        /// The role's human-readable name, batch-loaded; a UUID naming no
        /// surviving row renders as "(deleted role)".
        let roleDisplayName: String
        let grantedAt: Date?
        /// The grant expires at this instant; nil never expires. Folder grants
        /// cannot be written with a TTL through this API, but a binding seeded
        /// elsewhere can carry one, and hiding it would misreport the grant.
        let expiresAt: Date?
        /// The user is not a member of the folder's organization — cross-org
        /// access, deliberately prominent wherever grants are listed
        /// (issue #485).
        let external: Bool
    }

    struct FolderGroupGrantResponse: Content {
        let groupId: UUID?
        let name: String
        let role: UUID
        let roleDisplayName: String
        let grantedAt: Date?
        let expiresAt: Date?
        /// The group belongs to another organization (issue #485).
        let external: Bool
    }

    struct FolderMembersResponse: Content {
        let users: [FolderMemberResponse]
        let groups: [FolderGroupGrantResponse]
    }

    struct GrantMemberRequest: Content {
        let userEmail: String?
        let userID: UUID?
        let role: UUID
    }

    struct UpdateMemberRoleRequest: Content {
        let role: UUID
    }

    struct GrantGroupRequest: Content {
        let groupID: UUID
        let role: UUID
    }

    // MARK: - Handlers

    /// GET /api/organizations/:organizationID/ous/:ouID/members — the folder's
    /// user and group grants.
    func list(req: Request) async throws -> FolderMembersResponse {
        let folder = try await requireFolder(req)
        let node = folder.node
        try await requireGrantAdmin(on: node, write: false, req: req)

        let bindings = try await RoleBindingService.activeBindings(
            nodeType: .organizationalUnit, nodeID: node.id, using: iam)

        // Only users and groups are listed. Service accounts and workloads are
        // bindable principals too (issue #491), but they are managed from their
        // own surfaces and nothing grants one a folder role today; showing them
        // here without a way to edit them would be worse than omitting them.
        let userBindings = bindings.filter { $0.principalType == IAMPrincipalType.user.rawValue }
        let groupBindings = bindings.filter { $0.principalType == IAMPrincipalType.group.rawValue }

        // Each principal kind resolves in one query, and an empty binding set
        // skips it entirely rather than issuing an empty `IN ()`.
        var usersByID: [UUID: UserDirectorySnapshot] = [:]
        if !userBindings.isEmpty {
            for user in try await users.users(ids: userBindings.map(\.principalID)) {
                usersByID[user.id] = user
            }
        }
        var groups: [UUID: GroupSnapshot] = [:]
        if !groupBindings.isEmpty {
            for group in try await groupStore.groups(ids: groupBindings.map(\.principalID)) {
                groups[group.id] = group
            }
        }

        // Cross-org principals are marked, not filtered (issue #485). One bulk
        // membership read; no root org means nothing to be external to.
        let rootOrgID = try await IAMResourceTree.ancestors(of: node, using: iam)
            .last.flatMap { $0.type == .organization ? $0.id : nil }
        var internalUserIDs: Set<UUID> = []
        if let rootOrgID, !usersByID.isEmpty {
            internalUserIDs = try await users.organizationMemberIDs(
                organizationID: rootOrgID,
                among: Array(usersByID.keys)
            )
        }

        let displayNames = try await RoleDisplayNames.forRoleIDs(bindings.map(\.roleID), using: iam)

        // A binding whose principal row is gone is dropped rather than rendered
        // blank: evaluation ignores it too, so listing it would report access
        // nobody has.
        return FolderMembersResponse(
            users: userBindings.compactMap { binding in
                guard let user = usersByID[binding.principalID] else { return nil }
                return FolderMemberResponse(
                    userId: user.id,
                    username: user.username,
                    displayName: user.displayName,
                    email: user.email,
                    role: binding.roleID,
                    roleDisplayName: displayNames.displayName(forRoleID: binding.roleID),
                    grantedAt: binding.createdAt,
                    expiresAt: binding.expiresAt,
                    external: rootOrgID != nil && !internalUserIDs.contains(binding.principalID)
                )
            },
            groups: groupBindings.compactMap { binding in
                guard let group = groups[binding.principalID] else { return nil }
                return FolderGroupGrantResponse(
                    groupId: group.id,
                    name: group.name,
                    role: binding.roleID,
                    roleDisplayName: displayNames.displayName(forRoleID: binding.roleID),
                    grantedAt: binding.createdAt,
                    expiresAt: binding.expiresAt,
                    external: rootOrgID != nil && group.organizationID != rootOrgID
                )
            }
        )
    }

    /// POST /api/organizations/:organizationID/ous/:ouID/members — grant a user
    /// a role on the folder.
    func grant(req: Request) async throws -> Response {
        let folder = try await requireFolder(req)
        let node = folder.node
        try await requireGrantAdmin(on: node, write: true, req: req)

        let body = try req.content.decode(GrantMemberRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, using: iam)
        let userID = try await resolveUser(body)

        // Optimistic: refuse a doomed grant before taking the folder lock.
        // `insertExclusiveGrant` re-checks under it, which is the check that actually
        // holds.
        try await requireNoExistingGrant(principalType: .user, principalID: userID, node: node)

        // A principal outside the folder's org needs the dedicated resource-side
        // permission — cross-org grants are explicit-only and gated at write
        // time (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, using: iam, req: req)

        // A ceiling in force on this folder (or above it) may narrow what the
        // grant reaches. Reported with the response rather than refused (#484,
        // STR-110) — and a folder grant reaches the whole subtree, so this is
        // where the explanation matters most.
        let proposed = ProposedBinding(
            principalType: .user,
            principalID: userID,
            roleActions: role.actions,
            roleLabel: role.displayName,
            node: node
        )

        try await RoleBindingService.insertExclusiveGrant(
            principalType: .user, principalID: userID, roleID: role.id, node: node,
            createdBy: req.auth.get(User.self)?.id, using: iam)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .user, principalID: userID,
                role: role.displayName, node: node, using: iam, req: req)
        }
        return try await report(for: proposed, req: req)
            .encodeResponse(status: .created, for: req)
    }

    /// PATCH /api/organizations/:organizationID/ous/:ouID/members/:userID —
    /// change a user's role on the folder.
    func updateRole(req: Request) async throws -> Response {
        let folder = try await requireFolder(req)
        let node = folder.node
        try await requireGrantAdmin(on: node, write: true, req: req)

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        let body = try req.content.decode(UpdateMemberRoleRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, using: iam)

        // Optimistic 404, so a PATCH for a user who holds nothing here does not
        // take the folder lock first. `replaceExclusiveGrant` re-checks under it.
        let holdsRole = try await RoleBindingService.activeBindings(
            principalType: .user, principalID: userID,
            nodeType: .organizationalUnit, nodeID: node.id, using: iam)
        guard !holdsRole.isEmpty else {
            throw Abort(.notFound, reason: "User has no role on this folder")
        }

        // A role change for an external principal is a new cross-org grant —
        // same gate as the initial one (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, using: iam, req: req)

        // Reported even though the user already holds a role here: the new role
        // is a different grant, and widening viewer to editor is exactly the
        // move a ceiling bears on.
        let proposed = ProposedBinding(
            principalType: .user,
            principalID: userID,
            roleActions: role.actions,
            roleLabel: role.displayName,
            node: node
        )

        try await RoleBindingService.replaceExclusiveGrant(
            principalType: .user, principalID: userID, roleID: role.id, node: node,
            createdBy: req.auth.get(User.self)?.id, using: iam)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .user, principalID: userID,
                role: role.displayName, node: node, using: iam, req: req)
        }
        return try await report(for: proposed, req: req)
            .encodeResponse(status: .ok, for: req)
    }

    /// DELETE /api/organizations/:organizationID/ous/:ouID/members/:userID —
    /// revoke a user's role on the folder.
    func revoke(req: Request) async throws -> HTTPStatus {
        let folder = try await requireFolder(req)
        let node = folder.node
        try await requireGrantAdmin(on: node, write: true, req: req)

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        try await revokeGrant(principalType: .user, principalID: userID, node: node, req: req)
        return .noContent
    }

    /// POST /api/organizations/:organizationID/ous/:ouID/groups — grant a group
    /// a role on the folder.
    func grantGroup(req: Request) async throws -> Response {
        let folder = try await requireFolder(req)
        let node = folder.node
        try await requireGrantAdmin(on: node, write: true, req: req)

        let body = try req.content.decode(GrantGroupRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, using: iam)

        guard try await groupStore.group(id: body.groupID) != nil else {
            throw Abort(.notFound, reason: "Group not found")
        }
        // Optimistic; `insertExclusiveGrant` re-checks under the folder lock.
        try await requireNoExistingGrant(
            principalType: .group, principalID: body.groupID, node: node)

        // A group from another organization is grantable — cross-org access is
        // explicit-bindings-only, so it passes the same write-time gate as an
        // external user rather than being flatly refused (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .group, principalID: body.groupID, node: node, using: iam, req: req)

        // A group grant reaches every member, so the ceiling report asks whether
        // it covers the group or anyone in it (#484).
        let proposed = ProposedBinding(
            principalType: .group,
            principalID: body.groupID,
            roleActions: role.actions,
            roleLabel: role.displayName,
            node: node
        )

        try await RoleBindingService.insertExclusiveGrant(
            principalType: .group, principalID: body.groupID, roleID: role.id, node: node,
            createdBy: req.auth.get(User.self)?.id, using: iam)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .group, principalID: body.groupID,
                role: role.displayName, node: node, using: iam, req: req)
        }
        return try await report(for: proposed, req: req)
            .encodeResponse(status: .created, for: req)
    }

    /// DELETE /api/organizations/:organizationID/ous/:ouID/groups/:groupID —
    /// revoke a group's role on the folder.
    func revokeGroup(req: Request) async throws -> HTTPStatus {
        let folder = try await requireFolder(req)
        let node = folder.node
        try await requireGrantAdmin(on: node, write: true, req: req)

        guard let groupID = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }
        try await revokeGrant(principalType: .group, principalID: groupID, node: node, req: req)
        return .noContent
    }

    // MARK: - Shared grant mechanics

    /// Revoke everything the principal holds on the folder, 404-ing when it
    /// holds nothing, and keeping the cross-org revoke loud (issue #485).
    private func revokeGrant(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode, req: Request
    ) async throws {
        let crossOrg = try await CrossOrgBindingGate.isCrossOrg(
            principalType: principalType, principalID: principalID, node: node,
            using: iam)

        let revokedRole =
            try await RoleBindingService.revokeExclusiveGrant(
                principalType: principalType, principalID: principalID, node: node, using: iam
            ).first?.uuidString ?? "unknown"
        if crossOrg {
            // Revokes need no gate — taking cross-org access away is always
            // allowed — but they stay loud, so external access has a visible end
            // in the trail (issue #485).
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgRevoke, principalType: principalType, principalID: principalID,
                role: revokedRole, node: node, using: iam, req: req)
        }
    }

    /// Refuse a second grant for a principal that already holds a live role
    /// here: one role per principal per folder, changed with `PATCH` rather than
    /// accumulated. Keyed on *active* bindings — an expired row grants nothing,
    /// so it is not "already has a role", and `revokeGrant` clears it either
    /// way.
    private func requireNoExistingGrant(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode
    ) async throws {
        let existing = try await RoleBindingService.activeBindings(
            principalType: principalType, principalID: principalID,
            nodeType: .organizationalUnit, nodeID: node.id, using: iam)
        guard existing.isEmpty else {
            throw Abort(
                .conflict,
                reason: principalType == .group
                    ? "Group already has a role on this folder" : "User already has a role on this folder")
        }
    }

    // MARK: - Helpers

    /// The folder named by the path, verified to live in the organization the
    /// path also names — the same containment check the folder CRUD routes make,
    /// so `/organizations/A/ous/<folder in B>` cannot be used to reach B.
    private func requireFolder(_ req: Request) async throws -> OrganizationalUnitSnapshot {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }
        guard let overview = try await hierarchy.organizationalUnit(id: ouID) else {
            throw Abort(.notFound, reason: "Folder not found")
        }
        let folder = overview.organizationalUnit
        guard folder.organizationID == organizationID else {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }
        return folder
    }

    /// Reading the folder's grants is `iam:readPolicy`; writing one is
    /// `iam:setPolicy` — the same pair that gates roles, authored policies, and
    /// guardrails, because a binding is policy and not folder data. Who holds
    /// what on a subtree is itself a statement about who can do what, so the
    /// listing is not on `folder:read`.
    private func requireGrantAdmin(on node: IAMNode, write: Bool, req: Request) async throws {
        guard try await req.can(write ? "iam:setPolicy" : "iam:readPolicy", on: node) else {
            throw Abort(
                .forbidden,
                reason: write
                    ? "Managing this folder's role grants requires the iam:setPolicy permission on it"
                    : "Viewing this folder's role grants requires the iam:readPolicy permission on it")
        }
    }

    private func resolveUser(_ body: GrantMemberRequest) async throws -> UUID {
        if let userID = body.userID {
            guard try await users.user(id: userID) != nil else {
                throw Abort(.notFound, reason: "User not found")
            }
            return userID
        }
        if let email = body.userEmail {
            guard let user = try await users.user(email: email) else {
                throw Abort(.notFound, reason: "User not found")
            }
            return user.id
        }
        throw Abort(.badRequest, reason: "Provide userID or userEmail")
    }

    private func report(for binding: ProposedBinding, req: Request) async throws
        -> GrantWriteResponse
    {
        await GuardrailWriteReport.report(
            for: binding,
            using: iam,
            groups: groupStore,
            hierarchy: hierarchy,
            projects: projects,
            users: users,
            req: req
        )
    }
}

private extension OrganizationalUnitSnapshot {
    /// This folder as a binding/authorization tree node.
    var node: IAMNode {
        IAMNode(type: .organizationalUnit, id: id)
    }
}
