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

            if let transitionalStatus {
                vm.setStatus(transitionalStatus)
                try await vm.save(on: db)
            }

            return operation
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

            if let vmStatus, let vm = try await VM.find(vmID, on: app.db) {
                vm.setStatus(vmStatus)
                try await vm.save(on: app.db)
                if vmStatus == .error {
                    Telemetry.vmEnteredError(reason: "operation_failed")
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
        let allVMs = try await VM.query(on: req.db).all()
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

            vm = VM(
                name: createRequest.name,
                description: createRequest.description ?? "",
                image: image.name,
                projectID: projectId,
                environment: environment,
                cpu: cpuValue,
                memory: memoryValue,
                disk: diskValue,
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

        // Bind an immutable copy for the @Sendable transaction closure below; the
        // template selection is final by this point.
        let resolvedTemplate = template
        let userID = try user.requireID()

        // Reserve quota and persist the VM and its pending create operation in one
        // transaction: enforcement checks, the reservation bump, the initial insert,
        // the path update, and the operation record all commit together or roll back
        // together, so a quota rejection leaves nothing behind.
        let (networkInterfaces, operation): ([VMNetworkInterface], VMOperation) = try await req.db.transaction { db in
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

            // Update VM with generated paths
            try await vm.update(on: db)

            // Every VM starts with one NIC on the default network
            let networkInterface = VMNetworkInterface(
                vmID: vmID,
                macAddress: resolvedTemplate?.generateMacAddress()
                    ?? VMNetworkInterface.generateMACAddress()
            )
            try await networkInterface.save(on: db)

            // The pending create operation is the client's handle on the
            // asynchronous agent work that follows (issue #259).
            let operation = VMOperation(vmID: vmID, userID: userID, kind: .create)
            try await operation.save(on: db)

            return ([networkInterface], operation)
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

        // Create the VM via agent in the background (the scheduler selects a
        // hypervisor and persists hypervisorId); the agent's success/error
        // response — not this request — decides the operation's verdict.
        let vmSpec: VMSpec
        if let template = template {
            vmSpec = VMSpecBuilder.buildVMSpec(from: vm, template: template, networkInterfaces: networkInterfaces)
        } else if let image = image {
            vmSpec = VMSpecBuilder.buildVMSpec(from: vm, image: image, networkInterfaces: networkInterfaces)
        } else {
            throw Abort(.internalServerError, reason: "Neither template nor image available")
        }

        Self.runVMCreation(operation, vm: vm, vmSpec: vmSpec, image: image, app: req.application)

        req.logger.info(
            "VM creation accepted",
            metadata: [
                "vm_id": .string(vmID.uuidString),
                "operation_id": .string(operation.id?.uuidString ?? ""),
                "created_from": .string(template != nil ? "template" : "image"),
            ])

        return try Self.accepted(operation)
    }

    /// Background half of `create`: scheduling, reservation, dispatch, and the wait
    /// for the agent's completion response all happen here, after the `202` went out.
    /// A failure anywhere — no schedulable agent, dispatch error, agent-reported
    /// create failure, timeout — lands on the operation record and marks the VM
    /// `.error` so it never poses as a healthy `.created` VM that has no backing.
    private static func runVMCreation(
        _ operation: VMOperation,
        vm: VM,
        vmSpec: VMSpec,
        image: Image?,
        app: Application
    ) {
        guard let operationId = operation.id else { return }
        let vmID = operation.vmID

        Task {
            do {
                // The Image object is passed through so AgentService can build an
                // ImageInfo with a signed URL once the scheduler picks the agent.
                let response = try await app.agentService.createVM(
                    vm: vm, vmSpec: vmSpec, db: app.db, image: image)

                switch response {
                case .success:
                    // The VM exists on the hypervisor but has not been started;
                    // `.created` is its correct resting state, so only the
                    // operation completes.
                    await completeOperation(
                        operationId, vmID: vmID, as: .succeeded, error: nil,
                        settingVMStatus: nil, app: app)
                case .error(let message, let details):
                    let reason = details.map { "\(message): \($0)" } ?? message
                    await completeOperation(
                        operationId, vmID: vmID, as: .failed, error: reason,
                        settingVMStatus: .error, app: app)
                }
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

        let operation = try await beginOperation(.delete, vm: vm, user: user, on: req.db)
        Self.runVMDeletion(operation, vm: vm, app: req.application)
        return try Self.accepted(operation)
    }

    /// Background half of `delete`. The agent teardown decides the verdict: an
    /// agent that is *gone* (no mapping, not connected) does not block deletion —
    /// dead agents must not make their VMs undeletable — but an agent that is
    /// alive and refuses, or one that goes silent mid-delete, fails the operation
    /// and keeps the VM row rather than orphaning a possibly-running QEMU process.
    private static func runVMDeletion(_ operation: VMOperation, vm: VM, app: Application) {
        guard let operationId = operation.id else { return }
        let vmID = operation.vmID

        Task {
            if vm.hypervisorId != nil {
                do {
                    // Shutdown is best-effort — the guest may already be off; the
                    // delete's own response is what decides the operation.
                    _ = try? await app.agentService.performVMOperationAwaitingResponse(
                        .vmShutdown, vmId: vmID.uuidString,
                        timeout: VMOperationKind.shutdown.completionBudget)

                    // The delete phase gets what remains of the operation's budget
                    // after the shutdown phase's worst case, so the two waits
                    // combined can never outlive the stuck-operation sweep's budget
                    // (which would fail the operation while the agent is still
                    // legitimately working).
                    let deleteTimeout =
                        VMOperationKind.delete.completionBudget
                        - VMOperationKind.shutdown.completionBudget
                    let response = try await app.agentService.performVMOperationAwaitingResponse(
                        .vmDelete, vmId: vmID.uuidString, timeout: deleteTimeout)

                    if case .error(let message, let details) = response {
                        let reason = details.map { "\(message): \($0)" } ?? message
                        await completeOperation(
                            operationId, vmID: vmID, as: .failed, error: reason,
                            settingVMStatus: nil, app: app)
                        return
                    }
                } catch {
                    switch error {
                    case AgentServiceError.vmNotMapped, AgentServiceError.agentNotFound:
                        app.logger.warning(
                            "Deleting VM record without agent teardown; agent is gone",
                            metadata: ["vm_id": .string(vmID.uuidString)])
                    default:
                        await completeOperation(
                            operationId, vmID: vmID, as: .failed, error: error.localizedDescription,
                            settingVMStatus: nil, app: app)
                        return
                    }
                }
            }

            do {
                // If the sweep already failed this operation (e.g. the shutdown
                // wait outlived the budget), stop here: the user will retry, and
                // removing the row under a failed operation would contradict it.
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
        let operation = try await beginOperation(.pause, vm: vm, user: user, on: req.db)

        Self.runVMOperation(
            operation,
            sending: .vmPause,
            statusOnSuccess: .paused,
            statusOnFailure: nil,
            statusOnDispatchFailure: nil,
            app: req.application
        )

        return try Self.accepted(operation)
    }

    func resume(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "resume")

        guard vm.canResume else {
            throw Abort(.badRequest, reason: "VM cannot be resumed in current state: \(vm.status.rawValue)")
        }

        // Counterpart of pause: the VM stays `.paused` until the agent confirms.
        let operation = try await beginOperation(.resume, vm: vm, user: user, on: req.db)

        Self.runVMOperation(
            operation,
            sending: .vmResume,
            statusOnSuccess: .running,
            statusOnFailure: nil,
            statusOnDispatchFailure: nil,
            app: req.application
        )

        return try Self.accepted(operation)
    }

    func status(req: Request) async throws -> VM {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "read")

        // Sync status with agent if VM exists there. Transitional states are owned by
        // the dispatch path and confirmed via the agent's statusUpdate; a concurrent
        // poll may still see the pre-operation state on the agent and must not
        // overwrite the in-flight marker (which the stuck-VM sweep relies on).
        if vm.hypervisorId != nil && !vm.status.isTransitional {
            do {
                let actualStatus = try await req.agentService.getVMStatus(vmId: vm.id?.uuidString ?? "")
                if actualStatus != vm.status {
                    vm.setStatus(actualStatus)
                    try await vm.save(on: req.db)
                }
            } catch {
                req.logger.warning(
                    "Failed to sync VM status with agent: \(error)",
                    metadata: ["vm_id": .string(vm.id?.uuidString ?? "")])
            }
        }

        return vm
    }

    func start(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "start")

        guard vm.canStart else {
            throw Abort(.badRequest, reason: "VM cannot be started in current state: \(vm.status.rawValue)")
        }

        // Decide boot-vs-resume before we overwrite the status with a transitional one.
        let bootFresh = vm.shouldBootOnStart
        let previousStatus = vm.status

        // The `.starting` status and the pending operation commit together, so a
        // crash or lost confirmation leaves a detectable in-flight marker either
        // way — the stuck-operation sweep resolves both.
        let operation = try await beginOperation(
            .boot, vm: vm, user: user, settingVMStatus: .starting, on: req.db)

        Self.runVMOperation(
            operation,
            sending: bootFresh ? .vmBoot : .vmResume,
            statusOnSuccess: .running,
            statusOnFailure: .error,
            // Nothing reached an agent (e.g. the VM was never assigned one) —
            // restore the prior state instead of leaving a phantom `.starting`.
            statusOnDispatchFailure: previousStatus,
            app: req.application
        )

        return try Self.accepted(operation)
    }

    func stop(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let vm = try await fetchVMWithPermission(req: req, user: user, permission: "stop")

        guard vm.canStop else {
            throw Abort(.badRequest, reason: "VM cannot be stopped in current state: \(vm.status.rawValue)")
        }

        let previousStatus = vm.status

        let operation = try await beginOperation(
            .shutdown, vm: vm, user: user, settingVMStatus: .stopping, on: req.db)

        Self.runVMOperation(
            operation,
            sending: .vmShutdown,
            statusOnSuccess: .shutdown,
            statusOnFailure: .error,
            statusOnDispatchFailure: previousStatus,
            app: req.application
        )

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
