import Fluent
import Foundation
import Vapor

/// Manages direct project grants for users, groups, and workload principals.
/// Both listing and mutation operate on `role_bindings`; there is no
/// relational grant mirror.
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

    struct ProjectMemberResponse: Content {
        let userId: UUID?
        let username: String
        let displayName: String
        let email: String
        let role: UUID
        let roleDisplayName: String
        let joinedAt: Date?
        let external: Bool
    }

    struct ProjectGroupGrantResponse: Content {
        let groupId: UUID?
        let name: String
        let role: UUID
        let roleDisplayName: String
        let grantedAt: Date?
        let external: Bool
    }

    struct ProjectMembersResponse: Content {
        let users: [ProjectMemberResponse]
        let groups: [ProjectGroupGrantResponse]
        let workloads: [ProjectWorkloadGrantResponse]
    }

    struct ProjectWorkloadGrantResponse: Content {
        let registrationId: UUID
        let spiffeId: String
        let vmId: UUID?
        let displayName: String
        let role: UUID
        let roleDisplayName: String
        let grantedAt: Date?
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

    func list(req: Request) async throws -> ProjectMembersResponse {
        let project = try await req.requireProject()
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)
        let projectID = try project.requireID()

        let bindings = try await RoleBindingService.activeBindings(
            nodeType: .project, nodeID: projectID, on: req.db)
        let userBindings = bindings.filter { $0.principalType == IAMPrincipalType.user.rawValue }
        let groupBindings = bindings.filter { $0.principalType == IAMPrincipalType.group.rawValue }
        let workloadBindings = bindings.filter { $0.principalType == IAMPrincipalType.workload.rawValue }

        var users: [UUID: User] = [:]
        if !userBindings.isEmpty {
            for user in try await User.query(on: req.db)
                .filter(\.$id ~~ Array(Set(userBindings.map(\.principalID))))
                .all()
            {
                users[try user.requireID()] = user
            }
        }
        var groups: [UUID: Group] = [:]
        if !groupBindings.isEmpty {
            for group in try await Group.query(on: req.db)
                .filter(\.$id ~~ Array(Set(groupBindings.map(\.principalID))))
                .all()
            {
                groups[try group.requireID()] = group
            }
        }
        var workloads: [UUID: WorkloadRegistration] = [:]
        if !workloadBindings.isEmpty {
            for workload in try await WorkloadRegistration.query(on: req.db)
                .filter(\.$id ~~ Array(Set(workloadBindings.map(\.principalID))))
                .filter(\.$kind == .workload)
                .all()
            {
                workloads[try workload.requireID()] = workload
            }
        }
        let workloadVMNames = try await GuestIdentity.names(
            forVMs: workloads.values.compactMap { $0.$vm.id }, on: req.db)

        let rootOrgID = try await project.getRootOrganizationId(on: req.db)
        var internalUserIDs: Set<UUID> = []
        if let rootOrgID, !users.isEmpty {
            internalUserIDs = Set(
                try await UserOrganization.query(on: req.db)
                    .filter(\.$organization.$id == rootOrgID)
                    .filter(\.$user.$id ~~ Array(users.keys))
                    .all()
                    .map { $0.$user.id })
        }

        let displayNames = try await RoleDisplayNames.forRoleIDs(bindings.map(\.roleID), on: req.db)
        return ProjectMembersResponse(
            users: userBindings.compactMap { binding in
                guard let user = users[binding.principalID] else { return nil }
                return ProjectMemberResponse(
                    userId: user.id,
                    username: user.username,
                    displayName: user.displayName,
                    email: user.email,
                    role: binding.roleID,
                    roleDisplayName: displayNames.displayName(forRoleID: binding.roleID),
                    joinedAt: binding.createdAt,
                    external: rootOrgID != nil && !internalUserIDs.contains(binding.principalID))
            },
            groups: groupBindings.compactMap { binding in
                guard let group = groups[binding.principalID] else { return nil }
                return ProjectGroupGrantResponse(
                    groupId: group.id,
                    name: group.name,
                    role: binding.roleID,
                    roleDisplayName: displayNames.displayName(forRoleID: binding.roleID),
                    grantedAt: binding.createdAt,
                    external: rootOrgID != nil && group.$organization.id != rootOrgID)
            },
            workloads: workloadBindings.compactMap { binding in
                guard let workload = workloads[binding.principalID] else { return nil }
                return ProjectWorkloadGrantResponse(
                    registrationId: binding.principalID,
                    spiffeId: workload.spiffeID,
                    vmId: workload.$vm.id,
                    displayName: workload.$vm.id.flatMap { workloadVMNames[$0] }
                        ?? workload.displayName ?? workload.spiffeID,
                    role: binding.roleID,
                    roleDisplayName: displayNames.displayName(forRoleID: binding.roleID),
                    grantedAt: binding.createdAt)
            })
    }

    func grant(req: Request) async throws -> Response {
        let project = try await req.requireProject()
        try await OrganizationAccessService.requireProjectPolicyAdmin(project: project, on: req)
        let node = IAMNode(type: .project, id: try project.requireID())
        let body = try req.content.decode(GrantMemberRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, on: req.db)
        let targetUser = try await resolveUser(body, on: req)
        let userID = try targetUser.requireID()

        try await requireNoGrant(principalType: .user, principalID: userID, node: node, on: req.db)
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, req: req)
        let proposed = ProposedBinding(
            principalType: .user, principalID: userID, roleActions: role.actions,
            roleLabel: role.displayName, node: node)

        try await RoleBindingService.insertExclusiveGrant(
            principalType: .user, principalID: userID, roleID: role.id, node: node,
            createdBy: req.auth.get(User.self)?.id, on: req.db)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .user, principalID: userID,
                role: role.displayName, node: node, req: req)
        }
        return try await GuardrailWriteReport.report(for: proposed, req: req)
            .encodeResponse(status: .created, for: req)
    }

    func updateRole(req: Request) async throws -> Response {
        let project = try await req.requireProject()
        try await OrganizationAccessService.requireProjectPolicyAdmin(project: project, on: req)
        let node = IAMNode(type: .project, id: try project.requireID())
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        let body = try req.content.decode(UpdateMemberRoleRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, on: req.db)

        let existing = try await RoleBindingService.activeBindings(
            principalType: .user, principalID: userID,
            nodeType: .project, nodeID: node.id, on: req.db)
        guard !existing.isEmpty else { throw Abort(.notFound, reason: "User has no role on this project") }

        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, req: req)
        let proposed = ProposedBinding(
            principalType: .user, principalID: userID, roleActions: role.actions,
            roleLabel: role.displayName, node: node)
        try await RoleBindingService.replaceExclusiveGrant(
            principalType: .user, principalID: userID, roleID: role.id, node: node,
            createdBy: req.auth.get(User.self)?.id, on: req.db)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .user, principalID: userID,
                role: role.displayName, node: node, req: req)
        }
        return try await GuardrailWriteReport.report(for: proposed, req: req)
            .encodeResponse(status: .ok, for: req)
    }

    func revoke(req: Request) async throws -> HTTPStatus {
        let project = try await req.requireProject()
        try await OrganizationAccessService.requireProjectPolicyAdmin(project: project, on: req)
        let node = IAMNode(type: .project, id: try project.requireID())
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        try await revokeGrant(principalType: .user, principalID: userID, node: node, req: req)
        return .noContent
    }

    func grantGroup(req: Request) async throws -> Response {
        let project = try await req.requireProject()
        try await OrganizationAccessService.requireProjectPolicyAdmin(project: project, on: req)
        let node = IAMNode(type: .project, id: try project.requireID())
        let body = try req.content.decode(GrantGroupRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, on: req.db)
        guard try await Group.find(body.groupID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Group not found")
        }

        try await requireNoGrant(principalType: .group, principalID: body.groupID, node: node, on: req.db)
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .group, principalID: body.groupID, node: node, req: req)
        let proposed = ProposedBinding(
            principalType: .group, principalID: body.groupID, roleActions: role.actions,
            roleLabel: role.displayName, node: node)
        try await RoleBindingService.insertExclusiveGrant(
            principalType: .group, principalID: body.groupID, roleID: role.id, node: node,
            createdBy: req.auth.get(User.self)?.id, on: req.db)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgGrant, principalType: .group, principalID: body.groupID,
                role: role.displayName, node: node, req: req)
        }
        return try await GuardrailWriteReport.report(for: proposed, req: req)
            .encodeResponse(status: .created, for: req)
    }

    func revokeGroup(req: Request) async throws -> HTTPStatus {
        let project = try await req.requireProject()
        try await OrganizationAccessService.requireProjectPolicyAdmin(project: project, on: req)
        let node = IAMNode(type: .project, id: try project.requireID())
        guard let groupID = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }
        try await revokeGrant(principalType: .group, principalID: groupID, node: node, req: req)
        return .noContent
    }

    private func requireNoGrant(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode, on db: any Database
    ) async throws {
        let existing = try await RoleBindingService.activeBindings(
            principalType: principalType, principalID: principalID,
            nodeType: .project, nodeID: node.id, on: db)
        guard existing.isEmpty else { throw Abort(.conflict, reason: "Principal already has a role on this project") }
    }

    private func revokeGrant(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode, req: Request
    ) async throws {
        let crossOrg = try await CrossOrgBindingGate.isCrossOrg(
            principalType: principalType, principalID: principalID, node: node, on: req.db)
        let roles = try await RoleBindingService.revokeExclusiveGrant(
            principalType: principalType, principalID: principalID, node: node, on: req.db)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgRevoke, principalType: principalType, principalID: principalID,
                role: roles.first?.uuidString ?? "unknown", node: node, req: req)
        }
    }

    private func resolveUser(_ body: GrantMemberRequest, on req: Request) async throws -> User {
        switch (body.userID, body.userEmail?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case (.some(let id), .none), (.some(let id), .some("")):
            guard let user = try await User.find(id, on: req.db) else {
                throw Abort(.notFound, reason: "User not found")
            }
            return user
        case (.none, .some(let email)) where !email.isEmpty:
            guard let user = try await User.query(on: req.db).filter(\.$email == email).first() else {
                throw Abort(.notFound, reason: "User not found")
            }
            return user
        case (.some, .some):
            throw Abort(.badRequest, reason: "Provide either userID or userEmail, not both")
        default:
            throw Abort(.badRequest, reason: "Provide userID or userEmail")
        }
    }
}
