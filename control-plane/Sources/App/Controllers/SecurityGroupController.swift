import Fluent
import SQLKit
import StratoShared
import Vapor

/// Security groups: project-scoped, NIC-attached firewall rule sets realized
/// agent-side as OVN ACLs on port groups. Groups and their rules are plain
/// project resources (network-style authz); attach/detach additionally
/// requires `update` on the workload owning the NIC — a VM or (STR-34) a
/// sandbox — the volume/floating-IP rule.
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
    /// Query params: project_id (optional),
    /// limit/offset (optional) — select the page.
    @Sendable
    func listGroups(req: Request) async throws -> PagedResponse<SecurityGroupResponse> {
        let paging = try ListPaging.decode(from: req)
        let groups = try await visibleGroups(req: req)
        return paging.page(groups)
    }

    /// Every security group the caller may read, by name, ready for slicing.
    func visibleGroups(req: Request) async throws -> [SecurityGroupResponse] {
        _ = try req.auth.require(User.self)
        let requestedProjectId = req.query[String.self, at: "project_id"].flatMap(UUID.init(uuidString:))

        var query = SecurityGroup.query(on: req.db)
            .with(\.$rules)
            .sort(\.$name)
            .sort(\.$id)

        // Project scoping runs for every caller, admins included: their
        // fleet-wide view comes from the tier-1 `platform-system-admin` policy
        // answering each `view_project` check, so it lands in the decision log
        // and a tier-2 guardrail can narrow it.
        var visibility: ProjectVisibility?
        if let requestedProjectId {
            let hasAccess = try await req.can(
                "project:read", on: IAMNode(type: .project, id: requestedProjectId))
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
        // Two membership queries for the whole page instead of a COUNT per group.
        let groupIds = try groups.map { try $0.requireID() }
        let counts = try await SecurityGroupService.attachmentCounts(forGroups: groupIds, on: req.db)
        return try groups.map { group in
            try SecurityGroupResponse(from: group, attachmentCount: counts[group.requireID()] ?? 0)
        }
    }

    /// POST /api/security-groups
    @Sendable
    func createGroup(req: Request) async throws -> SecurityGroupResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decodeValidated(CreateSecurityGroupRequest.self)

        let project = try await req.authorizedProjectForCreate(
            requested: request.projectId,
            action: "securitygroup:create", resourceKind: "security groups")
        let projectId = try project.requireID()

        // Trimmed and bounded by `CreateSecurityGroupRequest.validate()`.
        let name = request.name
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
        let group = try await fetchGroupWithAction(req: req, action: "securitygroup:read")
        try await group.$rules.load(on: req.db)
        let count = try await SecurityGroupService.attachmentCount(
            forGroup: try group.requireID(), on: req.db)
        return try SecurityGroupResponse(from: group, attachmentCount: count)
    }

    /// PUT /api/security-groups/:groupId — name/description only; rules have
    /// their own endpoints.
    @Sendable
    func updateGroup(req: Request) async throws -> SecurityGroupResponse {
        let group = try await fetchGroupWithAction(req: req, action: "securitygroup:update")
        let request = try req.content.decodeValidated(UpdateSecurityGroupRequest.self)

        if let newName = request.name, newName != group.name {
            guard !group.isDefault else {
                throw Abort(.conflict, reason: "The default security group cannot be renamed")
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
        let count = try await SecurityGroupService.attachmentCount(
            forGroup: try group.requireID(), on: req.db)
        return try SecurityGroupResponse(from: group, attachmentCount: count)
    }

    /// DELETE /api/security-groups/:groupId
    @Sendable
    func deleteGroup(req: Request) async throws -> HTTPStatus {
        let group = try await fetchGroupWithAction(req: req, action: "securitygroup:delete")
        let groupId = try group.requireID()

        guard !group.isDefault else {
            throw Abort(.conflict, reason: "The default security group cannot be deleted")
        }
        let attachments = try await SecurityGroupService.attachmentCount(forGroup: groupId, on: req.db)
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
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Rules

    /// POST /api/security-groups/:groupId/rules
    @Sendable
    func createRule(req: Request) async throws -> SecurityGroupRuleResponse {
        let group = try await fetchGroupWithAction(req: req, action: "securitygroup:update")
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
            log: request.log ?? false,
            description: request.description
        )
        try await req.db.transaction { db in
            try await rule.save(on: db)
            try await Self.bumpGeneration(of: groupId, on: db)
        }

        await req.application.agentService.syncDesiredStateToFleet()
        return try SecurityGroupRuleResponse(from: rule)
    }

    /// DELETE /api/security-groups/:groupId/rules/:ruleId
    @Sendable
    func deleteRule(req: Request) async throws -> HTTPStatus {
        let group = try await fetchGroupWithAction(req: req, action: "securitygroup:update")
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

        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    /// Atomically increments a group's generation in SQL. A read-modify-write
    /// through the model would let two concurrent rule mutations both read N
    /// and both write N+1 — and once an agent has observed N+1 from the first
    /// sync, the second mutation's ACLs would never be written (the agent's
    /// generation guard sees "already applied"). `generation = generation + 1`
    /// makes the row's lock serialize the increments instead.
    private static func bumpGeneration(of groupId: UUID, on db: Database) async throws {
        switch try await DesiredStateGenerationWriter.advance(
            schema: SecurityGroup.schema, id: groupId, on: db)
        {
        case .applied:
            return
        case .missing:
            throw Abort(.notFound, reason: "Security group no longer exists")
        case .superseded:
            // No expected generation was supplied, so an existing row always
            // advances. Keep the impossible case loud.
            throw Abort(.internalServerError, reason: "Security-group generation did not advance")
        }
    }

    // MARK: - Attach / detach

    /// POST /api/security-groups/:groupId/attach
    @Sendable
    func attachGroup(req: Request) async throws -> HTTPStatus {
        let group = try await fetchGroupWithAction(req: req, action: "securitygroup:attach")
        let groupId = try group.requireID()
        let request = try req.content.decode(AttachSecurityGroupRequest.self)

        let target = try await resolveTargetNIC(req: req, request: request, group: group)

        // Rolling-upgrade gate (the floating-IP rule): a pre-v20 realizing
        // agent decodes the sync but ignores both security-group fields, so
        // the API would report filtering that nothing enforces. Unplaced VMs
        // pass — the default group must be attachable before scheduling, and
        // assembly omits the fields for old agents either way (documented
        // mixed-fleet semantics).
        //
        // A sandbox is gated on both halves (STR-103): its host must speak v20
        // *and* advertise sandbox networking, because only then is the NIC on
        // the wire with a port to join a port group. Enforcing the version half
        // alone — which is all that existed before the capability did — would
        // have refused attaches that were still inert while passing a v20 agent
        // that cannot realize a sandbox NIC at all.
        switch target.workload {
        case .vm(let vm):
            try await Self.assertRealizersSupportSecurityGroups(for: vm, on: req.db)
        case .sandbox(let sandbox):
            try await Self.assertSandboxNICCanBeFiltered(sandbox, on: req.db)
        }

        // Read-guard-write under one transaction and one per-NIC lock, so the
        // cap is enforced against a set that cannot move underneath it (see
        // `SecurityGroupService.lockMembership`).
        let changed: Bool
        do {
            changed = try await req.db.transaction { db -> Bool in
                try await SecurityGroupService.lockMembership(interfaceID: target.interfaceID, on: db)
                let existing = try await target.attachedGroupIDs(on: db)
                if existing.contains(groupId) { return false }
                guard existing.count < SecurityGroup.maxGroupsPerNIC else {
                    throw Abort(
                        .forbidden,
                        reason: "Interface already has \(SecurityGroup.maxGroupsPerNIC) security groups attached")
                }
                try await target.attach(groupID: groupId, on: db)
                return true
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Backstop only: the lock above already serializes duplicates, and
            // a non-Postgres database (where the advisory lock is a no-op)
            // still lands on the unique pair index. Either way a duplicate
            // attach is a no-op, not an error.
            return .noContent
        }
        guard changed else { return .noContent }

        // Only on a real change, and for both workloads: since STR-102 a
        // sandbox attach changes the group closure the topology authority
        // receives, so skipping the sync would leave the new port group
        // unrealized until the next periodic pass.
        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "Security group attached",
            metadata: [
                "securityGroupId": .string(groupId.uuidString),
                "workload": .string(target.workloadDescription),
                "interfaceId": .string(target.interfaceID.uuidString),
            ])
        return .noContent
    }

    /// POST /api/security-groups/:groupId/detach
    @Sendable
    func detachGroup(req: Request) async throws -> HTTPStatus {
        let group = try await fetchGroupWithAction(req: req, action: "securitygroup:detach")
        let groupId = try group.requireID()
        let request = try req.content.decode(AttachSecurityGroupRequest.self)

        let target = try await resolveTargetNIC(req: req, request: request, group: group)

        // One transaction and one per-NIC lock around read-guard-delete: two
        // concurrent detaches of a NIC's last two groups would otherwise both
        // observe two and both proceed, emptying the set. That state never
        // heals — see `SecurityGroupService.lockMembership`.
        let changed = try await req.db.transaction { db -> Bool in
            try await SecurityGroupService.lockMembership(interfaceID: target.interfaceID, on: db)
            let attached = try await target.attachedGroupIDs(on: db)
            guard attached.contains(groupId) else { return false }
            // The >=1-group invariant: a NIC with no groups is not "unfiltered"
            // but *unmanaged* — the spec omits the field, the agent reads that
            // as no opinion, and the port keeps its existing OVN membership
            // while the API reports an empty list.
            guard attached.count > 1 else {
                throw Abort(
                    .conflict,
                    reason:
                        "An interface must keep at least one security group; attach another before detaching this one"
                )
            }
            try await target.detach(groupID: groupId, on: db)
            return true
        }
        guard changed else { return .noContent }

        // Both workloads, for the same reason as the attach path: a detach can
        // drop the last NIC referencing a group, which retires its port group.
        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "Security group detached",
            metadata: [
                "securityGroupId": .string(groupId.uuidString),
                "workload": .string(target.workloadDescription),
                "interfaceId": .string(target.interfaceID.uuidString),
            ])
        return .noContent
    }

    // MARK: - Helpers

    /// A resolved attach/detach target: the NIC, and the workload that owns it
    /// so callers that only apply to VMs (the rolling-upgrade gate) can say so.
    /// The two workloads keep separate join tables, so membership reads and
    /// writes live here rather than being duplicated into both handlers.
    struct NICTarget {
        enum Workload {
            case vm(VM)
            case sandbox(Sandbox)
        }
        let workload: Workload
        let interfaceID: UUID

        var workloadDescription: String {
            switch workload {
            case .vm(let vm): return "vm:\(vm.id?.uuidString ?? "?")"
            case .sandbox(let sandbox): return "sandbox:\(sandbox.id?.uuidString ?? "?")"
            }
        }

        func attachedGroupIDs(on db: Database) async throws -> [UUID] {
            switch workload {
            case .vm:
                return try await VMInterfaceSecurityGroup.query(on: db)
                    .filter(\.$interface.$id == interfaceID)
                    .all()
                    .map { $0.$securityGroup.id }
            case .sandbox:
                return try await SandboxInterfaceSecurityGroup.query(on: db)
                    .filter(\.$interface.$id == interfaceID)
                    .all()
                    .map { $0.$securityGroup.id }
            }
        }

        func attach(groupID: UUID, on db: Database) async throws {
            switch workload {
            case .vm:
                try await VMInterfaceSecurityGroup(interfaceID: interfaceID, securityGroupID: groupID).save(on: db)
            case .sandbox:
                try await SandboxInterfaceSecurityGroup(interfaceID: interfaceID, securityGroupID: groupID)
                    .save(on: db)
            }
        }

        func detach(groupID: UUID, on db: Database) async throws {
            switch workload {
            case .vm:
                try await VMInterfaceSecurityGroup.query(on: db)
                    .filter(\.$interface.$id == interfaceID)
                    .filter(\.$securityGroup.$id == groupID)
                    .delete()
            case .sandbox:
                try await SandboxInterfaceSecurityGroup.query(on: db)
                    .filter(\.$interface.$id == interfaceID)
                    .filter(\.$securityGroup.$id == groupID)
                    .delete()
            }
        }
    }

    /// Resolves the attach/detach target NIC and checks `update` on the
    /// workload that owns it — owning the group is not enough, since
    /// (de)attaching changes that workload's traffic filtering (the
    /// volume/floating-IP rule).
    private func resolveTargetNIC(
        req: Request, request: AttachSecurityGroupRequest, group: SecurityGroup
    ) async throws -> NICTarget {
        switch try request.requireTarget() {
        case .vm(let vmId):
            return try await resolveVMNIC(req: req, vmId: vmId, request: request, group: group)
        case .sandbox(let sandboxId):
            return try await resolveSandboxNIC(req: req, sandboxId: sandboxId, request: request, group: group)
        }
    }

    private func resolveVMNIC(
        req: Request, vmId: UUID, request: AttachSecurityGroupRequest, group: SecurityGroup
    ) async throws -> NICTarget {
        // Owning the group is not enough, and an unreachable VM is answered as
        // absent whether it is missing or merely forbidden — see
        // `reachableVM` (issue #881).
        let vm = try await req.reachableVM(vmId, action: "vm:update")
        // After the VM check, never before: a containment refusal handed to a
        // caller who can't touch the VM would tell them it exists in another
        // project (issue #777).
        try ProjectContainment.require(
            "VM", in: vm.$project.id,
            sameProjectAs: "the security group", in: group.$project.id)

        let interfaces = try await VMNetworkInterface.query(on: req.db)
            .filter(\.$vm.$id == vmId)
            .sort(\.$orderIndex)
            .all()
        if let interfaceId = request.interfaceId {
            guard let match = interfaces.first(where: { $0.id == interfaceId }) else {
                throw Abort(.badRequest, reason: "Interface \(interfaceId) does not belong to VM \(vmId)")
            }
            return NICTarget(workload: .vm(vm), interfaceID: try match.requireID())
        }
        guard let first = interfaces.first else {
            throw Abort(.conflict, reason: "VM has no network interfaces")
        }
        return NICTarget(workload: .vm(vm), interfaceID: try first.requireID())
    }

    /// The sandbox twin. Same permission-then-containment ordering; the only
    /// structural difference is that a sandbox created without a network has
    /// no NIC at all (naming none is not an error the way it is for a VM), so
    /// "no interfaces" is an ordinary state rather than a corrupt one.
    private func resolveSandboxNIC(
        req: Request, sandboxId: UUID, request: AttachSecurityGroupRequest, group: SecurityGroup
    ) async throws -> NICTarget {
        let sandbox = try await req.authorizedSandbox(sandboxId, action: "sandbox:update")
        try ProjectContainment.require(
            "Sandbox", in: sandbox.$project.id,
            sameProjectAs: "the security group", in: group.$project.id)

        let interfaces = try await SandboxNetworkInterface.query(on: req.db)
            .filter(\.$sandbox.$id == sandboxId)
            .sort(\.$deviceName)
            .all()
        if let interfaceId = request.interfaceId {
            guard let match = interfaces.first(where: { $0.id == interfaceId }) else {
                throw Abort(.badRequest, reason: "Interface \(interfaceId) does not belong to sandbox \(sandboxId)")
            }
            return NICTarget(workload: .sandbox(sandbox), interfaceID: try match.requireID())
        }
        guard let first = interfaces.first else {
            throw Abort(.conflict, reason: "Sandbox has no network interfaces")
        }
        return NICTarget(workload: .sandbox(sandbox), interfaceID: try first.requireID())
    }

    /// Refuses a placed VM whose security groups would not actually be
    /// enforced: a realizing agent that predates security groups, or a site
    /// whose ACLs nothing would author at all (issue #833). Both come from
    /// `SecurityGroupService.realization`, so this gate and the API's
    /// `securityGroupsEnforced` indicator can never disagree. An unplaced VM
    /// passes — see the call site.
    static func assertRealizersSupportSecurityGroups(for vm: VM, on db: Database) async throws {
        try assertRealizersSupportSecurityGroups(try await SecurityGroupService.realization(for: vm, on: db))
    }

    /// The sandbox twin (STR-103), which asks one question first: a host that
    /// does not advertise sandbox networking is never sent the NIC's
    /// `NetworkSpec`, so no port exists for a port group to contain and the
    /// attach would record filtering that nothing can apply. An unplaced
    /// sandbox passes, like an unplaced VM — the project's default group is
    /// attached in the create transaction, long before scheduling.
    static func assertSandboxNICCanBeFiltered(_ sandbox: Sandbox, on db: Database) async throws {
        guard let hypervisorId = sandbox.hypervisorId,
            let hostID = UUID(uuidString: hypervisorId),
            let host = try await Agent.find(hostID, on: db)
        else { return }
        guard host.sandboxNetworkingCapable else {
            throw Abort(
                .conflict,
                reason:
                    "Agent '\(host.name)' cannot realize a sandbox NIC, so this sandbox's port does not exist "
                    + "to be filtered; it needs OVN networking, the sandbox jailer, and a guest image that "
                    + "configures the interface"
            )
        }
        try assertRealizersSupportSecurityGroups(try await SecurityGroupService.realization(host: host, on: db))
    }

    private static func assertRealizersSupportSecurityGroups(
        _ realization: SecurityGroupService.Realization
    ) throws {
        switch realization {
        case .unplaced:
            return
        case .unauthored(let refusal):
            throw refusal
        case .realizers:
            return
        }
    }

    private func fetchGroupWithAction(req: Request, action: String) async throws -> SecurityGroup {
        guard let groupId = req.parameters.get("groupId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid security group ID")
        }
        guard let group = try await SecurityGroup.find(groupId, on: req.db) else {
            throw Abort(.notFound, reason: "Security group not found")
        }
        let allowed = try await req.can(
            action, on: IAMNode(type: .securityGroup, id: groupId))
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this security group")
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
