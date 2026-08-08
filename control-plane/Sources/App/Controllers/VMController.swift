import Fluent
import Foundation
import SQLKit
import Vapor
import StratoShared

struct VMController: RouteCollection {
    private static func defaultVMStoragePath() -> String {
        if let override = Environment.get("VM_STORAGE_DIR"), !override.isEmpty {
            return override
        }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/vms"
        #else
        return "/var/lib/strato/vms"
        #endif
    }

    private static func socketPath(for vmID: UUID, filename: String) -> String {
        let base = defaultVMStoragePath()
        let vmDir = (base as NSString).appendingPathComponent(vmID.uuidString)
        return (vmDir as NSString).appendingPathComponent(filename)
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
            vm.put(use: update)
            vm.delete(use: delete)
            vm.post("start", use: start)
            vm.post("stop", use: stop)
            vm.post("restart", use: restart)
            vm.post("pause", use: pause)
            vm.post("resume", use: resume)
            vm.get("status", use: status)
            vm.get("operations", use: listOperations)
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
        let vm = try await fetchVMWithPermission(req: req, permission: "read")
        let vmID = try vm.requireID()

        let limit = try req.intQuery("limit", default: 20, in: 1...100)

        return try await OperationFacade.history(
            resourceKind: .virtualMachine, resourceID: vmID, limit: limit, on: req.db)
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
        let enforcement = try await SecurityGroupService.enforcementByVM(allVMs, on: req.db)

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
        let spiffeIDs = try await GuestIdentity.spiffeIDs(
            forVMs: visible.compactMap(\.id), on: req.db)

        return visible.compactMap { vm in
            guard let id = vm.id else { return nil }
            return VMDetailResponse(
                from: vm, securityGroupsEnforced: enforcement[id], spiffeId: spiffeIDs[id])
        }
    }

    /// Fetch a VM by its :vmID route parameter and enforce a permission on it.
    ///
    /// Delegates to the shared `Request.authorizedVM(_:permission:)` helper so the
    /// per-object authorization logic lives in one place (also used by other VM-scoped
    /// controllers such as `LogsController`).
    private func fetchVMWithPermission(req: Request, permission: String) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        return try await req.authorizedVM(vmID, permission: permission)
    }

    func show(req: Request) async throws -> VMDetailResponse {
        let vm = try await fetchVMWithPermission(req: req, permission: "read")
        try await vm.$networkInterfaces.load(on: req.db)
        for interface in vm.networkInterfaces {
            try await interface.$addresses.load(on: req.db)
            try await interface.$observedAddresses.load(on: req.db)
            // The response reports the NIC's network by name as well as id.
            try await interface.$logicalNetwork.load(on: req.db)
            // …and which security groups filter it (STR-34).
            try await interface.$securityGroupMemberships.load(on: req.db)
        }

        return try await VMDetailResponse(
            from: vm,
            securityGroupsEnforced: SecurityGroupService.enforcement(for: vm, on: req.db),
            spiffeId: GuestIdentity.spiffeID(forVM: vm.requireID(), on: req.db))
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
            /// Required: there is no default project (issue #1059). Optional here so
            /// the refusal is `Request.projectIsRequired`'s, which names the remedy,
            /// rather than a `Codable` decode failure that names neither.
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
        let hasImagePermission = try await req.can("read", on: "image", id: imageId.uuidString)

        guard hasImagePermission else {
            throw Abort(.forbidden, reason: "Access denied to image")
        }

        let image: Image = foundImage

        // Resolve the target project and environment (org membership, the
        // create_resources permission, and environment validity). Shared with
        // sandbox creation via `req.resolveProjectForCreate` (issue #675).
        let (project, environment) = try await req.resolveProjectForCreate(
            requestedProjectId: createRequest.projectId,
            requestedEnvironment: createRequest.environment,
            user: user,
            resourceKind: "VMs"
        )
        let projectId = try project.requireID()

        // The NIC's logical network is resolved inside the create transaction
        // (`LogicalNetworkService.resolveForWorkloadCreate`), scoped to this
        // VM's project. Validate the mutually-exclusive selectors up front so a
        // malformed request fails before any quota or placement work.
        if createRequest.networkId != nil && createRequest.networkName != nil {
            throw Abort(.badRequest, reason: "Specify either 'networkId' or 'networkName', not both")
        }

        // Resolve the NIC's security groups. Explicit ids must exist, belong
        // to this project, and fit the per-NIC cap; omitted (or empty) means
        // the project's default group, ensured inside the create transaction.
        let requestedSecurityGroupIds = try await SecurityGroupService.resolveRequestedGroupIDs(
            createRequest.securityGroupIds, projectID: projectId, on: req.db)

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
            graphicsConsole: createRequest.graphicsConsole ?? false
        )
        vm.cmdline = cmdlineValue
        // Link VM to source image
        vm.$sourceImage.id = image.id

        // When the image carries a typed artifact set, it must include what
        // the target hypervisor needs (a disk image for QEMU; a kernel +
        // rootfs for Firecracker of the image's architecture). Images with
        // no artifacts (legacy, pre-backfill) are left permissive — their
        // compatibility is unknown, matching pre-#214 behavior.
        let loadedArtifacts = image.$artifacts.value ?? []
        if !loadedArtifacts.isEmpty, !image.isUsable(by: vm.hypervisorType) {
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
        vm.sshPublicKey = createRequest.sshPublicKey

        // Guest provisioning: caller-supplied cloud-init user data, stored
        // verbatim (leading bytes are the format header cloud-init dispatches
        // on, so no trimming).
        vm.userData = try Self.validatedUserData(createRequest.userData)

        // User data is only delivered on the QEMU disk-boot path (the NoCloud
        // seed ISO); Firecracker VMs have no injection path yet. Reject rather
        // than return 202 and silently ignore the payload.
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

        if vm.userData != nil, vm.hypervisorType == .firecracker {
            throw Abort(
                .badRequest,
                reason: "'userData' is not supported for firecracker VMs (cloud-init runs only on QEMU disk boot)")
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

        // Reserve quota and persist the VM and its create record in one
        // transaction: enforcement checks, the reservation bump, the initial insert,
        // the path update, and the attribution event all commit together or roll back
        // together, so a quota rejection leaves nothing behind.
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
                // longer exists (and the failed attempt's setDesiredStatus
                // already bumped the generation). Reset both so every attempt
                // starts as a fresh insert.
                vm.id = nil
                vm.$id.exists = false
                vm.generation = initialGeneration
                return try await req.db.transaction { db in
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

                    // Every VM starts with one NIC on the network the caller named,
                    // resolved here — inside the transaction — so the row that IPAM
                    // allocates from is the one the NIC's foreign key then pins
                    // (issue #765).
                    let logicalNetwork = try await LogicalNetworkService.resolveForWorkloadCreate(
                        requestedID: createRequest.networkId,
                        requestedName: createRequest.networkName,
                        projectID: projectId,
                        on: db
                    )
                    let logicalNetworkID = try logicalNetwork.requireID()

                    // The VM's DNS label (issue #770), resolved against the
                    // zone the network registers into. An explicit hostname is
                    // held to strict uniqueness — the caller named it, so a
                    // collision is worth a 409 — while the default is
                    // disambiguated with a suffix, because two VMs called
                    // "web server" is an ordinary thing to do and failing the
                    // create over an implicit label would be baffling.
                    let registrationZones = try await DNSZoneService.registrationZones(
                        networkIDs: [logicalNetworkID], on: db)
                    if let requestedHostname = createRequest.hostname {
                        vm.hostname = try await DNSZoneService.validatedExplicitHostname(
                            requestedHostname, forVM: vmID, in: registrationZones, on: db)
                    } else {
                        vm.hostname = try await DNSZoneService.availableHostname(
                            basedOn: vm.name, forVM: vmID, in: registrationZones, on: db)
                    }

                    // Image-based paths - disk will be created by agent from cached image
                    vm.diskPath = "/var/lib/strato/vms/\(vmID)/disk.qcow2"

                    // Set up console sockets to align with agent VM storage path
                    vm.consoleSocket = Self.socketPath(for: vmID, filename: "console.sock")
                    vm.serialSocket = Self.socketPath(for: vmID, filename: "serial.sock")

                    // Desired state for a fresh VM: exists but not running. The bump
                    // to generation 1 distinguishes "never confirmed by any agent"
                    // (observed_generation 0) from "confirmed" (issue #260).
                    vm.setDesiredStatus(.shutdown)

                    // Update VM with generated paths
                    try await vm.update(on: db)

                    // The control plane owns IPAM (issue #212): the address is
                    // allocated here so agents receive it in the spec instead
                    // of inventing one.
                    let allocation = try await IPAMService.allocateIP(for: logicalNetwork, on: db)
                    let networkGateway = logicalNetwork.gateway
                    // Dual-stack network: the NIC gets one address per family.
                    let allocation6 = try await IPAMService.allocateIPv6(for: logicalNetwork, on: db)
                    let networkGateway6 = logicalNetwork.gateway6

                    let networkInterface = VMNetworkInterface(
                        vmID: vmID,
                        logicalNetworkID: logicalNetworkID,
                        macAddress: VMNetworkInterface.generateMACAddress()
                    )
                    try await networkInterface.save(on: db)

                    // The ≥1-group invariant: the NIC joins the requested
                    // security groups, or the project's default group when the
                    // caller picked none.
                    let groupIds: [UUID]
                    if requestedSecurityGroupIds.isEmpty {
                        let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                            projectID: projectId, on: db)
                        groupIds = [try defaultGroup.requireID()]
                    } else {
                        groupIds = requestedSecurityGroupIds
                    }
                    for groupId in groupIds {
                        try await VMInterfaceSecurityGroup(
                            interfaceID: try networkInterface.requireID(),
                            securityGroupID: groupId
                        ).save(on: db)
                    }

                    let address = VMInterfaceAddress(
                        interfaceID: try networkInterface.requireID(),
                        logicalNetworkID: logicalNetworkID,
                        family: .ipv4,
                        address: allocation.ipAddress,
                        prefixLength: allocation.prefixLength,
                        gateway: networkGateway
                    )
                    try await address.save(on: db)
                    if let allocation6 {
                        let address6 = VMInterfaceAddress(
                            interfaceID: try networkInterface.requireID(),
                            logicalNetworkID: logicalNetworkID,
                            family: .ipv6,
                            address: allocation6.ipAddress,
                            prefixLength: allocation6.prefixLength,
                            gateway: networkGateway6
                        )
                        try await address6.save(on: db)
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
                    // A `spiffe_id` collision — an administrator having
                    // hand-registered this VM's URI while `/vm/` is still
                    // unreserved (STR-165) — is a constraint failure, which the
                    // retry wrapper answers by redrawing the VM's id and
                    // therefore its identity, exactly as it answers an IPAM
                    // address race.
                    try await GuestIdentity.register(
                        vmID: vmID,
                        organizationID: rootOrganizationID,
                        createdBy: userID,
                        on: db
                    )

                    return ResourceMutation.Accepted(
                        mutationID: try event.requireID(), targetGeneration: vm.generation)
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
                    "project_id": .string(projectId.uuidString),
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
            .create, resourceType: VM.self, resourceID: vmID, hypervisorId: nil,
            strategy: .placement { @Sendable [app = req.application] db in
                try await app.agentService.createVM(vm: vm, db: db, image: image)
            }, app: req.application)

        req.logger.info(
            "VM creation accepted",
            metadata: [
                "vm_id": .string(vmID.uuidString),
                "mutation_id": .string(accepted.mutationID.uuidString),
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
    /// * **Running VM** — the change must fit the ceilings the running
    ///   process was spawned with, so it is validated against them, reserved
    ///   against quota, and written as a desired-state change with a
    ///   generation bump. The agent's reconciler diffs the new spec against
    ///   what the VM is running and hot-adds the difference. Answers `202`
    ///   with the operation to poll, like the other agent-backed mutations.
    ///
    /// Metadata-only updates keep their historical `200` + VM body.
    func update(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let existingVM = try await fetchVMWithPermission(req: req, permission: "update")

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

            enum CodingKeys: String, CodingKey {
                case name, hostname, description, cpu, memory, balloonTarget
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decodeIfPresent(String.self, forKey: .name)
                hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
                description = try c.decodeIfPresent(String.self, forKey: .description)
                cpu = try c.decodeIfPresent(Int.self, forKey: .cpu)
                memory = try c.decodeIfPresent(Int64.self, forKey: .memory)
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

        if let description = updateRequest.description {
            existingVM.description = description
        }

        let newCPU = updateRequest.cpu ?? existingVM.cpu
        let newMemory = updateRequest.memory ?? existingVM.memory
        let newBalloonTarget = updateRequest.balloonTarget ?? existingVM.balloonTarget
        let balloonChanged = newBalloonTarget != existingVM.balloonTarget
        guard newCPU != existingVM.cpu || newMemory != existingVM.memory || balloonChanged else {
            try await existingVM.save(on: req.db)
            if hostnameChanged { await req.application.agentService.syncDesiredStateToFleet() }
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
        let cpuDelta = newCPU - existingVM.cpu
        let memoryDelta = newMemory - existingVM.memory

        // A resting VM re-spawns from the new spec on its next boot, so both
        // the sizing and its ceilings can move freely.
        guard existingVM.status == .running else {
            guard existingVM.status == .created || existingVM.status == .shutdown || existingVM.status == .error
            else {
                throw Abort(
                    .conflict,
                    reason: "A VM can only be resized while it is running or stopped (this one is "
                        + "\(existingVM.status.rawValue))")
            }
            try await req.db.transaction { db in
                try await QuotaEnforcementService.reserveVMResize(
                    for: project, environment: existingVM.environment,
                    vcpuDelta: cpuDelta, memoryDelta: memoryDelta, on: db)
                existingVM.cpu = newCPU
                existingVM.memory = newMemory
                existingVM.balloonTarget = newBalloonTarget
                existingVM.maxCpu = max(existingVM.maxCpu, newCPU)
                existingVM.maxMemory = max(existingVM.maxMemory, newMemory)
                // The stopped VM still has a desired-state entry the agent
                // syncs on; bump so the new spec isn't dropped as stale.
                existingVM.bumpGeneration()
                try await existingVM.save(on: db)
            }
            if hostnameChanged { await req.application.agentService.syncDesiredStateToFleet() }
            return try await Self.detailResponse(for: existingVM, on: req)
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
        if newCPU != existingVM.cpu || newMemory != existingVM.memory {
            guard await Self.agentSupportsOnlineResize(vm: existingVM, app: req.application) else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "This VM's agent is too old to resize a running VM; restart the VM to apply a new size")
            }
        }
        if balloonChanged {
            // No "restart to apply" remedy to offer here, unlike a resize: a
            // balloon target only exists on a running guest, so an agent that
            // ignores the field can't realize it at any later point either.
            guard await Self.agentSupportsBalloonTarget(vm: existingVM, app: req.application) else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "This VM's agent is too old to set a memory balloon target; upgrade the agent")
            }
        }

        let existingVMID = try existingVM.requireID()
        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .resize, on: existingVM, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable db in
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
            existingVM.bumpGeneration()
        }
        // The resize's own dispatch reaches this VM's agent and its site
        // controller; a hostname edge riding along needs the wider ring.
        if hostnameChanged { await req.application.agentService.syncDesiredStateToFleet() }
        return try await Self.acceptedResponse(for: existingVM, accepted, on: req)
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

    /// Whether the VM's agent speaks the reconciler resize step. A pre-v17
    /// agent reports the bumped generation as converged without touching the
    /// guest, so the operation would succeed having changed nothing.
    private static func agentSupportsOnlineResize(vm: VM, app: Application) async -> Bool {
        guard let agentId = vm.hypervisorId,
            let agent = await app.agentService.getAgentInfo(agentId)
        else { return false }
        return WireProtocol.supportsVMResize(agent.wireProtocolVersion ?? 0)
    }

    /// Whether the VM's agent realizes `VMSpec.balloonTargetBytes`. A pre-v19
    /// agent reports the bumped generation as converged without touching the
    /// balloon, so the operation would succeed having reclaimed nothing.
    private static func agentSupportsBalloonTarget(vm: VM, app: Application) async -> Bool {
        guard let agentId = vm.hypervisorId,
            let agent = await app.agentService.getAgentInfo(agentId)
        else { return false }
        return WireProtocol.supportsBalloonTarget(agent.wireProtocolVersion ?? 0)
    }

    /// The VM detail DTO with its NIC children loaded. The DTO, not the model:
    /// the raw `VM` encoding would expose fields that must stay server-side
    /// (cloud-init user_data can carry secrets).
    private static func detailResponse(for vm: VM, on req: Request) async throws -> Response {
        try await detail(for: vm, on: req).encodeResponse(for: req)
    }

    /// - Parameter resolvingEnforcement: whether to ask whether the VM's
    ///   security groups are actually enforced. That answer costs its own
    ///   queries and means nothing for a VM being torn down, so the delete path
    ///   skips it and reports `nil` — "unknown", which is the truth there.
    private static func detail(
        for vm: VM, on req: Request, resolvingEnforcement: Bool = true
    ) async throws -> VMDetailResponse {
        try await vm.$networkInterfaces.load(on: req.db)
        for interface in vm.networkInterfaces {
            try await interface.$addresses.load(on: req.db)
            try await interface.$observedAddresses.load(on: req.db)
            try await interface.$securityGroupMemberships.load(on: req.db)
        }
        return try await VMDetailResponse(
            from: vm,
            securityGroupsEnforced: resolvingEnforcement
                ? SecurityGroupService.enforcement(for: vm, on: req.db) : nil,
            // Deliberately not behind `resolvingEnforcement`: that flag exists
            // because the enforcement walk costs its own queries and answers
            // nothing for a VM being torn down. This is one indexed point
            // lookup, and a client polling a delete still wants to know which
            // identity is going away.
            spiffeId: GuestIdentity.spiffeID(forVM: vm.requireID(), on: req.db))
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

    func delete(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let vm = try await fetchVMWithPermission(req: req, permission: "delete")

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
                        metadata: ["vm_id": .string(vmID.uuidString)])
                }
                let outcome: ResourceFinalizerService.ClearOutcome
                do {
                    outcome = try await ResourceFinalizerService.clear(
                        .agentAbsent, from: vm, on: db, app: app)
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
                            "vm_id": .string(vmID.uuidString),
                            "finalizers": .string(remaining.joined(separator: ",")),
                        ])
                }
                return outcome.isRemoved
            }

        let accepted = try await req.resourceMutation.accept(
            .delete, on: vm, actor: .user(userID), dispatch: strategy,
            on: req.db, app: app
        ) { @Sendable _ in
            // Stamp before the mark: `stampForDeletion` reads whether the VM
            // is already terminating, and re-stamping a second DELETE would
            // resurrect tokens their participants have already cleared.
            ResourceFinalizerService.stampForDeletion(vm)
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
        let vm = try await fetchVMWithPermission(req: req, permission: "pause")

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
        let vm = try await fetchVMWithPermission(req: req, permission: "resume")

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
        let vm = try await fetchVMWithPermission(req: req, permission: "read")

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
        return try await VMDetailResponse(
            from: vm,
            securityGroupsEnforced: SecurityGroupService.enforcement(for: vm, on: req.db),
            spiffeId: GuestIdentity.spiffeID(forVM: vm.requireID(), on: req.db))
    }

    func start(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Mutating a VM")
        let vm = try await fetchVMWithPermission(req: req, permission: "start")

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
            let authority = try await SiteNetworkAuthority.resolve(forAgent: agent, on: req.db)
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
        let vm = try await fetchVMWithPermission(req: req, permission: "stop")

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
        let vm = try await fetchVMWithPermission(req: req, permission: "restart")

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
        _ agentId: String?, requiring capability: String? = nil, app: Application
    ) async throws {
        guard let agentId else {
            throw Abort(.conflict, reason: "VM is not placed on any agent")
        }
        guard let agent = await app.agentService.getAgentInfo(agentId) else {
            throw Abort(.conflict, reason: "Agent '\(agentId)' is unknown")
        }
        guard WireProtocol.supportsEdgeNonces(agent.wireProtocolVersion ?? 0) else {
            throw Abort(
                .conflict,
                reason:
                    "Agent '\(agentId)' is too old to apply restarts and restores from the desired-state "
                    + "sync (wire protocol v\(WireProtocol.edgeNonceMinimumVersion) required). Upgrade the agent."
            )
        }
        if let capability, !agent.capabilities.contains(capability) {
            throw Abort(
                .conflict,
                reason:
                    "Agent '\(agentId)' cannot realize this request (capability '\(capability)' not "
                    + "advertised); upgrade the agent, or place the VM on a host with a backend that can.")
        }
    }
}
