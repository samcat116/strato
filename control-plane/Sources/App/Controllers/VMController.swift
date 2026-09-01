import Fluent
import Foundation
import SQLKit
import Vapor
import StratoShared

struct CreateVMNetworkInterfaceRequest: Content {
    let networkId: UUID?
    let networkName: String?
    let securityGroupIds: [UUID]?
    let mtu: Int?

    func validate(path: String) throws {
        guard (networkId == nil) != (networkName == nil) else {
            throw Abort(.badRequest, reason: "\(path) must specify exactly one of 'networkId' or 'networkName'")
        }
        try Validate.list(
            securityGroupIds, "\(path).securityGroupIds", max: SecurityGroup.maxGroupsPerNIC)
        if let mtu, !(68...65_535).contains(mtu) {
            throw Abort(.badRequest, reason: "\(path).mtu must be between 68 and 65535")
        }
    }
}

/// The mutable portion of a VM's guest-visible instance metadata (STR-66).
///
/// Omission leaves a field alone; an empty map/list clears it. Explicit JSON
/// `null` also decodes as omission, so callers that want to revoke every tag or
/// key must send `{}` or `[]` respectively.
struct PatchVMMetadataRequest: Content, ValidatedRequestBody {
    static let maxTags = 64
    static let maxAuthorizedKeys = 64

    var tags: [String: String]?
    var sshAuthorizedKeys: [String]?

    mutating func validate() throws {
        try Validate.stringMap(
            tags, "tags", maxEntries: Self.maxTags,
            maxKeyLength: Validate.nameLength, maxValueLength: Validate.textLength)
        if let tags {
            for (key, value) in tags {
                guard !key.isEmpty else {
                    throw Abort(.badRequest, reason: "Keys in 'tags' must not be empty")
                }
                guard !key.contains("\n"), !key.contains("\r") else {
                    throw Abort(.badRequest, reason: "Keys in 'tags' must be one line")
                }
                guard !key.contains("\0"), !value.contains("\0") else {
                    throw Abort(.badRequest, reason: "Keys and values in 'tags' must not contain NUL characters")
                }
            }
        }

        try Validate.stringList(
            sshAuthorizedKeys, "sshAuthorizedKeys", maxEntries: Self.maxAuthorizedKeys)
        if let requested = sshAuthorizedKeys {
            sshAuthorizedKeys = try requested.compactMap {
                try Validate.sshPublicKey($0, "sshAuthorizedKeys")
            }
        }
    }
}

struct VMRunCommandRequest: Content, ValidatedRequestBody {
    var command: [String]
    var env: [String: String]?
    var workingDir: String?

    mutating func validate() throws {
        guard !command.isEmpty else {
            throw Abort(.badRequest, reason: "'command' must be a non-empty array of strings")
        }
        try Validate.stringList(command, "command", maxEntries: 128)
        try Validate.stringMap(env, "env", maxEntries: 128)
        _ = try Validate.text(workingDir, "workingDir")
        guard !command[0].isEmpty else {
            throw Abort(.badRequest, reason: "The executable in 'command' must not be empty")
        }
        guard command.allSatisfy({ !$0.contains("\0") }) else {
            throw Abort(.badRequest, reason: "Entries in 'command' must not contain NUL characters")
        }
        if let env {
            for (key, value) in env {
                guard
                    !key.isEmpty, !key.contains("="), !key.contains("\0"),
                    !value.contains("\0")
                else {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Environment keys must be non-empty and contain neither '=' nor NUL; values must not contain NUL"
                    )
                }
            }
        }
        guard workingDir?.contains("\0") != true else {
            throw Abort(.badRequest, reason: "'workingDir' must not contain NUL characters")
        }
    }
}

struct VMController: RouteCollection {
    static func resolvedMetadataSource(
        _ requested: MetadataSource?, for hypervisor: HypervisorType,
        architecture: CPUArchitecture
    ) -> MetadataSource {
        if let requested {
            return requested
        }
        return hypervisor == .qemu && architecture == .x86_64 ? .imds : .iso
    }

    struct VMProjectGrantResponse: Content {
        let grant: ProjectMemberController.ProjectWorkloadGrantResponse?
    }

    /// Validates caller-supplied cloud-init user data: bounded in size and
    /// starting with a header cloud-init actually dispatches on — a payload
    /// without one (say, a script missing its shebang) would be silently
    /// ignored in the guest, so rejecting it here turns a hard-to-debug boot
    /// no-op into an immediate 400. Empty/whitespace-only input normalizes to
    /// nil; valid input is returned verbatim (the leading bytes ARE the format
    /// header, so no trimming).
    static func validatedUserData(_ userData: String?) throws -> String? {
        guard let userData, !userData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard userData.utf8.count <= CloudInitUserDataFormat.maxBytes else {
            throw Abort(
                .badRequest,
                reason: "'userData' exceeds \(CloudInitUserDataFormat.maxBytes / 1024) KiB")
        }
        guard CloudInitUserDataFormat.detect(userData) != nil else {
            throw Abort(
                .badRequest,
                reason: "'userData' must start with a cloud-init header: #cloud-config, #! (shell script), "
                    + "#include, #cloud-boothook, #part-handler, '## template: jinja', or a MIME document"
            )
        }
        return userData
    }

    /// Runs `body` again (up to `attempts` total) when it fails with a
    /// database constraint violation. Used around the VM-create transaction:
    /// two concurrent creates can race IPAM to the same address, and the
    /// loser's unique-index violation is only recoverable by rerunning the
    /// whole transaction with a fresh read of the used set. A violation that
    /// persists through every attempt propagates.
    static func retryingOnConstraintFailure<T>(
        attempts: Int = 3, _ body: () async throws -> T
    ) async throws -> T {
        precondition(attempts >= 1)
        for attempt in 1...attempts {
            do {
                return try await body()
            } catch let error as any DatabaseError where error.isConstraintFailure && attempt < attempts {
                continue
            }
        }
        preconditionFailure("unreachable: the final attempt either returns or throws")
    }

    func boot(routes: any RoutesBuilder) throws {
        let vms = routes.grouped("api", "vms")
        vms.get(use: index)
        vms.post(use: create)
        vms.group(":vmID") { vm in
            vm.get(use: show)
            vm.get("project-grant", use: projectGrant)
            vm.put(use: update)
            vm.patch(use: patchMetadata)
            vm.delete(use: delete)
            vm.post("start", use: start)
            vm.post("stop", use: stop)
            vm.post("restart", use: restart)
            vm.post("pause", use: pause)
            vm.post("resume", use: resume)
            vm.get("status", use: status)
            vm.get("operations", use: listOperations)
            vm.post("exec", use: exec)
            vm.group("actions") { actions in
                actions.post("run", use: runCommand)
            }
            vm.get("interfaces", use: listInterfaces)
            vm.post("interfaces", use: attachInterface)
            vm.group("interfaces", ":interfaceID") { interface in
                interface.delete(use: detachInterface)
                interface.post("retry", use: retryInterfaceMutation)
            }
            // Full-VM checkpoints (issue #564); handlers live in
            // VMSnapshotController.swift.
            vm.post("snapshots", use: createSnapshot)
            vm.get("snapshots", use: listSnapshots)
            vm.group("snapshots", ":snapshotID") { snapshot in
                snapshot.delete(use: deleteSnapshot)
                snapshot.post("restore", use: restoreSnapshot)
            }
        }
    }

    func listOperations(req: Request) async throws -> [OperationResponse] {
        let vm = try await fetchVMWithAction(req: req, action: "vm:read")
        let vmID = try vm.requireID()

        let limit = try req.intQuery("limit", default: 20, in: 1...100)

        return try await OperationFacade.history(
            resourceKind: .virtualMachine, resourceID: vmID, limit: limit, on: req.db)
    }

    func listInterfaces(req: Request) async throws -> [NetworkInterfaceResponse] {
        let vm = try await fetchVMWithAction(req: req, action: "vm:read")
        try await Self.loadInterfaces(for: vm, on: req.db)
        return vm.networkInterfaces.inDeviceOrder.map { NetworkInterfaceResponse(from: $0, vm: vm) }
    }

    func attachInterface(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Attaching a VM network interface")
        let vm = try await fetchVMWithAction(req: req, action: "vm:update")
        guard vm.hypervisorType == .qemu else {
            throw Abort(.conflict, reason: "Post-create network-interface changes are supported only for QEMU VMs")
        }
        let request = try req.content.decode(CreateVMNetworkInterfaceRequest.self)
        try request.validate(path: "interface")
        let projectID = vm.$project.id
        let vmID = try vm.requireID()
        let requestedGroups = try await SecurityGroupService.resolveRequestedGroupIDs(
            request.securityGroupIds, projectID: projectID, on: req.db)
        let userID = try user.requireID()

        let accepted = try await Self.retryingOnConstraintFailure {
            try await req.resourceMutation.accept(
                .attach, on: vm, actor: .user(userID), dispatch: .stateSync,
                on: req.db, app: req.application
            ) { @Sendable db in
                let agent = try await Self.requirePlacedAgentForNetworkHotplug(vm, on: db)
                let existing = try await VMNetworkInterface.query(on: db)
                    .filter(\.$vm.$id == vmID)
                    .all()
                guard existing.count < VMNetworkInterface.maxInterfacesPerVM else {
                    throw Abort(
                        .conflict,
                        reason: "A VM may retain at most \(VMNetworkInterface.maxInterfacesPerVM) network interfaces")
                }
                let used = Set(existing.map(\.orderIndex))
                guard let orderIndex = (0..<VMNetworkInterface.maxInterfacesPerVM).first(where: { !used.contains($0) })
                else {
                    throw Abort(.conflict, reason: "No free VM network-interface slot is available")
                }

                let network = try await LogicalNetworkService.resolveForWorkloadCreate(
                    requestedID: request.networkId,
                    requestedName: request.networkName,
                    projectID: projectID,
                    on: db)
                try Self.requireDHCPNetworkForHotplug(network)
                if agent.$site.id != network.$site.id {
                    throw Abort(
                        .conflict,
                        reason: "This network is pinned to a different site than the VM's agent")
                }
                if let mtu = request.mtu, network.subnet6 != nil, mtu < 1_280 {
                    throw Abort(.badRequest, reason: "interface.mtu must be at least 1280 on an IPv6 network")
                }
                let networkID = try network.requireID()
                if let hostname = vm.hostname {
                    let zones = try await DNSZoneService.registrationZones(networkIDs: [networkID], on: db)
                    _ = try await DNSZoneService.validatedExplicitHostname(
                        hostname, forVM: vmID, in: zones, on: db)
                }

                // `ResourceMutation.accept` holds the VM row lock and advances
                // the generation atomically after this closure. Its next value
                // is therefore stable here and is the generation at which the
                // agent must report this interface as applied.
                let targetGeneration = vm.generation + 1
                let interfaceID = UUID()
                let macAddress = try await MACAllocator.allocate(
                    for: .vmInterface, ownerID: interfaceID, on: db)
                let interface = VMNetworkInterface(
                    id: interfaceID,
                    vmID: vmID,
                    logicalNetworkID: networkID,
                    macAddress: macAddress.description,
                    mtu: request.mtu,
                    deviceName: "net\(orderIndex)",
                    orderIndex: orderIndex)
                interface.attachGeneration = targetGeneration
                try await interface.save(on: db)

                let groupIDs: [UUID]
                if requestedGroups.isEmpty {
                    let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                        projectID: projectID, on: db)
                    groupIDs = [try defaultGroup.requireID()]
                } else {
                    groupIDs = requestedGroups
                }
                for groupID in groupIDs {
                    try await VMInterfaceSecurityGroup(
                        interfaceID: interfaceID, securityGroupID: groupID
                    ).save(on: db)
                }

                let allocation = try await IPAMService.allocateIP(for: network, on: db)
                try await VMInterfaceAddress(
                    interfaceID: interfaceID,
                    logicalNetworkID: networkID,
                    family: .ipv4,
                    address: allocation.ipAddress,
                    prefixLength: allocation.prefixLength,
                    gateway: network.gateway
                ).save(on: db)
                if let allocation6 = try await IPAMService.allocateIPv6(for: network, on: db) {
                    try await VMInterfaceAddress(
                        interfaceID: interfaceID,
                        logicalNetworkID: networkID,
                        family: .ipv6,
                        address: allocation6.ipAddress,
                        prefixLength: allocation6.prefixLength,
                        gateway: network.gateway6
                    ).save(on: db)
                }
            }
        }
        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }

    func detachInterface(req: Request) async throws -> Response {
        try await mutateInterface(req: req, requestedKind: .detach)
    }

    func retryInterfaceMutation(req: Request) async throws -> Response {
        try await mutateInterface(req: req, requestedKind: nil)
    }

    private func mutateInterface(req: Request, requestedKind: VMOperationKind?) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM network interface")
        let vm = try await fetchVMWithAction(req: req, action: "vm:update")
        guard vm.hypervisorType == .qemu else {
            throw Abort(.conflict, reason: "Post-create network-interface changes are supported only for QEMU VMs")
        }
        guard let interfaceID = req.parameters.get("interfaceID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid interface ID")
        }
        let vmID = try vm.requireID()
        guard
            let initial = try await VMNetworkInterface.query(on: req.db)
                .filter(\.$id == interfaceID)
                .filter(\.$vm.$id == vmID)
                .first()
        else {
            throw Abort(.notFound, reason: "Network interface not found")
        }

        let kind: VMOperationKind
        if let requestedKind {
            kind = requestedKind
        } else if let failedGeneration = vm.failedGeneration,
            initial.detachGeneration == failedGeneration
        {
            kind = .detach
        } else if let failedGeneration = vm.failedGeneration,
            initial.attachGeneration == failedGeneration
        {
            kind = .attach
        } else {
            throw Abort(.conflict, reason: "This network interface has no failed mutation to retry")
        }

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            kind, on: vm, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable db in
            _ = try await Self.requirePlacedAgentForNetworkHotplug(vm, on: db)
            guard
                let interface = try await VMNetworkInterface.query(on: db)
                    .filter(\.$id == interfaceID)
                    .filter(\.$vm.$id == vmID)
                    .first()
            else {
                throw Abort(.notFound, reason: "Network interface no longer exists")
            }
            if kind == .attach {
                guard interface.detachGeneration == nil else {
                    throw Abort(.conflict, reason: "A detaching interface cannot be retried as an attach")
                }
                try await Self.requireDHCPNetworkForHotplug(
                    interface.$logicalNetwork.get(on: db))
            }
            // The row is locked by `ResourceMutation.accept`; its atomic
            // generation advance immediately after this closure will produce
            // this exact value.
            let targetGeneration = vm.generation + 1
            if kind == .detach {
                interface.detachGeneration = targetGeneration
            } else {
                interface.attachGeneration = targetGeneration
            }
            try await interface.save(on: db)
        }
        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }

    /// GET /api/vms
    /// Query params: organization_id (optional) — narrows to one org's hierarchy;
    /// limit/offset (optional) — select the page.
    func index(req: Request) async throws -> PagedResponse<VMDetailResponse> {
        let paging = try ListPaging.decode(from: req)
        let vms = try await visibleVMs(req: req)
        return paging.page(vms)
    }

    /// Every VM the caller may read, newest first, ready for slicing.
    func visibleVMs(req: Request) async throws -> [VMDetailResponse] {
        // Any authenticated principal — a user, or a service account /
        // workload authenticated by JWT-SVID (issue #495). Which VMs it may
        // actually see is `canFilter`'s answer below, not this guard's.
        _ = try req.requireActingPrincipal()

        // A VM reaches its organization through its project, so narrowing by org means
        // narrowing to that org's projects. An org with no projects matches no VMs —
        // return early rather than let an empty `~~ []` stand in for "unfiltered".
        var query = VM.query(on: req.db)
            .with(\.$networkInterfaces) {
                $0.with(\.$addresses)
                $0.with(\.$observedAddresses)
                // The response reports each NIC's network by name as well as id.
                $0.with(\.$logicalNetwork)
                // …and which security groups filter it (STR-34).
                $0.with(\.$securityGroupMemberships)
            }
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
        if let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req) {
            let projectIDs = try await orgFilter.projectIDs(on: req.db)
            if projectIDs.isEmpty { return [] }
            query = query.filter(\.$project.$id ~~ projectIDs)
        }

        // Scope the page to what the caller may read. One batched decision for
        // the whole page (#687): looping `req.can` per VM cost a full entity
        // slice and a decision-log insert each, so a hundred rows meant
        // hundreds of queries to answer one question a hundred times.
        let allVMs = try await query.all()
        let nodes = allVMs.compactMap { $0.id.map { IAMNode(type: .virtualMachine, id: $0) } }
        let readable = try await req.canFilter("vm:read", on: nodes)

        // Batched for the same reason the authorization decision is: a
        // per-row realizer walk would be three queries per VM.
        let enforcement = try await SecurityGroupService.enforcementByVM(
            allVMs,
            offlineGrace: req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
            on: req.db)

        let visible = allVMs.filter { vm in
            vm.id.map { readable.contains(IAMNode(type: .virtualMachine, id: $0)) } ?? false
        }

        // …and for the same reason again: the page's instance identities
        // (STR-55) in one query rather than one per row.
        //
        // Over `visible`, not `allVMs`: this is the one lookup here whose `IN`
        // list grows with the *fleet* rather than with the host count, so it is
        // also the one worth not widening with rows whose identity is about to
        // be discarded — and resolving an identity for a VM the caller may not
        // read is work with no reader.
        let identities = try await GuestIdentity.registrations(
            forVMs: visible.compactMap(\.id), on: req.db)

        return visible.compactMap { vm in
            guard let id = vm.id else { return nil }
            return VMDetailResponse(
                from: vm,
                securityGroupsEnforced: enforcement[id],
                spiffeId: identities[id]?.spiffeID,
                instanceIdentityPrincipalId: identities[id]?.principalID,
                instanceIdentityStatus: identities[id] == nil ? .revoked : .enabled)
        }
    }

    /// Fetch a VM by its :vmID route parameter and enforce a permission on it.
    ///
    /// Delegates to the shared `Request.authorizedVM(_:action:)` helper so the
    /// per-object authorization logic lives in one place (also used by other VM-scoped
    /// controllers such as `LogsController`).
    private func fetchVMWithAction(req: Request, action: String) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        return try await req.authorizedVM(vmID, action: action)
    }

    func show(req: Request) async throws -> VMDetailResponse {
        let vm = try await fetchVMWithAction(req: req, action: "vm:read")
        try await vm.$networkInterfaces.load(on: req.db)
        for interface in vm.networkInterfaces {
            try await interface.$addresses.load(on: req.db)
            try await interface.$observedAddresses.load(on: req.db)
            // The response reports the NIC's network by name as well as id.
            try await interface.$logicalNetwork.load(on: req.db)
            // …and which security groups filter it (STR-34).
            try await interface.$securityGroupMemberships.load(on: req.db)
        }

        let identity = try await GuestIdentity.registration(forVM: vm.requireID(), on: req.db)
        let enforcement = try await SecurityGroupService.enforcement(
            for: vm,
            offlineGrace: req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
            on: req.db)
        return VMDetailResponse(
            from: vm,
            securityGroupsEnforced: enforcement,
            spiffeId: identity?.spiffeID,
            instanceIdentityPrincipalId: identity?.principalID,
            instanceIdentityStatus: identity == nil ? .revoked : .enabled)
    }

    /// The one project role held by this VM's instance identity. This follows
    /// the VM detail authorization boundary instead of requiring visibility
    /// into the project's complete member inventory.
    func projectGrant(req: Request) async throws -> VMProjectGrantResponse {
        let vm = try await fetchVMWithAction(req: req, action: "vm:read")
        let vmID = try vm.requireID()
        guard let identity = try await GuestIdentity.registration(forVM: vmID, on: req.db) else {
            return VMProjectGrantResponse(grant: nil)
        }

        let bindings = try await RoleBindingService.activeBindings(
            principalType: .workload,
            principalID: identity.principalID,
            nodeType: .project,
            nodeID: vm.$project.id,
            on: req.db)
        guard let binding = bindings.first else {
            return VMProjectGrantResponse(grant: nil)
        }

        let displayNames = try await RoleDisplayNames.forRoleIDs([binding.roleID], on: req.db)
        return VMProjectGrantResponse(
            grant: ProjectMemberController.ProjectWorkloadGrantResponse(
                registrationId: identity.principalID,
                spiffeId: identity.spiffeID,
                vmId: vmID,
                displayName: vm.name,
                role: binding.roleID,
                roleDisplayName: displayNames.displayName(forRoleID: binding.roleID),
                grantedAt: binding.createdAt))
    }

    func create(req: Request) async throws -> Response {
        try await VMCreationWorkflow.create(req: req)
    }
    /// Updates a VM's metadata and, since issue #568, its vCPU/memory sizing.
    ///
    /// Sizing changes take one of two routes:
    ///
    /// * **Resting VM** — the new sizing is simply persisted (raising the
    ///   hot-add ceilings with it, since the next boot spawns a fresh
    ///   hypervisor process). Answers `200` with the updated VM.
    /// * **Running VM** — vCPU growth and memory changes must fit the ceilings
    ///   the running process was spawned with, so they are validated against
    ///   them, reserved against quota, and written as a desired-state change
    ///   with a generation bump. Running vCPU shrink is rejected because the
    ///   backend cannot unplug CPUs reliably. Answers `202` only for a change
    ///   the agent can apply online.
    ///
    /// Metadata-only updates keep their historical `200` + VM body.
    func update(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let existingVM = try await fetchVMWithAction(req: req, action: "vm:update")
        let existingVMID = try existingVM.requireID()
        let actor = MutationActor.user(try user.requireID())

        // Decodable rather than Content: `balloonTarget` needs to tell an
        // absent key from an explicit null, which needs a hand-written decode,
        // and Content's Encodable half has nothing to encode here.
        struct UpdateVMRequest: Decodable, ValidatedRequestBody {
            var name: String?
            /// The VM's DNS label (issue #770). Set explicitly: renaming the
            /// VM deliberately does *not* move its records, so this is the
            /// only way its name in DNS changes.
            let hostname: String?
            let description: String?
            /// Target boot vCPU count (issue #568).
            let cpu: Int?
            /// Target memory in bytes (issue #568).
            let memory: Int64?
            /// Operator balloon target in bytes (issue #567 phase 2), doubly
            /// optional so the two ways of "not a number" stay distinct:
            /// `.none` (key absent) leaves the current target alone, while
            /// `.some(nil)` (explicit null) clears it and hands the guest its
            /// whole grant back.
            let balloonTarget: Int64??
            /// The per-instance metadata kill switch (STR-185). Absent leaves
            /// it alone; this is the endpoint an operator hardening a running
            /// workload against SSRF reaches for.
            let metadataEnabled: Bool?

            enum CodingKeys: String, CodingKey {
                case name, hostname, description, cpu, memory, balloonTarget, metadataEnabled
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decodeIfPresent(String.self, forKey: .name)
                hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
                description = try c.decodeIfPresent(String.self, forKey: .description)
                cpu = try c.decodeIfPresent(Int.self, forKey: .cpu)
                memory = try c.decodeIfPresent(Int64.self, forKey: .memory)
                metadataEnabled = try c.decodeIfPresent(Bool.self, forKey: .metadataEnabled)
                balloonTarget =
                    c.contains(.balloonTarget)
                    ? .some(try c.decodeIfPresent(Int64.self, forKey: .balloonTarget)) : .none
            }

            mutating func validate() throws {
                name = try Validate.name(name)
                try Validate.text(description)
            }
        }

        let updateRequest = try req.content.decodeValidated(UpdateVMRequest.self)

        if let name = updateRequest.name {
            existingVM.name = name
        }

        let originalHostname = existingVM.hostname
        if let hostname = updateRequest.hostname {
            let vmID = try existingVM.requireID()
            let zones = try await DNSZoneService.registrationZones(vmID: vmID, on: req.db)
            existingVM.hostname = try await DNSZoneService.validatedExplicitHostname(
                hostname, forVM: vmID, in: zones, on: req.db)
        }
        // A hostname edit moves this VM's derived records, which are realized
        // by a topology authority that may not be this VM's own agent — and,
        // for a zone attached across sites, not even in its site (STR-39). So
        // it rings the fleet rather than the placement, like a zone edit. The
        // change never bumps the VM's generation: nothing about the VM itself
        // is re-realized, only the network-carried zone it registers into.
        let hostnameChanged = existingVM.hostname != originalHostname

        // Neither a hostname edit nor the metadata switch bumps the VM's
        // generation, so neither rides a mutation's own dispatch — each needs
        // an explicit nudge at whichever of the three exits below it leaves by.
        // A hostname edit is realized by a topology authority that may be
        // neither this VM's agent nor even in its site (STR-39), so it rings the
        // fleet; the kill switch is enforced entirely on the VM's own host, so
        // it rings that one. The fleet ring is a superset, which is why this is
        // `else if` rather than two independent sends.
        if let description = updateRequest.description {
            existingVM.description = description
        }

        let newCPU = updateRequest.cpu ?? existingVM.cpu
        let newMemory = updateRequest.memory ?? existingVM.memory
        let newBalloonTarget = updateRequest.balloonTarget ?? existingVM.balloonTarget
        let balloonChanged = newBalloonTarget != existingVM.balloonTarget
        guard newCPU != existingVM.cpu || newMemory != existingVM.memory || balloonChanged else {
            let metadataEnabledChanged = try await req.db.transaction { db in
                try await IdempotencyService.reserve(
                    req.idempotencyContext, actor: actor, on: db)
                guard try await existingVM.lockAndRefresh(on: db) else {
                    throw Abort(.notFound, reason: "VM no longer exists")
                }
                let changed = try await Self.applyMetadataUpdate(
                    updateRequest.metadataEnabled, to: existingVM, on: db)
                try await existingVM.save(on: db)
                try await IdempotencyService.completeSynchronousResponse(
                    req.idempotencyContext,
                    actor: actor,
                    resourceKind: .virtualMachine,
                    resourceID: existingVMID,
                    responseStatus: .ok,
                    on: db)
                return changed
            }
            await Self.nudgeAfterMetadataOrHostnameUpdate(
                hostnameChanged: hostnameChanged,
                metadataEnabledChanged: metadataEnabledChanged,
                placedAgentId: existingVM.hypervisorId,
                app: req.application)
            return try await Self.detailResponse(for: existingVM, on: req)
        }

        try Self.validateSizing(cpu: newCPU, memory: newMemory, balloonTarget: newBalloonTarget)

        guard let project = try await Project.find(existingVM.$project.id, on: req.db) else {
            throw Abort(.internalServerError, reason: "VM's project no longer exists")
        }
        // A resting VM can apply the new sizing without live-unplug support.
        // QEMU/libvirt still has a persistent definition to update, so this
        // generation must reach the placed agent before it is converged.
        guard existingVM.status == .running else {
            guard existingVM.status == .created || existingVM.status == .shutdown || existingVM.status == .error
            else {
                throw Abort(
                    .conflict,
                    reason: "A VM can only be resized while it is running or stopped (this one is "
                        + "\(existingVM.status.rawValue))")
            }
            try await Self.requirePlacedResizeCapacity(
                vm: existingVM, newCPU: newCPU, newMemory: newMemory, on: req)
            try await req.db.transaction { db in
                try await IdempotencyService.reserve(
                    req.idempotencyContext, actor: actor, on: db)
                guard try await existingVM.lockAndRefresh(on: db) else {
                    throw Abort(.notFound, reason: "VM no longer exists")
                }
                let committed = try await Self.committedVMSizing(existingVMID, on: db)
                let lockedCPU = updateRequest.cpu ?? committed.cpu
                let lockedMemory = updateRequest.memory ?? committed.memory
                let lockedBalloonTarget = updateRequest.balloonTarget ?? committed.balloonTarget
                try Self.validateSizing(
                    cpu: lockedCPU, memory: lockedMemory, balloonTarget: lockedBalloonTarget)
                _ = try await Self.applyMetadataUpdate(
                    updateRequest.metadataEnabled, to: existingVM, on: db)
                try await QuotaEnforcementService.reserveVMResize(
                    for: project, environment: existingVM.environment,
                    vcpuDelta: lockedCPU - committed.cpu,
                    memoryDelta: lockedMemory - committed.memory, on: db)
                existingVM.cpu = lockedCPU
                existingVM.memory = lockedMemory
                existingVM.balloonTarget = lockedBalloonTarget
                existingVM.maxCpu = max(committed.maxCPU, lockedCPU)
                existingVM.maxMemory = max(committed.maxMemory, lockedMemory)
                // The stopped VM still has a desired-state entry the agent
                // syncs on; bump so the new spec isn't dropped as stale.
                let expectedGeneration = existingVM.generation
                guard
                    case .applied = try await existingVM.advanceDesiredStateGeneration(
                        expectedGeneration: expectedGeneration, on: db)
                else {
                    throw Abort(
                        .internalServerError,
                        reason: "Failed to advance the locked VM generation")
                }
                try await existingVM.save(on: db)
                try await IdempotencyService.completeSynchronousResponse(
                    req.idempotencyContext,
                    actor: actor,
                    resourceKind: .virtualMachine,
                    resourceID: existingVMID,
                    responseStatus: .ok,
                    on: db)
            }
            if let placedAgentId = existingVM.hypervisorId {
                await req.application.agentService.syncDesiredState(agentId: placedAgentId)
            }
            await Self.nudgeAfterMetadataOrHostnameUpdate(
                hostnameChanged: hostnameChanged,
                // The generation sync above already carries this switch to the
                // placed agent. Only the fleet-scoped hostname nudge remains.
                metadataEnabledChanged: false,
                placedAgentId: existingVM.hypervisorId,
                app: req.application)
            return try await Self.detailResponse(for: existingVM, on: req)
        }

        // The running-resize contract is online. libvirt deliberately does
        // not attempt vCPU unplug because guest support is unreliable; writing
        // only the persistent definition would make this request look
        // converged while `virsh vcpucount --live` still showed the old count.
        // Refuse before quota or generation moves when the current desired
        // count is also known to be the live count. While another resize is
        // pending, `cpu` is only its desired value: a 2 -> 6 request followed
        // by 2 -> 4 is still growth from the last observed runtime and retains
        // ResourceMutation's last-writer-wins contract. The libvirt guard is
        // authoritative if the runtime races ahead of the control-plane report.
        if let requestedCPU = updateRequest.cpu,
            requestedCPU < existingVM.cpu,
            existingVM.conditions.converged
        {
            throw Self.runningVCPUShrinkAbort(from: existingVM.cpu, to: requestedCPU)
        }

        // Online resize: the ceilings were fixed when the process spawned, so
        // exceeding them is a `422` naming the restart as the remedy rather
        // than an operation that could never converge.
        guard newCPU <= existingVM.maxCpu else {
            throw Abort(
                .unprocessableEntity,
                reason: "This VM was started with a maximum of \(existingVM.maxCpu) vCPUs; "
                    + "restart it to grow beyond that")
        }
        guard newMemory <= existingVM.maxMemory else {
            throw Abort(
                .unprocessableEntity,
                reason: "This VM was started with a maximum of \(existingVM.maxMemory) bytes of memory; "
                    + "restart it to grow beyond that")
        }
        try await Self.requirePlacedResizeCapacity(
            vm: existingVM, newCPU: newCPU, newMemory: newMemory, on: req)
        let accepted = try await req.resourceMutation.accept(
            .resize, on: existingVM, actor: actor, dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable db in
            // `accept` took and refreshed the row lock before entering this
            // closure, so a placement that won the race is visible to the
            // capability gate and a placement still waiting must schedule
            // from the value persisted here.
            _ = try await Self.applyMetadataUpdate(
                updateRequest.metadataEnabled, to: existingVM, on: db)
            // Lock the row and recompute the deltas against what it says right
            // now. This is the one guard the dropped "operation already
            // pending" mutex was actually load-bearing for (STR-147): the
            // sizing above was read before the transaction, so two concurrent
            // resizes would each charge quota for the same delta and the
            // project would be under-counted by one of them. `accept` already
            // holds this row's lock, so the read below sees the winner's
            // committed sizing — which is what makes the delta right rather
            // than merely refused.
            let committed = try await Self.committedVMSizing(existingVMID, on: db)
            let lockedCPU = updateRequest.cpu ?? committed.cpu
            let lockedMemory = updateRequest.memory ?? committed.memory
            let lockedBalloonTarget = updateRequest.balloonTarget ?? committed.balloonTarget
            try Self.validateSizing(
                cpu: lockedCPU, memory: lockedMemory, balloonTarget: lockedBalloonTarget)
            try await QuotaEnforcementService.reserveVMResize(
                for: project, environment: existingVM.environment,
                vcpuDelta: lockedCPU - committed.cpu,
                memoryDelta: lockedMemory - committed.memory, on: db)
            existingVM.cpu = lockedCPU
            existingVM.memory = lockedMemory
            // Deliberately not a quota movement: ballooning reclaims memory
            // opportunistically, the grant the project is charged for is
            // still committed, and the guest takes it all back the moment the
            // target is cleared.
            existingVM.balloonTarget = lockedBalloonTarget
            // Desired status is unchanged — this is a spec change — but the
            // generation must still advance for the agent to apply it. The
            // generation it builds on came from `accept`'s refresh, so the
            // loser of a race lands strictly above the winner rather than
            // reusing its number.
        }
        // The resize's own dispatch reaches this VM's agent and its site
        // controller — which already covers a kill-switch edge riding along,
        // since the sync it triggers is the whole desired entry. A hostname
        // edge needs the wider ring, and that is what this call is for; the
        // redundant placement ring in the other branch is harmless (identical
        // syncs diff to nothing on the agent) and keeps one exit rule.
        await Self.nudgeAfterMetadataOrHostnameUpdate(
            hostnameChanged: hostnameChanged,
            metadataEnabledChanged: false,
            placedAgentId: existingVM.hypervisorId,
            app: req.application)
        return try await Self.acceptedResponse(for: existingVM, accepted, on: req)
    }

    /// Replaces the guest-visible tags and authorized-key list without
    /// recreating or rebooting the VM (STR-66).
    ///
    /// The payload and generation advance in one row-locking transaction. A
    /// newer generation is what prevents a delayed sync from putting an older
    /// metadata document back after a rotation; the placed agent is then rung
    /// through the replica-aware desired-state doorbell so the new document
    /// lands promptly rather than waiting for its periodic fetch.
    func patchMetadata(req: Request) async throws -> Response {
        _ = try req.requireActingUser("Mutating VM instance metadata")
        let existingVM = try await fetchVMWithAction(req: req, action: "vm:update")
        let patch = try req.content.decodeValidated(PatchVMMetadataRequest.self)
        let vmID = try existingVM.requireID()

        let (updatedVM, changed) = try await req.db.transaction { db -> (VM, Bool) in
            guard try await existingVM.lockAndRefresh(on: db),
                let committed = try await VM.find(vmID, on: db)
            else {
                throw Abort(.notFound, reason: "VM no longer exists")
            }

            let nextTags = patch.tags ?? committed.tags
            let nextAuthorizedKeys = patch.sshAuthorizedKeys ?? committed.effectiveSSHAuthorizedKeys
            let changed =
                nextTags != committed.tags
                || nextAuthorizedKeys != committed.effectiveSSHAuthorizedKeys
            guard changed else { return (committed, false) }

            committed.tags = nextTags
            committed.setSSHAuthorizedKeys(nextAuthorizedKeys)
            let expectedGeneration = committed.generation
            guard
                case .applied = try await committed.advanceDesiredStateGeneration(
                    expectedGeneration: expectedGeneration, on: db)
            else {
                throw Abort(
                    .internalServerError,
                    reason: "Failed to advance the locked VM generation")
            }
            try await committed.save(on: db)
            return (committed, true)
        }

        if changed, let placedAgentId = updatedVM.hypervisorId {
            await req.application.agentService.syncDesiredState(agentId: placedAgentId)
        }
        return try await Self.detailResponse(for: updatedVM, on: req)
    }

    private static func runningVCPUShrinkAbort(from current: Int, to requested: Int) -> Abort {
        Abort(
            .unprocessableEntity,
            reason: "Cannot reduce a running VM from \(current) to \(requested) vCPUs: "
                + "live vCPU unplug is not supported. Stop the VM, resize it, then start it again; "
                + "no resize was recorded.")
    }

    private static func validateSizing(cpu: Int, memory: Int64, balloonTarget: Int64?) throws {
        guard cpu > 0 else { throw Abort(.badRequest, reason: "'cpu' must be positive") }
        guard memory > 0 else { throw Abort(.badRequest, reason: "'memory' must be positive") }
        guard cpu <= Self.maxHotpluggableCPUs else {
            throw Abort(.badRequest, reason: "'cpu' must not exceed \(Self.maxHotpluggableCPUs)")
        }
        // A stopped VM raises its own `maxMemory` to the new sizing, so this
        // one bound covers the ceiling too.
        guard memory <= WorkloadSizeLimits.maxMemoryBytes else {
            throw Abort(
                .badRequest,
                reason: "'memory' must not exceed \(WorkloadSizeLimits.maxMemoryBytes) bytes")
        }
        if let balloonTarget {
            // A target is a reclaim floor within the grant. Re-checking this
            // relation under the row lock matters when memory and balloon
            // updates race and each began from the other's old value.
            guard balloonTarget <= memory else {
                throw Abort(
                    .badRequest,
                    reason: "'balloonTarget' must not exceed the VM's memory (\(memory) bytes); "
                        + "raise 'memory' to give the guest more")
            }
            guard balloonTarget >= Self.minimumBalloonTargetBytes else {
                throw Abort(
                    .badRequest,
                    reason: "'balloonTarget' must be at least \(Self.minimumBalloonTargetBytes) bytes; "
                        + "a smaller target would leave the guest too little memory to stay alive")
            }
        }
    }

    /// Rejects a placed resize before quota, sizing, or generation mutate.
    /// The node repeats this decision authoritatively; this last-reported check
    /// keeps requests that are already impossible out of reconciliation.
    private static func requirePlacedResizeCapacity(
        vm: VM, newCPU: Int, newMemory: Int64, on req: Request
    ) async throws {
        guard let agentIDString = vm.hypervisorId else {
            // A stopped, unplaced VM is sized before placement and relies on
            // the scheduler. A running VM without a placement is inconsistent
            // and cannot safely accept host-bound growth.
            guard vm.status != .running else {
                throw Abort(.conflict, reason: "This running VM has no placed agent to validate resize capacity")
            }
            return
        }
        guard let agentID = UUID(uuidString: agentIDString),
            let agent = try await Agent.find(agentID, on: req.db)
        else {
            throw Abort(.conflict, reason: "The VM's placed agent is no longer available")
        }

        let cpuGrowth = max(0, newCPU - vm.cpu)
        let memoryGrowth: Int64
        if vm.hypervisorType == .qemu, newMemory > vm.memory {
            guard let architecture = agent.cpuArchitecture else {
                throw Abort(
                    .conflict,
                    reason: "Agent `\(agent.name)` has not reported its CPU architecture; "
                        + "QEMU resize capacity cannot be validated")
            }
            // QEMU reserves only the block-aligned hot-add region the agent can
            // realize, not the raw maxMemory request. Recompute both sides with
            // the placed host's architecture so sub-block headroom is charged
            // when a stopped resize turns it into guest memory.
            let currentReservation = QEMUMemoryReservation.reservedBytes(
                memoryBytes: vm.memory,
                maxMemoryBytes: vm.maxMemory,
                architecture: architecture)
            let requestedReservation = QEMUMemoryReservation.reservedBytes(
                memoryBytes: newMemory,
                maxMemoryBytes: max(vm.maxMemory, newMemory),
                architecture: architecture)
            memoryGrowth = max(0, requestedReservation - currentReservation)
        } else if vm.hypervisorType == .qemu {
            // Alignment can make the recomputed reservation move upward while
            // the guest grant moves downward. A true shrink never needs new
            // capacity, regardless of that representational artifact.
            memoryGrowth = 0
        } else {
            memoryGrowth = max(0, newMemory - vm.memory)
        }
        guard cpuGrowth > 0 || memoryGrowth > 0 else { return }

        let active =
            await req.application.coordination.activeReservations(agentIds: [agentIDString])[
                agentIDString] ?? .zero
        let reservedCPU = max(0, active.cpu)
        let reservedMemory = max(Int64(0), active.memory)
        let effectiveCPU = reservedCPU >= agent.availableCPU ? 0 : agent.availableCPU - reservedCPU
        let effectiveMemory = reservedMemory >= agent.availableMemory ? 0 : agent.availableMemory - reservedMemory
        guard cpuGrowth <= effectiveCPU, memoryGrowth <= effectiveMemory else {
            throw Abort(
                .conflict,
                reason: "Agent `\(agent.name)` has \(effectiveCPU) vCPUs and "
                    + "\(effectiveMemory.formattedByteSize) effectively available after active placements; "
                    + "this resize requests \(cpuGrowth) additional vCPUs and "
                    + "\(memoryGrowth.formattedByteSize) additional memory")
        }
    }

    /// Applies the metadata switch from a row-locking transaction so a racing
    /// placement or update cannot make this request save stale VM state.
    ///
    /// When the request omits the field, adopt the committed value before the
    /// whole-model save. Otherwise a request loaded before a competing switch
    /// update could silently write that update back even though it said
    /// nothing about metadata.
    private static func applyMetadataUpdate(
        _ requested: Bool?, to vm: VM, on db: any Database
    ) async throws -> Bool {
        let vmID = try vm.requireID()
        guard let committed = try await VM.find(vmID, on: db) else {
            throw Abort(.notFound, reason: "VM no longer exists")
        }
        guard let requested else {
            vm.metadataEnabled = committed.metadataEnabled
            return false
        }

        vm.metadataEnabled = requested
        return requested != committed.metadataEnabled
    }

    private static func nudgeAfterMetadataOrHostnameUpdate(
        hostnameChanged: Bool,
        metadataEnabledChanged: Bool,
        placedAgentId: String?,
        app: Application
    ) async {
        if hostnameChanged {
            await app.agentService.syncDesiredStateToFleet()
        } else if metadataEnabledChanged, let placedAgentId {
            await app.agentService.syncDesiredState(agentId: placedAgentId)
        }
    }

    /// The VM's committed sizing, read inside the mutation transaction — where
    /// `ResourceMutation.accept` already holds the row lock, so this sees what
    /// a racing resize committed rather than the request's own stale snapshot.
    ///
    /// Read here rather than adopted by `accept`'s refresh because sizing is
    /// mutation-owned state: the refresh deliberately leaves it alone so this
    /// request's explicit fields are not overwritten before they are merged.
    private static func committedVMSizing(_ id: UUID, on db: any Database) async throws -> CommittedVMSizing {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Resizing a VM requires an SQL database")
        }
        guard
            let row = try await sql.raw(
                "SELECT cpu, max_cpu, memory, max_memory, balloon_target FROM vms WHERE id = \(bind: id)"
            ).first(decoding: CommittedVMSizing.self)
        else {
            throw Abort(.notFound, reason: "VM no longer exists")
        }
        return row
    }

    private struct CommittedVMSizing: Decodable {
        let cpu: Int
        let maxCPU: Int
        let memory: Int64
        let maxMemory: Int64
        let balloonTarget: Int64?

        enum CodingKeys: String, CodingKey {
            case cpu, memory
            case maxCPU = "max_cpu"
            case maxMemory = "max_memory"
            case balloonTarget = "balloon_target"
        }
    }

    /// Upper bound on a VM's vCPU count, and so on the hotplug slots QEMU is
    /// spawned with. Well above any host Strato schedules onto, low enough
    /// that a mistyped ceiling can't produce an unbootable machine. Shared
    /// with the sandbox path, which bounds its `cpus` against the same figure.
    static let maxHotpluggableCPUs = WorkloadSizeLimits.maxVCPUs

    /// Floor on an operator's balloon target (issue #567 phase 2). A guest
    /// squeezed below this has no realistic chance of staying up — the point
    /// where a mis-sized target stops being aggressive and starts being an
    /// OOM — so the API refuses it rather than reclaiming a guest to death.
    static let minimumBalloonTargetBytes: Int64 = 128 * 1024 * 1024

    /// The VM detail DTO with its NIC children loaded. The DTO, not the model:
    /// the raw `VM` encoding would expose fields that must stay server-side
    /// (cloud-init user_data can carry secrets).
    static func detailResponse(for vm: VM, on req: Request) async throws -> Response {
        try await detail(for: vm, on: req).encodeResponse(for: req)
    }

    /// - Parameter resolvingEnforcement: whether to ask whether the VM's
    ///   security groups are actually enforced. That answer costs its own
    ///   queries and means nothing for a VM being torn down, so the delete path
    ///   skips it and reports `nil` — "unknown", which is the truth there.
    static func detail(
        for vm: VM,
        on req: Request,
        resolvingEnforcement: Bool = true,
        database: (any Database)? = nil
    ) async throws -> VMDetailResponse {
        let database = database ?? req.db
        try await loadInterfaces(for: vm, on: database)
        let identity = try await GuestIdentity.registration(forVM: vm.requireID(), on: database)
        let enforcement =
            resolvingEnforcement
            ? try await SecurityGroupService.enforcement(
                for: vm,
                offlineGrace: req.controlPlaneConfiguration.double(
                    .siteControllerOfflineGraceSeconds),
                on: database) : nil
        return VMDetailResponse(
            from: vm,
            securityGroupsEnforced: enforcement,
            // Deliberately not behind `resolvingEnforcement`: that flag exists
            // because the enforcement walk costs its own queries and answers
            // nothing for a VM being torn down. This is one indexed point
            // lookup, and a client polling a delete still wants to know which
            // identity is going away.
            spiffeId: identity?.spiffeID,
            instanceIdentityPrincipalId: identity?.principalID,
            instanceIdentityStatus: identity == nil ? .revoked : .enabled)
    }

    /// The `202` body every accepted VM lifecycle mutation answers with
    /// (STR-147): the VM as the mutation left it, plus the generation its
    /// `conditions.observedGeneration` has to reach.
    ///
    /// The full detail DTO rather than a bare id — a client that just resized
    /// or started a VM re-renders from this and only then starts polling, which
    /// is one fewer round trip than the operation object ever gave it.
    /// Internal, not private: the checkpoint handlers in
    /// `VMSnapshotController.swift` extend this same type from another file and
    /// answer a restore with the VM's own accepted-mutation shape (STR-151).
    static func acceptedResponse(
        for vm: VM, _ accepted: ResourceMutation.Accepted, on req: Request,
        resolvingEnforcement: Bool = true
    ) async throws -> Response {
        try await AcceptedMutation(
            detail(for: vm, on: req, resolvingEnforcement: resolvingEnforcement), accepted
        ).acceptedResponse()
    }

    // MARK: - Exec (STR-81)

    /// `POST /api/vms/:id/actions/run`: accept a durable captured command and
    /// queue its exec stream on the replica that owns the VM's agent socket.
    func runCommand(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Running a command on a VM")
        let run = try req.content.decodeValidated(VMRunCommandRequest.self)
        let vm = try await fetchVMWithAction(req: req, action: "vm:runCommand")
        let vmID = try vm.requireID()

        guard vm.isRunning else {
            throw Abort(
                .badRequest,
                reason: "VM must be running to run a command. Current state: \(vm.status.rawValue)")
        }
        guard vm.guestAgentEnabled else {
            throw Abort(
                .badRequest,
                reason: "Running a command requires a VM created with the Strato guest agent enabled")
        }
        guard let agentIDString = vm.hypervisorId,
            let agentID = UUID(uuidString: agentIDString),
            let agent = try await Agent.find(agentID, on: req.db)
        else {
            throw Abort(.conflict, reason: "VM is not placed on an available agent")
        }
        guard agent.supportsGuestExec(for: vm.hypervisorType) else {
            throw Abort(
                .serviceUnavailable,
                reason: "Agent '\(agent.name)' does not support VM guest exec for \(vm.hypervisorType.rawValue)")
        }

        let executionID = UUID()
        let auditContext = VMGuestExecutionAudit.makeContext(
            vmID: vmID,
            projectID: vm.$project.id,
            correlationID: executionID.uuidString,
            argv: run.command,
            on: req)
        let execution = VMCommandExecution(
            id: executionID,
            vmID: vmID,
            actorID: try user.requireID(),
            agentKey: agent.identity.key,
            deadline: Date().addingTimeInterval(VMCommandExecutionService.completionBudget),
            actorUsername: auditContext.username,
            apiKeyID: auditContext.apiKeyID,
            organizationID: auditContext.organizationID,
            sourceIP: auditContext.sourceIP,
            adminBypass: auditContext.adminBypass)
        try await req.db.transaction { db in
            try await execution.create(command: run.command, on: db)
        }
        let requestedAuditRecord = VMGuestExecutionAudit.makeCommandRequestedRecord(auditContext)
        await req.audit.recordFailOpen(requestedAuditRecord)

        do {
            try await req.application.replicaBridge.deliver(
                GuestExecStartMessage(
                    resourceKind: .virtualMachine,
                    resourceId: vmID.uuidString,
                    sessionKind: .recorded,
                    sessionId: executionID.uuidString,
                    command: run.command,
                    env: run.env,
                    workingDir: run.workingDir,
                    tty: false),
                agentKey: agent.identity.key)
        } catch let error as ReplicaMessageBridge.DeliveryError where !error.isDefinitive {
            req.logger.warning(
                "VM command delivery outcome is unknown; leaving operation pending",
                metadata: [
                    "executionId": .string(executionID.uuidString),
                    "strato.agent.identity": .string(agent.identity.key),
                    "error": .string(error.localizedDescription),
                ])
        } catch {
            await req.vmCommandExecutionService.markDispatchFailed(
                id: executionID, reason: "Could not dispatch command: \(error.localizedDescription)")
        }

        guard let stored = try await VMCommandExecution.find(executionID, on: req.db) else {
            throw Abort(.internalServerError, reason: "Command execution disappeared after acceptance")
        }
        let response = Response(status: .accepted)
        try response.content.encode(try await stored.operationResponse(on: req.db))
        return response
    }

    /// `POST /api/vms/:id/exec`: mint an exec session inside a running VM.
    /// The process starts only when the caller attaches to the returned
    /// WebSocket path.
    func exec(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")

        let execRequest = try req.content.decode(GuestExecRequest.self)
        try execRequest.validate()

        let vm = try await fetchVMWithAction(req: req, action: "vm:exec")
        let vmID = try vm.requireID()

        guard vm.isRunning else {
            throw Abort(
                .badRequest,
                reason: "VM must be running to exec. Current state: \(vm.status.rawValue)")
        }

        guard vm.guestAgentEnabled else {
            throw Abort(
                .badRequest,
                reason: "VM exec requires a VM created with the Strato guest agent enabled")
        }

        guard let agentIdString = vm.hypervisorId,
            let agentId = UUID(uuidString: agentIdString)
        else {
            throw Abort(.conflict, reason: "VM is not placed on any agent")
        }

        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.internalServerError, reason: "Agent not found for VM")
        }

        // A virtio-vsock device does not prove that this agent build has the
        // node-agent bridge that speaks the guest exec protocol. Fail closed
        // until the assigned backend explicitly advertises STR-82 support;
        // otherwise every successfully minted session would be rejected by
        // the production agent after attach.
        guard agent.supportsGuestExec(for: vm.hypervisorType) else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Agent '\(agent.name)' does not support VM guest exec for \(vm.hypervisorType.rawValue)"
            )
        }

        // Exec frames flow over the agent's WebSocket, which only this
        // process can write to. If another replica holds the socket the
        // client must retry against that replica (console parity).
        guard req.application.websocketManager.getConnection(agentKey: agent.identity.key) != nil else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "Agent '\(agent.name)' is not connected to this control-plane replica; exec requires the replica holding the agent socket"
            )
        }

        let sessionId = UUID().uuidString
        let auditContext = VMGuestExecutionAudit.makeContext(
            vmID: vmID,
            projectID: vm.$project.id,
            correlationID: sessionId,
            argv: execRequest.command,
            on: req)
        let session = req.guestExecSessionManager.createPendingSession(
            sessionId: sessionId,
            resourceKind: .virtualMachine,
            resourceId: vmID.uuidString,
            agentKey: agent.identity.key,
            userId: try user.requireID().uuidString,
            command: execRequest.command,
            env: execRequest.env,
            workingDir: execRequest.workingDir,
            tty: execRequest.tty ?? false,
            rows: execRequest.rows,
            cols: execRequest.cols,
            outputMode: execRequest.outputMode ?? .raw,
            auditContext: auditContext
        )
        let requestedAuditRecord = VMGuestExecutionAudit.makeExecRequestedRecord(auditContext)
        await req.audit.recordFailOpen(requestedAuditRecord)

        let response = Response(status: .created)
        try response.content.encode(
            GuestExecSessionResponse(
                sessionId: session.sessionId,
                websocketPath: "/api/vms/\(vmID.uuidString)/exec/\(session.sessionId)/attach",
                expiresAt: session.expiresAt,
                outputMode: session.outputMode
            ))
        return response
    }

    func delete(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let vm = try await fetchVMWithAction(req: req, action: "vm:delete")

        // Deletion via state sync: desired becomes `.absent`, the VM is
        // stamped with the finalizers its teardown owes, the agent tears the
        // VM down on its next sync, and the row is removed only once the last
        // finalizer clears — for a placed VM, the `agent.absent` token the
        // observed-state report's confirmation of absence removes. So the
        // delete survives restarts on both sides. Unassigned VMs and offline
        // agents keep a direct path that force-clears that token: dead agents
        // must not make their VMs undeletable, and there is no agent to
        // confirm anything anyway.
        let vmID = try vm.requireID()
        let userID = try user.requireID()
        let app = req.application
        let agentOnline: Bool
        if let hypervisorId = vm.hypervisorId {
            agentOnline = await app.agentService.agentIsOnline(agentId: hypervisorId)
        } else {
            agentOnline = false
        }

        // Offline/unassigned: nothing will ever confirm teardown, so clear the
        // agent's finalizer here — which reaps the row, since it is the only
        // participant. If the agent ever comes back still carrying the VM, its
        // observed-state report surfaces it as an orphan for operator attention.
        let strategy: ResourceMutation.Dispatch =
            agentOnline
            ? .stateSync
            : .directResolution { @Sendable db in
                if vm.hypervisorId != nil {
                    app.logger.warning(
                        "Deleting VM record without agent teardown; agent is offline",
                        metadata: ["strato.vm.id": .string(vmID.uuidString)])
                }
                let outcome: ResourceFinalizerService.ClearOutcome
                do {
                    outcome = try await ResourceFinalizerService.abandonOfflineVM(
                        vmID: vmID, on: db, app: app)
                } catch {
                    throw ResourceMutation.WorkError(
                        "Failed to delete VM record: \(error.localizedDescription)")
                }
                // Another participant still owes cleanup: the delete is under
                // way, not done, and the reap that finally removes the row is
                // what appends the terminal event a client is waiting for.
                if case .held(let remaining) = outcome {
                    app.logger.info(
                        "VM delete is waiting on finalizers other than the agent's",
                        metadata: [
                            "strato.vm.id": .string(vmID.uuidString),
                            "finalizers": .string(remaining.joined(separator: ",")),
                        ])
                }
                return outcome.isRemoved
            }

        let accepted = try await req.resourceMutation.accept(
            .delete, on: vm, actor: .user(userID), dispatch: strategy,
            on: req.db, app: app,
            idempotencyResponseBody: { @Sendable vm, accepted, db in
                try await AcceptedMutation(
                    Self.detail(
                        for: vm, on: req, resolvingEnforcement: false, database: db),
                    accepted
                ).encodedBody()
            }
        ) { @Sendable db in
            // Stamp before the mark: `stampForDeletion` reads whether the VM
            // is already terminating, and re-stamping a second DELETE would
            // resurrect tokens their participants have already cleared.
            try await ResourceFinalizerService.stampForDeletion(vm, on: db)
            let bootVolumes = try await Volume.query(on: db)
                .filter(\.$vm.$id == vmID)
                .filter(\.$volumeType == .boot)
                .all()
            guard bootVolumes.count == 1, let bootVolume = bootVolumes.first else {
                throw Abort(
                    .internalServerError,
                    reason: "VM \(vmID) must have exactly one managed boot volume during deletion")
            }
            if !vm.finalizers.contains(ResourceFinalizer.bootVolumeAbsent.rawValue) {
                vm.finalizers.append(ResourceFinalizer.bootVolumeAbsent.rawValue)
            }
            if !bootVolume.isTerminating {
                try await ResourceFinalizerService.stampForDeletion(bootVolume, on: db)
                bootVolume.setDesiredStatus(.absent)
                let expectedGeneration = bootVolume.generation
                guard
                    case .applied = try await bootVolume.advanceDesiredStateGeneration(
                        expectedGeneration: expectedGeneration, on: db)
                else {
                    throw ConvergenceWriteError.unsupportedDatabase
                }
                try await bootVolume.save(on: db)
                _ = try await ResourceEvent.record(
                    .delete,
                    resourceKind: .volume,
                    resourceID: try bootVolume.requireID(),
                    actor: .user(userID),
                    on: db)
            }
            vm.setDesiredStatus(.absent)
        }
        // The delete path skips the enforcement lookup: a client follows a
        // delete through the operations façade with `mutationId`, so nothing
        // reads this body beyond the id, and the VM may already be reaped.
        return try await Self.acceptedResponse(
            for: vm, accepted, on: req, resolvingEnforcement: false)
    }

    func pause(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let vm = try await fetchVMWithAction(req: req, action: "vm:pause")

        guard vm.canPause else {
            throw Abort(.badRequest, reason: "VM cannot be paused in current state: \(vm.status.rawValue)")
        }

        // No transitional status exists for pause; the VM stays `.running`
        // until the agent confirms, and the in-flight state is the gap between
        // `generation` and `observedGeneration` the conditions report.
        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .pause, on: vm, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            vm.setDesiredStatus(.paused)
        }

        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }

    func resume(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let vm = try await fetchVMWithAction(req: req, action: "vm:resume")

        guard vm.canResume else {
            throw Abort(.badRequest, reason: "VM cannot be resumed in current state: \(vm.status.rawValue)")
        }

        // Counterpart of pause: the VM stays `.paused` until the agent confirms.
        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .resume, on: vm, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            vm.setDesiredStatus(.running)
        }

        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }

    func status(req: Request) async throws -> VMDetailResponse {
        let vm = try await fetchVMWithAction(req: req, action: "vm:read")

        // The database row *is* the observed state: the owning agent's
        // periodic observed-state reports keep it fresh (issue #260), so no
        // agent round-trip happens here — which also makes this endpoint
        // replica-independent (issue #261). Returned as the DTO, not the
        // model: the raw `VM` encoding would expose fields that must stay
        // server-side (cloud-init user_data can carry secrets).
        try await vm.$networkInterfaces.load(on: req.db)
        for interface in vm.networkInterfaces {
            try await interface.$addresses.load(on: req.db)
            try await interface.$observedAddresses.load(on: req.db)
            try await interface.$securityGroupMemberships.load(on: req.db)
        }
        let identity = try await GuestIdentity.registration(forVM: vm.requireID(), on: req.db)
        let enforcement = try await SecurityGroupService.enforcement(
            for: vm,
            offlineGrace: req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
            on: req.db)
        return VMDetailResponse(
            from: vm,
            securityGroupsEnforced: enforcement,
            spiffeId: identity?.spiffeID,
            instanceIdentityPrincipalId: identity?.principalID,
            instanceIdentityStatus: identity == nil ? .revoked : .enabled)
    }

    func start(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let vm = try await fetchVMWithAction(req: req, action: "vm:start")

        guard vm.canStart else {
            throw Abort(.badRequest, reason: "VM cannot be started in current state: \(vm.status.rawValue)")
        }

        // A boot the network path can't complete is refused up front rather
        // than accepted as a 202 that never finishes: on an OVN host whose
        // site designates no network controller — or one whose controller is
        // long offline or came back unable to author (issue #833) — the VM's
        // logical switch is authored by nobody and the agent parks the workload
        // forever (issue #743). Placement guards the same condition at create
        // time; this catches a site that lost its controller since. Passing the
        // host lets `refusal` exempt the single-node site whose own node is the
        // offline controller: there the boot is simply waiting on that node to
        // come back, which is what desired state is for.
        if let hypervisorId = vm.hypervisorId,
            let agentUUID = UUID(uuidString: hypervisorId),
            let agent = try await Agent.find(agentUUID, on: req.db),
            agent.supportsInterVMNetworking
        {
            let authority = try await SiteNetworkAuthority.resolve(
                forAgent: agent,
                offlineGrace: req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
                on: req.db)
            if let refusal = SiteNetworkAuthority.refusal(
                authority, host: agent,
                consequence: "this VM's network cannot be realized and it would never boot")
            {
                throw refusal
            }
        }

        // The desired status and generation bump are the mutation;
        // observed-state reports decide whether it converged (issue #260). No
        // transitional `.starting` is stored — in-flight state is the gap
        // between desired and observed.
        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .boot, on: vm, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            vm.setDesiredStatus(.running)
        }

        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }

    func stop(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let vm = try await fetchVMWithAction(req: req, action: "vm:stop")

        guard vm.canStop else {
            throw Abort(.badRequest, reason: "VM cannot be stopped in current state: \(vm.status.rawValue)")
        }

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .shutdown, on: vm, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            vm.setDesiredStatus(.shutdown)
        }

        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }

    func restart(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let vm = try await fetchVMWithAction(req: req, action: "vm:restart")

        guard vm.isRunning else {
            throw Abort(.badRequest, reason: "VM must be running to restart. Current state: \(vm.status.rawValue)")
        }

        // A reboot starts and ends `.running`, so `desiredStatus` cannot carry
        // it — which is why this was the last VM verb still dispatched as an
        // imperative RPC. It rides the sync as a *nonce* now (ADR 0001 stage 9,
        // STR-151): `requestReboot` bumps a monotonic counter the agent applies
        // once against its own durable record, and the generation bump beside it
        // carries the mutation through the same conditions, sweep and webhook
        // path as every other one. Strictly better than what it replaces — a
        // socket dropped mid-flight used to lose the reboot silently; the nonce
        // survives and converges.
        try await Self.requireEdgeNonceCapableAgent(vm.hypervisorId, app: req.application)

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .reboot, on: vm, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable _ in
            vm.requestReboot()
        }

        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }

    /// Refuse an edge-nonce mutation whose agent could not converge it
    /// (STR-151).
    ///
    /// With `vm_reboot` and `vm_restore` gone there is no fallback, and a
    /// pre-v34 agent fails *silently*: it decodes the sync, ignores the field it
    /// has no case for, plans no work, and reports the bumped generation as
    /// converged — so the API would tell the user their VM restarted when it
    /// never did. `409` up front is the `supportsSnapshotSync` posture applied
    /// to a verb, and it names the remedy.
    ///
    /// `capability` is the second of the two signals issue #415 established, for
    /// the callers that need it: the version proves the agent *reads* the nonce,
    /// the capability proves a backend that can realize it is usable on that
    /// host. A restore needs both — admitting one against a QEMU-less host
    /// surfaces as a `degraded` condition half an hour later instead of a `409`
    /// naming the remedy — while a restart needs no snapshot backend and passes
    /// nil.
    ///
    /// Deliberately *not* checked: `status == .online`. The old
    /// `requireCapableAgent` preflight refused an offline agent because its RPC
    /// had nowhere to go; a nonce is desired state, so it converges when the
    /// agent comes back, exactly like start and stop.
    static func requireEdgeNonceCapableAgent(
        _ agentId: String?, requiring snapshotKind: SnapshotArtifactKind? = nil, app: Application
    ) async throws {
        guard let agentId else {
            throw Abort(.conflict, reason: "VM is not placed on any agent")
        }
        guard let agent = await app.agentService.getAgentInfo(agentId) else {
            throw Abort(.conflict, reason: "Agent '\(agentId)' is unknown")
        }
        if let snapshotKind, !agent.supportsSnapshotArtifact(snapshotKind) {
            throw Abort(
                .conflict,
                reason:
                    "Agent '\(agentId)' cannot realize this request (the required snapshot backend "
                    + "is unavailable); place the VM on a host with a capable backend.")
        }
    }

    static func requirePlacedAgentForNetworkHotplug(_ vm: VM, on db: any Database) async throws -> Agent {
        guard let agentID = vm.hypervisorId,
            let agentUUID = UUID(uuidString: agentID),
            let agent = try await Agent.find(agentUUID, on: db)
        else {
            throw Abort(.conflict, reason: "The VM must be placed on an agent before its interfaces can change")
        }
        return agent
    }

    /// A post-create NIC cannot receive the static guest configuration that
    /// QEMU VMs get from their immutable cloud-init seed at creation. Refuse
    /// the mutation before allocating an address or reporting it as accepted;
    /// the agent repeats this check as a defense against legacy or directly
    /// authored desired state.
    static func requireDHCPNetworkForHotplug(_ network: LogicalNetwork) throws {
        guard network.dhcpEnabled else {
            throw Abort(
                .conflict,
                reason: "Network '\(network.name)' has DHCP disabled and requires static guest configuration, "
                    + "which cannot be added after VM creation. Use a DHCP-enabled network or recreate the VM "
                    + "with this interface.")
        }
    }

    static func loadInterfaces(for vm: VM, on db: any Database) async throws {
        try await vm.$networkInterfaces.load(on: db)
        for interface in vm.networkInterfaces {
            try await interface.$addresses.load(on: db)
            try await interface.$observedAddresses.load(on: db)
            try await interface.$logicalNetwork.load(on: db)
            try await interface.$securityGroupMemberships.load(on: db)
        }
    }
}
