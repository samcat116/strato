import ControlPlanePostgres
import Foundation
import Vapor

/// Manages direct project grants for users, groups, and workload principals.
/// Both listing and mutation operate on `role_bindings`; there is no
/// relational grant mirror.
struct ProjectMemberController: RouteCollection {
    private let groupStore: GroupsPersistence
    private let hierarchy: HierarchyPersistence
    private let iam: IAMPersistence
    private let projects: ProjectsPersistence
    private let users: UserDirectoryPersistence
    private let workloads: WorkloadsPersistence

    init(
        groups: GroupsPersistence,
        hierarchy: HierarchyPersistence,
        iam: IAMPersistence,
        projects: ProjectsPersistence,
        users: UserDirectoryPersistence,
        workloads: WorkloadsPersistence
    ) {
        self.groupStore = groups
        self.hierarchy = hierarchy
        self.iam = iam
        self.projects = projects
        self.users = users
        self.workloads = workloads
    }

    func boot(routes: RoutesBuilder) throws {
        let members = routes.grouped("api", "projects", ":projectID", "members")
        members.get(use: list)
        members.post(use: grant)
        members.patch(":userID", use: updateRole)
        members.delete(":userID", use: revoke)

        let groups = routes.grouped("api", "projects", ":projectID", "groups")
        groups.post(use: grantGroup)
        groups.delete(":groupID", use: revokeGroup)

        routes.grouped("api", "projects", ":projectID", "vm-principals")
            .get(use: listVMPrincipals)
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

    struct ProjectVMPrincipalResponse: Content {
        let id: UUID
        let name: String
        let spiffeId: String?
        let instanceIdentityPrincipalId: UUID?
        let instanceIdentityStatus: InstanceIdentityStatus
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
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectMember(projectID: project.id, on: req)
        let projectID = project.id

        let bindings = try await RoleBindingService.activeBindings(
            nodeType: .project, nodeID: projectID, using: iam)
        let userBindings = bindings.filter { $0.principalType == IAMPrincipalType.user.rawValue }
        let groupBindings = bindings.filter { $0.principalType == IAMPrincipalType.group.rawValue }
        let workloadBindings = bindings.filter { $0.principalType == IAMPrincipalType.workload.rawValue }

        var usersByID: [UUID: UserDirectorySnapshot] = [:]
        if !userBindings.isEmpty {
            for user in try await users.users(ids: userBindings.map(\.principalID)) {
                usersByID[user.id] = user
            }
        }
        var groups: [UUID: GroupSnapshot] = [:]
        if !groupBindings.isEmpty {
            for group in try await groupStore.groups(
                ids: Array(Set(groupBindings.map(\.principalID))))
            {
                groups[group.id] = group
            }
        }
        var workloadsByID: [UUID: WorkloadPrincipalSnapshot] = [:]
        if !workloadBindings.isEmpty {
            for workload in try await workloads.workloadPrincipals(
                ids: workloadBindings.map(\.principalID)
            ) {
                workloadsByID[workload.id] = workload
            }
        }

        let rootOrgID = project.rootOrganizationID
        var internalUserIDs: Set<UUID> = []
        if let rootOrgID, !usersByID.isEmpty {
            internalUserIDs = try await users.organizationMemberIDs(
                organizationID: rootOrgID,
                among: Array(usersByID.keys)
            )
        }

        let displayNames = try await RoleDisplayNames.forRoleIDs(bindings.map(\.roleID), using: iam)
        return ProjectMembersResponse(
            users: userBindings.compactMap { binding in
                guard let user = usersByID[binding.principalID] else { return nil }
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
                    external: rootOrgID != nil && group.organizationID != rootOrgID)
            },
            workloads: workloadBindings.compactMap { binding in
                guard let workload = workloadsByID[binding.principalID] else { return nil }
                return ProjectWorkloadGrantResponse(
                    registrationId: binding.principalID,
                    spiffeId: workload.spiffeID,
                    vmId: workload.vmID,
                    displayName: workload.vmName ?? workload.displayName ?? workload.spiffeID,
                    role: binding.roleID,
                    roleDisplayName: displayNames.displayName(forRoleID: binding.roleID),
                    grantedAt: binding.createdAt)
            })
    }

    /// The lightweight VM-principal inventory used by project IAM management.
    /// Unlike `GET /api/vms`, this performs no interface or enforcement
    /// hydration and returns the complete readable set in one request.
    func listVMPrincipals(req: Request) async throws -> [ProjectVMPrincipalResponse] {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectMember(projectID: project.id, on: req)
        let projectID = project.id

        let vms = try await workloads.vmPrincipals(projectID: projectID)
        let nodes = vms.map { IAMNode(type: .virtualMachine, id: $0.id) }
        let readable = try await req.canFilter("vm:read", on: nodes)
        let visible = vms.filter { vm in
            readable.contains(IAMNode(type: .virtualMachine, id: vm.id))
        }

        return visible.map { vm in
            return ProjectVMPrincipalResponse(
                id: vm.id,
                name: vm.name,
                spiffeId: vm.spiffeID,
                instanceIdentityPrincipalId: vm.principalID,
                instanceIdentityStatus: vm.principalID == nil ? .revoked : .enabled)
        }
    }

    func grant(req: Request) async throws -> Response {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectPolicyAdmin(projectID: project.id, on: req)
        let node = IAMNode(type: .project, id: project.id)
        let body = try req.content.decode(GrantMemberRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, using: iam)
        let userID = try await resolveUser(body)

        try await requireNoGrant(principalType: .user, principalID: userID, node: node)
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, using: iam, req: req)
        let proposed = ProposedBinding(
            principalType: .user, principalID: userID, roleActions: role.actions,
            roleLabel: role.displayName, node: node)

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

    func updateRole(req: Request) async throws -> Response {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectPolicyAdmin(projectID: project.id, on: req)
        let node = IAMNode(type: .project, id: project.id)
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        let body = try req.content.decode(UpdateMemberRoleRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, using: iam)

        let existing = try await RoleBindingService.activeBindings(
            principalType: .user, principalID: userID,
            nodeType: .project, nodeID: node.id, using: iam)
        guard !existing.isEmpty else { throw Abort(.notFound, reason: "User has no role on this project") }

        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .user, principalID: userID, node: node, using: iam, req: req)
        let proposed = ProposedBinding(
            principalType: .user, principalID: userID, roleActions: role.actions,
            roleLabel: role.displayName, node: node)
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

    func revoke(req: Request) async throws -> HTTPStatus {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectPolicyAdmin(projectID: project.id, on: req)
        let node = IAMNode(type: .project, id: project.id)
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        try await revokeGrant(principalType: .user, principalID: userID, node: node, req: req)
        return .noContent
    }

    func grantGroup(req: Request) async throws -> Response {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectPolicyAdmin(projectID: project.id, on: req)
        let node = IAMNode(type: .project, id: project.id)
        let body = try req.content.decode(GrantGroupRequest.self)
        let role = try await MemberRoleResolver.resolve(body.role, scopeNode: node, using: iam)
        guard try await groupStore.group(id: body.groupID) != nil else {
            throw Abort(.notFound, reason: "Group not found")
        }

        try await requireNoGrant(principalType: .group, principalID: body.groupID, node: node)
        let crossOrg = try await CrossOrgBindingGate.requireGrantPermitted(
            principalType: .group, principalID: body.groupID, node: node, using: iam, req: req)
        let proposed = ProposedBinding(
            principalType: .group, principalID: body.groupID, roleActions: role.actions,
            roleLabel: role.displayName, node: node)
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

    func revokeGroup(req: Request) async throws -> HTTPStatus {
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectPolicyAdmin(projectID: project.id, on: req)
        let node = IAMNode(type: .project, id: project.id)
        guard let groupID = req.parameters.get("groupID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid group ID")
        }
        try await revokeGrant(principalType: .group, principalID: groupID, node: node, req: req)
        return .noContent
    }

    private func requireNoGrant(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode
    ) async throws {
        let existing = try await RoleBindingService.activeBindings(
            principalType: principalType, principalID: principalID,
            nodeType: .project, nodeID: node.id, using: iam)
        guard existing.isEmpty else { throw Abort(.conflict, reason: "Principal already has a role on this project") }
    }

    private func revokeGrant(
        principalType: IAMPrincipalType, principalID: UUID, node: IAMNode, req: Request
    ) async throws {
        let crossOrg = try await CrossOrgBindingGate.isCrossOrg(
            principalType: principalType, principalID: principalID, node: node,
            using: iam)
        let roles = try await RoleBindingService.revokeExclusiveGrant(
            principalType: principalType, principalID: principalID, node: node, using: iam)
        if crossOrg {
            await CrossOrgBindingGate.recordCrossOrgEvent(
                .crossOrgRevoke, principalType: principalType, principalID: principalID,
                role: roles.first?.uuidString ?? "unknown", node: node, using: iam, req: req)
        }
    }

    private func requireProject(_ req: Request) async throws -> ProjectSnapshot {
        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }
        guard let project = try await projects.project(id: projectID) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }

    private func resolveUser(_ body: GrantMemberRequest) async throws -> UUID {
        switch (body.userID, body.userEmail?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case (.some(let id), .none), (.some(let id), .some("")):
            guard try await users.user(id: id) != nil else {
                throw Abort(.notFound, reason: "User not found")
            }
            return id
        case (.none, .some(let email)) where !email.isEmpty:
            guard let user = try await users.user(email: email) else {
                throw Abort(.notFound, reason: "User not found")
            }
            return user.id
        case (.some, .some):
            throw Abort(.badRequest, reason: "Provide either userID or userEmail, not both")
        default:
            throw Abort(.badRequest, reason: "Provide userID or userEmail")
        }
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
