import Fluent
import Foundation
import StratoShared
import Vapor

/// Snapshot / checkpoint-resume handlers for `/api/sandboxes/:id/snapshots`
/// (issue #426), registered by `SandboxController.boot`.
///
/// Create, delete, and restore all follow the generalized 202-operation
/// machinery (#412): the pending operation row and the snapshot/desired-state
/// mutation commit in one transaction, the agent round-trip happens in the
/// background over the imperative snapshot RPC (the volume-ops precedent,
/// forwarded across replicas by `AgentService`), and the RPC verdict
/// completes the operation — with the stuck-operation sweep as backstop.
extension SandboxController {

    // MARK: - Create

    /// POST /api/sandboxes/:sandboxID/snapshots
    /// Body: { "name"?: string, "stop"?: bool }
    ///
    /// Checkpoints the sandbox: the agent drains guest connections, pauses
    /// the microVM, captures memory + vmstate, copies the rootfs, then
    /// resumes — or stays stopped when `stop` is true (checkpoint-and-stop).
    func createSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "snapshot")
        let sandboxID = try sandbox.requireID()
        // The body is optional, but a body that *is* sent must decode:
        // masking a malformed `stop` behind defaults would silently run the
        // wrong checkpoint mode.
        let request: CreateSandboxSnapshotRequest
        if req.body.data == nil {
            request = CreateSandboxSnapshotRequest(name: nil, stop: nil)
        } else {
            request = try req.content.decode(CreateSandboxSnapshotRequest.self)
        }
        let stopAfterSnapshot = request.stop ?? false

        // Only a sandbox with live guest state can be checkpointed: it must
        // be placed, confirmed by its agent, and not mid-transition.
        guard let agentId = sandbox.hypervisorId else {
            throw Abort(.conflict, reason: "Sandbox is not placed on any agent")
        }
        guard sandbox.observedGeneration > 0 else {
            throw Abort(.conflict, reason: "Sandbox has not been confirmed by its agent yet")
        }
        switch sandbox.status {
        case .running, .stopped, .exited:
            break
        case .starting, .stopping, .error, .unknown:
            throw Abort(
                .conflict,
                reason: "Sandbox cannot be snapshotted in state '\(sandbox.status.rawValue)'")
        }
        // Fail fast on an offline or incapable agent instead of parking the
        // operation against silence.
        do {
            try await SandboxSnapshotService.requireCapableAgent(agentId, app: req.application)
        } catch let error as SandboxSnapshotServiceError {
            throw Abort(.conflict, reason: error.localizedDescription)
        }

        guard let project = try await Project.find(sandbox.$project.id, on: req.db) else {
            throw Abort(.internalServerError, reason: "Sandbox project not found")
        }

        let name =
            request.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "snapshot-\(Int(Date().timeIntervalSince1970))"

        let userID = try user.requireID()
        let snapshot = SandboxSnapshot(
            name: name,
            sandboxID: sandboxID,
            projectID: sandbox.$project.id,
            environment: sandbox.environment,
            agentId: agentId,
            createdByID: userID)
        // Admission estimate: the memory file dominates and is bounded by
        // guest RAM. Replaced by the agent's actual sizes on completion.
        snapshot.size = sandbox.memory

        let environment = sandbox.environment
        let memory = sandbox.memory
        let operation = try await ResourceOperation.begin(
            .snapshot,
            resourceKind: .sandbox,
            resourceID: sandboxID,
            userID: userID,
            on: req.db
        ) { db in
            // Snapshot storage draws from the shared storage quota pool
            // (issue #415 enforcement points).
            try await QuotaEnforcementService.reserveSandboxSnapshot(
                for: project, environment: environment, size: memory, on: db)
            try await snapshot.save(on: db)
            // IAM dual-write (issue #477): the creator's binding on the
            // snapshot, in the create transaction (the volume-snapshot path).
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: userID,
                role: .admin,
                nodeType: .sandboxSnapshot,
                nodeID: snapshot.requireID(),
                createdBy: userID,
                on: db
            )
            if stopAfterSnapshot {
                // Checkpoint-and-stop: the agent leaves the microVM paused
                // after the capture, and the desired state must agree so the
                // reconciler doesn't immediately resume it.
                sandbox.setDesiredStatus(.stopped)
                try await sandbox.save(on: db)
            }
        }

        let snapshotID = try snapshot.requireID()

        // Ownership relationships, mirroring volume snapshots: the creator,
        // the source sandbox (read/delete/restore resolve through it), and
        // the project. The operation and snapshot rows are already committed,
        // so a failed write must compensate — without tuples the `.creating`
        // row would be an unmanageable orphan holding quota until nothing.
        do {
            try await req.spicedb.writeRelationship(
                entity: "sandbox_snapshot", entityId: snapshotID.uuidString,
                relation: "owner", subject: "user", subjectId: userID.uuidString)
            try await req.spicedb.writeRelationship(
                entity: "sandbox_snapshot", entityId: snapshotID.uuidString,
                relation: "sandbox", subject: "sandbox", subjectId: sandboxID.uuidString)
            try await req.spicedb.writeRelationship(
                entity: "sandbox_snapshot", entityId: snapshotID.uuidString,
                relation: "project", subject: "project", subjectId: sandbox.$project.id.uuidString)
        } catch {
            snapshot.status = .error
            snapshot.errorMessage = "authorization setup failed: \(error.localizedDescription)"
            snapshot.size = 0
            try? await snapshot.save(on: req.db)
            _ = try? await operation.completeIfPending(
                as: .failed,
                error: "Failed to record snapshot ownership relationships",
                on: req.db)
            try? await QuotaEnforcementService.release(for: sandbox, on: req.db)
            throw Abort(
                .internalServerError,
                reason: "Failed to record snapshot ownership relationships; the operation was cancelled")
        }

        Self.runSnapshotCreation(
            operation, snapshot: snapshot, sandbox: sandbox,
            mode: stopAfterSnapshot ? .stop : .resume,
            agentId: agentId, app: req.application)

        req.logger.info(
            "Sandbox snapshot accepted",
            metadata: [
                "sandbox_id": .string(sandboxID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
                "stop": .stringConvertible(stopAfterSnapshot),
            ])

        return try Self.accepted(operation)
    }

    /// Background half of `createSnapshot`: the agent RPC and the verdict.
    private static func runSnapshotCreation(
        _ operation: ResourceOperation,
        snapshot: SandboxSnapshot,
        sandbox: Sandbox,
        mode: SandboxSnapshotMode,
        agentId: String,
        app: Application
    ) {
        guard let operationId = operation.id, let snapshotId = snapshot.id else { return }
        let sandboxID = operation.resourceID

        let projectID = snapshot.$project.id
        let environment = snapshot.environment

        app.backgroundTasks.spawn {
            do {
                let report = try await SandboxSnapshotService.requestSnapshotCreate(
                    sandboxId: sandboxID, snapshotId: snapshotId, mode: mode,
                    agentId: agentId, app: app)

                if let current = try await SandboxSnapshot.find(snapshotId, on: app.db) {
                    current.status = .ready
                    current.size = report.sizeBytes
                    current.storagePath = report.storagePath
                    current.firecrackerVersion = report.firecrackerVersion
                    current.architecture = report.architecture?.rawValue
                    current.guestControlProtocolVersion = report.guestControlProtocolVersion
                    try await current.save(on: app.db)
                }

                // Admission reserved only an estimate (guest memory); the
                // actual footprint adds vmstate + the rootfs copy. Resync the
                // counters to the reported figures and, if that blew past an
                // enabled storage quota, delete the snapshot rather than keep
                // over-quota storage.
                if let violatedQuota = try await QuotaEnforcementService.storageOverCommit(
                    projectID: projectID, environment: environment, on: app.db)
                {
                    try? await SandboxSnapshotService.requestSnapshotDelete(
                        sandboxId: sandboxID, snapshotId: snapshotId, agentId: agentId, app: app)
                    if let current = try? await SandboxSnapshot.find(snapshotId, on: app.db) {
                        current.status = .error
                        current.errorMessage =
                            "Snapshot exceeded storage quota '\(violatedQuota)' and was deleted"
                        current.size = 0
                        try? await current.save(on: app.db)
                    }
                    try? await QuotaEnforcementService.release(for: sandbox, on: app.db)
                    await completeOperation(
                        operationId, sandboxID: sandboxID, as: .failed,
                        error:
                            "Snapshot's actual size exceeded storage quota '\(violatedQuota)'; its artifacts were deleted",
                        settingSandboxStatus: nil, app: app)
                    return
                }

                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .succeeded, error: nil,
                    settingSandboxStatus: nil, app: app)
            } catch {
                // A clean agent-side failure already removed its partial
                // artifacts. An ambiguous transport failure (timeout,
                // disconnect) may have left real files behind — attempt the
                // idempotent delete so the charge we drop below matches
                // reality; if the agent is unreachable, the artifacts live
                // under the sandbox's storage directory and are removed with
                // the sandbox by the authoritative desired-state sync.
                try? await SandboxSnapshotService.requestSnapshotDelete(
                    sandboxId: sandboxID, snapshotId: snapshotId, agentId: agentId, app: app)
                if let current = try? await SandboxSnapshot.find(snapshotId, on: app.db) {
                    current.status = .error
                    current.errorMessage = error.localizedDescription
                    current.size = 0
                    try? await current.save(on: app.db)
                }
                try? await QuotaEnforcementService.release(for: sandbox, on: app.db)
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .failed,
                    error: error.localizedDescription,
                    settingSandboxStatus: nil, app: app)
            }
        }
    }

    // MARK: - List

    /// GET /api/sandboxes/:sandboxID/snapshots
    func listSnapshots(req: Request) async throws -> [SandboxSnapshotResponse] {
        _ = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        let sandboxID = try sandbox.requireID()

        let snapshots = try await SandboxSnapshot.query(on: req.db)
            .filter(\.$sandbox.$id == sandboxID)
            .sort(\.$createdAt, .descending)
            .all()
        return snapshots.map { SandboxSnapshotResponse(from: $0) }
    }

    // MARK: - Delete

    /// DELETE /api/sandboxes/:sandboxID/snapshots/:snapshotID
    func deleteSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        let snapshot = try await fetchSnapshot(req: req, sandbox: sandbox)
        let snapshotID = try snapshot.requireID()

        let canDelete = try await req.spicedb.checkPermission(
            subject: try user.requireID().uuidString,
            permission: "delete",
            resource: "sandbox_snapshot",
            resourceId: snapshotID.uuidString)
        guard canDelete else {
            throw Abort(.forbidden, reason: "You don't have permission to delete this snapshot")
        }

        guard snapshot.canDelete else {
            throw Abort(
                .conflict,
                reason: "Snapshot cannot be deleted in status '\(snapshot.status.rawValue)'")
        }
        guard try await Self.liveForkCount(from: snapshotID, on: req.db) == 0 else {
            throw Abort(
                .conflict,
                reason: "Snapshot cannot be deleted while sandboxes forked from it still exist")
        }

        let operation = try await ResourceOperation.begin(
            .snapshotDelete,
            resourceKind: .sandbox,
            resourceID: try sandbox.requireID(),
            userID: try user.requireID(),
            on: req.db
        ) { db in
            snapshot.status = .deleting
            try await snapshot.save(on: db)
        }

        Self.runSnapshotDeletion(operation, snapshot: snapshot, sandbox: sandbox, app: req.application)
        return try Self.accepted(operation)
    }

    /// Background half of `deleteSnapshot`. A snapshot whose agent is gone
    /// (sandbox unplaced) has no artifacts anyone can reach — the row is
    /// removed directly; an offline agent fails the operation so the delete
    /// can be retried once it returns.
    private static func runSnapshotDeletion(
        _ operation: ResourceOperation,
        snapshot: SandboxSnapshot,
        sandbox: Sandbox,
        app: Application
    ) {
        guard let operationId = operation.id, let snapshotId = snapshot.id else { return }
        let sandboxID = operation.resourceID

        app.backgroundTasks.spawn {
            do {
                if let agentId = snapshot.agentId ?? sandbox.hypervisorId {
                    try await SandboxSnapshotService.requestSnapshotDelete(
                        sandboxId: sandboxID, snapshotId: snapshotId,
                        agentId: agentId, app: app)
                }
                let sandboxRef = snapshot.$sandbox.id
                let projectRef = snapshot.$project.id
                let ownerRef = snapshot.$createdBy.id
                try await app.db.transaction { db in
                    try await snapshot.delete(on: db)
                    // IAM dual-write: drop the snapshot's bindings with the row.
                    try await RoleBindingService.revokeAll(
                        nodeType: .sandboxSnapshot, nodeID: snapshotId, on: db)
                }
                // Relationship cleanup mirrors what create wrote; best-effort
                // (a leaked tuple on a deleted row grants nothing reachable).
                try? await app.spicedb.deleteRelationship(
                    entity: "sandbox_snapshot", entityId: snapshotId.uuidString,
                    relation: "owner", subject: "user", subjectId: ownerRef.uuidString)
                try? await app.spicedb.deleteRelationship(
                    entity: "sandbox_snapshot", entityId: snapshotId.uuidString,
                    relation: "sandbox", subject: "sandbox", subjectId: sandboxRef.uuidString)
                try? await app.spicedb.deleteRelationship(
                    entity: "sandbox_snapshot", entityId: snapshotId.uuidString,
                    relation: "project", subject: "project", subjectId: projectRef.uuidString)
                try? await QuotaEnforcementService.release(for: sandbox, on: app.db)
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .succeeded, error: nil,
                    settingSandboxStatus: nil, app: app)
            } catch {
                if let current = try? await SandboxSnapshot.find(snapshotId, on: app.db) {
                    // Keep `.deleting` — it is retryable (`canDelete`), and
                    // agent-side deletion is idempotent.
                    current.errorMessage = error.localizedDescription
                    try? await current.save(on: app.db)
                }
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .failed,
                    error: error.localizedDescription,
                    settingSandboxStatus: nil, app: app)
            }
        }
    }

    // MARK: - Restore

    /// POST /api/sandboxes/:sandboxID/snapshots/:snapshotID/restore
    ///
    /// Resume-in-place: the sandbox's agent tears down the current microVM
    /// and boots the checkpoint — same sandbox, same identity, same agent
    /// (v1 pins restore placement to the snapshot's agent; the sandbox's
    /// IPAM allocations were never released, so its addresses still hold).
    func restoreSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithPermission(req: req, permission: "read")
        let snapshot = try await fetchSnapshot(req: req, sandbox: sandbox)
        let snapshotID = try snapshot.requireID()
        let sandboxID = try sandbox.requireID()

        let canRestore = try await req.spicedb.checkPermission(
            subject: try user.requireID().uuidString,
            permission: "restore",
            resource: "sandbox_snapshot",
            resourceId: snapshotID.uuidString)
        guard canRestore else {
            throw Abort(.forbidden, reason: "You don't have permission to restore this snapshot")
        }

        guard snapshot.canRestore else {
            throw Abort(
                .conflict,
                reason: "Snapshot cannot be restored in status '\(snapshot.status.rawValue)'")
        }
        // Clone-safety policy (issue #427): do not rewind the source identity
        // to the same memory/RNG/TCP state while live forks of that checkpoint
        // exist. The operator can snapshot again or delete the forks first.
        guard try await Self.liveForkCount(from: snapshotID, on: req.db) == 0 else {
            throw Abort(
                .conflict,
                reason: "Snapshot cannot be restored in place while live forks of it exist")
        }
        guard let agentId = sandbox.hypervisorId else {
            throw Abort(.conflict, reason: "Sandbox is not placed on any agent")
        }
        // v1: artifacts live only on the agent that took the snapshot.
        if let snapshotAgent = snapshot.agentId, snapshotAgent != agentId {
            throw Abort(
                .conflict,
                reason:
                    "Snapshot was taken on agent '\(snapshotAgent)' but the sandbox now lives on '\(agentId)'; cross-agent restore is not supported yet"
            )
        }
        do {
            try await SandboxSnapshotService.requireCapableAgent(agentId, app: req.application)
        } catch let error as SandboxSnapshotServiceError {
            throw Abort(.conflict, reason: error.localizedDescription)
        }

        // The restored guest resumes running; desired state must agree or
        // the next sync would pause it right back.
        let operation = try await beginOperation(
            .restore, sandbox: sandbox, user: user,
            settingDesiredStatus: .running,
            on: req.db)

        Self.runSnapshotRestore(
            operation, snapshotID: snapshotID, agentId: agentId, app: req.application)

        req.logger.info(
            "Sandbox restore accepted",
            metadata: [
                "sandbox_id": .string(sandboxID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
            ])
        return try Self.accepted(operation)
    }

    /// Background half of `restoreSnapshot`.
    private static func runSnapshotRestore(
        _ operation: ResourceOperation,
        snapshotID: UUID,
        agentId: String,
        app: Application
    ) {
        guard let operationId = operation.id else { return }
        let sandboxID = operation.resourceID

        app.backgroundTasks.spawn {
            do {
                try await SandboxSnapshotService.requestRestore(
                    sandboxId: sandboxID, snapshotId: snapshotID, agentId: agentId, app: app)
                // The agent confirmed the guest answered post-restore; the
                // periodic observed report re-confirms.
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .succeeded, error: nil,
                    settingSandboxStatus: .running, app: app)
            } catch {
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .failed,
                    error: error.localizedDescription,
                    settingSandboxStatus: nil, app: app)
            }
        }
    }

    // MARK: - Shared

    static func liveForkCount(from snapshotID: UUID, on db: any Database) async throws -> Int {
        try await Sandbox.query(on: db)
            .filter(\.$restoredFromSnapshotId == snapshotID)
            .count()
    }

    /// Fetch the :snapshotID snapshot and confirm it belongs to `sandbox`
    /// (the route nests snapshots under their sandbox).
    private func fetchSnapshot(req: Request, sandbox: Sandbox) async throws -> SandboxSnapshot {
        guard let snapshotID = req.parameters.get("snapshotID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid snapshot ID")
        }
        guard let snapshot = try await SandboxSnapshot.find(snapshotID, on: req.db),
            snapshot.$sandbox.id == (try sandbox.requireID())
        else {
            throw Abort(.notFound, reason: "Snapshot not found")
        }
        return snapshot
    }
}
