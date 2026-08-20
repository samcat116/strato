import ControlPlanePostgres
import Foundation
import Vapor

struct GroupController: RouteCollection {
    private let groups: GroupsPersistence

    init(groups: GroupsPersistence) {
        self.groups = groups
    }

    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("api", "organizations")
        organizations.group(":organizationID") { organization in
            let groupRoutes = organization.grouped("groups")
            groupRoutes.get(use: index)
            groupRoutes.post(use: create)

            groupRoutes.group(":groupID") { group in
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

    func index(req: Request) async throws -> [GroupResponse] {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        return try await groups.groups(organizationID: organizationID).map {
            GroupResponse(from: $0.group, memberCount: $0.memberCount)
        }
    }

    func show(req: Request) async throws -> GroupResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        let groupID = try groupID(req)
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        let group = try await requireGroup(id: groupID, organizationID: organizationID)
        return GroupResponse(
            from: group,
            memberCount: try await groups.memberCount(groupID: groupID)
        )
    }

    func create(req: Request) async throws -> GroupResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        let body = try req.content.decodeValidated(CreateGroupRequest.self)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        do {
            let group = try await groups.create(
                GroupWrite(
                    organizationID: organizationID,
                    name: body.name,
                    description: body.description
                )
            )
            return GroupResponse(from: group, memberCount: 0)
        } catch GroupPersistenceError.duplicateName {
            throw Abort(.conflict, reason: "Group name already exists in this organization")
        }
    }

    func update(req: Request) async throws -> GroupResponse {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        let groupID = try groupID(req)
        let body = try req.content.decodeValidated(UpdateGroupRequest.self)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        let current = try await requireGroup(id: groupID, organizationID: organizationID)
        do {
            guard
                let updated = try await groups.replace(
                    GroupWrite(
                        id: current.id,
                        organizationID: current.organizationID,
                        name: body.name ?? current.name,
                        description: body.description ?? current.description,
                        scimProvisioned: current.scimProvisioned
                    )
                )
            else { throw Abort(.notFound, reason: "Group not found") }
            return GroupResponse(
                from: updated,
                memberCount: try await groups.memberCount(groupID: groupID)
            )
        } catch GroupPersistenceError.duplicateName {
            throw Abort(.conflict, reason: "Group name already exists in this organization")
        }
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        let groupID = try groupID(req)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        _ = try await requireGroup(id: groupID, organizationID: organizationID)
        guard try await groups.delete(id: groupID, organizationID: organizationID) else {
            throw Abort(.notFound, reason: "Group not found")
        }
        return .noContent
    }

    func getMembers(req: Request) async throws -> [GroupMemberResponse] {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        let groupID = try groupID(req)
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        _ = try await requireGroup(id: groupID, organizationID: organizationID)
        return try await groups.members(groupID: groupID).map(GroupMemberResponse.init(from:))
    }

    func addMembers(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        let groupID = try groupID(req)
        let body = try req.content.decode(AddGroupMemberRequest.self)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        _ = try await requireGroup(id: groupID, organizationID: organizationID)
        let result = try await groups.addMembers(
            body.userIds,
            to: groupID,
            organizationID: organizationID
        )
        guard result.groupFound else { throw Abort(.notFound, reason: "Group not found") }
        for userID in result.ineligibleUserIDs {
            req.logger.warning(
                "Attempted to add a user who is not a member of the organization",
                metadata: [
                    "user_id": .string(userID.uuidString),
                    "organization_id": .string(organizationID.uuidString),
                ]
            )
        }
        return .ok
    }

    func removeMembers(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        let groupID = try groupID(req)
        let body = try req.content.decode(RemoveGroupMemberRequest.self)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        _ = try await requireGroup(id: groupID, organizationID: organizationID)
        let result = try await groups.removeMembers(
            body.userIds,
            from: groupID,
            organizationID: organizationID
        )
        guard result.groupFound else { throw Abort(.notFound, reason: "Group not found") }
        return .ok
    }

    func removeMember(req: Request) async throws -> HTTPStatus {
        guard req.auth.get(User.self) != nil else { throw Abort(.unauthorized) }
        let organizationID = try organizationID(req)
        let groupID = try groupID(req)
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization, group, or user ID")
        }
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        _ = try await requireGroup(id: groupID, organizationID: organizationID)
        let result = try await groups.removeMembers(
            [userID],
            from: groupID,
            organizationID: organizationID
        )
        guard result.groupFound else { throw Abort(.notFound, reason: "Group not found") }
        return .ok
    }

    private func organizationID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }
        return id
    }

    private func groupID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }
        return id
    }

    /// Keep the established HTTP distinction between a missing group and a
    /// real group addressed through the wrong organization route.
    private func requireGroup(id: UUID, organizationID: UUID) async throws -> GroupSnapshot {
        guard let group = try await groups.group(id: id) else {
            throw Abort(.notFound, reason: "Group not found")
        }
        guard group.organizationID == organizationID else {
            throw Abort(.badRequest, reason: "Group does not belong to the specified organization")
        }
        return group
    }
}
