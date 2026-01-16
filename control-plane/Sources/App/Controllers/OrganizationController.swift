import Foundation
import Vapor
import Fluent

struct OrganizationController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("api", "organizations")
        organizations.get(use: index)
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
            description: createRequest.description
        )

        try await organization.save(on: req.db)

        // Add creator as admin
        let userOrganization = UserOrganization(
            userID: user.id!,
            organizationID: organization.id!,
            role: "admin"
        )
        try await userOrganization.save(on: req.db)

        // Set as current organization if user doesn't have one
        if user.currentOrganizationId == nil {
            user.currentOrganizationId = organization.id
            try await user.save(on: req.db)
        }

        // Create organization in SpiceDB
        try await req.spicedb.writeRelationship(
            entity: "organization",
            entityId: organization.id?.uuidString ?? "",
            relation: "admin",
            subject: "user",
            subjectId: user.id?.uuidString ?? ""
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

        try await organization.delete(on: req.db)

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

        guard let targetUser = try await User.query(on: req.db)
            .filter(\.$email == addRequest.userEmail)
            .first() else {
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
        try await membership.save(on: req.db)

        // Create SpiceDB relationship
        try await req.spicedb.writeRelationship(
            entity: "organization",
            entityId: organizationID.uuidString,
            relation: addRequest.role,
            subject: "user",
            subjectId: targetUser.id?.uuidString ?? ""
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

        guard let membership = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
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

        try await membership.delete(on: req.db)

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

        guard let membership = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$organization.$id == organizationID)
            .first() else {
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

        membership.role = updateRequest.role
        try await membership.save(on: req.db)

        // Update SpiceDB relationship
        try await req.spicedb.writeRelationship(
            entity: "organization",
            entityId: organizationID.uuidString,
            relation: updateRequest.role,
            subject: "user",
            subjectId: userID.uuidString
        )

        return .ok
    }
}
