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

        // Check if user belongs to this organization
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard let userOrganization = userOrg else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }

        return OrganizationResponse(from: organization, userRole: userOrganization.role)
    }

    func create(req: Request) async throws -> OrganizationResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

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

        // Add creator as admin. IAM dual-write (issue #477): the admin role
        // binding lands in the same transaction as the mirror row; SpiceDB
        // stays authoritative.
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
        }

        // Set as current organization if user doesn't have one
        if user.currentOrganizationId == nil {
            user.currentOrganizationId = organization.id
            try await user.save(on: req.db)
        }

        // Create organization in SpiceDB. Route the admin grant through the shared
        // helper (with no previous role) so every org-role write goes through the
        // same delete-old-then-write path and can never leave a stale tuple.
        try await req.spicedb.setOrganizationRole(
            userID: user.id?.uuidString ?? "",
            organizationID: organization.id?.uuidString ?? "",
            oldRole: nil,
            newRole: "admin"
        )

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

        // Link the default project to its parent organization in SpiceDB.
        try await req.spicedb.writeRelationship(
            entity: "project",
            entityId: defaultProject.id?.uuidString ?? "",
            relation: "parent",
            subject: "organization",
            subjectId: organization.id?.uuidString ?? ""
        )

        return OrganizationResponse(from: organization, userRole: "admin")
    }

    func update(req: Request) async throws -> OrganizationResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Check if user is admin of this organization
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$role == "admin")
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Only organization admins can update organization")
        }

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
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Check if user is admin of this organization
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$role == "admin")
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Only organization admins can delete organization")
        }

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

        // IAM dual-write (issue #477): bindings have no FK to the nodes they
        // protect, so drop the org node's bindings — and those of every
        // project that cascades away with it — alongside the row.
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
        try await req.db.transaction { db in
            try await organization.delete(on: db)
            try await RoleBindingService.revokeAll(
                nodeType: .organization, nodeID: organizationID, on: db)
            for projectID in cascadedProjectIDs {
                try await RoleBindingService.revokeAll(
                    nodeType: .project, nodeID: projectID, on: db)
            }
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

        // Check if user belongs to this organization
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }

        user.currentOrganizationId = organizationID
        try await user.save(on: req.db)

        return .ok
    }

    // MARK: - Member Management

    func getMembers(req: Request) async throws -> [OrganizationMemberResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Check if user belongs to this organization
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }

        let members = try await UserOrganization.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .with(\.$user)
            .all()

        return members.map { userOrg in
            OrganizationMemberResponse(
                id: userOrg.user.id,
                username: userOrg.user.username,
                displayName: userOrg.user.displayName,
                email: userOrg.user.email,
                role: userOrg.role,
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

        // Check if current user is admin of this organization
        let userOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == currentUser.id!)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$role == "admin")
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Only organization admins can add members")
        }

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

        let membership = UserOrganization(
            userID: targetUser.id!,
            organizationID: organizationID,
            role: addRequest.role
        )
        // IAM dual-write (issue #477): org admins get an admin binding on the
        // org node; bare membership maps to no binding.
        let actorID = req.auth.get(User.self)?.id
        try await req.db.transaction { db in
            try await membership.save(on: db)
            if let bindingRole = IAMRole.fromOrganizationRole(addRequest.role) {
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: targetUser.id!,
                    role: bindingRole,
                    nodeType: .organization,
                    nodeID: organizationID,
                    createdBy: actorID,
                    on: db
                )
            }
        }

        // Create SpiceDB relationship (no previous role for a brand-new member).
        try await req.spicedb.setOrganizationRole(
            userID: targetUser.id?.uuidString ?? "",
            organizationID: organizationID.uuidString,
            oldRole: nil,
            newRole: addRequest.role
        )

        return .created
    }

    func removeMember(req: Request) async throws -> HTTPStatus {
        guard let currentUser = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }

        // Check if current user is admin of this organization
        let currentUserOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == currentUser.id!)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$role == "admin")
            .first()

        guard currentUserOrg != nil else {
            throw Abort(.forbidden, reason: "Only organization admins can remove members")
        }

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

        let removedRole = membership.role
        try await req.db.transaction { db in
            try await membership.delete(on: db)
            // IAM dual-write: drop the departing member's bindings on the org node.
            try await RoleBindingService.revoke(
                principalType: .user,
                principalID: userID,
                nodeType: .organization,
                nodeID: organizationID,
                on: db
            )
        }

        // Delete the SpiceDB tuple too, or the removed user keeps SpiceDB-granted
        // access even though their relational membership is gone.
        try await req.spicedb.removeOrganizationMember(
            userID: userID.uuidString,
            organizationID: organizationID.uuidString,
            role: removedRole
        )

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

        // Check if current user is admin of this organization
        let currentUserOrg = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == currentUser.id!)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$role == "admin")
            .first()

        guard currentUserOrg != nil else {
            throw Abort(.forbidden, reason: "Only organization admins can update member roles")
        }

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

        // Prevent changing role if this would remove the last admin
        if membership.role == "admin" && updateRequest.role != "admin" {
            let adminCount = try await UserOrganization.query(on: req.db)
                .filter(\.$organization.$id == organizationID)
                .filter(\.$role == "admin")
                .count()

            if adminCount <= 1 {
                throw Abort(.badRequest, reason: "Cannot change role of the last admin")
            }
        }

        let previousRole = membership.role
        membership.role = updateRequest.role
        let actorID = req.auth.get(User.self)?.id
        try await req.db.transaction { db in
            try await membership.save(on: db)
            // IAM dual-write: swap the role's binding atomically with the
            // mirror-row update (admin↔member changes add/remove the admin
            // binding; bare membership has none).
            if let oldBinding = IAMRole.fromOrganizationRole(previousRole) {
                try await RoleBindingService.revoke(
                    principalType: .user,
                    principalID: userID,
                    role: oldBinding,
                    nodeType: .organization,
                    nodeID: organizationID,
                    on: db
                )
            }
            if let newBinding = IAMRole.fromOrganizationRole(updateRequest.role) {
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: userID,
                    role: newBinding,
                    nodeType: .organization,
                    nodeID: organizationID,
                    createdBy: actorID,
                    on: db
                )
            }
        }

        // Update SpiceDB: delete the old role tuple before writing the new one, or
        // the stale tuple lingers and a demoted admin keeps admin permissions.
        try await req.spicedb.setOrganizationRole(
            userID: userID.uuidString,
            organizationID: organizationID.uuidString,
            oldRole: previousRole,
            newRole: updateRequest.role
        )

        return .ok
    }
}
