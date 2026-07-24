import Fluent
import Foundation
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
        }
    }

    func listOperations(req: Request) async throws -> [OperationResponse] {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "read")
        let vmID = try vm.requireID()

        let requestedLimit: Int = req.query["limit"] ?? 20
        let limit = min(max(requestedLimit, 1), 100)

        let operations = try await ResourceOperation.query(on: req.db)
            .filter(\.$resourceKind == .virtualMachine)
            .filter(\.$resourceID == vmID)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()

        return operations.map { OperationResponse(from: $0) }
    }

    /// GET /api/vms
    /// Query params: organization_id (optional) — narrows to one org's hierarchy.
    func index(req: Request) async throws -> [VMDetailResponse] {
        // Get user from middleware
        guard req.auth.has(User.self) else {
            throw Abort(.unauthorized)
        }

        // A VM reaches its organization through its project, so narrowing by org means
        // narrowing to that org's projects. An org with no projects matches no VMs —
        // return early rather than let an empty `~~ []` stand in for "unfiltered".
        var query = VM.query(on: req.db).with(\.$networkInterfaces) {
            $0.with(\.$addresses)
            $0.with(\.$observedAddresses)
        }
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

        return allVMs.compactMap { vm in
            guard let id = vm.id, readable.contains(IAMNode(type: .virtualMachine, id: id)) else { return nil }
            return VMDetailResponse(from: vm)
        }
    }

    /// Fetch a VM by its :vmID route parameter and enforce a permission on it.
    ///
    /// Delegates to the shared `Request.authorizedVM(_:permission:)` helper so the
    /// per-object authorization logic lives in one place (also used by other VM-scoped
    /// controllers such as `LogsController`).
    private func fetchVMWithPermission(req: Request, user: User, permission: String) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        return try await req.authorizedVM(vmID, permission: permission)
    }

    func show(req: Request) async throws -> VMDetailResponse {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "read")
        try await vm.$networkInterfaces.load(on: req.db)
        for interface in vm.networkInterfaces {
            try await interface.$addresses.load(on: req.db)
            try await interface.$observedAddresses.load(on: req.db)
        }

        return VMDetailResponse(from: vm)
    }

    func create(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        struct CreateVMRequest: Content {
            let name: String
            let description: String?
            let imageId: UUID?
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
            let sshPublicKey: String?
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
            // Security groups for the VM's NIC. Omitted (or empty) means the
            // project's default group — every NIC must belong to at least one
            // group.
            let securityGroupIds: [UUID]?
        }

        let createRequest = try req.content.decode(CreateVMRequest.self)

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

        // Resolve which logical network the VM's NIC attaches to. Omitting both
        // fields keeps the historical default-network behavior (including the
        // degrade-to-addressless-NIC fallback when the row is missing); an
        // explicit selection is a hard requirement that never degrades.
        if createRequest.networkId != nil && createRequest.networkName != nil {
            throw Abort(.badRequest, reason: "Specify either 'networkId' or 'networkName', not both")
        }

        let resolvedNetworkName: String
        let networkExplicitlyRequested: Bool
        if createRequest.networkId != nil || createRequest.networkName != nil {
            let network: LogicalNetwork?
            if let networkId = createRequest.networkId {
                network = try await LogicalNetwork.find(networkId, on: req.db)
            } else {
                network = try await LogicalNetwork.query(on: req.db)
                    .filter(\.$name == createRequest.networkName!)
                    .first()
            }
            guard let network else {
                throw Abort(.badRequest, reason: "Network not found")
            }

            // The caller already proved membership in this VM's project above, so
            // no extra permission check is needed: a global network (nil project) is
            // usable by anyone, and a project-scoped network is usable only by the
            // project it belongs to.
            if let networkProjectId = network.$project.id, networkProjectId != projectId {
                throw Abort(.forbidden, reason: "Network belongs to a different project")
            }

            resolvedNetworkName = network.name
            networkExplicitlyRequested = true
        } else {
            resolvedNetworkName = LogicalNetwork.defaultNetworkName
            networkExplicitlyRequested = false
        }

        // Resolve the NIC's security groups. Explicit ids must exist, belong
        // to this project, and fit the per-NIC cap; omitted (or empty) means
        // the project's default group, ensured inside the create transaction.
        // No agent-version gate here: VM create must work on a pre-security-
        // group fleet, where assembly simply omits the fields (documented
        // mixed-fleet rollout semantics).
        let requestedSecurityGroupIds: [UUID] = (createRequest.securityGroupIds ?? [])
            .reduce(into: []) { unique, groupId in
                if !unique.contains(groupId) { unique.append(groupId) }
            }
        if requestedSecurityGroupIds.count > SecurityGroup.maxGroupsPerNIC {
            throw Abort(
                .badRequest,
                reason: "At most \(SecurityGroup.maxGroupsPerNIC) security groups per interface")
        }
        for groupId in requestedSecurityGroupIds {
            guard let group = try await SecurityGroup.find(groupId, on: req.db) else {
                throw Abort(.badRequest, reason: "Security group \(groupId) does not exist")
            }
            guard group.$project.id == projectId else {
                throw Abort(.badRequest, reason: "Security group \(groupId) belongs to a different project")
            }
        }

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
        guard diskValue > 0 else {
            throw Abort(.badRequest, reason: "'disk' must be positive")
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
            tpmEnabled: createRequest.tpm ?? false
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

        // Guest login: authorize the caller-provided SSH public key via cloud-init.
        vm.sshPublicKey = createRequest.sshPublicKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

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

        let userID = try user.requireID()

        // Reserve quota and persist the VM and its pending create operation in one
        // transaction: enforcement checks, the reservation bump, the initial insert,
        // the path update, and the operation record all commit together or roll back
        // together, so a quota rejection leaves nothing behind.
        let operation: ResourceOperation
        do {
            // IPAM's unique (network, address) index is the backstop against
            // concurrent creates racing to the same address. A violation
            // poisons the whole Postgres transaction, so the retry wraps the
            // transaction (not the insert): the loser re-reads the used set
            // and allocates the next free address.
            let initialGeneration = vm.generation
            operation = try await Self.retryingOnConstraintFailure {
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

                    // Save VM to database first to generate ID
                    try await vm.save(on: db)

                    // Generate unique paths and configurations using the generated ID
                    let vmID = try vm.requireID()

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

                    // Every VM starts with one NIC on the resolved network (the default
                    // network unless the caller picked one). The control plane owns IPAM
                    // (issue #212): allocate the NIC's address from the logical network
                    // here so agents receive it in the spec instead of inventing one.
                    // For the implicit default, a missing network row (pre-migration
                    // data) degrades to an address-less NIC, matching the old behavior;
                    // an explicitly requested network must exist, so its absence fails.
                    let networkName = resolvedNetworkName
                    var allocation: IPAMService.Allocation?
                    var allocation6: IPAMService.Allocation6?
                    var networkGateway: String?
                    var networkGateway6: String?
                    if let logicalNetwork = try await LogicalNetwork.query(on: db)
                        .filter(\.$name == networkName)
                        .first()
                    {
                        allocation = try await IPAMService.allocateIP(for: logicalNetwork, on: db)
                        networkGateway = logicalNetwork.gateway
                        // Dual-stack network: the NIC gets one address per family.
                        allocation6 = try await IPAMService.allocateIPv6(for: logicalNetwork, on: db)
                        networkGateway6 = logicalNetwork.gateway6
                    } else if networkExplicitlyRequested {
                        throw Abort(.badRequest, reason: "Network '\(networkName)' no longer exists")
                    }

                    let networkInterface = VMNetworkInterface(
                        vmID: vmID,
                        network: networkName,
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

                    if let allocation {
                        let address = VMInterfaceAddress(
                            interfaceID: try networkInterface.requireID(),
                            network: networkName,
                            family: .ipv4,
                            address: allocation.ipAddress,
                            prefixLength: allocation.prefixLength,
                            gateway: networkGateway
                        )
                        try await address.save(on: db)
                    }
                    if let allocation6 {
                        let address6 = VMInterfaceAddress(
                            interfaceID: try networkInterface.requireID(),
                            network: networkName,
                            family: .ipv6,
                            address: allocation6.ipAddress,
                            prefixLength: allocation6.prefixLength,
                            gateway: networkGateway6
                        )
                        try await address6.save(on: db)
                    }

                    // The pending create operation is the client's handle on the
                    // asynchronous agent work that follows (issue #259).
                    let operation = ResourceOperation(vmID: vmID, userID: userID, kind: .create)
                    try await operation.save(on: db)

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

                    return operation
                }
            }
        } catch let error as IPAMService.IPAMError {
            // The chosen network's subnet is full; the whole transaction rolled
            // back, so no VM was created.
            throw Abort(.conflict, reason: error.errorDescription ?? "No free IP addresses in the selected network")
        }

        let vmID = try vm.requireID()

        // Place the VM in the background: the scheduler selects a hypervisor
        // and persists hypervisorId, and the desired-state sync carries the
        // VM (spec assembled from the database) to its agent. Observed-state
        // reports — not this request — decide the operation's verdict.
        req.resourceOperationCoordinator.dispatch(
            operation, resourceKind: .virtualMachine, resourceID: vmID, hypervisorId: nil,
            dispatch: .placement { @Sendable [app = req.application] db in
                try await app.agentService.createVM(vm: vm, db: db, image: image)
            }, app: req.application)

        req.logger.info(
            "VM creation accepted",
            metadata: [
                "vm_id": .string(vmID.uuidString),
                "operation_id": .string(operation.id?.uuidString ?? ""),
                "created_from": .string("image"),
            ])

        return try operation.acceptedResponse()
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
        let user = try req.auth.require(User.self)
        let existingVM = try await fetchVMWithPermission(req: req, user: user, permission: "update")

        // Decodable rather than Content: `balloonTarget` needs to tell an
        // absent key from an explicit null, which needs a hand-written decode,
        // and Content's Encodable half has nothing to encode here.
        struct UpdateVMRequest: Decodable {
            let name: String?
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
                case name, description, cpu, memory, balloonTarget
            }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decodeIfPresent(String.self, forKey: .name)
                description = try c.decodeIfPresent(String.self, forKey: .description)
                cpu = try c.decodeIfPresent(Int.self, forKey: .cpu)
                memory = try c.decodeIfPresent(Int64.self, forKey: .memory)
                balloonTarget =
                    c.contains(.balloonTarget)
                    ? .some(try c.decodeIfPresent(Int64.self, forKey: .balloonTarget)) : .none
            }
        }

        let updateRequest = try req.content.decode(UpdateVMRequest.self)

        if let name = updateRequest.name {
            existingVM.name = name
        }

        if let description = updateRequest.description {
            existingVM.description = description
        }

        let newCPU = updateRequest.cpu ?? existingVM.cpu
        let newMemory = updateRequest.memory ?? existingVM.memory
        let newBalloonTarget = updateRequest.balloonTarget ?? existingVM.balloonTarget
        let balloonChanged = newBalloonTarget != existingVM.balloonTarget
        guard newCPU != existingVM.cpu || newMemory != existingVM.memory || balloonChanged else {
            try await existingVM.save(on: req.db)
            return try await Self.detailResponse(for: existingVM, on: req)
        }

        guard newCPU > 0 else { throw Abort(.badRequest, reason: "'cpu' must be positive") }
        guard newMemory > 0 else { throw Abort(.badRequest, reason: "'memory' must be positive") }
        guard newCPU <= Self.maxHotpluggableCPUs else {
            throw Abort(.badRequest, reason: "'cpu' must not exceed \(Self.maxHotpluggableCPUs)")
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
        let operation = try await req.resourceOperationCoordinator.perform(
            .resize, resourceKind: .virtualMachine, resourceID: existingVMID, userID: userID,
            hypervisorId: existingVM.hypervisorId, dispatch: .stateSync, on: req.db, app: req.application
        ) { @Sendable db in
            try await QuotaEnforcementService.reserveVMResize(
                for: project, environment: existingVM.environment,
                vcpuDelta: cpuDelta, memoryDelta: memoryDelta, on: db)
            existingVM.cpu = newCPU
            existingVM.memory = newMemory
            // Deliberately not a quota movement: ballooning reclaims memory
            // opportunistically, the grant the project is charged for is
            // still committed, and the guest takes it all back the moment the
            // target is cleared.
            existingVM.balloonTarget = newBalloonTarget
            // Desired status is unchanged — this is a spec change — but the
            // generation must still advance for the agent to apply it.
            existingVM.bumpGeneration()
            try await existingVM.save(on: db)
        }
        return try operation.acceptedResponse()
    }

    /// Upper bound on a VM's vCPU count, and so on the hotplug slots QEMU is
    /// spawned with. Well above any host Strato schedules onto, low enough
    /// that a mistyped ceiling can't produce an unbootable machine.
    static let maxHotpluggableCPUs = 512

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
        try await vm.$networkInterfaces.load(on: req.db)
        for interface in vm.networkInterfaces {
            try await interface.$addresses.load(on: req.db)
            try await interface.$observedAddresses.load(on: req.db)
        }
        return try await VMDetailResponse(from: vm).encodeResponse(for: req)
    }

    func delete(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "delete")

        // Deletion via state sync: desired becomes `.absent`, the agent tears
        // the VM down on its next sync, and the row is removed only once a
        // report confirms absence — so the delete survives restarts on both
        // sides. Unassigned VMs and offline agents keep a direct database
        // path: dead agents must not make their VMs undeletable, and there is
        // no agent to confirm anything anyway.
        let vmID = try vm.requireID()
        let userID = try user.requireID()
        let app = req.application
        let agentOnline: Bool
        if let hypervisorId = vm.hypervisorId {
            agentOnline = await app.agentService.agentIsOnline(agentId: hypervisorId)
        } else {
            agentOnline = false
        }

        // Offline/unassigned: remove the record directly without agent teardown.
        // If the agent ever comes back still carrying the VM, its observed-state
        // report surfaces it as an orphan for operator attention.
        let strategy: ResourceOperationCoordinator.Strategy =
            agentOnline
            ? .stateSync
            : .directResolution { @Sendable db in
                if vm.hypervisorId != nil {
                    app.logger.warning(
                        "Deleting VM record without agent teardown; agent is offline",
                        metadata: ["vm_id": .string(vmID.uuidString)])
                }
                // Delete the VM, then recompute its quotas from the remaining
                // VMs, in one transaction so the reservation counters and the
                // VM row stay consistent.
                do {
                    try await db.transaction { db in
                        try await vm.delete(on: db)
                        try await QuotaEnforcementService.release(for: vm, on: db)
                    }
                } catch {
                    throw ResourceOperationCoordinator.WorkError(
                        "Failed to delete VM record: \(error.localizedDescription)")
                }
            }

        let operation = try await req.resourceOperationCoordinator.perform(
            .delete, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
            hypervisorId: vm.hypervisorId, dispatch: strategy, on: req.db, app: app
        ) { @Sendable db in
            vm.setDesiredStatus(.absent)
            try await vm.save(on: db)
        }
        return try operation.acceptedResponse()
    }

    func pause(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "pause")

        guard vm.canPause else {
            throw Abort(.badRequest, reason: "VM cannot be paused in current state: \(vm.status.rawValue)")
        }

        // No transitional status exists for pause; the VM stays `.running` until
        // the agent confirms, and the operation record carries the in-flight state.
        let vmID = try vm.requireID()
        let userID = try user.requireID()
        let operation = try await req.resourceOperationCoordinator.perform(
            .pause, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
            hypervisorId: vm.hypervisorId, dispatch: .stateSync, on: req.db, app: req.application
        ) { @Sendable db in
            vm.setDesiredStatus(.paused)
            try await vm.save(on: db)
        }

        return try operation.acceptedResponse()
    }

    func resume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "resume")

        guard vm.canResume else {
            throw Abort(.badRequest, reason: "VM cannot be resumed in current state: \(vm.status.rawValue)")
        }

        // Counterpart of pause: the VM stays `.paused` until the agent confirms.
        let vmID = try vm.requireID()
        let userID = try user.requireID()
        let operation = try await req.resourceOperationCoordinator.perform(
            .resume, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
            hypervisorId: vm.hypervisorId, dispatch: .stateSync, on: req.db, app: req.application
        ) { @Sendable db in
            vm.setDesiredStatus(.running)
            try await vm.save(on: db)
        }

        return try operation.acceptedResponse()
    }

    func status(req: Request) async throws -> VMDetailResponse {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "read")

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
        }
        return VMDetailResponse(from: vm)
    }

    func start(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "start")

        guard vm.canStart else {
            throw Abort(.badRequest, reason: "VM cannot be started in current state: \(vm.status.rawValue)")
        }

        // The desired status and generation bump are the mutation;
        // observed-state reports complete the operation (issue #260). No
        // transitional `.starting` is stored — in-flight state is derived
        // from desired != observed plus the pending operation.
        let vmID = try vm.requireID()
        let userID = try user.requireID()
        let operation = try await req.resourceOperationCoordinator.perform(
            .boot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
            hypervisorId: vm.hypervisorId, dispatch: .stateSync, on: req.db, app: req.application
        ) { @Sendable db in
            vm.setDesiredStatus(.running)
            try await vm.save(on: db)
        }

        return try operation.acceptedResponse()
    }

    func stop(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "stop")

        guard vm.canStop else {
            throw Abort(.badRequest, reason: "VM cannot be stopped in current state: \(vm.status.rawValue)")
        }

        let vmID = try vm.requireID()
        let userID = try user.requireID()
        let operation = try await req.resourceOperationCoordinator.perform(
            .shutdown, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
            hypervisorId: vm.hypervisorId, dispatch: .stateSync, on: req.db, app: req.application
        ) { @Sendable db in
            vm.setDesiredStatus(.shutdown)
            try await vm.save(on: db)
        }

        return try operation.acceptedResponse()
    }

    func restart(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "restart")

        guard vm.isRunning else {
            throw Abort(.badRequest, reason: "VM must be running to restart. Current state: \(vm.status.rawValue)")
        }

        // A reboot starts and ends `.running`, so no status change on any
        // outcome; it is an action, not a state, so it awaits an imperative
        // agent response rather than riding the desired-state sync. A failure
        // is visible on the operation record.
        let vmID = try vm.requireID()
        let userID = try user.requireID()
        let operation = try await req.resourceOperationCoordinator.perform(
            .reboot, resourceKind: .virtualMachine, resourceID: vmID, userID: userID,
            hypervisorId: vm.hypervisorId, dispatch: .awaitingResponse(.vmReboot),
            on: req.db, app: req.application)

        return try operation.acceptedResponse()
    }
}
