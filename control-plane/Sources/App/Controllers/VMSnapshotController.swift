import Fluent
import Foundation
import StratoShared
import Vapor

/// Full-VM checkpoint handlers for `/api/vms/:vmID/snapshots` (issue #564),
/// registered by `VMController.boot`.
///
/// A checkpoint here is RAM + device state + disks at one instant, which is a
/// different primitive from the disk-only volume snapshot: it lives *inside*
/// the VM's qcow2 disks as a QEMU internal snapshot, so it never leaves the
/// agent that took it and restore placement is pinned to that agent.
///
/// Create and delete became declarative in ADR 0001 stage 8 (STR-150). Both
/// answer `202 {resource, targetGeneration, mutationId}` and the client polls
/// the checkpoint's own `conditions`; the agent captures or removes the bytes
/// on its next sync and reports what it did. The background RPC-and-verdict
/// halves this file used to carry are gone with them — including the one that
/// had to guess, after a lost response, whether a checkpoint it could not see
/// existed.
///
/// Restore followed in stage 9 (STR-151), by the other route out of the same
/// dichotomy: loading a captured RAM image back into a live QEMU process really
/// is an edge, so it did not become a state by being re-described — it became
/// one by being *counted*. `VM.requestRestore` bumps a monotonic nonce naming
/// the checkpoint, and the agent applies it once against its own durable record.
/// Nothing in this file awaits an agent response any more.
extension VMController {

    // MARK: - Create

    /// POST /api/vms/:vmID/snapshots
    /// Body: { "name"?: string, "description"?: string, "ttlSeconds"?: int }
    ///
    /// Checkpoints the VM: the agent has QEMU write guest RAM and device state
    /// into an internal snapshot of the disks. The guest keeps running — QEMU
    /// pauses it only for the duration of the save — so no VM desired state
    /// changes here.
    func createSnapshot(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Checkpointing a VM")
        let vm = try await authorizedVM(req: req, action: "vm:snapshot")
        let vmID = try vm.requireID()

        // The body is optional, but a body that *is* sent must decode: masking
        // a malformed field behind defaults would silently name the checkpoint
        // something the caller never asked for.
        let request: CreateVMSnapshotRequest
        if req.body.data == nil {
            request = CreateVMSnapshotRequest(name: nil, description: nil, ttlSeconds: nil)
        } else {
            request = try req.content.decodeValidated(CreateVMSnapshotRequest.self)
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
        // Capture admission, not placement: an artifact inherits its parent's
        // host, so there is no scheduling decision to gate. With the imperative
        // frames gone there is no fallback either, so a checkpoint requested
        // against an agent that cannot converge one is refused here rather than
        // accepted into a desired state nothing would ever realize.
        try await SnapshotArtifactMutation.requireCaptureCapableAgent(
            agentId, kind: .vmCheckpoint, app: req.application)

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
            expiresAt: try SnapshotRetention.expiry(requested: request.ttlSeconds),
            createdByID: userID)
        // Admission estimate: the machine state is bounded by the memory the
        // guest was granted. Replaced by the agent's actual figure once its
        // observed report carries one.
        snapshot.size = vm.memory
        // The capture has a budget to converge in; past it the stuck-convergence
        // sweep marks the artifact degraded rather than leaving a client polling
        // a checkpoint that will never appear.
        snapshot.extendConvergenceDeadline(
            by: OperationResourceKind.vmCheckpoint.completionBudgetSeconds(for: .create))

        let environment = vm.environment
        let memory = vm.memory
        let accepted = try await req.db.transaction { db -> ResourceMutation.Accepted in
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
            return try await SnapshotArtifactMutation.recordCapture(
                snapshot, actor: .user(userID), on: db)
        }

        let snapshotID = try snapshot.requireID()
        try SnapshotArtifactMutation.dispatchCapture(snapshot, app: req.application)

        req.logger.info(
            "VM checkpoint accepted",
            metadata: [
                "vm_id": .string(vmID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
            ])
        return try AcceptedMutation(VMSnapshotResponse(from: snapshot), accepted).acceptedResponse()
    }

    // MARK: - List

    /// GET /api/vms/:vmID/snapshots
    /// Query params: limit/offset (optional) — select the page.
    func listSnapshots(req: Request) async throws -> PagedResponse<VMSnapshotResponse> {
        let paging = try ListPaging.decode(from: req)
        let vm = try await authorizedVM(req: req, action: "vm:read")
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
    ///
    /// Marks the checkpoint absent and stamps the finalizers its teardown owes.
    /// The row outlives this request: it goes only once the owning agent's
    /// observed report stops listing the artifact, which is what makes a delete
    /// durable across a control-plane restart.
    func deleteSnapshot(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Deleting a VM checkpoint")
        let vm = try await authorizedVM(req: req, action: "vm:read")
        let snapshot = try await fetchSnapshot(req: req, vm: vm)
        let snapshotID = try snapshot.requireID()

        let canDelete = try await req.can(
            "vm:snapshot", on: IAMNode(type: .vmSnapshot, id: snapshotID))
        guard canDelete else {
            throw Abort(.forbidden, reason: "You don't have permission to delete this checkpoint")
        }

        let accepted = try await SnapshotArtifactMutation.delete(
            snapshot, actor: .user(try user.requireID()), on: req.db, app: req.application)

        req.logger.info(
            "VM checkpoint deletion requested",
            metadata: ["snapshot_id": .string(snapshotID.uuidString)])
        return try AcceptedMutation(VMSnapshotResponse(from: snapshot), accepted).acceptedResponse()
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
        let vm = try await authorizedVM(req: req, action: "vm:read")
        let snapshot = try await fetchSnapshot(req: req, vm: vm)
        let snapshotID = try snapshot.requireID()
        let vmID = try vm.requireID()

        let canRestore = try await req.can(
            "vm:restore", on: IAMNode(type: .vmSnapshot, id: snapshotID))
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
        // Both signals: the wire version proves the agent applies the nonce,
        // the capability proves a QEMU backend that can load a checkpoint is
        // usable on that host (issue #415). The capture path checks the same
        // pair, so admission is symmetric.
        try await Self.requireEdgeNonceCapableAgent(
            agentId, requiring: SnapshotArtifactKind.vmCheckpoint.agentCapability,
            app: req.application)

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .restore, on: vm, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable db in
            // Re-checked inside the mutation's transaction, under the VM's row
            // lock: the preflight above ran before it, and a checkpoint can be
            // deleted in between.
            guard let current = try await VMSnapshot.find(snapshotID, on: db), current.canRestore else {
                throw Abort(.conflict, reason: "Checkpoint is no longer restorable")
            }
            vm.requestRestore(snapshotID: snapshotID)
        }

        req.logger.info(
            "VM restore accepted",
            metadata: [
                "vm_id": .string(vmID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
            ])
        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }

    // MARK: - Shared

    /// Fetch the :vmID VM and enforce a permission on it. Mirrors
    /// `VMController.fetchVMWithAction`, which is private to that file.
    private func authorizedVM(req: Request, action: String) async throws -> VM {
        guard let vmID = req.parameters.get("vmID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }
        return try await req.authorizedVM(vmID, action: action)
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
