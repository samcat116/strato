import Fluent
import SQLKit
import StratoShared
import Vapor

/// Security groups: project-scoped, NIC-attached firewall rule sets realized
/// agent-side as OVN ACLs on port groups. Groups and their rules are plain
/// project resources (network-style authz); attach/detach additionally
/// requires `update` on the VM, the volume/floating-IP rule.
///
/// Rule mutations are sub-resource endpoints and rules are immutable (delete
/// + recreate to edit): whole-set PUTs would let two concurrent editors
/// silently drop each other's rules. Every rule mutation bumps the group's
/// `generation` so replayed syncs can't resurrect old ACLs.
struct SecurityGroupController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let groups = routes.grouped("api", "security-groups").grouped(User.guardMiddleware())
        groups.get(use: listGroups)
        groups.post(use: createGroup)
        groups.get(":groupId", use: getGroup)
        groups.put(":groupId", use: updateGroup)
        groups.delete(":groupId", use: deleteGroup)
        groups.post(":groupId", "rules", use: createRule)
        groups.delete(":groupId", "rules", ":ruleId", use: deleteRule)
        groups.post(":groupId", "attach", use: attachGroup)
        groups.post(":groupId", "detach", use: detachGroup)
    }

    // MARK: - CRUD

    /// GET /api/security-groups
    /// Query params: project_id (optional)
    @Sendable
    func listGroups(req: Request) async throws -> [SecurityGroupResponse] {
        _ = try req.auth.require(User.self)
        let requestedProjectId = req.query[String.self, at: "project_id"].flatMap(UUID.init(uuidString:))

        var query = SecurityGroup.query(on: req.db)
            .with(\.$rules)
            .sort(\.$name)

        // Project scoping runs for every caller, admins included: their
        // fleet-wide view comes from the tier-1 `platform-system-admin` policy
        // answering each `view_project` check, so it lands in the decision log
        // and a tier-2 guardrail can narrow it.
        var visibility: ProjectVisibility?
        if let requestedProjectId {
            let hasAccess = try await req.can("view_project", on: "project", id: requestedProjectId.uuidString)
            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }
            query = query.filter(\.$project.$id == requestedProjectId)
        } else {
            // Narrow to the projects the caller could reach, then let the
            // evaluator decide the ones that carry rows (`ProjectVisibility`).
            let resolved = try await ProjectVisibility.resolve(on: req)
            guard !resolved.reachesNoProject else { return [] }
            if let candidates = resolved.candidateProjectIDs {
                query = query.filter(\.$project.$id ~~ candidates)
            }
            visibility = resolved
        }

        var groups = try await query.all()
        if let visibility {
            groups = try await visibility.readableRows(groups, projectID: { $0.$project.id }, on: req)
        }
        // One membership query for the whole page instead of a COUNT per group.
        let groupIds = try groups.map { try $0.requireID() }
        var counts: [UUID: Int] = [:]
        if !groupIds.isEmpty {
            let memberships = try await VMInterfaceSecurityGroup.query(on: req.db)
                .filter(\.$securityGroup.$id ~~ groupIds)
                .all()
            for membership in memberships {
                counts[membership.$securityGroup.id, default: 0] += 1
            }
        }
        return try groups.map { group in
            try SecurityGroupResponse(from: group, attachmentCount: counts[group.requireID()] ?? 0)
        }
    }

    /// POST /api/security-groups
    @Sendable
    func createGroup(req: Request) async throws -> SecurityGroupResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decode(CreateSecurityGroupRequest.self)

        // Same project resolution as networks/volumes/floating IPs.
        let projectId: UUID
        if let requestProjectId = request.projectId {
            projectId = requestProjectId
        } else if let currentOrgId = user.currentOrganizationId {
            guard
                let defaultProject = try await Project.query(on: req.db)
                    .filter(\.$organization.$id == currentOrgId)
                    .first()
            else {
                throw Abort(.badRequest, reason: "No project specified and no default project found")
            }
            projectId = defaultProject.id!
        } else {
            throw Abort(.badRequest, reason: "No project specified and user has no current organization")
        }

        let hasPermission = try await req.can("create_security_group", on: "project", id: projectId.uuidString)
        guard hasPermission else {
            throw Abort(
                .forbidden, reason: "You don't have permission to create security groups in this project")
        }
        guard try await Project.find(projectId, on: req.db) != nil else {
            throw Abort(.badRequest, reason: "Project \(projectId) does not exist")
        }

        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Security group name must not be empty")
        }
        guard name != SecurityGroup.defaultGroupName else {
            throw Abort(.conflict, reason: "'\(SecurityGroup.defaultGroupName)' is reserved for the default group")
        }

        let existingCount = try await SecurityGroup.query(on: req.db)
            .filter(\.$project.$id == projectId)
            .count()
        guard existingCount < SecurityGroup.maxGroupsPerProject else {
            throw Abort(
                .forbidden,
                reason: "Security group limit reached: \(SecurityGroup.maxGroupsPerProject) groups per project")
        }

        let creatorID = user.id!
        let group = SecurityGroup(
            projectID: projectId,
            name: name,
            description: request.description,
            createdByID: creatorID
        )
        do {
            try await req.db.transaction { db in
                try await group.save(on: db)
                // Creator binding (issue #477), mirroring network create.
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: creatorID,
                    role: .admin,
                    nodeType: .securityGroup,
                    nodeID: group.id!,
                    createdBy: creatorID,
                    on: db
                )
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A security group named '\(name)' already exists in this project")
        }

        req.logger.info(
            "Security group created",
            metadata: [
                "securityGroupId": .string(group.id!.uuidString),
                "name": .string(name),
                "projectId": .string(projectId.uuidString),
            ])
        // A fresh group has no rules and no attachments.
        return try SecurityGroupResponse(from: loadedEmpty(group), attachmentCount: 0)
    }

    /// GET /api/security-groups/:groupId
    @Sendable
    func getGroup(req: Request) async throws -> SecurityGroupResponse {
        let group = try await fetchGroupWithPermission(req: req, permission: "read")
        try await group.$rules.load(on: req.db)
        let count = try await VMInterfaceSecurityGroup.query(on: req.db)
            .filter(\.$securityGroup.$id == group.requireID())
            .count()
        return try SecurityGroupResponse(from: group, attachmentCount: count)
    }

    /// PUT /api/security-groups/:groupId — name/description only; rules have
    /// their own endpoints.
    @Sendable
    func updateGroup(req: Request) async throws -> SecurityGroupResponse {
        let group = try await fetchGroupWithPermission(req: req, permission: "update")
        let request = try req.content.decode(UpdateSecurityGroupRequest.self)

        if let newName = request.name.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
            newName != group.name
        {
            guard !group.isDefault else {
                throw Abort(.conflict, reason: "The default security group cannot be renamed")
            }
            guard !newName.isEmpty else {
                throw Abort(.badRequest, reason: "Security group name must not be empty")
            }
            guard newName != SecurityGroup.defaultGroupName else {
                throw Abort(
                    .conflict, reason: "'\(SecurityGroup.defaultGroupName)' is reserved for the default group")
            }
            group.name = newName
        }
        if let description = request.description {
            group.groupDescription = description.isEmpty ? nil : description
        }

        do {
            try await group.save(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A security group named '\(group.name)' already exists in this project")
        }

        try await group.$rules.load(on: req.db)
        let count = try await VMInterfaceSecurityGroup.query(on: req.db)
            .filter(\.$securityGroup.$id == group.requireID())
            .count()
        return try SecurityGroupResponse(from: group, attachmentCount: count)
    }

    /// DELETE /api/security-groups/:groupId
    @Sendable
    func deleteGroup(req: Request) async throws -> HTTPStatus {
        let group = try await fetchGroupWithPermission(req: req, permission: "delete")
        let groupId = try group.requireID()

        guard !group.isDefault else {
            throw Abort(.conflict, reason: "The default security group cannot be deleted")
        }
        let attachments = try await VMInterfaceSecurityGroup.query(on: req.db)
            .filter(\.$securityGroup.$id == groupId)
            .count()
        guard attachments == 0 else {
            throw Abort(.conflict, reason: "Security group is attached to \(attachments) interface(s); detach first")
        }
        // Rules in *other* groups referencing this one keep their FK rows, so
        // deletion would break their address-set matches; the group's own
        // self-referencing rules cascade away and don't block.
        let references = try await SecurityGroupRule.query(on: req.db)
            .filter(\.$remoteGroup.$id == groupId)
            .filter(\.$securityGroup.$id != groupId)
            .count()
        guard references == 0 else {
            throw Abort(
                .conflict,
                reason: "Security group is referenced by \(references) rule(s) in other groups; delete those first")
        }

        do {
            try await req.db.transaction { db in
                try await group.delete(on: db)
                try await RoleBindingService.revokeAll(nodeType: .securityGroup, nodeID: groupId, on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // The pre-checks above race concurrent attach/rule-create: the FK
            // NO ACTION constraints are the authority, so a lost race surfaces
            // as the same 409 the friendly path gives.
            throw Abort(
                .conflict,
                reason: "Security group became attached or referenced while deleting; detach or delete those first")
        }

        // The group's port group drops out of the next sync's desired state
        // and the topology authority tears it down.
        await req.application.agentService.syncDesiredStateToAllAgents()
        return .noContent
    }

    // MARK: - Rules

    /// POST /api/security-groups/:groupId/rules
    @Sendable
    func createRule(req: Request) async throws -> SecurityGroupRuleResponse {
        let group = try await fetchGroupWithPermission(req: req, permission: "update")
        let groupId = try group.requireID()
        let request = try req.content.decode(CreateSecurityGroupRuleRequest.self)

        let protocolName = try await SecurityGroupService.validateRule(
            request, groupProjectID: group.$project.id, on: req.db)

        let ruleCount = try await SecurityGroupRule.query(on: req.db)
            .filter(\.$securityGroup.$id == groupId)
            .count()
        guard ruleCount < SecurityGroup.maxRulesPerGroup else {
            throw Abort(
                .forbidden,
                reason: "Rule limit reached: \(SecurityGroup.maxRulesPerGroup) rules per security group")
        }

        let rule = SecurityGroupRule(
            securityGroupID: groupId,
            direction: request.direction,
            ethertype: request.ethertype,
            protocolName: protocolName,
            portRangeMin: request.portRangeMin,
            portRangeMax: request.portRangeMax,
            remoteCIDR: request.remoteCIDR,
            remoteGroupID: request.remoteGroupId,
            description: request.description
        )
        try await req.db.transaction { db in
            try await rule.save(on: db)
            try await Self.bumpGeneration(of: groupId, on: db)
        }

        await req.application.agentService.syncDesiredStateToAllAgents()
        return try SecurityGroupRuleResponse(from: rule)
    }

    /// DELETE /api/security-groups/:groupId/rules/:ruleId
    @Sendable
    func deleteRule(req: Request) async throws -> HTTPStatus {
        let group = try await fetchGroupWithPermission(req: req, permission: "update")
        let groupId = try group.requireID()
        guard let ruleId = req.parameters.get("ruleId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid rule ID")
        }
        guard
            let rule = try await SecurityGroupRule.query(on: req.db)
                .filter(\.$id == ruleId)
                .filter(\.$securityGroup.$id == groupId)
                .first()
        else {
            throw Abort(.notFound, reason: "Rule not found in this security group")
        }

        try await req.db.transaction { db in
            try await rule.delete(on: db)
            try await Self.bumpGeneration(of: groupId, on: db)
        }

        await req.application.agentService.syncDesiredStateToAllAgents()
        return .noContent
    }

    /// Atomically increments a group's generation in SQL. A read-modify-write
    /// through the model would let two concurrent rule mutations both read N
    /// and both write N+1 — and once an agent has observed N+1 from the first
    /// sync, the second mutation's ACLs would never be written (the agent's
    /// generation guard sees "already applied"). `generation = generation + 1`
    /// makes the row's lock serialize the increments instead.
    private static func bumpGeneration(of groupId: UUID, on db: Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Generation bump requires an SQL database")
        }
        try await sql.raw(
            "UPDATE security_groups SET generation = generation + 1 WHERE id = \(bind: groupId)"
        ).run()
    }

    // MARK: - Attach / detach

    /// POST /api/security-groups/:groupId/attach
    @Sendable
    func attachGroup(req: Request) async throws -> HTTPStatus {
        let group = try await fetchGroupWithPermission(req: req, permission: "attach")
        let groupId = try group.requireID()
        let request = try req.content.decode(AttachSecurityGroupRequest.self)

        let (vm, interface) = try await resolveTargetNIC(req: req, request: request, group: group)
        let interfaceId = try interface.requireID()

        // Rolling-upgrade gate (the floating-IP rule): a pre-v20 realizing
        // agent decodes the sync but ignores both security-group fields, so
        // the API would report filtering that nothing enforces. Unplaced VMs
        // pass — the default group must be attachable before scheduling, and
        // assembly omits the fields for old agents either way (documented
        // mixed-fleet semantics).
        try await Self.assertRealizersSupportSecurityGroups(for: vm, on: req.db)

        let existing = try await VMInterfaceSecurityGroup.query(on: req.db)
            .filter(\.$interface.$id == interfaceId)
            .all()
        if existing.contains(where: { $0.$securityGroup.id == groupId }) {
            return .noContent
        }
        guard existing.count < SecurityGroup.maxGroupsPerNIC else {
            throw Abort(
                .forbidden,
                reason: "Interface already has \(SecurityGroup.maxGroupsPerNIC) security groups attached")
        }

        do {
            try await VMInterfaceSecurityGroup(interfaceID: interfaceId, securityGroupID: groupId)
                .save(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Concurrent duplicate attach: the unique pair index makes it a
            // no-op rather than an error.
            return .noContent
        }

        await req.application.agentService.syncDesiredStateToAllAgents()

        req.logger.info(
            "Security group attached",
            metadata: [
                "securityGroupId": .string(groupId.uuidString),
                "vmId": .string(request.vmId.uuidString),
                "interfaceId": .string(interfaceId.uuidString),
            ])
        return .noContent
    }

    /// POST /api/security-groups/:groupId/detach
    @Sendable
    func detachGroup(req: Request) async throws -> HTTPStatus {
        let group = try await fetchGroupWithPermission(req: req, permission: "detach")
        let groupId = try group.requireID()
        let request = try req.content.decode(AttachSecurityGroupRequest.self)

        let (_, interface) = try await resolveTargetNIC(req: req, request: request, group: group)
        let interfaceId = try interface.requireID()

        let memberships = try await VMInterfaceSecurityGroup.query(on: req.db)
            .filter(\.$interface.$id == interfaceId)
            .all()
        guard let membership = memberships.first(where: { $0.$securityGroup.id == groupId }) else {
            return .noContent
        }
        // The ≥1-group invariant: a NIC without any group would silently fall
        // out of the drop group and go unfiltered.
        guard memberships.count > 1 else {
            throw Abort(
                .conflict,
                reason: "An interface must keep at least one security group; attach another before detaching this one"
            )
        }

        try await membership.delete(on: req.db)
        await req.application.agentService.syncDesiredStateToAllAgents()

        req.logger.info(
            "Security group detached",
            metadata: [
                "securityGroupId": .string(groupId.uuidString),
                "interfaceId": .string(interfaceId.uuidString),
            ])
        return .noContent
    }

    // MARK: - Helpers

    /// Resolves the attach/detach target NIC and checks `update` on its VM —
    /// owning the group is not enough, since (de)attaching changes the VM's
    /// traffic filtering (the volume/floating-IP rule).
    private func resolveTargetNIC(
        req: Request, request: AttachSecurityGroupRequest, group: SecurityGroup
    ) async throws -> (VM, VMNetworkInterface) {
        guard let vm = try await VM.find(request.vmId, on: req.db) else {
            throw Abort(.badRequest, reason: "VM \(request.vmId) does not exist")
        }
        guard vm.$project.id == group.$project.id else {
            throw Abort(.conflict, reason: "VM belongs to a different project than the security group")
        }
        let hasVMPermission = try await req.can("update", on: "virtual_machine", id: vm.id!.uuidString)
        guard hasVMPermission else {
            throw Abort(.forbidden, reason: "You don't have permission to modify this VM")
        }

        let interfaces = try await VMNetworkInterface.query(on: req.db)
            .filter(\.$vm.$id == request.vmId)
            .sort(\.$orderIndex)
            .all()
        if let interfaceId = request.interfaceId {
            guard let match = interfaces.first(where: { $0.id == interfaceId }) else {
                throw Abort(.badRequest, reason: "Interface \(interfaceId) does not belong to VM \(request.vmId)")
            }
            return (vm, match)
        }
        guard let first = interfaces.first else {
            throw Abort(.conflict, reason: "VM has no network interfaces")
        }
        return (vm, first)
    }

    /// Refuses a placed VM whose realizing agents predate security groups:
    /// the hosting agent (which binds port-group membership) and, for a sited
    /// host, the site's network controller (which authors the ACLs). An
    /// unplaced VM passes — see the call site.
    static func assertRealizersSupportSecurityGroups(for vm: VM, on db: Database) async throws {
        guard let hypervisorId = vm.hypervisorId,
            let agentUUID = UUID(uuidString: hypervisorId),
            let host = try await Agent.find(agentUUID, on: db)
        else { return }

        var realizers = [host]
        if let siteID = host.$site.id,
            let site = try await Site.find(siteID, on: db),
            let controllerID = site.$networkControllerAgent.id,
            let controller = try await Agent.find(controllerID, on: db),
            controller.id != host.id
        {
            realizers.append(controller)
        }
        for agent in realizers {
            guard WireProtocol.supportsSecurityGroups(agent.wireProtocolVersion ?? 0) else {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent '\(agent.name)' registered with a protocol too old for security groups; upgrade it first"
                )
            }
        }
    }

    private func fetchGroupWithPermission(req: Request, permission: String) async throws -> SecurityGroup {
        guard let groupId = req.parameters.get("groupId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid security group ID")
        }
        guard let group = try await SecurityGroup.find(groupId, on: req.db) else {
            throw Abort(.notFound, reason: "Security group not found")
        }
        let allowed = try await req.can(permission, on: "security_group", id: groupId.uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this security group")
        }
        return group
    }

    /// A just-created group with its (empty) rules relation marked loaded, so
    /// the response builder can map it without a database round trip.
    private func loadedEmpty(_ group: SecurityGroup) -> SecurityGroup {
        group.$rules.value = []
        return group
    }
}
