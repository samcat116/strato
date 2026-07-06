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

    // MARK: - Async operation plumbing (issue #259)

    /// Creates the pending operation record and applies the VM's in-flight status
    /// change in one transaction, rejecting with `409 Conflict` when any operation
    /// is already pending for the VM — the double-submit guard from issue #259.
    private func beginOperation(
        _ kind: VMOperationKind,
        vm: VM,
        user: User,
        settingVMStatus transitionalStatus: VMStatus? = nil,
        settingDesiredStatus desiredStatus: DesiredVMStatus? = nil,
        on db: Database
    ) async throws -> VMOperation {
        let vmID = try vm.requireID()
        let userID = try user.requireID()

        return try await db.transaction { db in
            // Read first for a friendly reason naming the conflicting kind; the
            // partial unique index on pending operations (CreateVMOperation) is
            // what actually closes the race when two mutations arrive at once.
            if let pending = try await VMOperation.query(on: db)
                .filter(\.$vmID == vmID)
                .filter(\.$status == .pending)
                .first()
            {
                throw Abort(
                    .conflict,
                    reason: "A \(pending.kind.rawValue) operation is already pending for this VM")
            }

            let operation = VMOperation(vmID: vmID, userID: userID, kind: kind)
            do {
                try await operation.save(on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw Abort(.conflict, reason: "An operation is already pending for this VM")
            }

            // Desired state and its generation bump commit atomically with the
            // operation record (issue #260); the sync to the agent is a
            // fire-and-forget nudge, with the periodic timer as the backstop.
            if let desiredStatus {
                vm.setDesiredStatus(desiredStatus)
            }
            if let transitionalStatus {
                vm.setStatus(transitionalStatus)
            }
            if desiredStatus != nil || transitionalStatus != nil {
                try await vm.save(on: db)
            }

            return operation
        }
    }

    /// Whether the VM's owning agent is online somewhere in the cluster.
    /// Heartbeats through any replica keep the shared registry row fresh, so
    /// this view is replica-independent. False for unassigned VMs.
    private static func agentIsOnline(vm: VM, app: Application) async -> Bool {
        guard let agentId = vm.hypervisorId else { return false }
        guard let agent = await app.agentService.getAgentInfo(agentId) else { return false }
        return agent.status == .online
    }

    /// Push the freshly written desired state to the VM's agent — directly
    /// when this replica holds its socket, via a pub/sub nudge to the holding
    /// replica otherwise. Losing this nudge is safe — the periodic sync timer
    /// re-sends the full state.
    ///
    /// A VM with no agent — or one whose agent is offline cluster-wide — has
    /// nowhere to converge right now: fail the operation immediately (which
    /// also realigns desired state) instead of letting it sit pending for the
    /// stuck-operation sweep's multi-minute budget. This mirrors both the old
    /// imperative path's dispatch failure and `delete`'s offline handling.
    private static func dispatchStateSync(_ operation: VMOperation, vm: VM, app: Application) {
        guard let operationId = operation.id else { return }
        let vmID = operation.vmID

        guard let agentId = vm.hypervisorId else {
            Task {
                await completeOperation(
                    operationId, vmID: vmID, as: .failed,
                    error: AgentServiceError.vmNotMapped(vmID.uuidString).localizedDescription,
                    settingVMStatus: nil, app: app)
            }
            return
        }
        Task {
            guard let agent = await app.agentService.getAgentInfo(agentId), agent.status == .online else {
                await completeOperation(
                    operationId, vmID: vmID, as: .failed,
                    error: "Agent \(agentId) is offline; the VM cannot converge to the requested state",
                    settingVMStatus: nil, app: app)
                return
            }
            await app.agentService.syncDesiredState(agentId: agentId)
        }
    }

    /// `202 Accepted` carrying the operation record for the client to poll.
    private static func accepted(_ operation: VMOperation) throws -> Response {
        let response = Response(status: .accepted)
        try response.content.encode(OperationResponse(from: operation))
        return response
    }

    /// Records the verdict of an agent call on the operation row and resolves the
    /// VM status it left in flight. Every effect is gated on the operation still
    /// being pending, so whichever completes first — this path or the
    /// stuck-operation sweep — wins, and the loser is a no-op.
    private static func completeOperation(
        _ operationId: UUID,
        vmID: UUID,
        as status: VMOperationStatus,
        error: String?,
        settingVMStatus vmStatus: VMStatus?,
        app: Application
    ) async {
        do {
            guard let operation = try await VMOperation.find(operationId, on: app.db),
                try await operation.completeIfPending(as: status, error: error, on: app.db)
            else { return }

            if status == .failed {
                app.logger.warning(
                    "VM operation failed",
                    metadata: [
                        "operationId": .string(operationId.uuidString),
                        "vmId": .string(vmID.uuidString),
                        "kind": .string(operation.kind.rawValue),
                        "error": .string(error ?? "unknown"),
                    ])
            }

            if let vm = try await VM.find(vmID, on: app.db) {
                var changed = false
                if let vmStatus {
                    vm.setStatus(vmStatus)
                    changed = true
                    if vmStatus == .error {
                        Telemetry.vmEnteredError(reason: "operation_failed")
                    }
                }
                // A failed operation's intent was not achieved and the user has
                // been told — realign desired state with observed reality so the
                // divergence doesn't replay later (e.g. a failed delete's
                // `.absent` executing after the agent upgrades to state sync).
                if status == .failed, vm.revertDesiredToObserved() {
                    changed = true
                }
                if changed {
                    try await vm.save(on: app.db)
                }
            }
        } catch {
            app.logger.error(
                "Failed to record operation completion: \(error)",
                metadata: ["operationId": .string(operationId.uuidString)])
        }
    }

    /// Runs one agent-backed lifecycle operation in the background and records its
    /// outcome on the operation row. The HTTP response has already gone out with
    /// `202`, so nothing here may assume the request is still alive.
    ///
    /// The three status parameters resolve the VM once the operation completes:
    /// `statusOnDispatchFailure` applies when the request never reached an agent
    /// (no mapping, agent gone) — the VM is restored rather than escalated,
    /// mirroring the old synchronous handling.
    private static func runVMOperation(
        _ operation: VMOperation,
        sending messageType: MessageType,
        statusOnSuccess: VMStatus?,
        statusOnFailure: VMStatus?,
        statusOnDispatchFailure: VMStatus?,
        app: Application
    ) {
        guard let operationId = operation.id else { return }
        let vmID = operation.vmID
        let budget = operation.kind.completionBudget

        Task {
            do {
                let response = try await app.agentService.performVMOperationAwaitingResponse(
                    messageType, vmId: vmID.uuidString, timeout: budget)

                switch response {
                case .success:
                    await completeOperation(
                        operationId, vmID: vmID, as: .succeeded, error: nil,
                        settingVMStatus: statusOnSuccess, app: app)
                case .error(let message, let details):
                    let reason = details.map { "\(message): \($0)" } ?? message
                    await completeOperation(
                        operationId, vmID: vmID, as: .failed, error: reason,
                        settingVMStatus: statusOnFailure, app: app)
                }
            } catch {
                switch error {
                case AgentServiceError.vmNotMapped, AgentServiceError.agentNotFound:
                    await completeOperation(
                        operationId, vmID: vmID, as: .failed,
                        error: error.localizedDescription,
                        settingVMStatus: statusOnDispatchFailure, app: app)
                default:
                    await completeOperation(
                        operationId, vmID: vmID, as: .failed,
                        error: error.localizedDescription,
                        settingVMStatus: statusOnFailure, app: app)
                }
            }
        }
    }

    func listOperations(req: Request) async throws -> [OperationResponse] {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "read")
        let vmID = try vm.requireID()

        let requestedLimit: Int = req.query["limit"] ?? 20
        let limit = min(max(requestedLimit, 1), 100)

        let operations = try await VMOperation.query(on: req.db)
            .filter(\.$vmID == vmID)
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()

        return operations.map { OperationResponse(from: $0) }
    }

    func index(req: Request) async throws -> [VMDetailResponse] {
        // Get user from middleware
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Filter VMs based on user permissions
        let allVMs = try await VM.query(on: req.db).with(\.$networkInterfaces).all()
        var authorizedVMs: [VMDetailResponse] = []

        for vm in allVMs {
            let hasPermission = try await req.spicedb.checkPermission(
                subject: user.id?.uuidString ?? "",
                permission: "read",
                resource: "virtual_machine",
                resourceId: vm.id?.uuidString ?? ""
            )

            if hasPermission {
                authorizedVMs.append(VMDetailResponse(from: vm))
            }
        }

        return authorizedVMs
    }

    /// Fetch a VM by its :vmID route parameter and enforce a SpiceDB permission on it.
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

        return VMDetailResponse(from: vm)
    }

    func create(req: Request) async throws -> Response {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        struct CreateVMRequest: Content {
            let name: String
            let description: String?
            let templateName: String?  // Optional - either template or image required
            let imageId: UUID?  // Optional - either template or image required
            let projectId: UUID?
            let environment: String?
            let cpu: Int?
            let memory: Int64?
            let disk: Int64?
            let cmdline: String?
            let networkId: UUID?
            let networkName: String?
            // SSH public key authorized for the guest's default user (cloud-init).
            let sshPublicKey: String?
            // Target hypervisor. Optional: when omitted, it's inferred from the
            // image's artifact set if that set is compatible with exactly one
            // hypervisor, else falls back to the platform default (QEMU).
            let hypervisorType: HypervisorType?
        }

        let createRequest = try req.content.decode(CreateVMRequest.self)

        // Validate that either templateName or imageId is provided (but not both)
        if createRequest.templateName == nil && createRequest.imageId == nil {
            throw Abort(.badRequest, reason: "Either 'templateName' or 'imageId' must be provided")
        }
        if createRequest.templateName != nil && createRequest.imageId != nil {
            throw Abort(.badRequest, reason: "Cannot specify both 'templateName' and 'imageId'")
        }

        // Variables to hold template or image
        var template: VMTemplate?
        var image: Image?

        if let templateName = createRequest.templateName {
            // Find the template
            guard
                let foundTemplate = try await VMTemplate.query(on: req.db)
                    .filter(\VMTemplate.$imageName, .equal, templateName)
                    .filter(\VMTemplate.$isActive, .equal, true)
                    .first()
            else {
                throw Abort(.badRequest, reason: "Template '\(templateName)' not found or inactive")
            }
            template = foundTemplate
        } else if let imageId = createRequest.imageId {
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
            let hasImagePermission = try await req.spicedb.checkPermission(
                subject: user.id?.uuidString ?? "",
                permission: "read",
                resource: "image",
                resourceId: imageId.uuidString
            )

            guard hasImagePermission else {
                throw Abort(.forbidden, reason: "Access denied to image")
            }

            image = foundImage
        }

        // Determine project context
        let projectId: UUID
        if let requestedProjectId = createRequest.projectId {
            // Verify user has access to the requested project
            guard let project = try await Project.find(requestedProjectId, on: req.db) else {
                throw Abort(.badRequest, reason: "Project not found")
            }

            // Verify user belongs to the project's organization
            let rootOrgId = try await project.getRootOrganizationId(on: req.db)
            guard let orgId = rootOrgId, user.currentOrganizationId == orgId else {
                throw Abort(.forbidden, reason: "Access denied to project")
            }

            projectId = requestedProjectId
        } else {
            guard let currentOrgId = user.currentOrganizationId else {
                throw Abort(.badRequest, reason: "No current organization set. Please specify a project.")
            }

            // Find or create default project for organization
            let defaultProject = try await Project.query(on: req.db)
                .filter(\Project.$organization.$id, .equal, currentOrgId)
                .filter(\Project.$name, .equal, "Default Project")
                .first()

            guard let project = defaultProject else {
                throw Abort(.badRequest, reason: "No default project found. Please specify a project.")
            }
            projectId = project.id!
        }

        // Get project to validate environment
        guard let project = try await Project.find(projectId, on: req.db) else {
            throw Abort(.internalServerError, reason: "Project not found")
        }

        // Determine environment
        let environment = createRequest.environment ?? project.defaultEnvironment

        // Validate environment exists in project
        if !project.hasEnvironment(environment) {
            throw Abort(
                .badRequest,
                reason:
                    "Environment '\(environment)' not available in project. Available: \(project.environments.joined(separator: ", "))"
            )
        }

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
            // no extra SpiceDB check is needed: a global network (nil project) is
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

        // Create VM instance - either from template or image
        let vm: VM
        if let template = template {
            // Template-based VM creation (legacy)
            vm = try template.createVMInstance(
                name: createRequest.name,
                description: createRequest.description ?? "",
                projectID: projectId,
                environment: environment,
                cpu: createRequest.cpu,
                memory: createRequest.memory,
                disk: createRequest.disk,
                cmdline: createRequest.cmdline
            )
        } else if let image = image {
            // Image-based VM creation (new)
            // Pre-compute values to avoid complex expression
            let cpuValue = createRequest.cpu ?? image.defaultCpu ?? 1
            let memoryValue = createRequest.memory ?? image.defaultMemory ?? Int64(1024 * 1024 * 1024)
            let diskValue = createRequest.disk ?? image.defaultDisk ?? Int64(10 * 1024 * 1024 * 1024)
            let cmdlineValue = createRequest.cmdline ?? image.defaultCmdline

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

            vm = VM(
                name: createRequest.name,
                description: createRequest.description ?? "",
                image: image.name,
                projectID: projectId,
                environment: environment,
                cpu: cpuValue,
                memory: memoryValue,
                disk: diskValue,
                hypervisorType: chosenHypervisor,
                maxCpu: cpuValue
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
        } else {
            throw Abort(.internalServerError, reason: "Neither template nor image available")
        }

        // Guest login: authorize the caller-provided SSH public key via cloud-init.
        vm.sshPublicKey = createRequest.sshPublicKey?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        // Bind an immutable copy for the @Sendable transaction closure below; the
        // template selection is final by this point.
        let resolvedTemplate = template
        let userID = try user.requireID()

        // Reserve quota and persist the VM and its pending create operation in one
        // transaction: enforcement checks, the reservation bump, the initial insert,
        // the path update, and the operation record all commit together or roll back
        // together, so a quota rejection leaves nothing behind.
        let operation: VMOperation
        do {
            operation = try await req.db.transaction { db in
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

                if let template = resolvedTemplate {
                    // Template-based paths
                    vm.diskPath = template.generateDiskPath(for: vmID)
                    vm.kernelPath = template.kernelPath
                    vm.initramfsPath = template.initramfsPath
                    vm.firmwarePath = template.firmwarePath
                    vm.cmdline = vm.cmdline ?? template.defaultCmdline
                } else {
                    // Image-based paths - disk will be created by agent from cached image
                    vm.diskPath = "/var/lib/strato/vms/\(vmID)/disk.qcow2"
                }

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
                var networkGateway: String?
                if let logicalNetwork = try await LogicalNetwork.query(on: db)
                    .filter(\.$name == networkName)
                    .first()
                {
                    allocation = try await IPAMService.allocateIP(for: logicalNetwork, on: db)
                    networkGateway = logicalNetwork.gateway
                } else if networkExplicitlyRequested {
                    throw Abort(.badRequest, reason: "Network '\(networkName)' no longer exists")
                }

                let networkInterface = VMNetworkInterface(
                    vmID: vmID,
                    network: networkName,
                    macAddress: resolvedTemplate?.generateMacAddress()
                        ?? VMNetworkInterface.generateMACAddress(),
                    ipAddress: allocation?.ipAddress,
                    netmask: allocation?.netmask,
                    gateway: networkGateway
                )
                try await networkInterface.save(on: db)

                // The pending create operation is the client's handle on the
                // asynchronous agent work that follows (issue #259).
                let operation = VMOperation(vmID: vmID, userID: userID, kind: .create)
                try await operation.save(on: db)

                return operation
            }
        } catch let error as IPAMService.IPAMError {
            // The chosen network's subnet is full; the whole transaction rolled
            // back, so no VM was created.
            throw Abort(.conflict, reason: error.errorDescription ?? "No free IP addresses in the selected network")
        }

        let vmID = try vm.requireID()

        // Create relationships in SpiceDB
        let vmId = vm.id?.uuidString ?? ""
        let userId = user.id?.uuidString ?? ""

        // Create ownership relationship
        try await req.spicedb.writeRelationship(
            entity: "virtual_machine",
            entityId: vmId,
            relation: "owner",
            subject: "user",
            subjectId: userId
        )

        // Link VM to project
        try await req.spicedb.writeRelationship(
            entity: "virtual_machine",
            entityId: vmId,
            relation: "project",
            subject: "project",
            subjectId: projectId.uuidString
        )

        if let currentOrgId = user.currentOrganizationId {
            try await req.spicedb.writeRelationship(
                entity: "virtual_machine",
                entityId: vmId,
                relation: "organization",
                subject: "organization",
                subjectId: currentOrgId.uuidString
            )
        }

        // Place the VM in the background: the scheduler selects a hypervisor
        // and persists hypervisorId, and the desired-state sync carries the
        // VM (spec assembled from the database) to its agent. Observed-state
        // reports — not this request — decide the operation's verdict.
        Self.runVMCreation(operation, vm: vm, image: image, app: req.application)

        req.logger.info(
            "VM creation accepted",
            metadata: [
                "vm_id": .string(vmID.uuidString),
                "operation_id": .string(operation.id?.uuidString ?? ""),
                "created_from": .string(template != nil ? "template" : "image"),
            ])

        return try Self.accepted(operation)
    }

    /// Background half of `create`: scheduling, reservation, and the placement
    /// write all happen here, after the `202` went out. On success the desired
    /// state is persisted and synced; the agent's observed-state reports
    /// complete the operation (the stuck-operation sweep backstops its
    /// budget). A failure — no schedulable agent, placement write error —
    /// lands on the operation record and marks the VM `.error` so it never
    /// poses as a healthy `.created` VM that has no backing.
    private static func runVMCreation(
        _ operation: VMOperation,
        vm: VM,
        image: Image?,
        app: Application
    ) {
        guard let operationId = operation.id else { return }
        let vmID = operation.vmID

        Task {
            do {
                // The image constrains placement (architecture match); the
                // sync itself re-reads everything it needs from the database.
                try await app.agentService.createVM(vm: vm, db: app.db, image: image)
            } catch {
                await completeOperation(
                    operationId, vmID: vmID, as: .failed, error: error.localizedDescription,
                    settingVMStatus: .error, app: app)
            }
        }
    }

    func update(req: Request) async throws -> VM {
        let user = try req.auth.require(User.self)
        let existingVM = try await fetchVMWithPermission(req: req, user: user, permission: "update")

        struct UpdateVMRequest: Content {
            let name: String?
            let description: String?
        }

        let updateRequest = try req.content.decode(UpdateVMRequest.self)

        // Only allow updating name and description for now
        // Resource changes would require VM shutdown and recreation
        if let name = updateRequest.name {
            existingVM.name = name
        }

        if let description = updateRequest.description {
            existingVM.description = description
        }

        try await existingVM.save(on: req.db)
        return existingVM
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
        let agentOnline = await Self.agentIsOnline(vm: vm, app: req.application)
        let operation = try await beginOperation(
            .delete, vm: vm, user: user, settingDesiredStatus: .absent, on: req.db)

        if agentOnline {
            Self.dispatchStateSync(operation, vm: vm, app: req.application)
        } else {
            Self.runDirectVMDeletion(operation, vm: vm, app: req.application)
        }
        return try Self.accepted(operation)
    }

    /// Background half of `delete` for VMs whose agent is gone (never
    /// assigned, or offline cluster-wide): remove the record directly without
    /// agent teardown. If the agent ever comes back still carrying the VM,
    /// its observed-state report surfaces it as an orphan for operator
    /// attention — the same posture the imperative path took for dead agents.
    private static func runDirectVMDeletion(_ operation: VMOperation, vm: VM, app: Application) {
        guard let operationId = operation.id else { return }
        let vmID = operation.vmID

        Task {
            if vm.hypervisorId != nil {
                app.logger.warning(
                    "Deleting VM record without agent teardown; agent is offline",
                    metadata: ["vm_id": .string(vmID.uuidString)])
            }

            do {
                // If the sweep already failed this operation, stop here: the
                // user will retry, and removing the row under a failed
                // operation would contradict it.
                guard let current = try await VMOperation.find(operationId, on: app.db),
                    current.status == .pending
                else { return }

                // Delete the VM, then recompute its quotas from the remaining VMs,
                // in one transaction so the reservation counters and the VM row stay
                // consistent. Deletion happens first so the removed VM drops out of
                // the recount.
                try await app.db.transaction { db in
                    try await vm.delete(on: db)
                    try await QuotaEnforcementService.release(for: vm, on: db)
                }
                await completeOperation(
                    operationId, vmID: vmID, as: .succeeded, error: nil,
                    settingVMStatus: nil, app: app)
            } catch {
                await completeOperation(
                    operationId, vmID: vmID, as: .failed,
                    error: "Failed to delete VM record: \(error.localizedDescription)",
                    settingVMStatus: nil, app: app)
            }
        }
    }

    func pause(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "pause")

        guard vm.canPause else {
            throw Abort(.badRequest, reason: "VM cannot be paused in current state: \(vm.status.rawValue)")
        }

        // No transitional status exists for pause; the VM stays `.running` until
        // the agent confirms, and the operation record carries the in-flight state.
        let operation = try await beginOperation(
            .pause, vm: vm, user: user, settingDesiredStatus: .paused, on: req.db)

        Self.dispatchStateSync(operation, vm: vm, app: req.application)

        return try Self.accepted(operation)
    }

    func resume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "resume")

        guard vm.canResume else {
            throw Abort(.badRequest, reason: "VM cannot be resumed in current state: \(vm.status.rawValue)")
        }

        // Counterpart of pause: the VM stays `.paused` until the agent confirms.
        let operation = try await beginOperation(
            .resume, vm: vm, user: user, settingDesiredStatus: .running, on: req.db)

        Self.dispatchStateSync(operation, vm: vm, app: req.application)

        return try Self.accepted(operation)
    }

    func status(req: Request) async throws -> VM {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "read")

        // The database row *is* the observed state: the owning agent's
        // periodic observed-state reports keep it fresh (issue #260), so no
        // agent round-trip happens here — which also makes this endpoint
        // replica-independent (issue #261).
        return vm
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
        let operation = try await beginOperation(
            .boot, vm: vm, user: user,
            settingDesiredStatus: .running,
            on: req.db)

        Self.dispatchStateSync(operation, vm: vm, app: req.application)

        return try Self.accepted(operation)
    }

    func stop(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "stop")

        guard vm.canStop else {
            throw Abort(.badRequest, reason: "VM cannot be stopped in current state: \(vm.status.rawValue)")
        }

        let operation = try await beginOperation(
            .shutdown, vm: vm, user: user,
            settingDesiredStatus: .shutdown,
            on: req.db)

        Self.dispatchStateSync(operation, vm: vm, app: req.application)

        return try Self.accepted(operation)
    }

    func restart(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "restart")

        guard vm.isRunning else {
            throw Abort(.badRequest, reason: "VM must be running to restart. Current state: \(vm.status.rawValue)")
        }

        // A reboot starts and ends `.running`, so no status change on any outcome;
        // a failure is visible on the operation record.
        let operation = try await beginOperation(.reboot, vm: vm, user: user, on: req.db)

        Self.runVMOperation(
            operation,
            sending: .vmReboot,
            statusOnSuccess: nil,
            statusOnFailure: nil,
            statusOnDispatchFailure: nil,
            app: req.application
        )

        return try Self.accepted(operation)
    }
}
