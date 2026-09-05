import Fluent
import Foundation
import SQLKit
import Vapor
import StratoShared

/// Owns the complete VM creation use case. The controller delegates here so
/// request transport stays separate from image validation, quota reservation,
/// transactional persistence, placement, and asynchronous mutation dispatch.
enum VMCreationWorkflow {
    static func create(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Creating a VM")

        struct CreateVMRequest: Content, ValidatedRequestBody {
            var name: String
            /// The VM's DNS label (issue #770). Defaults to a slugified
            /// `name`, disambiguated against whatever already registers into
            /// the target network's primary zone.
            let hostname: String?
            let description: String?
            let imageId: UUID?
            /// Required: there is no default project (issue #1059). Optional here so
            /// the refusal is `Request.projectIsRequired`'s, which names the remedy,
            /// rather than a `Codable` decode failure that names neither.
            let projectId: UUID?
            let environment: String?
            let cpu: Int?
            let memory: Int64?
            let disk: Int64?
            /// Storage pool for the managed boot volume. Omission preserves
            /// the seeded default-local behavior.
            let poolId: UUID?
            /// QEMU host-cache policy for the managed boot volume. Omission
            /// keeps the historical conservative path.
            let blockMode: VolumeBlockMode?
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
        let bootPool = try await StoragePool.resolveForCreate(
            requestedPoolID: createRequest.poolId, projectID: projectId, on: req.db)
        let bootPoolID = try bootPool.requireID()

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
        guard maxCpuValue <= VMController.maxHotpluggableCPUs else {
            throw Abort(.badRequest, reason: "'maxCpu' must not exceed \(VMController.maxHotpluggableCPUs)")
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
        let metadataSource = VMController.resolvedMetadataSource(
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
        vm.userData = try VMController.validatedUserData(createRequest.userData)

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
        // committed state. Explicit Ceph selection is project-scoped above;
        // omission still selects the seeded local pool exactly as before.

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
            accepted = try await VMController.retryingOnConstraintFailure {
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
                        format: bootPool.mode == .ceph || vm.hypervisorType == .firecracker
                            ? .raw : .qcow2,
                        volumeType: .boot,
                        status: .creating,
                        createdByID: userID,
                        poolID: bootPoolID,
                        sourceImageID: imageId,
                        blockMode: createRequest.blockMode ?? .conservative)
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

        return try await VMController.acceptedResponse(for: vm, accepted, on: req)
    }
}
