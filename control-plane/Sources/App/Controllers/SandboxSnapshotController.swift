import Fluent
import Foundation
import StratoShared
import Vapor

/// Snapshot / checkpoint-resume handlers for `/api/sandboxes/:id/snapshots`
/// (issue #426), registered by `SandboxController.boot`.
///
/// Create and delete became declarative in ADR 0001 stage 8 (STR-150): both
/// answer `202 {resource, targetGeneration, mutationId}`, the client polls the
/// snapshot's own `conditions`, and the agent captures or removes the artifacts
/// on its next sync and reports what it did — sizes, Firecracker version, fork
/// layout and CPU template included, on a report that is re-sent every
/// heartbeat rather than a reply that a dropped socket could lose.
///
/// Restore followed in stage 9 (STR-151). Loading a checkpoint back over a live
/// microVM really is an edge rather than a state, so it became one by being
/// *counted*: `Sandbox.requestRestore` bumps a monotonic nonce naming the
/// snapshot, and the agent applies it once against its own durable record.
/// Nothing in this file awaits an agent response any more.
extension SandboxController {

    // MARK: - Create

    /// POST /api/sandboxes/:sandboxID/snapshots
    /// Body: { "name"?: string, "stop"?: bool, "ttlSeconds"?: int }
    ///
    /// Checkpoints the sandbox: the agent drains guest connections, pauses
    /// the microVM, captures memory + vmstate, copies the rootfs, then
    /// resumes — or stays stopped when `stop` is true (checkpoint-and-stop).
    func createSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:snapshot")
        let sandboxID = try sandbox.requireID()
        // The body is optional, but a body that *is* sent must decode:
        // masking a malformed `stop` behind defaults would silently run the
        // wrong checkpoint mode.
        let request: CreateSandboxSnapshotRequest
        if req.body.data == nil {
            request = CreateSandboxSnapshotRequest(name: nil, stop: nil, ttlSeconds: nil)
        } else {
            request = try req.content.decodeValidated(CreateSandboxSnapshotRequest.self)
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
        // Capture admission: with the imperative frames gone there is no
        // fallback, so an agent that cannot converge a snapshot is refused here
        // rather than handed a desired state nothing would ever realize.
        try await SnapshotArtifactMutation.requireCaptureCapableAgent(
            agentId, kind: .sandboxSnapshot, app: req.application)

        let project = try await sandbox.project(on: req.db)

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
            captureMode: stopAfterSnapshot ? .stop : .resume,
            expiresAt: nil,
            createdByID: userID)
        // Admission estimate: the memory file dominates and is bounded by
        // guest RAM. Replaced by the agent's actual sizes once its observed
        // report carries them.
        snapshot.size = sandbox.memory
        // The source host's CPU model, recorded now rather than on completion:
        // it is a fact about the *agent*, which the agent's own report has no
        // reason to carry, and an un-templated snapshot needs it to be mobile
        // at all (issue #428).
        snapshot.sourceCPUModel =
            (await req.application.agentService.getAgentInfo(agentId))?
            .hostInfo?.cpuModel
        let environment = sandbox.environment
        let memory = sandbox.memory
        let accepted = try await req.db.transaction { db -> ResourceMutation.Accepted in
            let acceptedAt = try await ClusterClock.read(on: db)
            try await IdempotencyService.reserve(
                req.idempotencyContext, actor: .user(userID), on: db)
            // Snapshot storage draws from the shared storage quota pool
            // (issue #415 enforcement points).
            try await QuotaEnforcementService.reserveSnapshotStorage(
                for: project, environment: environment, size: memory, on: db)
            snapshot.expiresAt = try SnapshotRetention.expiry(
                requested: request.ttlSeconds,
                defaultTTLSeconds: req.controlPlaneConfiguration.optionalInt(
                    .snapshotDefaultTTLSeconds),
                from: acceptedAt)
            snapshot.extendConvergenceDeadline(
                by: OperationResourceKind.sandboxSnapshot.completionBudgetSeconds(for: .create),
                from: acceptedAt)
            try await snapshot.save(on: db)
            // The creator's binding on the snapshot, in the create
            // transaction (the volume-snapshot path, issue #477).
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
                // Checkpoint-and-stop has two halves and they live in two
                // places on purpose. The *capture* leaves the microVM paused,
                // which the agent reads off `captureMode` as a create strategy;
                // the *lasting* intent is the sandbox's own desired state, so
                // the reconciler does not resume it on the next sync. Writing
                // only the first would make "and stop" last exactly until the
                // next level-triggered pass.
                guard try await sandbox.lockAndRefresh(on: db) else {
                    throw Abort(.notFound, reason: "Sandbox no longer exists")
                }
                let expectedGeneration = sandbox.generation
                sandbox.setDesiredStatus(.stopped)
                guard
                    case .applied = try await sandbox.advanceDesiredStateGeneration(
                        expectedGeneration: expectedGeneration, on: db)
                else {
                    throw Abort(
                        .internalServerError,
                        reason: "Failed to advance the locked sandbox generation")
                }
                try await sandbox.save(on: db)
            }
            return try await SnapshotArtifactMutation.recordCapture(
                snapshot, actor: .user(userID), idempotencyContext: req.idempotencyContext, on: db)
        }

        let snapshotID = try snapshot.requireID()
        try SnapshotArtifactMutation.dispatchCapture(snapshot, app: req.application)

        req.logger.info(
            "Sandbox snapshot accepted",
            metadata: [
                "strato.sandbox.id": .string(sandboxID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
                "stop": .stringConvertible(stopAfterSnapshot),
            ])

        return try AcceptedMutation(SandboxSnapshotResponse(from: snapshot), accepted)
            .acceptedResponse()
    }

    // MARK: - List

    /// GET /api/sandboxes/:sandboxID/snapshots
    /// Query params: limit/offset (optional) — select the page.
    func listSnapshots(req: Request) async throws -> PagedResponse<SandboxSnapshotResponse> {
        let paging = try ListPaging.decode(from: req)
        _ = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:read")
        let sandboxID = try sandbox.requireID()

        let snapshots = try await SandboxSnapshot.query(on: req.db)
            .filter(\.$sandbox.$id == sandboxID)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .all()
        return paging.page(snapshots.map { SandboxSnapshotResponse(from: $0) })
    }

    // MARK: - Delete

    /// DELETE /api/sandboxes/:sandboxID/snapshots/:snapshotID
    ///
    /// Marks the snapshot absent and stamps the finalizers its teardown owes.
    /// The row outlives this request: it goes only once the owning agent's
    /// observed report stops listing the artifact, and `SandboxSnapshot.reap`
    /// removes the exported copy and the role bindings at that point.
    func deleteSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:read")
        let snapshot = try await fetchSnapshot(req: req, sandbox: sandbox)
        let snapshotID = try snapshot.requireID()

        let canDelete = try await req.can(
            "sandbox:snapshot", on: IAMNode(type: .sandboxSnapshot, id: snapshotID))
        guard canDelete else {
            throw Abort(.forbidden, reason: "You don't have permission to delete this snapshot")
        }

        // The lineage guard is a data-dependency rule, not a lifecycle one:
        // deleting a checkpoint that live forks were built from would break
        // them. This is a readable preflight; `SnapshotArtifactMutation.delete`
        // checks it authoritatively under the lineage lock in its transaction,
        // shared with every API and retention deletion path.
        if let blocker = try await SnapshotDeletionGuard.blocker(for: snapshot, on: req.db) {
            throw Abort(.conflict, reason: blocker)
        }

        let accepted = try await SnapshotArtifactMutation.delete(
            snapshot, actor: .user(try user.requireID()),
            idempotencyContext: req.idempotencyContext,
            idempotencyResponseBody: { @Sendable snapshot, accepted, _ in
                try AcceptedMutation(SandboxSnapshotResponse(from: snapshot), accepted).encodedBody()
            },
            on: req.db, app: req.application)

        req.logger.info(
            "Sandbox snapshot deletion requested",
            metadata: ["snapshot_id": .string(snapshotID.uuidString)])
        if let response = accepted.cachedResponse() { return response }
        return try AcceptedMutation(SandboxSnapshotResponse(from: snapshot), accepted)
            .acceptedResponse()
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
        let sandbox = try await fetchSandboxWithAction(req: req, action: "sandbox:read")
        let snapshot = try await fetchSnapshot(req: req, sandbox: sandbox)
        let snapshotID = try snapshot.requireID()
        let sandboxID = try sandbox.requireID()

        let canRestore = try await req.can(
            "sandbox:restore", on: IAMNode(type: .sandboxSnapshot, id: snapshotID))
        guard canRestore else {
            throw Abort(.forbidden, reason: "You don't have permission to restore this snapshot")
        }

        guard snapshot.canRestore else {
            throw Abort(
                .conflict,
                reason: "Snapshot cannot be restored in status '\(snapshot.status.rawValue)'")
        }
        guard snapshot.guestControlProtocolVersion == SandboxGuestControlProtocol.currentVersion else {
            throw Abort(
                .conflict,
                reason: Self.unsupportedGuestProtocolReason(snapshot.guestControlProtocolVersion))
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
        guard let targetAgent = await req.application.agentService.getAgentInfo(agentId) else {
            throw Abort(.conflict, reason: "Sandbox's agent '\(agentId)' is unknown")
        }
        // The issue #415 rule the capture path also follows: the capability
        // proves a backend that can load a checkpoint is usable on that host.
        // A host without one fails later still, as a `degraded` condition an
        // hour after admission — refused here instead.
        guard targetAgent.supportsSnapshotArtifact(.sandboxSnapshot) else {
            throw Abort(
                .conflict,
                reason:
                    "Agent '\(agentId)' cannot restore sandbox snapshots "
                    + "(the Firecracker snapshot backend is unavailable).")
        }
        // Cross-agent restore (issue #428): when the sandbox no longer lives
        // on the agent that took the snapshot, the restore rides the exported
        // copy — which must exist, and the target must satisfy the recorded
        // compatibility constraints (Firecracker version, architecture, CPU
        // template or identical CPU). Only the *eligibility* is decided here;
        // the descriptors themselves are resolved fresh at sync assembly, so a
        // nonce that sits in the desired state never carries a stale locator.
        if let snapshotAgent = snapshot.agentId, snapshotAgent != agentId {
            guard snapshot.isExported else {
                throw Abort(
                    .conflict,
                    reason:
                        "Snapshot was taken on agent '\(snapshotAgent)' but the sandbox now lives on '\(agentId)'; export the snapshot first to enable cross-agent restore"
                )
            }
            if let blocker = SandboxSnapshotCompatibility.restoreBlocker(
                snapshot: snapshot, target: targetAgent)
            {
                throw Abort(.conflict, reason: blocker)
            }
            guard (try snapshot.exportedArtifactDescriptors()) != nil else {
                throw Abort(.conflict, reason: "Snapshot's exported copy is incomplete; re-export it")
            }
        }

        let userID = try user.requireID()
        let accepted = try await req.resourceMutation.accept(
            .restore, on: sandbox, actor: .user(userID), dispatch: .stateSync,
            on: req.db, app: req.application
        ) { @Sendable db in
            try await Self.lockSnapshotLineage([snapshotID], on: db)
            guard let current = try await SandboxSnapshot.find(snapshotID, on: db), current.canRestore
            else {
                throw Abort(.conflict, reason: "Snapshot is no longer restorable")
            }
            guard
                current.guestControlProtocolVersion
                    == SandboxGuestControlProtocol.currentVersion
            else {
                throw Abort(
                    .conflict,
                    reason: Self.unsupportedGuestProtocolReason(
                        current.guestControlProtocolVersion))
            }
            // Clone-safety policy (issue #427): do not rewind the source
            // identity to the same memory/RNG/TCP state while live forks of
            // that checkpoint exist.
            guard try await Self.liveForkCount(from: snapshotID, on: db) == 0 else {
                throw Abort(
                    .conflict,
                    reason: "Snapshot cannot be restored in place while live forks of it exist")
            }
            // Bumps the restore nonce and sets desired `.running` — the restored
            // guest resumes, so desired state has to agree or the next sync
            // would stop it right back.
            sandbox.requestRestore(snapshotID: snapshotID)
        }

        req.logger.info(
            "Sandbox restore accepted",
            metadata: [
                "strato.sandbox.id": .string(sandboxID.uuidString),
                "snapshot_id": .string(snapshotID.uuidString),
            ])
        return try await SandboxController.acceptedResponse(for: sandbox, accepted, on: req)
    }

    // MARK: - Shared

    static func liveForkCount(from snapshotID: UUID, on db: any Database) async throws -> Int {
        try await Sandbox.query(on: db)
            .filter(\.$restoredFromSnapshotId == snapshotID)
            .count()
    }

    /// Serialize every fork admission and destructive lineage transition on
    /// the snapshot IDs they touch. Postgres advisory locks span replicas and
    /// live until the enclosing transaction commits.
    static func lockSnapshotLineage(_ snapshotIDs: [UUID], on db: any Database) async throws {
        try await AdvisoryLock.acquireTransactionLocks(
            .sandboxSnapshotLineage, objectIDs: snapshotIDs, on: db)
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
        guard snapshot.guestControlProtocolVersion == SandboxGuestControlProtocol.currentVersion else {
            throw Abort(
                .conflict,
                reason: unsupportedGuestProtocolReason(snapshot.guestControlProtocolVersion))
        }
        let sourceID = snapshot.$sandbox.id
        guard let source = try await Sandbox.find(sourceID, on: db), source.desiredStatus != .absent else {
            throw Abort(.conflict, reason: "Snapshot source sandbox is being deleted")
        }
        try await requireNoRestoreInFlight(on: source, on: db)
    }

    /// Refuses a fork while the source sandbox has an in-place restore the
    /// agent has not applied: its rootfs is about to be replaced under the
    /// fork's feet, so the layout this fork would clone is not the one it read.
    ///
    /// Read from the audit trail plus the source's own convergence, rather than
    /// from a pending operation row — which is what this used to query, and
    /// which nothing has written since restore became an edge-nonce (STR-151).
    ///
    /// **The newest `.restore`, not the newest mutation.** The row this replaces
    /// matched *any* pending restore, and the agent's rule is that nothing
    /// supersedes a restore — `Reconciliation.planWorkloadSteps` applies one
    /// only when the workload is wanted running, and a stop makes it wait
    /// rather than consume it. So a restore followed by a `.shutdown` is still
    /// outstanding even though the shutdown is the newer event, and keying on
    /// "the newest mutation happens to be a restore" would admit a fork the row
    /// refused.
    ///
    /// **Known gap.** The agent reports no applied-nonce echo —
    /// `ObservedSandboxState` carries `observedGeneration` and nothing about
    /// `restore` — so the only signal here is generation convergence, and it
    /// cannot see a restore the agent has deferred. A restore requested at
    /// generation N and then superseded by a stop converges at N+1 with the
    /// restore still pending on the agent, and this admits the fork. Closing
    /// that needs the applied nonce on the wire (or a control-plane latch fed
    /// by one); it is deliberately not faked from current state, because every
    /// derivation that closes it also refuses forks of any sandbox that was
    /// restored and later stopped.
    private static func requireNoRestoreInFlight(
        on source: Sandbox, on db: any Database
    ) async throws {
        let sourceID = try source.requireID()
        let restore = try await ResourceEvent.query(on: db)
            .filter(\.$resourceKind == .sandbox)
            .filter(\.$resourceID == sourceID)
            .filter(\.$phase == .requested)
            .filter(\.$mutation == .restore)
            .sort(\.$createdAt, .descending)
            .first()
        guard let restore else { return }
        // `requestRestore` bumps the sandbox's generation alongside its
        // `restoreGeneration` (via `setDesiredStatus(.running)`), so the
        // generation the restore was requested at is what the agent has to
        // report before it can have applied it.
        guard source.observedGeneration < (restore.targetGeneration ?? source.generation) else {
            return
        }
        throw Abort(.conflict, reason: "Snapshot is being restored in place")
    }

    private static func unsupportedGuestProtocolReason(_ version: Int?) -> String {
        "Snapshot uses unsupported guest control protocol "
            + "\(version.map(String.init) ?? "missing"); version "
            + "\(SandboxGuestControlProtocol.currentVersion) is required. Delete this snapshot "
            + "and recapture it after upgrading the sandbox guest image."
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
