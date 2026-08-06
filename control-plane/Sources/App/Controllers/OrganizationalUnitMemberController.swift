import Fluent
import Foundation
import SQLKit
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
/// Two things differ from `ProjectMemberController`, which this otherwise
/// mirrors:
///
///  - **No mirror table.** Projects keep `ProjectMember`/`ProjectGroupGrant`
///    rows so the members list renders from a relational query; folders have no
///    such table and none is added — `role_bindings` is read directly, which is
///    the source of truth anyway. Nothing here has to decode legacy stored role
///    names, because no folder binding predates this surface: the `role` column
///    is always a role id.
///  - **Gated on `iam:setPolicy` / `iam:readPolicy`** at the folder rather than
///    a `manage_*` permission. A grant is policy, so it sits with roles,
///    authored policies, and guardrails — and, unlike `folder:update`, it can be
///    withheld from a custom role or ceilinged on its own.
///
/// The rest carries over unchanged: `MemberRoleResolver` for the role
/// vocabulary, `CrossOrgBindingGate` for external principals, and
/// `GuardrailWriteReport` for the write-time ceiling report.
struct OrganizationalUnitMemberController: RouteCollection {
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
        /// The granted role's `iam_roles` id, as a string.
        let role: String
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
        let role: String
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

    /// GET /api/organizations/:organizationID/ous/:ouID/members — the folder's
    /// user and group grants.
    func list(req: Request) async throws -> FolderMembersResponse {
        let folder = try await requireFolder(req)
        let node = try folder.node()
        try await requireGrantAdmin(on: node, write: false, req: req)

        let bindings = try await RoleBindingService.activeBindings(
            nodeType: .organizationalUnit, nodeID: node.id, on: req.db)

        // Only users and groups are listed. Service accounts and workloads are
        // bindable principals too (issue #491), but they are managed from their
        // own surfaces and nothing grants one a folder role today; showing them
        // here without a way to edit them would be worse than omitting them.
        let userBindings = bindings.filter { $0.principalType == IAMPrincipalType.user.rawValue }
        let groupBindings = bindings.filter { $0.principalType == IAMPrincipalType.group.rawValue }

        // Each principal kind resolves in one query, and an empty binding set
        // skips it entirely rather than issuing an empty `IN ()`.
        var users: [UUID: User] = [:]
        if !userBindings.isEmpty {
            for user in try await User.query(on: req.db)
                .filter(\.$id ~~ userBindings.map(\.principalID))
                .all()
            {
                users[try user.requireID()] = user
            }
        }
        var groups: [UUID: Group] = [:]
        if !groupBindings.isEmpty {
            for group in try await Group.query(on: req.db)
                .filter(\.$id ~~ groupBindings.map(\.principalID))
                .all()
            {
                groups[try group.requireID()] = group
            }
        }

        // Cross-org principals are marked, not filtered (issue #485). One bulk
        // membership read; no root org means nothing to be external to.
        let rootOrgID = try await CrossOrgBindingGate.rootOrganizationID(of: node, on: req.db)
        var internalUserIDs: Set<UUID> = []
        if let rootOrgID, !users.isEmpty {
            internalUserIDs = Set(
                try await UserOrganization.query(on: req.db)
                    .filter(\.$organization.$id == rootOrgID)
                    .filter(\.$user.$id ~~ Array(users.keys))
                    .all()
                    .map { $0.$user.id }
            )
        }

        let displayNames = try await RoleDisplayNames.forRoleIDs(
            bindings.compactMap { UUID(uuidString: $0.role) }, on: req.db)

        // A binding whose principal row is gone, or whose role is unparseable,
        // is dropped rather than rendered blank: both are already ignored by
        // every evaluation path, so listing them would report access nobody has.
        return FolderMembersResponse(
            users: userBindings.compactMap { binding in
                guard let user = users[binding.principalID], let roleID = UUID(uuidString: binding.role) else {
                    return nil
                }
                return FolderMemberResponse(
                    userId: user.id,
                    username: user.username,
                    displayName: user.displayName,
                    email: user.email,
                    role: roleID.uuidString,
                    roleDisplayName: displayNames.displayName(forRoleID: roleID),
                    grantedAt: binding.createdAt,
                    expiresAt: binding.expiresAt,
                    external: rootOrgID != nil && !internalUserIDs.contains(binding.principalID)
                )
            },
            groups: groupBindings.compactMap { binding in
                guard let group = groups[binding.principalID], let roleID = UUID(uuidString: binding.role) else {
                    return nil
                }
                return FolderGroupGrantResponse(
                    groupId: group.id,
                    name: group.name,
                    role: roleID.uuidString,
                    roleDisplayName: displayNames.displayName(forRoleID: roleID),
                    grantedAt: binding.createdAt,
                    expiresAt: binding.expiresAt,
                    external: rootOrgID != nil && group.$organization.id != rootOrgID
                )
            }
        )
    }

    /// POST /api/organizations/:organizationID/ous/:ouID/members — grant a user
    /// a role on the folder.
    func grant(req: Request) async throws -> Response {
        let folder = try await requireFolder(req)
        let node = try folder.node()
        try await requireGrantAdmin(on: node, write: true, req: req)

        let body = try req.content.decode(GrantMemberRequest.self)
        let role = try await MemberRoleResolver.resolve(
            body.role, scopeNode: node, acceptsLegacyProjectRoles: false, on: req.db)
        let targetUser = try await resolveUser(body, on: req)
        let userID = try targetUser.requireID()

        // Optimistic: refuse a doomed grant before taking the folder lock.
        // `insertGrant` re-checks under it, which is the check that actually
        // holds.
        try await requireNoExistingGrant(principalType: .user, principalID: userID, node: node, on: req.db)

        // A principal outside the folder's org needs the dedicated resource-side
        // permission — cross-org grants are explicit-only and gated at write
        // time (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, req: req)

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

        try await insertGrant(
            principalType: .user, principalID: userID, roleID: role.id, node: node, req: req)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .user, principalID: userID,
                role: role.displayName, node: node, req: req)
        }
        return try await GuardrailWriteReport.report(for: proposed, req: req)
            .encodeResponse(status: .created, for: req)
    }

    /// PATCH /api/organizations/:organizationID/ous/:ouID/members/:userID —
    /// change a user's role on the folder.
    func updateRole(req: Request) async throws -> Response {
        let folder = try await requireFolder(req)
        let node = try folder.node()
        try await requireGrantAdmin(on: node, write: true, req: req)

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        let body = try req.content.decode(UpdateMemberRoleRequest.self)
        let role = try await MemberRoleResolver.resolve(
            body.role, scopeNode: node, acceptsLegacyProjectRoles: false, on: req.db)

        // Optimistic 404, so a PATCH for a user who holds nothing here does not
        // take the folder lock first. `replaceGrant` re-checks under it.
        let holdsRole = try await RoleBindingService.activeBindings(
            principalType: .user, principalID: userID,
            nodeType: .organizationalUnit, nodeID: node.id, on: req.db)
        guard !holdsRole.isEmpty else {
            throw Abort(.notFound, reason: "User has no role on this folder")
        }

        // A role change for an external principal is a new cross-org grant —
        // same gate as the initial one (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, req: req)

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

        try await replaceGrant(
            principalType: .user, principalID: userID, roleID: role.id, node: node, req: req)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .user, principalID: userID,
                role: role.displayName, node: node, req: req)
        }
        return try await GuardrailWriteReport.report(for: proposed, req: req)
            .encodeResponse(status: .ok, for: req)
    }

    /// DELETE /api/organizations/:organizationID/ous/:ouID/members/:userID —
    /// revoke a user's role on the folder.
    func revoke(req: Request) async throws -> HTTPStatus {
        let folder = try await requireFolder(req)
        let node = try folder.node()
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
        let node = try folder.node()
        try await requireGrantAdmin(on: node, write: true, req: req)

        let body = try req.content.decode(GrantGroupRequest.self)
        let role = try await MemberRoleResolver.resolve(
            body.role, scopeNode: node, acceptsLegacyProjectRoles: false, on: req.db)

        guard try await Group.find(body.groupID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Group not found")
        }
        // Optimistic; `insertGrant` re-checks under the folder lock.
        try await requireNoExistingGrant(
            principalType: .group, principalID: body.groupID, node: node, on: req.db)

        // A group from another organization is grantable — cross-org access is
        // explicit-bindings-only, so it passes the same write-time gate as an
        // external user rather than being flatly refused (issue #485).
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .group, principalID: body.groupID, node: node, req: req)

        // A group grant reaches every member, so the ceiling report asks whether
        // it covers the group or anyone in it (#484).
        let proposed = ProposedBinding(
            principalType: .group,
            principalID: body.groupID,
            roleActions: role.actions,
            roleLabel: role.displayName,
            node: node
        )

        try await insertGrant(
            principalType: .group, principalID: body.groupID, roleID: role.id, node: node, req: req)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .group, principalID: body.groupID,
                role: role.displayName, node: node, req: req)
        }
        return try await GuardrailWriteReport.report(for: proposed, req: req)
            .encodeResponse(status: .created, for: req)
    }

    /// DELETE /api/organizations/:organizationID/ous/:ouID/groups/:groupID —
    /// revoke a group's role on the folder.
    func revokeGroup(req: Request) async throws -> HTTPStatus {
        let folder = try await requireFolder(req)
        let node = try folder.node()
        try await requireGrantAdmin(on: node, write: true, req: req)

        guard let groupID = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }
        try await revokeGrant(principalType: .group, principalID: groupID, node: node, req: req)
        return .noContent
    }

    // MARK: - Shared grant mechanics

    /// Run `body` in a transaction holding an exclusive row lock on the folder,
    /// serializing this folder's grant writes against each other.
    ///
    /// This is what makes "one role per principal per folder" true by
    /// construction rather than by convention. Projects get the same invariant
    /// from the database — `project_members` is `unique(project_id, user_id)`,
    /// and the mirror insert shares the binding's transaction, so the loser of a
    /// race rolls back. Dropping the mirror table for folders removed that, and
    /// `role_bindings`' own uniqueness key includes `role`: two concurrent
    /// grants of *different* roles to one principal never collide, so an
    /// unguarded check-then-act lets both land and the principal ends up holding
    /// the union, inherited down the whole subtree.
    ///
    /// Locking the folder row rather than adding a partial unique index keeps
    /// the property that this feature needs no migration; grants are rare, so
    /// serializing them per folder costs nothing. The lock is taken before any
    /// binding read inside `body`, so every re-check below sees a settled state.
    private func withFolderLocked<T: Sendable>(
        _ node: IAMNode, req: Request, _ body: @Sendable @escaping (any Database) async throws -> T
    ) async throws -> T {
        try await req.db.transaction { db in
            guard let sql = db as? any SQLDatabase else {
                // Postgres is the only supported backend. Continuing without the
                // lock would silently restore the race this exists to close, so
                // it fails loudly instead.
                throw Abort(
                    .internalServerError,
                    reason: "Folder grant writes require a SQL database that can lock the folder row")
            }
            try await sql.raw("SELECT id FROM organizational_units WHERE id = \(bind: node.id) FOR UPDATE").run()
            return try await body(db)
        }
    }

    /// Replace whatever the principal holds on the folder with exactly one
    /// binding for `roleID`.
    ///
    /// Revoke-then-grant rather than revoking the previously held role by name:
    /// with `role_bindings` as the only store there is no mirror row to read the
    /// old role from, and clearing the node outright is what makes "one role per
    /// principal per folder" true after the write rather than merely intended.
    ///
    /// The membership re-check happens under the lock, so the 404 cannot race a
    /// concurrent revoke into a grant that resurrects it.
    private func replaceGrant(
        principalType: IAMPrincipalType, principalID: UUID, roleID: UUID, node: IAMNode, req: Request
    ) async throws {
        let actorID = req.auth.get(User.self)?.id
        try await withFolderLocked(node, req: req) { db in
            let existing = try await RoleBindingService.activeBindings(
                principalType: principalType, principalID: principalID,
                nodeType: .organizationalUnit, nodeID: node.id, on: db)
            guard !existing.isEmpty else {
                throw Abort(
                    .notFound,
                    reason: principalType == .group
                        ? "Group has no role on this folder" : "User has no role on this folder")
            }
            try await RoleBindingService.revoke(
                principalType: principalType,
                principalID: principalID,
                roleID: nil,
                nodeType: .organizationalUnit,
                nodeID: node.id,
                on: db
            )
            try await RoleBindingService.grant(
                principalType: principalType,
                principalID: principalID,
                roleID: roleID,
                nodeType: .organizationalUnit,
                nodeID: node.id,
                createdBy: actorID,
                on: db
            )
        }
    }

    /// Write the one binding a fresh grant creates, refusing under the lock if
    /// the principal already holds a live role here.
    ///
    /// The caller has already made the same check optimistically, outside the
    /// lock, so an obviously-doomed request is refused before the guardrail
    /// solver runs. This one is the authoritative one.
    private func insertGrant(
        principalType: IAMPrincipalType, principalID: UUID, roleID: UUID, node: IAMNode, req: Request
    ) async throws {
        let actorID = req.auth.get(User.self)?.id
        try await withFolderLocked(node, req: req) { db in
            try await requireNoExistingGrant(
                principalType: principalType, principalID: principalID, node: node, on: db)
            try await RoleBindingService.grant(
                principalType: principalType,
                principalID: principalID,
                roleID: roleID,
                nodeType: .organizationalUnit,
                nodeID: node.id,
                createdBy: actorID,
                on: db
            )
        }
    }

    /// Revoke everything the principal holds on the folder, 404-ing when it
    /// holds nothing, and keeping the cross-org revoke loud (issue #485).
    private func revokeGrant(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode, req: Request
    ) async throws {
        let crossOrg = try await CrossOrgBindingGate.isCrossOrg(
            principalType: principalType, principalID: principalID, node: node, on: req.db)

        // Read and delete under the folder lock, so the 404 reflects the state
        // the delete then acts on.
        let revokedRole = try await withFolderLocked(node, req: req) { db -> String in
            let bindings = try await RoleBindingService.activeBindings(
                principalType: principalType, principalID: principalID,
                nodeType: .organizationalUnit, nodeID: node.id, on: db)
            guard let binding = bindings.first else {
                throw Abort(
                    .notFound,
                    reason: principalType == .group
                        ? "Group has no role on this folder" : "User has no role on this folder")
            }
            // `roleID: nil` also sweeps any expired row for this principal here,
            // which the active-only conflict check in `requireNoExistingGrant`
            // deliberately allows to be granted around.
            try await RoleBindingService.revoke(
                principalType: principalType,
                principalID: principalID,
                roleID: nil,
                nodeType: .organizationalUnit,
                nodeID: node.id,
                on: db
            )
            return binding.role
        }
        if crossOrg {
            // Revokes need no gate — taking cross-org access away is always
            // allowed — but they stay loud, so external access has a visible end
            // in the trail (issue #485).
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgRevoke, principalType: principalType, principalID: principalID,
                role: revokedRole, node: node, req: req)
        }
    }

    /// Refuse a second grant for a principal that already holds a live role
    /// here: one role per principal per folder, changed with `PATCH` rather than
    /// accumulated. Keyed on *active* bindings — an expired row grants nothing,
    /// so it is not "already has a role", and `revokeGrant` clears it either
    /// way.
    private func requireNoExistingGrant(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode, on db: any Database
    ) async throws {
        let existing = try await RoleBindingService.activeBindings(
            principalType: principalType, principalID: principalID,
            nodeType: .organizationalUnit, nodeID: node.id, on: db)
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
    private func requireFolder(_ req: Request) async throws -> OrganizationalUnit {
        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }
        guard let folder = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }
        guard folder.$organization.id == organizationID else {
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

extension OrganizationalUnit {
    /// This folder as a binding/authorization tree node.
    func node() throws -> IAMNode {
        IAMNode(type: .organizationalUnit, id: try requireID())
    }
}
