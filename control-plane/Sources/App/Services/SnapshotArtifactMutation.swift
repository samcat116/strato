import Fluent
import Foundation
import StratoShared
import Vapor

/// Lifecycle mutations shared by all three snapshot-artifact families. Applies
/// desired state, records and dispatches through `ResourceMutation`, then lets
/// the agent's report close the loop.
enum SnapshotArtifactMutation {

    /// Appends the capture's attribution event and completes its idempotency
    /// reservation. Call inside the same transaction as the insert, after it:
    /// a mutation must never apply unrecorded, nor be recorded without applying.
    ///
    /// Separate from `ResourceMutation.accept` for the reason every create path
    /// is: the insert owns its transaction (each family's carries different
    /// quota and IAM work), so what is shared is completion and dispatch, not
    /// the transaction. Each caller reserves the key at the start of its own
    /// transaction before quota, uniqueness, or resource effects can run.
    static func recordCapture<A: SnapshotArtifactResource>(
        _ artifact: A,
        actor: MutationActor,
        idempotencyContext: IdempotencyRequestContext? = nil,
        on db: any Database
    ) async throws -> ResourceMutation.Accepted {
        let artifactID = try artifact.requireID()
        let event = try await ResourceEvent.record(
            .create,
            resourceKind: A.operationResourceKind,
            resourceID: artifactID,
            actor: actor,
            on: db)
        let accepted = ResourceMutation.Accepted(
            mutationID: try event.requireID(), targetGeneration: artifact.generation)
        try await IdempotencyService.complete(
            idempotencyContext,
            actor: actor,
            resourceKind: A.operationResourceKind,
            resourceID: artifactID,
            accepted: accepted,
            on: db)
        return accepted
    }

    /// Nudges the agent that should capture the artifact. Runs after the insert
    /// commits, so the sync it triggers can see the row.
    static func dispatchCapture<A: SnapshotArtifactResource>(
        _ artifact: A, app: Application
    ) throws {
        app.resourceMutation.dispatch(
            .create,
            resourceType: A.self,
            resourceID: try artifact.requireID(),
            targetGeneration: artifact.generation,
            agentIDs: artifact.agentId.map { [$0] } ?? [],
            strategy: .stateSync,
            app: app)
    }

    /// Accepts a delete: desired `.absent`, the finalizers its teardown owes,
    /// and the attribution event, in one transaction.
    ///
    /// The row outlives this call and is removed only after the owning agent's
    /// observed report stops listing it, making deletion durable across a
    /// control-plane restart.
    @discardableResult
    static func delete<A: SnapshotArtifactResource>(
        _ artifact: A,
        actor: MutationActor,
        idempotencyContext: IdempotencyRequestContext? = nil,
        idempotencyResponseBody:
            @escaping @Sendable (A, ResourceMutation.Accepted, any Database) async throws -> Data? = {
                _, _, _ in nil
            },
        reassignedAgentId: String? = nil,
        on db: any Database,
        app: Application,
        failureReason: String? = nil
    ) async throws -> ResourceMutation.Accepted {
        let artifactID = try artifact.requireID()

        var effectiveReassignedAgentId = reassignedAgentId
        if effectiveReassignedAgentId == nil,
            let volumeSnapshot = artifact as? VolumeSnapshot,
            let volume = try await Volume.find(volumeSnapshot.$volume.id, on: db),
            try await VolumeService.pool(of: volume, on: db)?.mode == .ceph
        {
            let resolution = try await VolumeService.resolveAgentHolding(volume, on: db)
            guard let selected = resolution.agentID else {
                throw Abort(
                    .conflict,
                    reason: "No configured Ceph client is online to delete this snapshot")
            }
            effectiveReassignedAgentId = selected
            if resolution.changed, let previous = resolution.previousAgentID {
                await app.agentService.syncDesiredState(agentId: previous)
            }
        }

        // An unplaced artifact or one whose agent is unavailable cannot confirm
        // teardown, so clear the agent finalizer rather than make it undeletable.
        let finalReassignedAgentId = effectiveReassignedAgentId
        let effectiveAgentId = finalReassignedAgentId ?? artifact.agentId
        let agentCanConverge = await agentConvergesSnapshots(effectiveAgentId, app: app)
        let strategy: ResourceMutation.Dispatch =
            agentCanConverge
            ? .stateSync
            : .directResolution { @Sendable db in
                if artifact.agentId != nil {
                    app.logger.warning(
                        "Deleting snapshot record without agent teardown; its agent cannot converge snapshots",
                        metadata: [
                            "resourceKind": .string(A.operationResourceKind.rawValue),
                            "resourceId": .string(artifactID.uuidString),
                        ])
                }
                let outcome: ResourceFinalizerService.ClearOutcome
                do {
                    outcome = try await ResourceFinalizerService.clear(
                        .agentAbsent, from: artifact, on: db, app: app)
                } catch {
                    throw ResourceMutation.WorkError(
                        "Failed to delete snapshot record: \(error.localizedDescription)")
                }
                _ = outcome.isRemoved
            }

        let previousArtifactAgentId = artifact.agentId
        let accepted = try await ResourceMutation(
            agentDispatch: app.agentService,
            logger: app.logger,
            idempotencyContext: idempotencyContext
        ).accept(
            .delete,
            on: artifact,
            actor: actor,
            dispatch: strategy,
            on: db,
            app: app,
            beforeResourceLock: { @Sendable transaction in
                guard A.artifactKind == .sandboxSnapshot else { return }
                try await AdvisoryLock.acquireTransactionLock(
                    .object(.sandboxSnapshotLineage, id: artifactID), on: transaction)
                if let blocker = try await SnapshotDeletionGuard.blocker(
                    for: artifact, on: transaction)
                {
                    throw Abort(.conflict, reason: blocker)
                }
            },
            idempotencyResponseBody: idempotencyResponseBody,
            applying: { @Sendable transaction in
                if let failureReason {
                    artifact.lastError = failureReason
                }
                // Stamp before the mark: `stampForDeletion` reads whether the
                // artifact is already terminating, and re-stamping a second DELETE
                // would resurrect tokens their participants have already cleared.
                try await ResourceFinalizerService.stampForDeletion(artifact, on: transaction)
                if let finalReassignedAgentId {
                    // Shared storage can move lifecycle execution without moving
                    // bytes. Persist the move under the artifact row lock.
                    artifact.agentId = finalReassignedAgentId
                }
                artifact.setDesiredStatus(.absent)
            }
        )
        if let previousArtifactAgentId, let finalReassignedAgentId,
            previousArtifactAgentId != finalReassignedAgentId
        {
            await app.agentService.syncDesiredState(agentId: previousArtifactAgentId)
        }
        return accepted
    }

    /// Accepts an export request: the placement fact "this snapshot should also
    /// exist in the control plane's object store".
    ///
    /// Sticky, and generation-bumping. Sticky because a re-export after the
    /// object store lost a copy is the same desire restated, not a new one;
    /// generation-bumping because the agent's staleness guard drops any entry
    /// not newer than the last one it applied, so an export requested without a
    /// bump would be silently ignored.
    ///
    /// The previous completion is deliberately **not** cleared. Clearing it
    /// would make a re-export that died partway — agent crash, expired budget —
    /// permanently demote a snapshot that still has a complete, valid copy, and
    /// the only recovery would be another re-export that could fail the same
    /// way (the issue #428 review's finding, which the per-PUT clear caused).
    /// Every object key is deterministic and the artifacts are immutable once
    /// `.ready`, so the recorded copy keeps describing what is actually stored
    /// no matter how many times the upload is re-driven.
    @discardableResult
    static func requestExport(
        _ snapshot: SandboxSnapshot,
        actor: MutationActor,
        idempotencyContext: IdempotencyRequestContext? = nil,
        on db: any Database,
        app: Application
    ) async throws -> ResourceMutation.Accepted {
        try await ResourceMutation(
            agentDispatch: app.agentService,
            logger: app.logger,
            idempotencyContext: idempotencyContext
        ).accept(
            .snapshotExport, on: snapshot, actor: actor, dispatch: .stateSync, on: db, app: app
        ) { @Sendable _ in
            snapshot.exportDesired = true
        }
    }

    /// Whether `agentId` names an agent that can converge snapshot artifacts:
    /// known and online.
    ///
    /// Read on both the admission and the delete path, for opposite purposes —
    /// admission refuses so nothing is accepted that can never converge, and
    /// delete force-clears so nothing becomes undeletable.
    static func agentConvergesSnapshots(_ agentId: String?, app: Application) async -> Bool {
        guard let agentId, let info = await app.agentService.getAgentInfo(agentId) else { return false }
        return info.status == .online
    }

    /// Preflights capture admission on the agent that would hold the artifact,
    /// translating a refusal into the `409` the API contract uses for "this
    /// cannot be done right now".
    ///
    /// The capability proves a backend that can realize the capture is usable
    /// on that host (the `sandboxCapable` rule from issue #415); without it the
    /// request could only fail as a `degraded` condition long after admission.
    static func requireCaptureCapableAgent(
        _ agentId: String, kind: SnapshotArtifactKind, app: Application
    ) async throws {
        guard let info = await app.agentService.getAgentInfo(agentId) else {
            throw Abort(.conflict, reason: "Agent '\(agentId)' not found")
        }
        guard info.status == .online else {
            throw Abort(.conflict, reason: "Agent '\(agentId)' is offline")
        }
        guard info.supportsSnapshotArtifact(kind) else {
            throw Abort(
                .conflict,
                reason: "Agent '\(agentId)' cannot capture \(kind.rawValue) artifacts "
                    + "(the required snapshot backend is unavailable); "
                    + "place the workload on a host with a capable backend.")
        }
    }
}

/// Why a snapshot artifact cannot be deleted right now, or nil to let it
/// through.
///
/// Shared by the API delete handlers and the retention sweep so an artifact
/// that a fork depends on is refused identically whether a human or a clock
/// asked. The only rule today is the sandbox lineage guard (issue #427); the
/// other two families have no dependents.
enum SnapshotDeletionGuard {
    static func blocker<A: SnapshotArtifactResource>(
        for artifact: A, on db: any Database
    ) async throws -> String? {
        guard A.artifactKind == .sandboxSnapshot, let snapshotID = artifact.id else { return nil }
        guard try await SandboxController.liveForkCount(from: snapshotID, on: db) == 0 else {
            return "Snapshot cannot be deleted while sandboxes forked from it still exist"
        }
        return nil
    }
}
