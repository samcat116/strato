import Fluent
import Foundation
import SQLKit
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

        return try operation.acceptedResponse()
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

                // The agent RPC above can span shutdown's drain; bail before the
                // write-back if it cancelled us (see `Application.liveDB`), and
                // reuse the captured handle for the rest of the body.
                guard let db = app.liveDB else { return }
                if let current = try await SandboxSnapshot.find(snapshotId, on: db) {
                    current.status = .ready
                    current.size = report.sizeBytes
                    current.storagePath = report.storagePath
                    current.firecrackerVersion = report.firecrackerVersion
                    current.architecture = report.architecture?.rawValue
                    current.guestControlProtocolVersion = report.guestControlProtocolVersion
                    current.forkLayoutVersion = report.forkLayoutVersion
                    // Mobility constraints (issue #428): the template the
                    // guest actually booted with (agent-authoritative), and
                    // the source host's CPU model — the identity check an
                    // un-templated snapshot needs to move at all.
                    current.cpuTemplate = report.cpuTemplate
                    current.sourceCPUModel =
                        (await app.agentService.getAgentInfo(agentId))?.hostInfo?.cpuModel
                    try await current.save(on: db)
                }

                // Admission reserved only an estimate (guest memory); the
                // actual footprint adds vmstate + the rootfs copy. Resync the
                // counters to the reported figures and, if that blew past an
                // enabled storage quota, delete the snapshot rather than keep
                // over-quota storage.
                if let violatedQuota = try await QuotaEnforcementService.storageOverCommit(
                    projectID: projectID, environment: environment, on: db)
                {
                    try? await SandboxSnapshotService.requestSnapshotDelete(
                        sandboxId: sandboxID, snapshotId: snapshotId, agentId: agentId, app: app)
                    if let current = try? await SandboxSnapshot.find(snapshotId, on: db) {
                        current.status = .error
                        current.errorMessage =
                            "Snapshot exceeded storage quota '\(violatedQuota)' and was deleted"
                        current.size = 0
                        try? await current.save(on: db)
                    }
                    try? await QuotaEnforcementService.release(for: sandbox, on: db)
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
                // `try?` does not catch the fatal unwrap a torn-down `app.db`
                // produces, so short-circuit on cancellation before each access.
                if let db = app.liveDB, let current = try? await SandboxSnapshot.find(snapshotId, on: db) {
                    current.status = .error
                    current.errorMessage = error.localizedDescription
                    current.size = 0
                    try? await current.save(on: db)
                }
                if let db = app.liveDB {
                    try? await QuotaEnforcementService.release(for: sandbox, on: db)
                }
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
        let operation = try await ResourceOperation.begin(
            .snapshotDelete,
            resourceKind: .sandbox,
            resourceID: try sandbox.requireID(),
            userID: try user.requireID(),
            on: req.db
        ) { db in
            try await Self.lockSnapshotLineage([snapshotID], on: db)
            guard let current = try await SandboxSnapshot.find(snapshotID, on: db), current.canDelete else {
                throw Abort(.conflict, reason: "Snapshot is no longer deletable")
            }
            guard try await Self.liveForkCount(from: snapshotID, on: db) == 0 else {
                throw Abort(
                    .conflict,
                    reason: "Snapshot cannot be deleted while sandboxes forked from it still exist")
            }
            current.status = .deleting
            try await current.save(on: db)
        }

        Self.runSnapshotDeletion(operation, snapshot: snapshot, sandbox: sandbox, app: req.application)
        return try operation.acceptedResponse()
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
                // The exported copy goes with the snapshot (issue #428);
                // best-effort, like the SpiceDB tuples below.
                await snapshot.deleteExportedObjects(app: app)
                let sandboxRef = snapshot.$sandbox.id
                let projectRef = snapshot.$project.id
                let ownerRef = snapshot.$createdBy.id
                // The agent RPC above can span shutdown's drain; bail before the
                // row delete if it cancelled us (see `Application.liveDB`).
                guard let db = app.liveDB else { return }
                try await db.transaction { db in
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
                try? await QuotaEnforcementService.release(for: sandbox, on: db)
                await completeOperation(
                    operationId, sandboxID: sandboxID, as: .succeeded, error: nil,
                    settingSandboxStatus: nil, app: app)
            } catch {
                // `try?` does not catch the fatal unwrap a torn-down `app.db`
                // produces, so short-circuit on cancellation before the access.
                if let db = app.liveDB, let current = try? await SandboxSnapshot.find(snapshotId, on: db) {
                    // Keep `.deleting` — it is retryable (`canDelete`), and
                    // agent-side deletion is idempotent.
                    current.errorMessage = error.localizedDescription
                    try? await current.save(on: db)
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
        // Preserve the specific clone-safety error during request preflight;
        // the locked transaction below repeats this check authoritatively.
        guard try await Self.liveForkCount(from: snapshotID, on: req.db) == 0 else {
            throw Abort(
                .conflict,
                reason: "Snapshot cannot be restored in place while live forks of it exist")
        }
        guard let agentId = sandbox.hypervisorId else {
            throw Abort(.conflict, reason: "Sandbox is not placed on any agent")
        }
        do {
            try await SandboxSnapshotService.requireCapableAgent(agentId, app: req.application)
        } catch let error as SandboxSnapshotServiceError {
            throw Abort(.conflict, reason: error.localizedDescription)
        }
        // Cross-agent restore (issue #428): when the sandbox no longer lives
        // on the agent that took the snapshot, the restore rides the exported
        // copy — which must exist, and the target must satisfy the recorded
        // compatibility constraints (Firecracker version, architecture, CPU
        // template or identical CPU).
        var transferArtifacts: [SandboxSnapshotArtifactDescriptor]?
        if let snapshotAgent = snapshot.agentId, snapshotAgent != agentId {
            guard snapshot.isExported else {
                throw Abort(
                    .conflict,
                    reason:
                        "Snapshot was taken on agent '\(snapshotAgent)' but the sandbox now lives on '\(agentId)'; export the snapshot first to enable cross-agent restore"
                )
            }
            guard let targetAgent = await req.application.agentService.getAgentInfo(agentId) else {
                throw Abort(.conflict, reason: "Sandbox's agent '\(agentId)' is unknown")
            }
            if let blocker = SandboxSnapshotCompatibility.restoreBlocker(
                snapshot: snapshot, target: targetAgent)
            {
                throw Abort(.conflict, reason: blocker)
            }
            transferArtifacts = try snapshot.exportedArtifactDescriptors()
            guard transferArtifacts != nil else {
                throw Abort(.conflict, reason: "Snapshot's exported copy is incomplete; re-export it")
            }
        }

        // The restored guest resumes running; desired state must agree or
        // the next sync would pause it right back.
        let operation = try await beginOperation(
            .restore, sandbox: sandbox, user: user,
            settingDesiredStatus: .running,
            on: req.db
        ) { db in
            try await Self.lockSnapshotLineage([snapshotID], on: db)
            guard let current = try await SandboxSnapshot.find(snapshotID, on: db), current.canRestore
            else {
                throw Abort(.conflict, reason: "Snapshot is no longer restorable")
            }
            // Clone-safety policy (issue #427): do not rewind the source
            // identity to the same memory/RNG/TCP state while live forks of
            // that checkpoint exist.
            guard try await Self.liveForkCount(from: snapshotID, on: db) == 0 else {
                throw Abort(
                    .conflict,
                    reason: "Snapshot cannot be restored in place while live forks of it exist")
            }
        }

        Self.runSnapshotRestore(
            operation, snapshotID: snapshotID, agentId: agentId,
            artifacts: transferArtifacts, app: req.application)

        req.logger.info(
            "Sandbox restore accepted",
            metadata: [
                "sandbox_id": .string(sandboxID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
            ])
        return try operation.acceptedResponse()
    }

    /// Background half of `restoreSnapshot`. `artifacts` is non-nil for a
    /// cross-agent restore: the target agent stages the exported archive from
    /// object storage before loading it (issue #428).
    private static func runSnapshotRestore(
        _ operation: ResourceOperation,
        snapshotID: UUID,
        agentId: String,
        artifacts: [SandboxSnapshotArtifactDescriptor]? = nil,
        app: Application
    ) {
        guard let operationId = operation.id else { return }
        let sandboxID = operation.resourceID

        app.backgroundTasks.spawn {
            do {
                try await SandboxSnapshotService.requestRestore(
                    sandboxId: sandboxID, snapshotId: snapshotID, agentId: agentId,
                    artifacts: artifacts, app: app)
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

    /// Serialize every fork admission and destructive lineage transition on
    /// the snapshot IDs they touch. Postgres advisory locks span replicas and
    /// live until the enclosing transaction commits; SQLite writes already
    /// serialize in local tests, so it needs no separate primitive.
    static func lockSnapshotLineage(_ snapshotIDs: [UUID], on db: any Database) async throws {
        guard let sql = db as? SQLDatabase, sql.dialect.name == "postgresql" else { return }
        for snapshotID in Set(snapshotIDs).sorted(by: { $0.uuidString < $1.uuidString }) {
            try await sql.raw(
                "SELECT pg_advisory_xact_lock(hashtext(\(bind: "sandbox-snapshot-lineage:\(snapshotID.uuidString)")))"
            ).run()
        }
    }

    /// Removes the exported object-store copies of every snapshot belonging
    /// to `sandboxID` (issue #428). Called on the sandbox-row deletion paths
    /// *before* the delete, because the snapshot rows cascade with the
    /// sandbox and take the export records with them. Best-effort by the
    /// same rationale as `deleteExportedObjects`.
    static func cleanUpExportedSnapshotObjects(for sandboxID: UUID, app: Application) async {
        // Best-effort cleanup runs on the delete completion paths, which may
        // reach here after shutdown's drain cancelled the task; `try?` does not
        // catch the fatal unwrap a torn-down `app.db` produces, so guard first.
        guard let db = app.liveDB else { return }
        guard
            let snapshots = try? await SandboxSnapshot.query(on: db)
                .filter(\.$sandbox.$id == sandboxID)
                .all()
        else { return }
        for snapshot in snapshots {
            await snapshot.deleteExportedObjects(app: app)
        }
    }

    /// Shared guard for every source-sandbox deletion path, including API
    /// requests and automated TTL/retention expiry. The caller must invoke it
    /// in the same transaction that marks the source absent.
    static func requireSnapshotLineageDeletable(
        for sandboxID: UUID, on db: any Database
    ) async throws {
        let snapshotIDs = try await SandboxSnapshot.query(on: db)
            .filter(\.$sandbox.$id == sandboxID)
            .all()
            .compactMap(\.id)
        try await lockSnapshotLineage(snapshotIDs, on: db)
        guard !snapshotIDs.isEmpty else { return }
        let descendants = try await Sandbox.query(on: db)
            .filter(\.$restoredFromSnapshotId ~~ snapshotIDs)
            .count()
        guard descendants == 0 else {
            throw Abort(
                .conflict,
                reason: "Sandbox cannot be deleted while forks derived from its snapshots still exist")
        }
    }

    /// Load-bearing fork recheck performed under the same lineage lock and
    /// transaction as the target sandbox insert. The outer request preflight
    /// gives specific authorization/compatibility errors; this closes races
    /// with snapshot delete, source delete, and in-place restore.
    static func requireSnapshotAvailableForFork(
        _ snapshotID: UUID, on db: any Database
    ) async throws {
        try await lockSnapshotLineage([snapshotID], on: db)
        guard let snapshot = try await SandboxSnapshot.find(snapshotID, on: db), snapshot.isReady else {
            throw Abort(.conflict, reason: "Snapshot is no longer ready for fork")
        }
        guard SandboxSnapshotForkLayout.supportsFork(snapshot.forkLayoutVersion) else {
            throw Abort(
                .conflict,
                reason: "Snapshot was not captured in a fork-compatible jailed layout")
        }
        let sourceID = snapshot.$sandbox.id
        guard let source = try await Sandbox.find(sourceID, on: db), source.desiredStatus != .absent else {
            throw Abort(.conflict, reason: "Snapshot source sandbox is being deleted")
        }
        let pendingRestore = try await ResourceOperation.query(on: db)
            .filter(\.$resourceKind == .sandbox)
            .filter(\.$resourceID == sourceID)
            .filter(\.$status == .pending)
            .filter(\.$kind == .restore)
            .first()
        guard pendingRestore == nil else {
            throw Abort(.conflict, reason: "Snapshot is being restored in place")
        }
    }

    /// Fetch the :snapshotID snapshot and confirm it belongs to `sandbox`
    /// (the route nests snapshots under their sandbox). Internal because the
    /// mobility handlers in SandboxSnapshotTransferController.swift share it.
    func fetchSnapshot(req: Request, sandbox: Sandbox) async throws -> SandboxSnapshot {
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
