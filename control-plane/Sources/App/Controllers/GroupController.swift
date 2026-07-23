import Foundation
import Vapor
import Fluent

struct GroupController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("api", "organizations")

        // Group routes under organization context
        organizations.group(":organizationID") { org in
            let groups = org.grouped("groups")
            groups.get(use: index)
            groups.post(use: create)

            groups.group(":groupID") { group in
                group.get(use: show)
                group.put(use: update)
                group.delete(use: delete)
                group.get("members", use: getMembers)
                group.post("members", use: addMembers)
                group.delete("members", use: removeMembers)
                group.delete("members", ":userID", use: removeMember)
            }
        }
    }

    // MARK: - Group CRUD Operations

    func index(req: Request) async throws -> [GroupResponse] {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Get all groups in the organization
        let groups = try await Group.query(on: req.db)
            .filter(\.$organization.$id, .equal, organizationID)
            .sort(\.$name)
            .all()

        var responses: [GroupResponse] = []

        for group in groups {
            let memberCount = try await group.getMemberCount(on: req.db)
            let response = GroupResponse(from: group, memberCount: memberCount)
            responses.append(response)
        }

        return responses
    }

    func show(req: Request) async throws -> GroupResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or group ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found")
        }

        // Verify group belongs to the organization
        if group.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Group does not belong to the specified organization")
        }

        let memberCount = try await group.getMemberCount(on: req.db)
        return GroupResponse(from: group, memberCount: memberCount)
    }

    func create(req: Request) async throws -> GroupResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let createRequest = try req.content.decode(CreateGroupRequest.self)

        // Verify user has admin access to organization
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        // Check for name uniqueness within organization
        let existingGroup = try await Group.query(on: req.db)
            .filter(\.$organization.$id, .equal, organizationID)
            .filter(\.$name, .equal, createRequest.name)
            .first()

        if existingGroup != nil {
            throw Abort(.conflict, reason: "Group name already exists in this organization")
        }

        // Create group
        let group = Group(
            name: createRequest.name,
            description: createRequest.description,
            organizationID: organizationID
        )

        try await group.save(on: req.db)

        return GroupResponse(from: group, memberCount: 0)
    }

    func update(req: Request) async throws -> GroupResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or group ID")
        }

        let updateRequest = try req.content.decode(UpdateGroupRequest.self)

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found")
        }

        // Verify group belongs to organization
        if group.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Group does not belong to the specified organization")
        }

        // Update fields
        if let name = updateRequest.name {
            // Check name uniqueness
            let existingGroup = try await Group.query(on: req.db)
                .filter(\.$organization.$id, .equal, organizationID)
                .filter(\.$name, .equal, name)
                .filter(\.$id, .notEqual, groupID)
                .first()

            if existingGroup != nil {
                throw Abort(.conflict, reason: "Group name already exists in this organization")
            }

            group.name = name
        }

        if let description = updateRequest.description {
            group.description = description
        }

        try await group.save(on: req.db)

        let memberCount = try await group.getMemberCount(on: req.db)
        return GroupResponse(from: group, memberCount: memberCount)
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or group ID")
        }

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found")
        }

        // Verify group belongs to organization
        if group.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Group does not belong to the specified organization")
        }

        // Mirror rows (user_groups, project_group_grants) cascade with the
        // group row; role bindings have no FK by design and must be swept by
        // principal — across every org, since a group may hold cross-org
        // bindings (issue #485).
        try await req.db.transaction { db in
            try await RoleBindingService.revokeAll(principalType: .group, principalID: groupID, on: db)
            try await group.delete(on: db)
        }
        return .noContent
    }

    // MARK: - Group Membership Operations

    func getMembers(req: Request) async throws -> [GroupMemberResponse] {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or group ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found")
        }

        // Verify group belongs to organization
        if group.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Group does not belong to the specified organization")
        }

        return try await group.getMembersWithJoinDates(on: req.db)
    }

    func addMembers(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or group ID")
        }

        let addRequest = try req.content.decode(AddGroupMemberRequest.self)

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found")
        }

        // Verify group belongs to organization
        if group.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Group does not belong to the specified organization")
        }

        // Add each user to the group
        for userID in addRequest.userIds {
            // Verify user exists and belongs to organization
            let userOrg = try await UserOrganization.query(on: req.db)
                .filter(\.$user.$id, .equal, userID)
                .filter(\.$organization.$id, .equal, organizationID)
                .first()

            guard userOrg != nil else {
                req.logger.warning(
                    "Attempted to add user \(userID) who is not a member of organization \(organizationID)")
                continue  // Skip invalid users instead of failing the entire request
            }

            try await group.addMember(userID, on: req.db)
        }

        return .ok
    }

    func removeMembers(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or group ID")
        }

        let removeRequest = try req.content.decode(RemoveGroupMemberRequest.self)

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found")
        }

        // Verify group belongs to organization
        if group.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Group does not belong to the specified organization")
        }

        // Remove each user from the group
        for userID in removeRequest.userIds {
            try await group.removeMember(userID, on: req.db)
        }

        return .ok
    }

    func removeMember(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let groupID = req.parameters.get("groupID", as: UUID.self),
            let userID = req.parameters.get("userID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization, group, or user ID")
        }

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        guard let group = try await Group.find(groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found")
        }

        // Verify group belongs to organization
        if group.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Group does not belong to the specified organization")
        }

        try await group.removeMember(userID, on: req.db)

        return .ok
    }

    // MARK: - Helper Methods

}
