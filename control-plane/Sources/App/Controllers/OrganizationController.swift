import ControlPlanePostgres
import Foundation
import Vapor
import Fluent

struct OrganizationController: RouteCollection {
    let groups: GroupsPersistence?
    let hierarchy: HierarchyPersistence
    let iam: IAMPersistence
    let projects: ProjectsPersistence?
    let users: UserDirectoryPersistence?

    init(
        groups: GroupsPersistence,
        hierarchy: HierarchyPersistence,
        iam: IAMPersistence,
        projects: ProjectsPersistence,
        users: UserDirectoryPersistence
    ) {
        self.groups = groups
        self.hierarchy = hierarchy
        self.iam = iam
        self.projects = projects
        self.users = users
    }

    /// Direct-method test seam for read-only organization listing.
    package init(hierarchy: HierarchyPersistence, iam: IAMPersistence) {
        groups = nil
        self.hierarchy = hierarchy
        self.iam = iam
        projects = nil
        users = nil
    }

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
        _ = try await req.requireSystemAdmin("System admin access required")

        return try await hierarchy.allOrganizations().map {
            OrganizationResponse(from: $0, userRole: nil)
        }
    }

    func index(req: Request) async throws -> [OrganizationResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        return try await hierarchy.organizations(forUser: user.requireID()).map { membership in
            OrganizationResponse(from: membership.organization, userRole: membership.roleID)
        }
    }

    func show(req: Request) async throws -> OrganizationResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let organization = try await hierarchy.organization(id: organizationID) else {
            throw Abort(.notFound)
        }

        // Authorization goes through the Cedar evaluator (via
        // OrganizationAccessService). The membership row survives only to
        // display the caller's role — nil for a system admin who isn't a member.
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        let membership = try await hierarchy.membership(
            userID: user.requireID(),
            organizationID: organizationID
        )

        return OrganizationResponse(from: organization, userRole: membership?.roleID)
    }

    func create(req: Request) async throws -> OrganizationResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        // Open by design: any authenticated user may start an organization
        // (they become its admin below). Declared so the default-deny
        // middleware's handler assertion knows this is deliberate.
        try await req.markRowScopedAuthorization()

        let createRequest = try req.content.decodeValidated(CreateOrganizationRequest.self)

        let organizationID = UUID()
        let trustDomain: String?
        if req.controlPlaneConfiguration.bool(.spireOrgTrustDomainsEnabled) == true {
            let shortID = organizationID.uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
            trustDomain = "org-\(shortID).\(req.controlPlaneConfiguration.string(.spireTrustDomain)!)"
                .lowercased()
        } else {
            trustDomain = nil
        }

        do {
            let provisioned = try await hierarchy.provisionOrganization(
                OrganizationProvisioningWrite(
                    organization: OrganizationWrite(
                        id: organizationID,
                        name: createRequest.name,
                        description: createRequest.description ?? ""
                    ),
                    creatorID: try user.requireID(),
                    administratorRoleID: IAMRole.admin.seededID,
                    projectDescription: "Default project for \(createRequest.name)",
                    siteName: "\(createRequest.name) Default Site",
                    siteDescription: "Default availability zone for \(createRequest.name)",
                    trustDomain: trustDomain
                )
            )
            return OrganizationResponse(
                from: provisioned.organization,
                userRole: IAMRole.admin.seededID
            )
        } catch HierarchyPersistenceError.duplicateOrganizationName {
            throw Abort(.conflict, reason: "Organization name already exists")
        } catch HierarchyPersistenceError.trustDomainCollision(
            let trustDomain,
            let existingOrganizationID
        ) {
            throw Abort(
                .conflict,
                reason:
                    "Trust domain \(trustDomain) is already claimed by organization \(existingOrganizationID); retry creating this organization"
            )
        }
    }

    func update(req: Request) async throws -> OrganizationResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Org-admin check through the Cedar evaluator (`org:update`).
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        let updateRequest = try req.content.decodeValidated(UpdateOrganizationRequest.self)

        do {
            guard
                let organization = try await hierarchy.updateOrganization(
                    id: organizationID,
                    name: updateRequest.name,
                    description: updateRequest.description
                )
            else { throw Abort(.notFound) }
            return OrganizationResponse(from: organization, userRole: IAMRole.admin.seededID)
        } catch HierarchyPersistenceError.duplicateOrganizationName {
            throw Abort(.conflict, reason: "Organization name already exists")
        }
    }

    /// Refuse a delete that would cascade over live workloads, naming the
    /// projects holding them so the operator knows where to look.
    private static func requireNoWorkloads(
        inProjects projectIDs: [UUID], on db: Database
    ) async throws {
        guard !projectIDs.isEmpty else { return }
        let vmProjects = try await LegacyVMStore.vms(projectIDs: projectIDs, on: db).map(\.projectID)
        let sandboxProjects = try await LegacySandboxStore.sandboxes(
            projectIDs: projectIDs, on: db).map(\.projectID)
        let blocking = Set(vmProjects + sandboxProjects)
        guard !blocking.isEmpty else { return }

        let names = try await LegacyProjectStore.projects(ids: Array(blocking), on: db)
            .map(\.name).sorted()
        throw Abort(
            .conflict,
            reason: "Cannot delete organization: \(names.joined(separator: ", ")) "
                + "still contain VMs or sandboxes. Delete or move those workloads first.")
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

        // The projects that cascade away with the organization: the workload
        // check below names them, and the roles and policies they own go with
        // them. Their *bindings* are swept inside the transaction instead, by
        // `ResourceBindingCleanup`, which re-reads this set there rather than
        // trusting a snapshot taken outside it.
        let orgProjectIDs = try await LegacyProjectStore.projects(
            organizationIDs: [organizationID], on: req.db
        ).compactMap(\.id)
        let ouIDs = try await LegacyOrganizationalUnitStore.organizationalUnits(
            organizationIDs: [organizationID], on: req.db
        ).compactMap(\.id)
        var ouProjectIDs: [UUID] = []
        if !ouIDs.isEmpty {
            ouProjectIDs = try await LegacyProjectStore.projects(
                organizationalUnitIDs: ouIDs, on: req.db
            ).compactMap(\.id)
        }
        let cascadedProjectIDs = orgProjectIDs + ouProjectIDs

        // Refuse an org whose projects still hold workloads, before touching
        // anything. The FK below is what makes this *correct* under a race;
        // this is what makes it legible — it names the projects instead of
        // surfacing a constraint violation — and it runs ahead of the user
        // updates because those are not inside the transaction and would
        // otherwise persist through a failed delete.
        try await Self.requireNoWorkloads(inProjects: cascadedProjectIDs, on: req.db)

        guard let users else {
            throw Abort(.internalServerError, reason: "User persistence is unavailable")
        }

        // Update users who have this as current organization
        let usersWithCurrentOrg = try await users.users(
            filter: UserDirectoryFilter(currentOrganizationID: organizationID)
        ).map(User.init(snapshot:))

        for user in usersWithCurrentOrg {
            _ = try await users.save(user.replacingCurrentOrganization(nil).directoryWrite)
        }
        // Roles owned by the org (or by a project cascading away with it) go
        // too — a role outliving its owner is bindable nowhere and listed
        // nowhere, while still contributing a grants-field pair to the Cedar
        // schema. That makes this a policy-set change, so it runs inside
        // `withPolicySetChange` and bumps the version when roles actually went.
        let removed = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            // Bindings first: the sweep reads the rows the delete cascades
            // away — the org node, its folders, its projects, and everything
            // each project carries (STR-137) — so it cannot run after them.
            try await ResourceBindingCleanup.revokeBindings(forDeletedOrganization: organizationID, on: db)
            // Projects cascade away with the organization, and VM rows used to
            // cascade away with them — hard-deleted by the database, with no
            // `.absent`, no operation, and no audit, leaving running guests
            // their agents could only learn about as an absence. `project_id`
            // is RESTRICT now (STR-98), so the database refuses instead;
            // translate that into an answer a caller can act on.
            do {
                _ = try await LegacyOrganizationStore.delete(id: organizationID, on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw Abort(
                    .conflict,
                    reason: "Cannot delete organization: its projects still contain VMs or sandboxes. "
                        + "Delete or move those workloads first.")
            }
            // The trust domain row deliberately outlives the organization: it
            // is the instruction to destroy the org's CA, and the reconciler
            // has to be able to read it after the org is gone. Mark it for
            // teardown rather than deleting it.
            try await OrgTrustDomainProvisioning.markForTeardown(organizationID: organizationID, on: db)
            var removedRoles = try await RoleStore.deleteOwned(
                by: .organization, ownerID: organizationID, on: db)
            var removedPolicies = try await PolicyStore.deleteOwned(
                by: .organization, ownerID: organizationID, on: db)
            for projectID in cascadedProjectIDs {
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

        guard
            try await hierarchy.setCurrentOrganization(
                userID: user.requireID(),
                organizationID: organizationID
            )
        else { throw Abort(.notFound, reason: "User not found") }

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

        let members = try await hierarchy.members(organizationID: organizationID)
        let displayNames = try await RoleDisplayNames.forRoleIDs(
            members.compactMap(\.roleID),
            using: iam
        )

        return members.map { userOrg in
            OrganizationMemberResponse(
                id: userOrg.userID,
                username: userOrg.username,
                displayName: userOrg.displayName,
                email: userOrg.email,
                role: userOrg.roleID,
                roleDisplayName: userOrg.roleID.map(displayNames.displayName(forRoleID:)),
                joinedAt: userOrg.joinedAt
            )
        }
    }

    func addMember(req: Request) async throws -> Response {
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
            let role: UUID?
        }

        let addRequest = try req.content.decode(AddMemberRequest.self)

        guard let targetUserID = try await hierarchy.userID(email: addRequest.userEmail) else {
            throw Abort(.notFound, reason: "User not found")
        }

        let node = IAMNode(type: .organization, id: organizationID)
        let resolved: MemberRoleResolver.Resolved?
        if let roleID = addRequest.role {
            resolved = try await MemberRoleResolver.resolve(roleID, scopeNode: node, using: iam)
        } else {
            resolved = nil
        }

        // Org admins (and any role granted by UUID) get a binding on the org
        // node; bare membership maps to no binding — and with no binding there
        // is nothing for a ceiling to narrow (#484).
        let proposed = resolved.map { resolved in
            ProposedBinding(
                principalType: .user,
                principalID: targetUserID,
                roleActions: resolved.actions,
                roleLabel: resolved.displayName,
                node: node
            )
        }

        let result = try await hierarchy.addMember(
            userID: targetUserID,
            organizationID: organizationID,
            roleID: resolved?.id,
            createdBy: currentUser.id
        )
        switch result {
        case .applied:
            break
        case .alreadyMember:
            throw Abort(.conflict, reason: "User is already a member of this organization")
        case .principalAlreadyBound:
            throw Abort(.conflict, reason: "Principal already has a role on this organization")
        case .organizationNotFound:
            throw Abort(.notFound, reason: "Organization not found")
        case .membershipNotFound, .lastAdministrator:
            throw Abort(.internalServerError, reason: "Unexpected organization membership state")
        }

        return try await report(for: proposed, req: req).encodeResponse(status: .created, for: req)
    }

    /// The ceiling report for a binding this write created, or the empty one
    /// when it created no binding (bare membership).
    private func report(for proposed: ProposedBinding?, req: Request) async -> GrantWriteResponse {
        guard let proposed else { return .noBinding }
        guard let groups, let projects, let users else {
            preconditionFailure("Organization mutation routes require complete persistence modules")
        }
        return await GuardrailWriteReport.report(
            for: proposed,
            using: iam,
            groups: groups,
            hierarchy: hierarchy,
            projects: projects,
            users: users,
            req: req
        )
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

        switch try await hierarchy.removeMember(
            userID: userID,
            organizationID: organizationID,
            administratorRoleID: IAMRole.admin.seededID
        ) {
        case .applied:
            break
        case .membershipNotFound:
            throw Abort(.notFound, reason: "User is not a member of this organization")
        case .lastAdministrator:
            throw Abort(.badRequest, reason: "Cannot remove the last admin from organization")
        case .organizationNotFound:
            throw Abort(.notFound, reason: "Organization not found")
        case .alreadyMember, .principalAlreadyBound:
            throw Abort(.internalServerError, reason: "Unexpected organization membership state")
        }

        return .noContent
    }

    func updateMemberRole(req: Request) async throws -> Response {
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
            let role: UUID?
        }

        let updateRequest = try req.content.decode(UpdateRoleRequest.self)

        let node = IAMNode(type: .organization, id: organizationID)
        let resolved: MemberRoleResolver.Resolved?
        if let roleID = updateRequest.role {
            resolved = try await MemberRoleResolver.resolve(roleID, scopeNode: node, using: iam)
        } else {
            resolved = nil
        }

        // Only the direction that *adds* a binding has anything to report;
        // dropping to bare membership takes access away, which no ceiling
        // bears on.
        let proposed = resolved.map { resolved in
            ProposedBinding(
                principalType: .user,
                principalID: userID,
                roleActions: resolved.actions,
                roleLabel: resolved.displayName,
                node: node
            )
        }

        switch try await hierarchy.updateMemberRole(
            userID: userID,
            organizationID: organizationID,
            roleID: resolved?.id,
            administratorRoleID: IAMRole.admin.seededID,
            createdBy: currentUser.id
        ) {
        case .applied:
            break
        case .membershipNotFound:
            throw Abort(.notFound, reason: "User is not a member of this organization")
        case .lastAdministrator:
            throw Abort(.badRequest, reason: "Cannot change role of the last admin")
        case .organizationNotFound:
            throw Abort(.notFound, reason: "Organization not found")
        case .alreadyMember, .principalAlreadyBound:
            throw Abort(.internalServerError, reason: "Unexpected organization membership state")
        }

        return try await report(for: proposed, req: req).encodeResponse(status: .ok, for: req)
    }

}

private extension OrganizationResponse {
    init(from organization: OrganizationSnapshot, userRole: UUID?) {
        self.id = organization.id
        self.name = organization.name
        self.description = organization.description
        self.createdAt = organization.createdAt
        self.userRole = userRole
    }
}
