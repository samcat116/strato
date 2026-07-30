import Fluent
import Foundation
import StratoShared
import Vapor

/// Full-VM checkpoint handlers for `/api/vms/:vmID/snapshots` (issue #564),
/// registered by `VMController.boot`.
///
/// Create, delete, and restore follow the generalized 202-operation machinery
/// (#412): the pending operation row and the snapshot mutation commit in one
/// transaction, the agent round-trip happens in the background over the
/// imperative checkpoint RPC (the volume-ops precedent, forwarded across
/// replicas by `AgentService`), and the RPC verdict completes the operation —
/// with the stuck-operation sweep as backstop.
///
/// A checkpoint here is RAM + device state + disks at one instant, which is a
/// different primitive from the disk-only volume snapshot: it lives *inside*
/// the VM's qcow2 disks as a QEMU internal snapshot, so it never leaves the
/// agent that took it and restore placement is pinned to that agent.
extension VMController {

    // MARK: - Create

    /// POST /api/vms/:vmID/snapshots
    /// Body: { "name"?: string, "description"?: string }
    ///
    /// Checkpoints the VM: the agent has QEMU write guest RAM and device state
    /// into an internal snapshot of the disks. The guest keeps running — QEMU
    /// pauses it only for the duration of the save — so no desired state
    /// changes here.
    func createSnapshot(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Checkpointing a VM")
        let vm = try await authorizedVM(req: req, permission: "snapshot")
        let vmID = try vm.requireID()

        // The body is optional, but a body that *is* sent must decode: masking
        // a malformed field behind defaults would silently name the checkpoint
        // something the caller never asked for.
        let request: CreateVMSnapshotRequest
        if req.body.data == nil {
            request = CreateVMSnapshotRequest(name: nil, description: nil)
        } else {
            request = try req.content.decode(CreateVMSnapshotRequest.self)
        }

        // Only a VM with live machine state can be checkpointed. A shut-down
        // VM has no QEMU process to capture from — and its disks alone are
        // what volume snapshots are for.
        guard let agentId = vm.hypervisorId else {
            throw Abort(.conflict, reason: "VM is not placed on any agent")
        }
        guard vm.status == .running || vm.status == .paused else {
            throw Abort(
                .conflict,
                reason:
                    "VM cannot be checkpointed in state '\(vm.status.rawValue)'; it must be running or paused")
        }
        // Fail fast on an offline or incapable agent instead of parking the
        // operation against silence.
        try await Self.requireCheckpointCapableAgent(agentId, app: req.application)

        guard let project = try await Project.find(vm.$project.id, on: req.db) else {
            throw Abort(.internalServerError, reason: "VM project not found")
        }

        let trimmedName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name =
            (trimmedName?.isEmpty == false)
            ? trimmedName! : "checkpoint-\(Int(Date().timeIntervalSince1970))"

        let userID = try user.requireID()
        let snapshot = VMSnapshot(
            name: name,
            description: request.description ?? "",
            vmID: vmID,
            projectID: vm.$project.id,
            environment: vm.environment,
            agentId: agentId,
            createdByID: userID)
        // Admission estimate: the machine state is bounded by the memory the
        // guest was granted. Replaced by the agent's actual figure on
        // completion.
        snapshot.size = vm.memory

        let environment = vm.environment
        let memory = vm.memory
        let operation = try await ResourceOperation.begin(
            .snapshot,
            resourceKind: .virtualMachine,
            resourceID: vmID,
            userID: userID,
            on: req.db
        ) { db in
            // Checkpoint state draws from the shared storage quota pool
            // (issue #415 enforcement points).
            try await QuotaEnforcementService.reserveVMSnapshot(
                for: project, environment: environment, size: memory, on: db)
            try await snapshot.save(on: db)
            // The creator's binding on the checkpoint, in the create
            // transaction (the volume-snapshot path, issue #477).
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: userID,
                role: .admin,
                nodeType: .vmSnapshot,
                nodeID: snapshot.requireID(),
                createdBy: userID,
                on: db
            )
        }

        let snapshotID = try snapshot.requireID()
        Self.runCheckpoint(operation, snapshot: snapshot, agentId: agentId, app: req.application)

        req.logger.info(
            "VM checkpoint accepted",
            metadata: [
                "vm_id": .string(vmID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
            ])
        return try operation.acceptedResponse()
    }

    /// Background half of `createSnapshot`: the agent RPC and the verdict.
    private static func runCheckpoint(
        _ operation: ResourceOperation,
        snapshot: VMSnapshot,
        agentId: String,
        app: Application
    ) {
        guard let operationId = operation.id, let snapshotId = snapshot.id else { return }
        let vmID = operation.resourceID
        let projectID = snapshot.$project.id
        let environment = snapshot.environment

        app.backgroundTasks.spawn {
            do {
                let report = try await VMSnapshotService.requestCheckpoint(
                    vmId: vmID, snapshotId: snapshotId, agentId: agentId, app: app)

                // The agent RPC above can span shutdown's drain; bail before the
                // write-back if it cancelled us (see `Application.liveDB`), and
                // reuse the captured handle for the rest of the body.
                guard let db = app.liveDB else { return }
                if let current = try await VMSnapshot.find(snapshotId, on: db) {
                    current.status = .ready
                    // A QEMU build that reported no size for the tag it just
                    // wrote leaves the admission estimate standing — an
                    // unknown footprint must not silently become a free one.
                    if let size = report.vmStateSizeBytes {
                        current.size = size
                    }
                    current.qemuVersion = report.qemuVersion
                    current.architecture = report.architecture?.rawValue
                    try await current.save(on: db)
                }

                // Admission reserved only an estimate (the memory grant); the
                // real figure may differ either way. Resync the counters and,
                // if that blew past an enabled storage quota, delete the
                // checkpoint rather than keep over-quota storage.
                if let violatedQuota = try await QuotaEnforcementService.storageOverCommit(
                    projectID: projectID, environment: environment, on: db)
                {
                    try? await VMSnapshotService.requestDelete(
                        vmId: vmID, snapshotId: snapshotId, agentId: agentId, app: app)
                    if let current = try? await VMSnapshot.find(snapshotId, on: db) {
                        current.status = .error
                        current.errorMessage =
                            "Checkpoint exceeded storage quota '\(violatedQuota)' and was deleted"
                        current.size = 0
                        try? await current.save(on: db)
                    }
                    await app.resourceOperationCoordinator.recordVerdict(
                        operationID: operationId, as: .failed,
                        error:
                            "Checkpoint's actual size exceeded storage quota '\(violatedQuota)'; it was deleted",
                        on: app)
                    return
                }

                await app.resourceOperationCoordinator.recordVerdict(
                    operationID: operationId, as: .succeeded, error: nil, on: app)
            } catch {
                // A clean agent-side failure leaves no tag behind. An ambiguous
                // transport failure (timeout, disconnect) may have written one —
                // attempt the idempotent delete so the charge dropped below
                // matches reality; if the agent is unreachable the state lives
                // inside the VM's own disks and goes with the VM.
                try? await VMSnapshotService.requestDelete(
                    vmId: vmID, snapshotId: snapshotId, agentId: agentId, app: app)
                // `try?` does not catch the fatal unwrap a torn-down `app.db`
                // produces, so short-circuit on cancellation before each access.
                if let db = app.liveDB, let current = try? await VMSnapshot.find(snapshotId, on: db) {
                    current.status = .error
                    current.errorMessage = error.localizedDescription
                    current.size = 0
                    try? await current.save(on: db)
                }
                await app.resourceOperationCoordinator.recordVerdict(
                    operationID: operationId, as: .failed, error: error.localizedDescription, on: app)
            }
        }
    }

    // MARK: - List

    /// GET /api/vms/:vmID/snapshots
    /// Query params: limit/offset (optional) — select the page.
    func listSnapshots(req: Request) async throws -> PagedResponse<VMSnapshotResponse> {
        let paging = try ListPaging.decode(from: req)
        let vm = try await authorizedVM(req: req, permission: "read")
        let vmID = try vm.requireID()

        let snapshots = try await VMSnapshot.query(on: req.db)
            .filter(\.$vm.$id == vmID)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .all()
        return paging.page(snapshots.map { VMSnapshotResponse(from: $0) })
    }

    // MARK: - Delete

    /// DELETE /api/vms/:vmID/snapshots/:snapshotID
    func deleteSnapshot(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Deleting a VM checkpoint")
        let vm = try await authorizedVM(req: req, permission: "read")
        let snapshot = try await fetchSnapshot(req: req, vm: vm)
        let snapshotID = try snapshot.requireID()

        let canDelete = try await req.can("delete", on: "vm_snapshot", id: snapshotID.uuidString)
        guard canDelete else {
            throw Abort(.forbidden, reason: "You don't have permission to delete this checkpoint")
        }
        guard snapshot.canDelete else {
            throw Abort(
                .conflict,
                reason: "Checkpoint cannot be deleted in status '\(snapshot.status.rawValue)'")
        }

        let vmID = try vm.requireID()
        let operation = try await ResourceOperation.begin(
            .snapshotDelete,
            resourceKind: .virtualMachine,
            resourceID: vmID,
            userID: try user.requireID(),
            on: req.db
        ) { db in
            guard let current = try await VMSnapshot.find(snapshotID, on: db), current.canDelete else {
                throw Abort(.conflict, reason: "Checkpoint is no longer deletable")
            }
            current.status = .deleting
            try await current.save(on: db)
        }

        Self.runCheckpointDeletion(
            operation, snapshot: snapshot, vmAgentId: vm.hypervisorId, app: req.application)
        return try operation.acceptedResponse()
    }

    /// Background half of `deleteSnapshot`. A checkpoint whose VM is unplaced
    /// has no state anyone can reach — the row goes directly; an offline agent
    /// fails the operation so the delete can be retried once it returns.
    private static func runCheckpointDeletion(
        _ operation: ResourceOperation,
        snapshot: VMSnapshot,
        vmAgentId: String?,
        app: Application
    ) {
        guard let operationId = operation.id, let snapshotId = snapshot.id else { return }
        let vmID = operation.resourceID

        app.backgroundTasks.spawn {
            do {
                if let agentId = snapshot.agentId ?? vmAgentId {
                    try await VMSnapshotService.requestDelete(
                        vmId: vmID, snapshotId: snapshotId, agentId: agentId, app: app)
                }
                // The agent RPC above can span shutdown's drain; bail before the
                // row delete if it cancelled us (see `Application.liveDB`).
                guard let db = app.liveDB else { return }
                try await db.transaction { db in
                    try await snapshot.delete(on: db)
                    // Drop the checkpoint's bindings with the row.
                    try await RoleBindingService.revokeAll(
                        nodeType: .vmSnapshot, nodeID: snapshotId, on: db)
                }
                // Resync the storage pool now that the checkpoint's bytes are
                // gone; the deleted row drops out of the recount.
                _ = try? await QuotaEnforcementService.storageOverCommit(
                    projectID: snapshot.$project.id, environment: snapshot.environment, on: db)
                await app.resourceOperationCoordinator.recordVerdict(
                    operationID: operationId, as: .succeeded, error: nil, on: app)
            } catch {
                if let db = app.liveDB, let current = try? await VMSnapshot.find(snapshotId, on: db) {
                    // Keep `.deleting` — it is retryable (`canDelete`), and
                    // agent-side deletion is idempotent.
                    current.errorMessage = error.localizedDescription
                    try? await current.save(on: db)
                }
                await app.resourceOperationCoordinator.recordVerdict(
                    operationID: operationId, as: .failed, error: error.localizedDescription, on: app)
            }
        }
    }

    // MARK: - Restore

    /// POST /api/vms/:vmID/snapshots/:snapshotID/restore
    ///
    /// Resume-in-place: the VM's agent loads the captured RAM and device state
    /// back into its QEMU process and resumes it — same VM, same identity,
    /// same agent. v1 pins restore placement to the agent that took the
    /// checkpoint, because the machine state lives inside disks on that host.
    func restoreSnapshot(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Restoring a VM checkpoint")
        let vm = try await authorizedVM(req: req, permission: "read")
        let snapshot = try await fetchSnapshot(req: req, vm: vm)
        let snapshotID = try snapshot.requireID()
        let vmID = try vm.requireID()

        let canRestore = try await req.can("restore", on: "vm_snapshot", id: snapshotID.uuidString)
        guard canRestore else {
            throw Abort(.forbidden, reason: "You don't have permission to restore this checkpoint")
        }
        guard snapshot.canRestore else {
            throw Abort(
                .conflict,
                reason: "Checkpoint cannot be restored in status '\(snapshot.status.rawValue)'")
        }
        guard let agentId = vm.hypervisorId else {
            throw Abort(.conflict, reason: "VM is not placed on any agent")
        }
        if let snapshotAgent = snapshot.agentId, snapshotAgent != agentId {
            throw Abort(
                .conflict,
                reason:
                    "Checkpoint was taken on agent '\(snapshotAgent)' but the VM now lives on '\(agentId)'; a full-VM checkpoint cannot move between hosts"
            )
        }
        // The VM must exist on the agent to load into. A shut-down VM is
        // deliberately allowed: the desired-state sync re-creates its QEMU
        // process (its disks, and the checkpoint inside them, never left the
        // host), which is what makes restore-after-restart work.
        guard vm.status != .error, vm.status != .unknown else {
            throw Abort(
                .conflict,
                reason: "VM cannot be restored in state '\(vm.status.rawValue)'")
        }
        try await Self.requireCheckpointCapableAgent(agentId, app: req.application)

        let userID = try user.requireID()
        let operation = try await ResourceOperation.begin(
            .restore,
            resourceKind: .virtualMachine,
            resourceID: vmID,
            userID: userID,
            on: req.db
        ) { db in
            guard let current = try await VMSnapshot.find(snapshotID, on: db), current.canRestore else {
                throw Abort(.conflict, reason: "Checkpoint is no longer restorable")
            }
            // The restored guest resumes running; desired state must agree or
            // the next sync would stop it right back.
            vm.setDesiredStatus(.running)
            try await vm.save(on: db)
        }

        Self.runCheckpointRestore(
            operation, snapshotID: snapshotID, agentId: agentId, app: req.application)

        req.logger.info(
            "VM restore accepted",
            metadata: [
                "vm_id": .string(vmID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
            ])
        return try operation.acceptedResponse()
    }

    /// Background half of `restoreSnapshot`.
    private static func runCheckpointRestore(
        _ operation: ResourceOperation,
        snapshotID: UUID,
        agentId: String,
        app: Application
    ) {
        guard let operationId = operation.id else { return }
        let vmID = operation.resourceID

        app.backgroundTasks.spawn {
            do {
                try await VMSnapshotService.requestRestore(
                    vmId: vmID, snapshotId: snapshotID, agentId: agentId, app: app)
                // The agent resumed the guest itself; the periodic observed
                // report re-confirms. Stamp `.running` only if we won the
                // verdict race — a lost race means the sweep already resolved
                // the VM and must not be contradicted.
                let won = await app.resourceOperationCoordinator.recordVerdict(
                    operationID: operationId, as: .succeeded, error: nil, on: app)
                guard won, !Task.isCancelled, let db = app.liveDB else { return }
                if let vm = try? await VM.find(vmID, on: db) {
                    vm.setStatus(.running)
                    try? await vm.save(on: db)
                }
            } catch {
                await app.resourceOperationCoordinator.recordVerdict(
                    operationID: operationId, as: .failed, error: error.localizedDescription, on: app)
            }
        }
    }

    // MARK: - Shared

    /// Preflight the agent, translating the service's own errors into the
    /// `409` the API contract uses for "this cannot be done right now".
    private static func requireCheckpointCapableAgent(_ agentId: String, app: Application) async throws {
        do {
            try await VMSnapshotService.requireCapableAgent(agentId, app: app)
        } catch let error as VMSnapshotServiceError {
            throw Abort(.conflict, reason: error.localizedDescription)
        }
    }

    /// Fetch the :vmID VM and enforce a permission on it. Mirrors
    /// `VMController.fetchVMWithPermission`, which is private to that file.
    private func authorizedVM(req: Request, permission: String) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }
        return try await req.authorizedVM(vmID, permission: permission)
    }

    /// Fetch the :snapshotID checkpoint and confirm it belongs to `vm` (the
    /// route nests checkpoints under their VM).
    private func fetchSnapshot(req: Request, vm: VM) async throws -> VMSnapshot {
        guard let snapshotID = req.parameters.get("snapshotID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid snapshot ID")
        }
        guard let snapshot = try await VMSnapshot.find(snapshotID, on: req.db),
            snapshot.$vm.id == (try vm.requireID())
        else {
            throw Abort(.notFound, reason: "Checkpoint not found")
        }
        return snapshot
    }
}
