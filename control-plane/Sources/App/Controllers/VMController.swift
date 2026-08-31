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
        let user = try req.requireActingUser("Creating a VM")

        struct CreateVMRequest: Content, ValidatedRequestBody {
            var name: String
            /// The VM's DNS label (issue #770). Defaults to a slugified
            /// `name`, disambiguated against whatever already registers into
            /// the target network's primary zone.
            let hostname: String?
            let description: String?
            let imageId: UUID?
            /// Required by project resolution; optional at decode time so the API can
            /// return a useful error.
            let projectId: UUID?
            let environment: String?
            let cpu: Int?
            let memory: Int64?
            let disk: Int64?
            // Hot-add ceilings (issue #568). Fixed for the life of a running
            // hypervisor process, so they are chosen here and only raised by
            // a stop/start. Default to the boot sizing, i.e. no headroom.
            let maxCpu: Int?
            let maxMemory: Int64?
            let cmdline: String?
            let networkId: UUID?
            let networkName: String?
            let networkInterfaces: [CreateVMNetworkInterfaceRequest]?
            // SSH public key authorized for the guest's default user (cloud-init).
            var sshPublicKey: String?
            // Cloud-init user data, verbatim (#cloud-config, #! script, MIME
            // multipart, ...). Combined with Strato's built-in provisioning
            // config on the agent; a full MIME document replaces it.
            let userData: String?
            // Target hypervisor. Optional: when omitted, it's inferred from the
            // image's artifact set if that set is compatible with exactly one
            // hypervisor, else falls back to the platform default (QEMU).
            let hypervisorType: HypervisorType?
            // Machine profile (issue #565). Both default false — today's
            // behavior — and both are what Windows 11 / Server 2025 require.
            let secureBoot: Bool?
            let tpm: Bool?
            // Strato guest agent (STR-76), distinct from QEMU's qga. Default
            // off; when enabled the QEMU domain gets a fixed-CID vsock device.
            let guestAgentEnabled: Bool?
            // Graphics console (issue #566): whether the guest boots with a
            // display device whose framebuffer the web UI can attach to.
            // Defaults false — headless, today's behavior. Fixed at create,
            // because the display device lives in the hypervisor process's
            // argument vector.
            let graphicsConsole: Bool?
            // Security groups for the VM's NIC. Omitted (or empty) means the
            // project's default group — every NIC must belong to at least one
            // group.
            let securityGroupIds: [UUID]?
            // The per-instance metadata kill switch (STR-185), EC2's
            // `MetadataOptions.HttpEndpoint`. Defaults true — the metadata
            // service replaces the boot-time seed ISO, so a VM created with it
            // off may well not finish provisioning, which is a choice to make
            // deliberately. Editable afterwards, unlike `graphicsConsole`
            // above: hardening a workload that is already running is the case
            // this exists for.
            let metadataEnabled: Bool?
            // Where cloud-init reads first-boot guest configuration (STR-64).
            // New x86 QEMU VMs default to IMDS. ARM64 QEMU and Firecracker keep
            // the ISO enum value because they lack the SMBIOS NoCloudNet hint.
            // Fixed at create because the agent materializes the QEMU ISO with
            // the domain.
            let metadataSource: MetadataSource?

            mutating func validate() throws {
                name = try Validate.name(name)
                try Validate.text(description)
                sshPublicKey = try Validate.sshPublicKey(sshPublicKey)
                // The same ceiling the attach endpoint enforces, applied to the
                // list as sent. `SecurityGroupService.resolveRequestedGroupIDs`
                // already caps the *deduplicated* set, but it reaches that cap
                // through an O(n²) dedupe, so an unbounded list is work done
                // before the guard rather than instead of it.
                try Validate.list(securityGroupIds, "securityGroupIds", max: SecurityGroup.maxGroupsPerNIC)
                try Validate.list(
                    networkInterfaces, "networkInterfaces", max: VMNetworkInterface.maxInterfacesPerVM)
                if let networkInterfaces {
                    guard !networkInterfaces.isEmpty else {
                        throw Abort(.badRequest, reason: "'networkInterfaces' must contain at least one interface")
                    }
                    guard networkId == nil, networkName == nil, securityGroupIds == nil else {
                        throw Abort(
                            .badRequest,
                            reason:
                                "'networkInterfaces' cannot be combined with legacy network or security-group fields")
                    }
                    for (index, interface) in networkInterfaces.enumerated() {
                        try interface.validate(path: "networkInterfaces[\(index)]")
                    }
                }
            }
        }

        let createRequest = try req.content.decodeValidated(CreateVMRequest.self)

        // An image is required to create a VM.
        guard let imageId = createRequest.imageId else {
            throw Abort(.badRequest, reason: "'imageId' must be provided")
        }

        // Find the image
        guard let foundImage = try await Image.find(imageId, on: req.db) else {
            throw Abort(.badRequest, reason: "Image not found")
        }
        // Load artifacts for the hypervisor-compatibility check below.
        try await foundImage.$artifacts.load(on: req.db)

        // Verify image is ready
        guard foundImage.status == .ready else {
            throw Abort(.badRequest, reason: "Image is not ready. Status: \(foundImage.status.rawValue)")
        }

        // Check user permission on image
        let hasImagePermission = try await req.can("image:read", on: IAMNode(type: .image, id: imageId))

        guard hasImagePermission else {
            throw Abort(.forbidden, reason: "Access denied to image")
        }

        let image: Image = foundImage

        // Resolve the target project and environment (org membership, the
        // vm:create action, and environment validity). Shared with
        // sandbox creation via `req.resolveProjectForCreate` (issue #675).
        let (project, environment) = try await req.resolveProjectForCreate(
            requestedProjectId: createRequest.projectId,
            requestedEnvironment: createRequest.environment,
            user: user,
            action: "vm:create",
            resourceKind: "VMs"
        )
        let projectId = try project.requireID()

        // NIC logical networks are resolved inside the create transaction
        // (`LogicalNetworkService.resolveForWorkloadCreate`), scoped to this
        // VM's project. Validate the mutually-exclusive selectors up front so a
        // malformed request fails before any quota or placement work.
        let requestedInterfaces: [CreateVMNetworkInterfaceRequest]
        if let networkInterfaces = createRequest.networkInterfaces {
            requestedInterfaces = networkInterfaces
        } else {
            let legacy = CreateVMNetworkInterfaceRequest(
                networkId: createRequest.networkId,
                networkName: createRequest.networkName,
                securityGroupIds: createRequest.securityGroupIds,
                mtu: nil)
            try legacy.validate(path: "network")
            requestedInterfaces = [legacy]
        }

        // Resolve every NIC's explicit security groups before quota/placement
        // work. Omitted or empty lists remain empty here and become the default
        // group inside the create transaction.
        var requestedGroupsByIndex: [[UUID]] = []
        for interface in requestedInterfaces {
            requestedGroupsByIndex.append(
                try await SecurityGroupService.resolveRequestedGroupIDs(
                    interface.securityGroupIds, projectID: projectId, on: req.db))
        }
        let resolvedRequestedGroupsByIndex = requestedGroupsByIndex

        // Create the VM instance from the image.
        // Pre-compute values to avoid complex expression
        let cpuValue = createRequest.cpu ?? image.defaultCpu ?? 1
        let memoryValue = createRequest.memory ?? image.defaultMemory ?? Int64(1024 * 1024 * 1024)
        let diskValue = createRequest.disk ?? image.defaultDisk ?? Int64(10 * 1024 * 1024 * 1024)
        guard cpuValue > 0 else {
            throw Abort(.badRequest, reason: "'cpu' must be positive")
        }
        guard memoryValue > 0 else {
            throw Abort(.badRequest, reason: "'memory' must be positive")
        }
        guard memoryValue <= WorkloadSizeLimits.maxMemoryBytes else {
            throw Abort(
                .badRequest,
                reason: "'memory' must not exceed \(WorkloadSizeLimits.maxMemoryBytes) bytes")
        }
        guard diskValue > 0 else {
            throw Abort(.badRequest, reason: "'disk' must be positive")
        }
        guard diskValue <= WorkloadSizeLimits.maxDiskBytes else {
            throw Abort(
                .badRequest,
                reason: "'disk' must not exceed \(WorkloadSizeLimits.maxDiskBytes) bytes")
        }

        // Hot-add headroom (issue #568). The ceilings bound what a later
        // online resize may reach; below the boot sizing they would be
        // meaningless, and the upper vCPU bound keeps a typo from spawning a
        // VM with thousands of (unusable) hotplug slots.
        let maxCpuValue = createRequest.maxCpu ?? cpuValue
        let maxMemoryValue = createRequest.maxMemory ?? memoryValue
        guard maxCpuValue >= cpuValue else {
            throw Abort(.badRequest, reason: "'maxCpu' must be at least 'cpu'")
        }
        guard maxCpuValue <= Self.maxHotpluggableCPUs else {
            throw Abort(.badRequest, reason: "'maxCpu' must not exceed \(Self.maxHotpluggableCPUs)")
        }
        guard maxMemoryValue >= memoryValue else {
            throw Abort(.badRequest, reason: "'maxMemory' must be at least 'memory'")
        }
        guard maxMemoryValue <= WorkloadSizeLimits.maxMemoryBytes else {
            throw Abort(
                .badRequest,
                reason: "'maxMemory' must not exceed \(WorkloadSizeLimits.maxMemoryBytes) bytes")
        }
        let cmdlineValue = createRequest.cmdline ?? image.defaultCmdline

        // The kernel cmdline is passed through to the agent's hypervisor
        // invocation. Bound its length and reject control characters (newlines,
        // NULs, escapes) so a caller cannot smuggle extra directives or line
        // breaks into the boot arguments.
        //
        // Only the *request's* cmdline is rejected here: an image's
        // `defaultCmdline` isn't the caller's to fix, so failing their create
        // over it would be an unactionable 400. That path is sanitized at the
        // sink instead (`VMSpecBuilder.ensureSerialConsole`), which every
        // source funnels through.
        if let cmdline = createRequest.cmdline {
            guard cmdline.utf8.count <= 4096 else {
                throw Abort(.badRequest, reason: "'cmdline' exceeds the maximum length of 4096 bytes")
            }
            guard !cmdline.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw Abort(.badRequest, reason: "'cmdline' contains disallowed control characters")
            }
        }

        // Choose the hypervisor: an explicit request wins; otherwise infer
        // it from the image when its artifact set is compatible with exactly
        // one hypervisor; otherwise fall back to the model default (QEMU).
        let chosenHypervisor: HypervisorType
        if let requested = createRequest.hypervisorType {
            chosenHypervisor = requested
        } else {
            let compatible = image.compatibleHypervisors()
            chosenHypervisor = compatible.count == 1 ? compatible.first! : .qemu
        }

        let metadataEnabled = createRequest.metadataEnabled ?? true
        let metadataSource = Self.resolvedMetadataSource(
            createRequest.metadataSource, for: chosenHypervisor,
            architecture: image.architecture)
        if metadataSource == .imds, !metadataEnabled {
            throw Abort(
                .badRequest,
                reason: "'metadataSource: imds' requires 'metadataEnabled' to be true during VM creation")
        }
        if metadataSource == .imds, chosenHypervisor == .firecracker {
            throw Abort(
                .badRequest,
                reason: "'metadataSource: imds' is not supported for firecracker VMs; use the qemu hypervisor")
        }

        let vm = VM(
            name: createRequest.name,
            description: createRequest.description ?? "",
            image: image.name,
            projectID: projectId,
            environment: environment,
            cpu: cpuValue,
            memory: memoryValue,
            disk: diskValue,
            hypervisorType: chosenHypervisor,
            maxCpu: maxCpuValue,
            maxMemory: maxMemoryValue,
            secureBoot: createRequest.secureBoot ?? false,
            tpmEnabled: createRequest.tpm ?? false,
            guestAgentEnabled: createRequest.guestAgentEnabled ?? false,
            graphicsConsole: createRequest.graphicsConsole ?? false,
            metadataEnabled: metadataEnabled,
            metadataSource: metadataSource
        )
        vm.cmdline = cmdlineValue
        // Link VM to source image
        vm.$sourceImage.id = image.id

        // The typed artifact set must include what the target hypervisor needs:
        // a disk image for QEMU, or an architecture-matched kernel + rootfs for
        // Firecracker. An empty or incomplete set is an explicit failure.
        if !image.isUsable(by: vm.hypervisorType) {
            let available = image.compatibleHypervisors()
                .map(\.rawValue).sorted().joined(separator: ", ")
            throw Abort(
                .badRequest,
                reason: "Image '\(image.name)' (\(image.architecture.rawValue)) is not usable by "
                    + "\(vm.hypervisorType.rawValue). Compatible hypervisors: "
                    + (available.isEmpty ? "none" : available))
        }

        // Guest login: authorize the caller-provided SSH public key via
        // cloud-init. Already trimmed, bounded and parsed by
        // `CreateVMRequest.validate()`; empty input arrived here as nil.
        vm.setSSHAuthorizedKeys(createRequest.sshPublicKey.map { [$0] } ?? [])

        // Guest provisioning: caller-supplied cloud-init user data, stored
        // verbatim for either backend (leading bytes are the format header
        // cloud-init dispatches on, so no trimming). QEMU puts it in its
        // selected NoCloud transport; Firecracker exposes it through MMDS.
        vm.userData = try Self.validatedUserData(createRequest.userData)

        // Secure Boot and a vTPM are firmware-boot features, and Firecracker
        // boots a kernel directly with no UEFI and no TPM device at all.
        // Rejecting is the only honest answer: accepting would return 202 for a
        // Windows VM that can never boot (issue #565).
        if vm.hypervisorType == .firecracker, vm.secureBoot || vm.tpmEnabled {
            throw Abort(
                .badRequest,
                reason: "'secureBoot' and 'tpm' are not supported for firecracker VMs "
                    + "(no UEFI firmware or TPM device); use the qemu hypervisor")
        }

        if vm.guestAgentEnabled, vm.hypervisorType == .firecracker {
            throw Abort(
                .badRequest,
                reason: "'guestAgentEnabled' is not supported for firecracker VMs; use the qemu hypervisor")
        }

        // Firecracker emulates no display device at all — it boots a kernel
        // directly and its only console is a serial port. Same reasoning as
        // Secure Boot above: returning 202 for a VM whose Display tab could
        // never work is worse than refusing (issue #566).
        if vm.graphicsConsole, vm.hypervisorType == .firecracker {
            throw Abort(
                .badRequest,
                reason: "'graphicsConsole' is not supported for firecracker VMs "
                    + "(no emulated display device); use the qemu hypervisor")
        }

        let userID = try user.requireID()

        // A VM's boot disk is a first-class managed volume from its first
        // committed state. Pool selection is not public yet, so it uses the
        // same seeded local pool as an explicit volume create.
        let bootPool = try await StoragePool.defaultPool(on: req.db)
        guard bootPool.mode == .local else {
            throw Abort(
                .conflict,
                reason: "Storage pool '\(bootPool.name)' is not supported for VM boot volumes")
        }
        let bootPoolID = try bootPool.requireID()

        // Reserve quota and persist the VM and its create record in one
        // transaction: enforcement checks, both inserts, creator grants, and
        // attribution events all commit together or roll back together.
        let accepted: ResourceMutation.Accepted
        do {
            // IPAM's unique (network, address) index is the backstop against
            // concurrent creates racing to the same address. A violation
            // poisons the whole Postgres transaction, so the retry wraps the
            // transaction (not the insert): the loser re-reads the used set
            // and allocates the next free address.
            let initialGeneration = vm.generation
            accepted = try await Self.retryingOnConstraintFailure {
                // A retried attempt reuses this model after its insert was
                // rolled back: Fluent recorded the generated id and marked the
                // model as existing, so saving again would UPDATE a row that no
                // longer exists (and the failed attempt's SQL writer refreshed
                // its in-memory generation). Reset both so every attempt starts
                // as a fresh insert.
                vm.id = nil
                vm.$id.exists = false
                vm.generation = initialGeneration
                return try await req.db.transaction { db in
                    try await IdempotencyService.reserve(
                        req.idempotencyContext, actor: .user(userID), on: db)
                    // Enforce and reserve applicable project/OU/org quotas before the VM row
                    // exists. Throws Abort(.forbidden) naming the quota if it would be exceeded.
                    try await QuotaEnforcementService.reserve(
                        for: project,
                        environment: environment,
                        vcpus: vm.cpu,
                        memory: vm.memory,
                        storage: vm.disk,
                        on: db
                    )

                    // How long the create has to converge before the
                    // stuck-convergence sweep marks the VM degraded (STR-147).
                    // Stamped with the insert, so a control-plane crash between
                    // here and placement still leaves a resource the sweep can
                    // judge.
                    vm.extendConvergenceDeadline(
                        by: OperationResourceKind.virtualMachine.completionBudgetSeconds(for: .create))

                    // Save VM to database first to generate ID
                    try await vm.save(on: db)

                    // Generate unique paths and configurations using the generated ID
                    let vmID = try vm.requireID()

                    // Resolve every requested network in the VM's project. They
                    // stay as distinct NIC requests even when two select the
                    // same logical network: each receives its own MAC and IPs.
                    var resolvedInterfaces:
                        [(
                            request: CreateVMNetworkInterfaceRequest,
                            network: LogicalNetwork,
                            networkID: UUID,
                            securityGroupIDs: [UUID]
                        )] = []
                    for (index, interface) in requestedInterfaces.enumerated() {
                        let network = try await LogicalNetworkService.resolveForWorkloadCreate(
                            requestedID: interface.networkId,
                            requestedName: interface.networkName,
                            projectID: projectId,
                            on: db)
                        if let mtu = interface.mtu, network.subnet6 != nil, mtu < 1_280 {
                            throw Abort(
                                .badRequest,
                                reason: "networkInterfaces[\(index)].mtu must be at least 1280 on an IPv6 network")
                        }
                        resolvedInterfaces.append(
                            (interface, network, try network.requireID(), resolvedRequestedGroupsByIndex[index]))
                    }

                    // Firecracker has no NoCloud disk or another user-data
                    // injection path: cloud-init reads the EC2 document from
                    // MMDS. Accepting the payload while either policy layer
                    // makes MMDS unreachable would return 202 for data the
                    // guest can never retrieve.
                    if vm.hypervisorType == .firecracker, vm.userData != nil {
                        guard vm.metadataEnabled else {
                            throw Abort(
                                .badRequest,
                                reason:
                                    "'userData' for firecracker VMs requires 'metadataEnabled' to be true")
                        }
                        guard
                            resolvedInterfaces.contains(where: {
                                $0.network.metadataEnabled && $0.network.dhcpEnabled
                            })
                        else {
                            throw Abort(
                                .badRequest,
                                reason: "'userData' for firecracker VMs requires at least one selected network "
                                    + "with metadata and DHCP enabled")
                        }
                    }

                    // An IMDS seed carries no real user data of its own. At
                    // least one selected network must publish the metadata
                    // localport/listener or the seedfrom hand-off can never
                    // complete. This runs inside the create transaction after
                    // project-scoped resolution; throwing rolls back the VM
                    // row and quota reservation together.
                    if vm.metadataSource == .imds,
                        !resolvedInterfaces.contains(where: { $0.network.metadataEnabled })
                    {
                        throw Abort(
                            .badRequest,
                            reason: "'metadataSource: imds' requires at least one selected network "
                                + "with metadata enabled")
                    }

                    // The VM's DNS label (issue #770), resolved against the
                    // zone the network registers into. An explicit hostname is
                    // held to strict uniqueness — the caller named it, so a
                    // collision is worth a 409 — while the default is
                    // disambiguated with a suffix, because two VMs called
                    // "web server" is an ordinary thing to do and failing the
                    // create over an implicit label would be baffling.
                    let registrationZones = try await DNSZoneService.registrationZones(
                        networkIDs: Array(Set(resolvedInterfaces.map(\.networkID))), on: db)
                    if let requestedHostname = createRequest.hostname {
                        vm.hostname = try await DNSZoneService.validatedExplicitHostname(
                            requestedHostname, forVM: vmID, in: registrationZones, on: db)
                    } else {
                        vm.hostname = try await DNSZoneService.availableHostname(
                            basedOn: vm.name, forVM: vmID, in: registrationZones, on: db)
                    }

                    // Desired state for a fresh VM: exists but not running. The bump
                    // to generation 1 distinguishes "never confirmed by any agent"
                    // (observed_generation 0) from "confirmed" (issue #260).
                    vm.setDesiredStatus(.shutdown)
                    guard
                        case .applied = try await vm.advanceDesiredStateGeneration(
                            expectedGeneration: 0, on: db)
                    else {
                        throw Abort(
                            .internalServerError,
                            reason: "Failed to initialize the VM desired-state generation")
                    }

                    // Persist the generated hostname and generation.
                    try await vm.update(on: db)

                    let bootVolume = Volume(
                        name: "boot-\(vmID.uuidString.lowercased())",
                        description: "Boot volume for VM \(vm.name)",
                        projectID: projectId,
                        environment: environment,
                        size: vm.disk,
                        format: vm.hypervisorType == .firecracker ? .raw : .qcow2,
                        volumeType: .boot,
                        status: .creating,
                        createdByID: userID,
                        poolID: bootPoolID,
                        sourceImageID: imageId)
                    bootVolume.$vm.id = vmID
                    bootVolume.deviceName = VolumeDeviceName.disk(0).rawValue
                    bootVolume.bootOrder = 0
                    bootVolume.readonly = false
                    bootVolume.generation = 1
                    bootVolume.extendConvergenceDeadline(
                        by: OperationResourceKind.volume.completionBudgetSeconds(for: .create))
                    try await bootVolume.save(on: db)
                    let bootVolumeID = try bootVolume.requireID()

                    try await RoleBindingService.grant(
                        principalType: .user,
                        principalID: userID,
                        role: .admin,
                        nodeType: .volume,
                        nodeID: bootVolumeID,
                        createdBy: userID,
                        on: db)
                    _ = try await ResourceEvent.record(
                        .create,
                        resourceKind: .volume,
                        resourceID: bootVolumeID,
                        actor: .user(userID),
                        on: db)

                    let defaultGroupID: UUID?
                    if resolvedInterfaces.contains(where: { $0.securityGroupIDs.isEmpty }) {
                        let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                            projectID: projectId, on: db)
                        defaultGroupID = try defaultGroup.requireID()
                    } else {
                        defaultGroupID = nil
                    }

                    // Allocate and persist one complete NIC at a time. All rows
                    // still share this outer retrying transaction, so any IPAM
                    // race rolls back the whole VM rather than leaving a partial
                    // interface set.
                    try await IPAMService.lockNetworkAllocations(
                        resolvedInterfaces.map(\.networkID), on: db)
                    for (orderIndex, resolved) in resolvedInterfaces.enumerated() {
                        let allocation = try await IPAMService.allocateIP(for: resolved.network, on: db)
                        let allocation6 = try await IPAMService.allocateIPv6(for: resolved.network, on: db)
                        let interfaceID = UUID()
                        let macAddress = try await MACAllocator.allocate(
                            for: .vmInterface, ownerID: interfaceID, on: db)
                        let networkInterface = VMNetworkInterface(
                            id: interfaceID,
                            vmID: vmID,
                            logicalNetworkID: resolved.networkID,
                            macAddress: macAddress.description,
                            mtu: resolved.request.mtu,
                            deviceName: "net\(orderIndex)",
                            orderIndex: orderIndex)
                        networkInterface.attachGeneration = vm.generation
                        try await networkInterface.save(on: db)

                        let groupIDs: [UUID]
                        if resolved.securityGroupIDs.isEmpty {
                            guard let defaultGroupID else {
                                throw Abort(.internalServerError, reason: "Default security group was not resolved")
                            }
                            groupIDs = [defaultGroupID]
                        } else {
                            groupIDs = resolved.securityGroupIDs
                        }
                        for groupID in groupIDs {
                            try await VMInterfaceSecurityGroup(
                                interfaceID: interfaceID, securityGroupID: groupID
                            ).save(on: db)
                        }

                        try await VMInterfaceAddress(
                            interfaceID: interfaceID,
                            logicalNetworkID: resolved.networkID,
                            family: .ipv4,
                            address: allocation.ipAddress,
                            prefixLength: allocation.prefixLength,
                            gateway: resolved.network.gateway
                        ).save(on: db)
                        if let allocation6 {
                            try await VMInterfaceAddress(
                                interfaceID: interfaceID,
                                logicalNetworkID: resolved.networkID,
                                family: .ipv6,
                                address: allocation6.ipAddress,
                                prefixLength: allocation6.prefixLength,
                                gateway: resolved.network.gateway6
                            ).save(on: db)
                        }
                    }

                    // The create's attribution record, and the client's handle
                    // on the asynchronous agent work that follows (ADR 0001
                    // stage 4). Appended here rather than by
                    // `ResourceMutation.accept`, because the retrying IPAM
                    // transaction owns this insert. The scope is passed rather
                    // than resolved: this transaction is the longest-held one
                    // in the system, and every field of it is already in
                    // memory.
                    //
                    // Resolved once and shared with the instance identity
                    // below, so the attribution record and the identity are
                    // scoped to the same organization by construction rather
                    // than by two lookups that could disagree.
                    let rootOrganizationID = try await project.getRootOrganizationId(on: db)

                    let event = try await ResourceEvent.record(
                        .create, resourceKind: .virtualMachine, resourceID: vmID,
                        actor: .user(userID),
                        scope: ResourceEvent.Scope(
                            organizationID: rootOrganizationID,
                            projectID: projectId,
                            resourceName: vm.name,
                            generation: vm.generation),
                        on: db)

                    // The creator's explicit, revocable binding on the VM, in
                    // the create transaction — the authoritative grant Cedar
                    // evaluates (issue #477).
                    try await RoleBindingService.grant(
                        principalType: .user,
                        principalID: userID,
                        role: .admin,
                        nodeType: .virtualMachine,
                        nodeID: vmID,
                        createdBy: userID,
                        on: db
                    )

                    // The VM's instance identity (STR-55): one registry row per
                    // VM, naming `spiffe://<trust-domain>/vm/<vm-id>`, written
                    // in this transaction and cascade-deleted with the VM row.
                    //
                    // Unconditional, for every VM, and deliberately *not*
                    // opt-in: a registration carries no grants of its own, so
                    // until an operator writes a role binding against it the
                    // principal authenticates and authorizes nothing. A per-VM
                    // switch would be a second lock on a door the authorization
                    // model already holds shut.
                    //
                    // No label is stored: the id in the SPIFFE path is the
                    // identity, a rename must never move one
                    // (docs/architecture/guest-identity.md, "UUIDs, never
                    // names"), and a stored copy of `vm.name` would only decay.
                    // The registry hydrates it from the VM. A project belonging
                    // to no organization still gets a row, scoped to nothing, on
                    // the platform domain.
                    //
                    // A `spiffe_id` collision from a legacy or directly
                    // inserted registration is a constraint failure, which the
                    // retry wrapper answers by redrawing the VM's id and
                    // therefore its identity, exactly as it answers an IPAM
                    // address race.
                    try await GuestIdentity.register(
                        vmID: vmID,
                        organizationID: rootOrganizationID,
                        createdBy: userID,
                        configuration: req.controlPlaneConfiguration,
                        on: db
                    )

                    let accepted = ResourceMutation.Accepted(
                        mutationID: try event.requireID(), targetGeneration: vm.generation)
                    try await IdempotencyService.complete(
                        req.idempotencyContext,
                        actor: .user(userID),
                        resourceKind: .virtualMachine,
                        resourceID: vmID,
                        accepted: accepted,
                        on: db)
                    return accepted
                }
            }
        } catch let error as IPAMService.IPAMError {
            // The chosen network's subnet is full; the whole transaction rolled
            // back, so no VM was created.
            throw Abort(.conflict, reason: error.errorDescription ?? "No free IP addresses in the selected network")
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // Every attempt lost the same constraint. A conflict rather than a
            // server fault — the transaction rolled back whole — so `409` is the
            // honest status, where this previously fell through as a `500`.
            //
            // The catch is broader than any one cause and the message stays
            // broad to match: an address race, a squatted
            // `spiffe://<td>/vm/<uuid>`, or a constraint on any other row this
            // transaction writes all land here, and naming only one of them
            // would send an operator down a dead end for the others. Which
            // constraint actually fired is in the log line below, where the
            // full error description carries the index name.
            req.logger.warning(
                "VM create exhausted its retries on a constraint failure",
                metadata: [
                    "strato.project.id": .string(projectId.uuidString),
                    "error": .string(String(describing: error)),
                ])
            throw Abort(
                .conflict,
                reason: """
                    Could not create the VM: a uniqueness constraint could not be satisfied \
                    after retrying. Retry; if it persists, the server log names the constraint.
                    """)
        }

        let vmID = try vm.requireID()

        // Place the VM in the background: the scheduler selects a hypervisor
        // and persists hypervisorId, and the desired-state sync carries the
        // VM (spec assembled from the database) to its agent. Observed-state
        // reports — not this request — decide whether it converged.
        req.resourceMutation.dispatch(
            .create, resourceType: VM.self, resourceID: vmID,
            targetGeneration: accepted.targetGeneration, agentIDs: [],
            strategy: .placement { @Sendable [app = req.application] db in
                try await app.workloadPlacement.createVM(vm: vm, db: db, image: image)
            }, app: req.application)

        req.logger.info(
            "VM creation accepted",
            metadata: [
                "strato.vm.id": .string(vmID.uuidString),
                "strato.operation.id": .string(accepted.mutationID.uuidString),
                "created_from": .string("image"),
            ])

        return try await Self.acceptedResponse(for: vm, accepted, on: req)
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

        guard newCPU > 0 else { throw Abort(.badRequest, reason: "'cpu' must be positive") }
        guard newMemory > 0 else { throw Abort(.badRequest, reason: "'memory' must be positive") }
        guard newCPU <= Self.maxHotpluggableCPUs else {
            throw Abort(.badRequest, reason: "'cpu' must not exceed \(Self.maxHotpluggableCPUs)")
        }
        // A stopped VM raises its own `maxMemory` to the new sizing below, so
        // this one bound covers the ceiling too.
        guard newMemory <= WorkloadSizeLimits.maxMemoryBytes else {
            throw Abort(
                .badRequest,
                reason: "'memory' must not exceed \(WorkloadSizeLimits.maxMemoryBytes) bytes")
        }
        if let target = newBalloonTarget {
            // A target is a reclaim floor within the grant, so it is bounded
            // by the memory the VM will have — growing a guest is `memory`,
            // not the balloon. The lower bound is the guard the issue calls
            // for: a target small enough to OOM the guest is a mistake the
            // API can catch, not a policy it should let through.
            guard target <= newMemory else {
                throw Abort(
                    .badRequest,
                    reason: "'balloonTarget' must not exceed the VM's memory (\(newMemory) bytes); "
                        + "raise 'memory' to give the guest more")
            }
            guard target >= Self.minimumBalloonTargetBytes else {
                throw Abort(
                    .badRequest,
                    reason: "'balloonTarget' must be at least \(Self.minimumBalloonTargetBytes) bytes; "
                        + "a smaller target would leave the guest too little memory to stay alive")
            }
        }

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
                _ = try await Self.applyMetadataUpdate(
                    updateRequest.metadataEnabled, to: existingVM, on: db)
                try await QuotaEnforcementService.reserveVMResize(
                    for: project, environment: existingVM.environment,
                    vcpuDelta: newCPU - committed.cpu,
                    memoryDelta: newMemory - committed.memory,
                    on: db)
                existingVM.cpu = newCPU
                existingVM.memory = newMemory
                existingVM.balloonTarget = newBalloonTarget
                existingVM.maxCpu = max(existingVM.maxCpu, newCPU)
                existingVM.maxMemory = max(existingVM.maxMemory, newMemory)
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
            try await QuotaEnforcementService.reserveVMResize(
                for: project, environment: existingVM.environment,
                vcpuDelta: newCPU - committed.cpu, memoryDelta: newMemory - committed.memory, on: db)
            existingVM.cpu = newCPU
            existingVM.memory = newMemory
            // Deliberately not a quota movement: ballooning reclaims memory
            // opportunistically, the grant the project is charged for is
            // still committed, and the guest takes it all back the moment the
            // target is cleared.
            existingVM.balloonTarget = newBalloonTarget
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
    /// Read here rather than adopted by `accept`'s refresh because `cpu` and
    /// `memory` are *mutation*-owned columns: the refresh deliberately leaves
    /// them alone so this request's new sizing is not overwritten by the old.
    private static func committedVMSizing(_ id: UUID, on db: any Database) async throws -> CommittedVMSizing {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Resizing a VM requires an SQL database")
        }
        guard
            let row = try await sql.raw(
                "SELECT cpu, memory FROM vms WHERE id = \(bind: id)"
            ).first(decoding: CommittedVMSizing.self)
        else {
            throw Abort(.notFound, reason: "VM no longer exists")
        }
        return row
    }

    private struct CommittedVMSizing: Decodable {
        let cpu: Int
        let memory: Int64
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
