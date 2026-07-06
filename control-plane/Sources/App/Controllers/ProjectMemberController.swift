import Fluent
import Vapor
import Foundation

/// Manages project-level role grants for users and groups. SpiceDB is the source of
/// truth for authorization; the `ProjectMember` / `ProjectGroupGrant` tables mirror
/// the grants so the members list renders from a fast relational query.
///
/// Listing requires `view_project`; all mutations require `manage_project` (enforced
/// via `OrganizationAccessService`, which delegates to SpiceDB).
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
        let role: String
        let joinedAt: Date?
    }

    struct ProjectGroupGrantResponse: Content {
        let groupId: UUID?
        let name: String
        let role: String
        let grantedAt: Date?
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

        return ProjectMembersResponse(
            users: members.map {
                ProjectMemberResponse(
                    userId: $0.user.id,
                    username: $0.user.username,
                    displayName: $0.user.displayName,
                    email: $0.user.email,
                    role: $0.role,
                    joinedAt: $0.createdAt
                )
            },
            groups: groupGrants.map {
                ProjectGroupGrantResponse(
                    groupId: $0.group.id,
                    name: $0.group.name,
                    role: $0.role,
                    grantedAt: $0.createdAt
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
        let role = try validatedRole(body.role)
        let targetUser = try await resolveUser(body, on: req)
        let userID = try targetUser.requireID()

        let existing = try await ProjectMember.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$user.$id == userID)
            .first()
        if existing != nil {
            throw Abort(.conflict, reason: "User already has a role on this project")
        }

        try await ProjectMember(projectID: projectID, userID: userID, role: role.rawValue).save(on: req.db)
        try await req.spicedb.setProjectRole(
            userID: userID.uuidString,
            projectID: projectID.uuidString,
            oldRole: nil,
            newRole: role.rawValue
        )
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
        let role = try validatedRole(body.role)

        guard
            let membership = try await ProjectMember.query(on: req.db)
                .filter(\.$project.$id == projectID)
                .filter(\.$user.$id == userID)
                .first()
        else {
            throw Abort(.notFound, reason: "User has no role on this project")
        }

        let previousRole = membership.role
        membership.role = role.rawValue
        try await membership.save(on: req.db)

        try await req.spicedb.setProjectRole(
            userID: userID.uuidString,
            projectID: projectID.uuidString,
            oldRole: previousRole,
            newRole: role.rawValue
        )
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

        let role = membership.role
        try await membership.delete(on: req.db)
        try await req.spicedb.removeProjectMember(
            userID: userID.uuidString,
            projectID: projectID.uuidString,
            role: role
        )
        return .noContent
    }

    /// POST /api/projects/:projectID/groups — grant a group a role on the project.
    func grantGroup(req: Request) async throws -> HTTPStatus {
        let project = try await loadProject(req)
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        let projectID = try project.requireID()

        let body = try req.content.decode(GrantGroupRequest.self)
        let role = try validatedRole(body.role)

        guard let group = try await Group.find(body.groupID, on: req.db) else {
            throw Abort(.notFound, reason: "Group not found")
        }
        // Keep grants within the project's organization.
        if let rootOrgID = try await project.getRootOrganizationId(on: req.db),
            group.$organization.id != rootOrgID
        {
            throw Abort(.badRequest, reason: "Group belongs to a different organization")
        }

        let existing = try await ProjectGroupGrant.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$group.$id == body.groupID)
            .first()
        if existing != nil {
            throw Abort(.conflict, reason: "Group already has a role on this project")
        }

        try await ProjectGroupGrant(projectID: projectID, groupID: body.groupID, role: role.rawValue)
            .save(on: req.db)
        try await req.spicedb.addGroupToProject(
            groupID: body.groupID.uuidString,
            projectID: projectID.uuidString,
            role: role.groupRelation
        )
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

        let role = ProjectRole(rawValue: grant.role) ?? .viewer
        try await grant.delete(on: req.db)
        try await req.spicedb.removeGroupFromProject(
            groupID: groupID.uuidString,
            projectID: projectID.uuidString,
            role: role.groupRelation
        )
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

    private func validatedRole(_ raw: String) throws -> ProjectRole {
        guard let role = ProjectRole(rawValue: raw) else {
            throw Abort(.badRequest, reason: "Invalid role; must be one of: admin, member, viewer")
        }
        return role
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
