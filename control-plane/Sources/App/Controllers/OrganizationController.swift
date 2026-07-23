import Foundation
import Vapor
import Fluent

struct OrganizationController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("api", "organizations")
        organizations.get(use: index)
        organizations.get("all", use: listAll)
        organizations.post(use: create)

        organizations.group(":organizationID") { org in
            org.get(use: show)
            org.put(use: update)
            org.delete(use: delete)
            org.post("switch", use: switchToOrganization)
            org.get("members", use: getMembers)
            org.post("members", use: addMember)
            org.delete("members", ":userID", use: removeMember)
            org.patch("members", ":userID", use: updateMemberRole)
        }
    }

    // MARK: - Organization CRUD

    /// System-admin only: every organization, regardless of membership. Backs
    /// admin flows (e.g. assigning an invited user to any org) where the caller
    /// isn't necessarily a member of the target. `index` stays membership-scoped
    /// for the normal org switcher.
    func listAll(req: Request) async throws -> [OrganizationResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System admin access required")
        }

        let organizations = try await Organization.query(on: req.db)
            .sort(\.$name)
            .all()
        return organizations.map { OrganizationResponse(from: $0, userRole: nil) }
    }

    func index(req: Request) async throws -> [OrganizationResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Get all organizations the user belongs to
        try await user.$organizations.load(on: req.db)

        // Get user roles for each organization
        var organizationResponses: [OrganizationResponse] = []

        for organization in user.organizations {
            let userOrg = try await UserOrganization.query(on: req.db)
                .filter(\.$user.$id == user.id!)
                .filter(\.$organization.$id == organization.id!)
                .first()

            let response = OrganizationResponse(
                from: organization,
                userRole: userOrg?.role
            )
            organizationResponses.append(response)
        }

        return organizationResponses
    }

    func show(req: Request) async throws -> OrganizationResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Authorization goes through the Cedar evaluator (via
        // OrganizationAccessService). The membership row survives only to
        // display the caller's role — nil for a system admin who isn't a member.
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        return OrganizationResponse(from: organization, userRole: userOrg?.role)
    }

    func create(req: Request) async throws -> OrganizationResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        // Open by design: any authenticated user may start an organization
        // (they become its admin below). Declared so the default-deny
        // middleware's handler assertion knows this is deliberate.
        req.markRowScopedAuthorization()

        let createRequest = try req.content.decode(CreateOrganizationRequest.self)

        // Check if organization name already exists
        let existingOrg = try await Organization.query(on: req.db)
            .filter(\.$name == createRequest.name)
            .first()

        if existingOrg != nil {
            throw Abort(.conflict, reason: "Organization name already exists")
        }

        let organization = Organization(
            name: createRequest.name,
            description: createRequest.description ?? ""
        )

        try await organization.save(on: req.db)

        // Add creator as admin: the admin role binding lands in the same
        // transaction as the mirror row.
        let userOrganization = UserOrganization(
            userID: user.id!,
            organizationID: organization.id!,
            role: "admin"
        )
        try await req.db.transaction { db in
            try await userOrganization.save(on: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: .admin,
                nodeType: .organization,
                nodeID: organization.id!,
                createdBy: user.id,
                on: db
            )
            // Claim the organization's trust domain in the same transaction as
            // its Cedar bindings, so an org can never exist without the row the
            // reconciler (issue #614) provisions its SPIRE instance from. Off
            // by default: with the feature flag down no row is written and only
            // the platform trust domain exists.
            try await OrgTrustDomainProvisioning.claim(organizationID: organization.id!, on: db)
        }

        // Set as current organization if user doesn't have one
        if user.currentOrganizationId == nil {
            user.currentOrganizationId = organization.id
            try await user.save(on: req.db)
        }

        // Create default project for the organization
        let defaultProject = Project(
            name: "Default Project",
            description: "Default project for \(organization.name)",
            organizationID: organization.id,
            path: "/\(organization.id!.uuidString)"
        )
        try await defaultProject.save(on: req.db)

        // Update project path with its own ID
        defaultProject.path = "/\(organization.id!.uuidString)/\(defaultProject.id!.uuidString)"
        try await defaultProject.save(on: req.db)

        // Creator binding on the default project (project creation writes an
        // explicit, revocable binding for its creator).
        try await RoleBindingService.grant(
            principalType: .user,
            principalID: user.id!,
            role: .admin,
            nodeType: .project,
            nodeID: defaultProject.id!,
            createdBy: user.id,
            on: req.db
        )

        // Give the org a default site (availability zone) so its first compute
        // agent can be enrolled without the operator hand-creating one first —
        // enrollment requires a site.
        try await Site.createDefault(
            forOrganization: organization.id!, named: organization.name, on: req.db)

        return OrganizationResponse(from: organization, userRole: "admin")
    }

    func update(req: Request) async throws -> OrganizationResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Org-admin check through the Cedar evaluator (`org:update`).
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        let updateRequest = try req.content.decode(UpdateOrganizationRequest.self)

        if let name = updateRequest.name {
            // Check if new name conflicts with existing organization
            let existingOrg = try await Organization.query(on: req.db)
                .filter(\.$name == name)
                .filter(\.$id != organizationID)
                .first()

            if existingOrg != nil {
                throw Abort(.conflict, reason: "Organization name already exists")
            }

            organization.name = name
        }

        if let description = updateRequest.description {
            organization.description = description
        }

        try await organization.save(on: req.db)

        return OrganizationResponse(from: organization, userRole: "admin")
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Org-admin check through the Cedar evaluator (`org:delete`).
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        // Check if this is the default organization
        if organization.name == "Default Organization" {
            throw Abort(.badRequest, reason: "Cannot delete the default organization")
        }

        // Update users who have this as current organization
        let usersWithCurrentOrg = try await User.query(on: req.db)
            .filter(\.$currentOrganizationId == organizationID)
            .all()

        for user in usersWithCurrentOrg {
            user.currentOrganizationId = nil
            try await user.save(on: req.db)
        }

        // Bindings have no FK to the nodes they protect, so drop the org
        // node's bindings — and those of every project that cascades away
        // with it — alongside the row.
        let orgProjectIDs = try await Project.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()
            .compactMap { $0.id }
        let ouIDs = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()
            .compactMap { $0.id }
        var ouProjectIDs: [UUID] = []
        if !ouIDs.isEmpty {
            ouProjectIDs = try await Project.query(on: req.db)
                .filter(\.$organizationalUnit.$id ~~ ouIDs)
                .all()
                .compactMap { $0.id }
        }
        let cascadedProjectIDs = orgProjectIDs + ouProjectIDs
        // Roles owned by the org (or by a project cascading away with it) go
        // too — a role outliving its owner is bindable nowhere and listed
        // nowhere, while still contributing a grants-field pair to the Cedar
        // schema. That makes this a policy-set change, so it runs inside
        // `withPolicySetChange` and bumps the version when roles actually went.
        let removed = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            try await organization.delete(on: db)
            // The trust domain row deliberately outlives the organization: it
            // is the instruction to destroy the org's CA, and the reconciler
            // has to be able to read it after the org is gone. Mark it for
            // teardown rather than deleting it.
            try await OrgTrustDomainProvisioning.markForTeardown(organizationID: organizationID, on: db)
            try await RoleBindingService.revokeAll(
                nodeType: .organization, nodeID: organizationID, on: db)
            var removedRoles = try await RoleStore.deleteOwned(
                by: .organization, ownerID: organizationID, on: db)
            var removedPolicies = try await PolicyStore.deleteOwned(
                by: .organization, ownerID: organizationID, on: db)
            for projectID in cascadedProjectIDs {
                try await RoleBindingService.revokeAll(
                    nodeType: .project, nodeID: projectID, on: db)
                removedRoles += try await RoleStore.deleteOwned(by: .project, ownerID: projectID, on: db)
                removedPolicies += try await PolicyStore.deleteOwned(by: .project, ownerID: projectID, on: db)
            }
            let removed = removedRoles + removedPolicies
            if removed > 0 {
                try await PolicySetVersionService.bump(
                    reason:
                        "organization deleted: \(removedRoles) owned role(s), \(removedPolicies) owned policy(ies) removed",
                    on: db)
            }
            return removed
        }
        if removed > 0 {
            await req.application.announcePolicySetChange()
        }

        return .noContent
    }

    // MARK: - Organization Switching

    func switchToOrganization(req: Request) async throws -> HTTPStatus {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Membership check through the Cedar evaluator. System admins may
        // switch to any organization — the same bypass the rest of the API
        // applies.
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        user.currentOrganizationId = organizationID
        try await user.save(on: req.db)

        return .ok
    }

    // MARK: - Member Management

    func getMembers(req: Request) async throws -> [OrganizationMemberResponse] {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Membership check through the Cedar evaluator; the member list stays
        // member-visible (`org:read`).
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        let members = try await UserOrganization.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .with(\.$user)
            .all()

        // Legacy literals (`admin`/`member`) display verbatim; a role granted
        // by id resolves to its row name, batch-loaded once (issue #608).
        let displayNames = try await RoleDisplayNames.forOrganizationRoles(members.map(\.role), on: req.db)

        return members.map { userOrg in
            OrganizationMemberResponse(
                id: userOrg.user.id,
                username: userOrg.user.username,
                displayName: userOrg.user.displayName,
                email: userOrg.user.email,
                role: userOrg.role,
                roleDisplayName: displayNames.organizationDisplayName(forStored: userOrg.role),
                joinedAt: userOrg.createdAt
            )
        }
    }

    func addMember(req: Request) async throws -> HTTPStatus {
        guard let currentUser = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Org-admin check through the Cedar evaluator (`org:update`).
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        struct AddMemberRequest: Content {
            let userEmail: String
            let role: String
        }

        let addRequest = try req.content.decode(AddMemberRequest.self)

        guard
            let targetUser = try await User.query(on: req.db)
                .filter(\.$email == addRequest.userEmail)
                .first()
        else {
            throw Abort(.notFound, reason: "User not found")
        }

        // Check if user is already a member
        let existingMembership = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == targetUser.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        if existingMembership != nil {
            throw Abort(.conflict, reason: "User is already a member of this organization")
        }

        // Legacy `admin`/`member` keep their literal membership semantics;
        // IAM names and org-owned role ids are additionally accepted, scoped to
        // the org (issue #608).
        let resolved = try await Self.resolveOrgRole(
            addRequest.role, organizationID: organizationID, on: req.db)
        let node = IAMNode(type: .organization, id: organizationID)

        let membership = UserOrganization(
            userID: targetUser.id!,
            organizationID: organizationID,
            role: resolved.storedRole
        )
        // Org admins (and any role granted by id/name) get a binding on the org
        // node; bare membership maps to no binding — and with no binding there
        // is nothing for a ceiling to be checked against (#484).
        if resolved.bindingRoleID != nil {
            try await GuardrailWriteCheck.requireNoViolation(
                ProposedBinding(
                    principalType: .user,
                    principalID: targetUser.id!,
                    roleActions: resolved.actions,
                    roleLabel: resolved.label,
                    node: node
                ), req: req)
        }

        let actorID = currentUser.id
        try await req.db.transaction { db in
            try await membership.save(on: db)
            if let bindingRoleID = resolved.bindingRoleID {
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: targetUser.id!,
                    roleID: bindingRoleID,
                    nodeType: .organization,
                    nodeID: organizationID,
                    createdBy: actorID,
                    on: db
                )
            }
        }

        return .created
    }

    func removeMember(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        // Org-admin check through the Cedar evaluator.
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard
            let membership = try await UserOrganization.query(on: req.db)
                .filter(\.$user.$id == userID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "User is not a member of this organization")
        }

        // Prevent removing the last admin
        if membership.role == "admin" {
            let adminCount = try await UserOrganization.query(on: req.db)
                .filter(\.$organization.$id == organizationID)
                .filter(\.$role == "admin")
                .count()

            if adminCount <= 1 {
                throw Abort(.badRequest, reason: "Cannot remove the last admin from organization")
            }
        }

        try await req.db.transaction { db in
            try await membership.delete(on: db)
            // Everything held inside the org goes with the membership — group
            // memberships, project mirror rows, and bindings across the whole
            // subtree, not just the org node (issue #485). Grants in other
            // orgs stay: those are the other orgs' to revoke.
            try await OffboardingSweep.userLeftOrganization(
                userID: userID, organizationID: organizationID, on: db)
        }

        return .noContent
    }

    func updateMemberRole(req: Request) async throws -> HTTPStatus {
        guard let currentUser = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        // Org-admin check through the Cedar evaluator.
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        struct UpdateRoleRequest: Content {
            let role: String
        }

        let updateRequest = try req.content.decode(UpdateRoleRequest.self)

        guard
            let membership = try await UserOrganization.query(on: req.db)
                .filter(\.$user.$id == userID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            throw Abort(.notFound, reason: "User is not a member of this organization")
        }

        // Legacy `admin`/`member` keep their literal membership semantics; IAM
        // names and org-owned role ids are additionally accepted (issue #608).
        let resolved = try await Self.resolveOrgRole(
            updateRequest.role, organizationID: organizationID, on: req.db)
        let node = IAMNode(type: .organization, id: organizationID)

        // Prevent changing role if this would remove the last admin. The guard
        // stays keyed on the literal "admin" membership: moving the last admin
        // to anything else — a bare member, or a role named by id — is what it
        // stops (issue #608).
        if membership.role == "admin" && resolved.storedRole != "admin" {
            let adminCount = try await UserOrganization.query(on: req.db)
                .filter(\.$organization.$id == organizationID)
                .filter(\.$role == "admin")
                .count()

            if adminCount <= 1 {
                throw Abort(.badRequest, reason: "Cannot change role of the last admin")
            }
        }

        // Only the direction that *adds* a binding needs checking; dropping to
        // bare membership takes access away, which no ceiling objects to.
        if resolved.bindingRoleID != nil {
            try await GuardrailWriteCheck.requireNoViolation(
                ProposedBinding(
                    principalType: .user,
                    principalID: userID,
                    roleActions: resolved.actions,
                    roleLabel: resolved.label,
                    node: node
                ), req: req)
        }

        let previousRole = membership.role
        membership.role = resolved.storedRole
        let actorID = currentUser.id
        try await req.db.transaction { db in
            try await membership.save(on: db)
            // Swap the role's binding atomically with the mirror-row update. The
            // previously stored value may be a legacy literal or a role id.
            if let oldBindingID = Self.orgStoredRoleID(previousRole) {
                try await RoleBindingService.revoke(
                    principalType: .user,
                    principalID: userID,
                    roleID: oldBindingID,
                    nodeType: .organization,
                    nodeID: organizationID,
                    on: db
                )
            }
            if let newBindingID = resolved.bindingRoleID {
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: userID,
                    roleID: newBindingID,
                    nodeType: .organization,
                    nodeID: organizationID,
                    createdBy: actorID,
                    on: db
                )
            }
        }

        return .ok
    }

    // MARK: - Org role resolution (issue #608)

    /// A membership role resolved for storage and binding.
    private struct ResolvedOrgRole {
        /// What `UserOrganization.role` stores: a legacy literal, or a role id.
        let storedRole: String
        /// The role id to bind on the org node, or nil for bare membership.
        let bindingRoleID: UUID?
        /// The role's action set, for the guardrail write-check.
        let actions: Set<String>
        /// A human-readable label for logs and refusals.
        let label: String
    }

    /// Resolve a requested org membership role across the unified vocabulary.
    ///
    /// Legacy `admin`/`member` keep their literal semantics: stored verbatim,
    /// `admin` carrying the admin binding and `member` none, so the last-admin
    /// guards continue to key on the literal. Everything else — an IAM role
    /// name or an org-owned role id — resolves through `MemberRoleResolver`,
    /// scoped to the org, and stores the role id (issue #608).
    private static func resolveOrgRole(
        _ raw: String, organizationID: UUID, on db: any Database
    ) async throws -> ResolvedOrgRole {
        if raw == "admin" || raw == "member" {
            let iamRole = IAMRole.fromOrganizationRole(raw)
            return ResolvedOrgRole(
                storedRole: raw,
                bindingRoleID: iamRole?.seededID,
                actions: iamRole.map { IAMRoleRegistry.actions(for: $0) } ?? [],
                label: raw
            )
        }
        let resolved = try await MemberRoleResolver.resolve(
            raw,
            scopeNode: IAMNode(type: .organization, id: organizationID),
            acceptsLegacyProjectRoles: false,
            on: db
        )
        // The seeded admin role — reachable by IAM name (already caught above as
        // the literal) or by its well-known id — *is* the org-admin membership
        // under another name. Store it as the literal "admin" so the last-admin
        // guards, which key on that literal, count it; otherwise an admin
        // granted by id would be invisible to them (issue #608 review).
        let storedRole = resolved.id == IAMRole.admin.seededID ? "admin" : resolved.id.uuidString
        return ResolvedOrgRole(
            storedRole: storedRole,
            bindingRoleID: resolved.id,
            actions: resolved.actions,
            label: resolved.displayName
        )
    }

    /// The role id a stored membership value names, for revoking its binding:
    /// a UUID directly, or a legacy literal via `fromOrganizationRole`
    /// (`member` names none).
    private static func orgStoredRoleID(_ stored: String) -> UUID? {
        if let uuid = UUID(uuidString: stored) { return uuid }
        return IAMRole.fromOrganizationRole(stored)?.seededID
    }
}
