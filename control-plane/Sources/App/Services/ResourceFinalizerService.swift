import Fluent
import SQLKit
import Vapor

/// A resource whose deletion runs through finalizers: the row is marked
/// terminating, carries a list of outstanding cleanup tokens, and is removed
/// only once that list empties (ADR 0001, stage 3).
///
/// Divergence between the workload kinds lives in `reap` — what each one has
/// to tear down alongside its row — rather than in the finalizer bookkeeping,
/// which is identical for both.
protocol FinalizableResource: Model, AgentPlacedResource where IDValue == UUID {
    /// Cleanup tokens still outstanding for a terminating resource; empty for
    /// a live one. Persisted as a Postgres `text[]`.
    var finalizers: [String] { get set }

    /// Whether a `DELETE` has been accepted — desired state is `.absent`. Only
    /// a terminating resource reaps, so a stray `clear` on a live one is a
    /// no-op rather than a deletion.
    var isTerminating: Bool { get }

    /// Everything that must happen when the last finalizer clears: external
    /// cleanup first, then the row and the accounting that goes with it.
    ///
    /// Returns whether *this* call removed the row. Two clears can decide to
    /// reap concurrently — the applier on one replica racing the direct path on
    /// another — so the implementation claims the row inside its transaction
    /// (`reapClaim`) and the loser returns false rather than logging a removal
    /// it did not perform. Everything before the claim must tolerate running
    /// twice; the row is what records that the teardown finished.
    static func reap(_ resource: Self, on db: any Database, app: Application) async throws -> Bool

    /// Which table the resource's `resource_events` rows point into.
    static var operationResourceKind: OperationResourceKind { get }
}

/// The finalizer bookkeeping shared by every terminating resource: stamping
/// the list at `DELETE` time, and clearing one participant's token — atomically
/// against other participants and other replicas — reaping the row when it was
/// the last one.
enum ResourceFinalizerService {

    /// What one `clear` did. Distinguishing these matters to callers: a
    /// deletion is only complete on `.reaped`/`.alreadyGone`, and `.held` is
    /// the one case where a row legitimately outlives its clear.
    enum ClearOutcome: Sendable, Equatable {
        /// The last token cleared and this call removed the row.
        case reaped
        /// The row was already gone — another participant, or another replica,
        /// reaped it first.
        case alreadyGone
        /// Tokens remain; these are they.
        case held([String])
        /// The resource is not terminating, so there was nothing to clear.
        case notTerminating

        /// Whether the resource is now absent from the database, however it got
        /// that way. This is what a caller deciding "is the delete done?"
        /// should ask — not `== .reaped`, which is only true for the winner of
        /// a race.
        var isRemoved: Bool {
            switch self {
            case .reaped, .alreadyGone: return true
            case .held, .notTerminating: return false
            }
        }
    }

    /// The tokens a fresh deletion of `resource` stamps. A resource with no
    /// agent has nothing to confirm, so it stamps nothing and reaps on the
    /// first `clear` — which is how an unplaced VM still deletes immediately.
    static func tokens<R: FinalizableResource>(
        forDeleting resource: R, on db: any Database
    ) async throws -> [ResourceFinalizer] {
        try await resource.placementAgentIDs(on: db).isEmpty ? [] : [.agentAbsent]
    }

    /// Stamps the finalizer list for a deletion. Call in the same write that
    /// marks desired state `.absent`, *before* the mark: a resource already
    /// terminating keeps the list it has, because re-stamping would resurrect
    /// tokens their participants have already cleared. Does not persist.
    static func stampForDeletion<R: FinalizableResource>(
        _ resource: R, on db: any Database
    ) async throws {
        guard !resource.isTerminating else { return }
        resource.finalizers = try await tokens(forDeleting: resource, on: db).map(\.rawValue)
    }

    /// Idempotently clears `token` from a terminating resource, reaping the row
    /// when it was the last one outstanding.
    ///
    /// The removal is a single `array_remove` statement rather than a
    /// read-modify-write: two participants clearing concurrently — on two
    /// replicas, in any order — would otherwise lose one of the updates and
    /// resurrect a token nothing will ever clear again. The statement returns
    /// the authoritative post-update list, which is also what the in-memory
    /// model is set to, so a later `save` on the same instance cannot write
    /// back a stale list and undo that guarantee.
    ///
    /// Clearing the token and reaping the row are two commits. A crash in
    /// between leaves a terminating row with an empty list, which the
    /// participant's next trigger reaps: clearing an already-cleared token
    /// still reaps an empty list. For `agent.absent` that trigger is every
    /// observed-state report omitting the workload; for the one-shot direct
    /// path it is `sweepOrphanedTerminatingResources`, the backstop that also
    /// covers any future participant whose trigger does not repeat.
    @discardableResult
    static func clear<R: FinalizableResource>(
        _ token: ResourceFinalizer,
        from resource: R,
        on db: any Database,
        app: Application
    ) async throws -> ClearOutcome {
        guard resource.isTerminating else { return .notTerminating }
        let id = try resource.requireID()

        guard let sql = db as? any SQLDatabase else {
            throw FinalizerError.unsupportedDatabase
        }

        let row = try await sql.raw(
            """
            UPDATE \(ident: R.schema)
            SET finalizers = array_remove(finalizers, \(bind: token.rawValue))
            WHERE id = \(bind: id)
            RETURNING finalizers
            """
        ).first(decoding: RemainingFinalizers.self)

        guard let row else { return .alreadyGone }

        // The post-update list from the database, not a hand-computed one: this
        // instance may be saved later, and the row may have changed under it.
        resource.finalizers = row.finalizers

        guard row.finalizers.isEmpty else { return .held(row.finalizers) }

        // Shutdown's drain cancels the background tasks the direct-deletion
        // path runs on, and `reap` opens a transaction on a database that is
        // about to be torn down. Fail rather than return: the row is still
        // standing, so reporting a removal would be a lie, and the caller's
        // verdict recording bails on a drained application anyway.
        try Task.checkCancellation()

        return try await R.reap(resource, on: db, app: app) ? .reaped : .alreadyGone
    }

    /// Resolve a VM-owned boot volume when its agent is offline. Physical
    /// bytes may remain on that host, matching the VM process orphan policy,
    /// but database ownership still tears down in boot-volume-before-VM order.
    /// Online deletes never call this; their agent must confirm both absences.
    static func abandonBootVolumeForOfflineVM(
        vmID: UUID, on db: any Database, app: Application
    ) async throws {
        let bootVolumes = try await Volume.query(on: db)
            .filter(\.$vm.$id == vmID)
            .filter(\.$volumeType == .boot)
            .all()

        if bootVolumes.isEmpty, let vm = try await VM.find(vmID, on: db) {
            _ = try await clear(.bootVolumeAbsent, from: vm, on: db, app: app)
            return
        }
        guard bootVolumes.count == 1, let bootVolume = bootVolumes.first else {
            throw FinalizerError.invalidBootVolumeCount(vmID: vmID, count: bootVolumes.count)
        }
        _ = try await clear(.agentAbsent, from: bootVolume, on: db, app: app)
    }

    /// Appends the terminal `resource_events` row for a completed deletion, and
    /// enqueues the `operation.completed` webhook that used to ride the
    /// operation's verdict (STR-147).
    ///
    /// Call inside the reap's transaction, *after* `reapClaim` — the claim is
    /// what makes "this call removed the row" true for exactly one writer, and
    /// so makes this append exactly-once under a reap race.
    ///
    /// This is the whole answer to "how does a client know a delete finished?".
    /// Every other mutation's outcome is readable off the resource's own
    /// `conditions`; a delete's is the resource being gone, and a `404` means
    /// deleted, never-existed and not-authorized alike. The row's scope is
    /// copied from the delete *request* event rather than resolved, because
    /// there is nothing left to resolve against by the time this runs.
    ///
    /// Best-effort on the request lookup: a row deleted by some path that never
    /// recorded a request (a pre-STR-147 delete mid-flight across a deploy)
    /// still gets a terminal event, just without the scope, which is strictly
    /// better than none.
    static func recordDeletionCompleted<R: FinalizableResource>(
        _ resource: R, in tx: any Database
    ) async throws {
        let id = try resource.requireID()
        let request = try await ResourceEvent.latest(
            .requested, resourceKind: R.operationResourceKind, resourceID: id, on: tx)

        let terminal = try await ResourceEvent.record(
            .delete,
            resourceKind: R.operationResourceKind,
            resourceID: id,
            actor: request.map { MutationActor(type: $0.actorType, id: $0.actorID) } ?? .system,
            phase: .completed,
            scope: ResourceEvent.Scope(
                organizationID: request?.organizationID,
                projectID: request?.projectID,
                resourceName: request?.resourceName,
                generation: request?.targetGeneration),
            on: tx)

        try await WebhookEvents.enqueueDeletionCompleted(terminal, requestID: request?.id, on: tx)
    }

    /// Claims the right to reap `id` inside `tx`, returning false when another
    /// writer already removed the row. `SELECT … FOR UPDATE` holds the row lock
    /// for the rest of the transaction, so a concurrent reap blocks here and
    /// then finds nothing — which is what makes "this call removed the row"
    /// exactly true for one of them.
    static func reapClaim<R: FinalizableResource>(
        _ type: R.Type, id: UUID, in tx: any Database
    ) async throws -> Bool {
        guard let sql = tx as? any SQLDatabase else {
            throw FinalizerError.unsupportedDatabase
        }
        return try await sql.raw(
            "SELECT id FROM \(ident: R.schema) WHERE id = \(bind: id) FOR UPDATE"
        ).first() != nil
    }

    /// The post-update finalizer list, read back from `RETURNING`.
    private struct RemainingFinalizers: Decodable {
        let finalizers: [String]
    }

    enum FinalizerError: Error, CustomStringConvertible {
        case unsupportedDatabase
        case invalidBootVolumeCount(vmID: UUID, count: Int)

        var description: String {
            switch self {
            case .unsupportedDatabase:
                return "Finalizer bookkeeping requires an SQL database"
            case .invalidBootVolumeCount(let vmID, let count):
                return "VM \(vmID) has \(count) canonical boot volumes during deletion"
            }
        }
    }
}

// MARK: - VM

extension VM: FinalizableResource {
    var isTerminating: Bool { desiredStatus == .absent }

    static func reap(_ vm: VM, on db: any Database, app: Application) async throws -> Bool {
        let vmID = try vm.requireID()

        let reaped = try await db.transaction { tx in
            // Attached data volumes are released, not deleted: they outlive
            // the VM. The canonical boot volume has already been reaped — its
            // finalizer is what allowed this VM to reach the claim. Necessary
            // because `volumes.vm_id` is `ON DELETE RESTRICT` — a volume still
            // pointing here fails the delete rather than being silently
            // stranded the way `SET NULL` left it.
            //
            // *Before* the claim, which is the whole reason it is up here: an
            // attach locks the volume row first (`lockAndRefresh`) and only then
            // touches its VM, through the foreign key's `FOR KEY SHARE`. A reap
            // that claimed the VM row first would take those two in the opposite
            // order and deadlock with it. Running before the claim is safe on
            // the claim's own terms — everything ahead of it must tolerate
            // running twice, and releasing an already-released volume finds no
            // rows to release.
            let released = try await VolumeAttachmentService.releaseDataVolumes(fromVM: vmID, on: tx)
            if !released.isEmpty {
                app.logger.info(
                    "Released volumes from deleted VM",
                    metadata: [
                        "strato.vm.id": .string(vmID.uuidString),
                        "volume_ids": .array(released.map { .string($0.uuidString) }),
                    ])
            }

            guard try await ResourceFinalizerService.reapClaim(VM.self, id: vmID, in: tx) else {
                return false
            }
            // Bindings first, unlike the delete-then-revoke order the other
            // controllers use: the revoke reads the VM's checkpoints, whose
            // rows the delete below cascades away (STR-112).
            try await ResourceBindingCleanup.revokeBindings(forDeletedVM: vmID, on: tx)
            // Before the row goes: the terminal event reads the delete request's
            // scope, and after the delete there is nothing left to read.
            try await ResourceFinalizerService.recordDeletionCompleted(vm, in: tx)
            try await vm.delete(on: tx)
            try await QuotaEnforcementService.release(for: vm, on: tx)
            return true
        }

        guard reaped else { return false }

        if let agentId = vm.hypervisorId {
            await app.coordination.releaseReservation(agentId: agentId, vmId: vmID.uuidString)
        }
        return true
    }
}

// MARK: - Sandbox

extension Sandbox: FinalizableResource {
    var isTerminating: Bool { desiredStatus == .absent }

    static func reap(_ sandbox: Sandbox, on db: any Database, app: Application) async throws -> Bool {
        let sandboxID = try sandbox.requireID()

        // Exported snapshot objects first: the snapshot rows cascade with the
        // sandbox row below (issue #428). Outside the transaction because it is
        // object-store I/O, so it can run twice — once per side of a reap race,
        // or again after a crash. Deleting an already-deleted object is a
        // no-op, which is what makes that safe.
        await SandboxController.cleanUpExportedSnapshotObjects(for: sandboxID, app: app)

        let reaped = try await db.transaction { tx in
            guard try await ResourceFinalizerService.reapClaim(Sandbox.self, id: sandboxID, in: tx) else {
                return false
            }
            // Bindings first, for the same reason the exported objects go
            // first: the revoke reads the snapshot rows the delete cascades
            // away (STR-112).
            try await ResourceBindingCleanup.revokeBindings(forDeletedSandbox: sandboxID, on: tx)
            try await ResourceFinalizerService.recordDeletionCompleted(sandbox, in: tx)
            try await sandbox.delete(on: tx)
            try await QuotaEnforcementService.release(for: sandbox, on: tx)
            return true
        }

        guard reaped else { return false }

        if let agentId = sandbox.hypervisorId {
            await app.coordination.releaseReservation(agentId: agentId, vmId: sandboxID.uuidString)
        }
        return true
    }
}

// MARK: - Volume

extension Volume: FinalizableResource {
    static func reap(_ volume: Volume, on db: any Database, app: Application) async throws -> Bool {
        let volumeID = try volume.requireID()
        let parentVMID = volume.volumeType == .boot ? volume.$vm.id : nil

        let reaped = try await db.transaction { tx in
            guard try await ResourceFinalizerService.reapClaim(Volume.self, id: volumeID, in: tx) else {
                return false
            }
            // Bindings first, for the same reason as VMs and sandboxes: the
            // revoke reads the volume's snapshot rows, which the delete below
            // cascades away.
            try await ResourceBindingCleanup.revokeBindings(forDeletedVolume: volumeID, on: tx)
            try await ResourceFinalizerService.recordDeletionCompleted(volume, in: tx)
            try await volume.delete(on: tx)
            if let parentVMID {
                guard let sql = tx as? any SQLDatabase else {
                    throw ResourceFinalizerService.FinalizerError.unsupportedDatabase
                }
                // Removing the child row and acknowledging its absence on the
                // parent are one commit. A crash after this transaction cannot
                // strand a VM behind a token whose only future trigger was the
                // now-deleted boot volume.
                try await sql.raw(
                    """
                    UPDATE vms
                    SET finalizers = array_remove(
                        finalizers, \(bind: ResourceFinalizer.bootVolumeAbsent.rawValue)
                    )
                    WHERE id = \(bind: parentVMID)
                    """
                ).run()
            }
            // After the delete, so the volume drops out of the recount (STR-181).
            // One call covers its snapshots too: their rows cascade with the one
            // above, and release recomputes rather than decrements.
            try await QuotaEnforcementService.release(for: volume, on: tx)
            return true
        }
        guard reaped else { return false }

        if let parentVMID, let parent = try await VM.find(parentVMID, on: db) {
            _ = try await ResourceFinalizerService.clear(
                .bootVolumeAbsent, from: parent, on: db, app: app)
        }
        return true
        // No placement reservation to give back — volumes draw on none. Their
        // `volume_replicas` and `volume_snapshots` rows cascade with the row
        // above.
    }
}

// MARK: - Snapshot artifacts (ADR 0001 stage 8, STR-150)

/// One reap for all three artifact families.
///
/// The three differ only in what has to happen *outside* the row — a sandbox
/// snapshot's exported objects, a checkpoint's nothing — and in which storage
/// pool the freed bytes belong to. Both are parameters, so the claim/record/
/// delete sequence that has to be exactly right is written once.
enum SnapshotArtifactReap {
    static func reap<A: SnapshotArtifactResource>(
        _ artifact: A,
        on db: any Database,
        app: Application,
        externalCleanup: @Sendable (A, Application) async -> Void = { _, _ in },
        releaseQuota: @escaping @Sendable (A, any Database) async throws -> Void = { _, _ in }
    ) async throws -> Bool {
        let artifactID = try artifact.requireID()

        // External cleanup first, and outside the transaction, because it is
        // object-store I/O: it can run twice — once per side of a reap race, or
        // again after a crash — and deleting an already-deleted object is a
        // no-op, which is what makes that safe (the `Sandbox.reap` precedent).
        await externalCleanup(artifact, app)

        return try await db.transaction { tx in
            guard try await ResourceFinalizerService.reapClaim(A.self, id: artifactID, in: tx) else {
                return false
            }
            // Bindings first, like every other reap.
            try await RoleBindingService.revokeAll(
                nodeType: A.iamNodeType, nodeID: artifactID, on: tx)
            // Before the row goes: the terminal event reads the delete
            // request's scope, and after the delete there is nothing to read.
            try await ResourceFinalizerService.recordDeletionCompleted(artifact, in: tx)
            try await artifact.delete(on: tx)
            try await releaseQuota(artifact, tx)
            return true
        }
    }
}

extension VolumeSnapshot: FinalizableResource {
    static func reap(_ snapshot: VolumeSnapshot, on db: any Database, app: Application) async throws -> Bool {
        try await SnapshotArtifactReap.reap(
            snapshot, on: db, app: app,
            releaseQuota: { snapshot, tx in
                // The overlay was charged to the project's storage pool at
                // admission (STR-181); recount now that it is gone.
                _ = try? await QuotaEnforcementService.storageOverCommit(
                    projectID: snapshot.$project.id, environment: snapshot.environment, on: tx)
            })
    }
}

extension VMSnapshot: FinalizableResource {
    static func reap(_ snapshot: VMSnapshot, on db: any Database, app: Application) async throws -> Bool {
        try await SnapshotArtifactReap.reap(
            snapshot, on: db, app: app,
            releaseQuota: { snapshot, tx in
                // The checkpoint's machine state was charged to the project's
                // storage pool at admission; recount now that it is gone.
                _ = try? await QuotaEnforcementService.storageOverCommit(
                    projectID: snapshot.$project.id, environment: snapshot.environment, on: tx)
            })
    }
}

extension SandboxSnapshot: FinalizableResource {
    static func reap(_ snapshot: SandboxSnapshot, on db: any Database, app: Application) async throws -> Bool {
        try await SnapshotArtifactReap.reap(
            snapshot, on: db, app: app,
            externalCleanup: { snapshot, app in
                // The exported copy goes with the snapshot (issue #428).
                await snapshot.deleteExportedObjects(app: app)
            },
            releaseQuota: { snapshot, tx in
                _ = try? await QuotaEnforcementService.storageOverCommit(
                    projectID: snapshot.$project.id, environment: snapshot.environment, on: tx)
            })
    }
}
