import Fluent
import Foundation
import StratoShared
import Vapor

/// The lifecycle mutations shared by all three snapshot-artifact families
/// (ADR 0001 stage 8, STR-150).
///
/// Three controllers used to hand-roll the same sequence three times — reserve
/// quota, insert the row, dispatch an RPC, hope, then patch the row from the
/// reply and record a verdict. What is left after the conversion is small
/// enough to be written once: apply the desired state, let `ResourceMutation`
/// record and dispatch it, and let the agent's report close the loop.
enum SnapshotArtifactMutation {

    /// Appends the capture's attribution event. Call inside the same
    /// transaction as the insert, after it: a mutation must never apply
    /// unrecorded, nor be recorded without applying.
    ///
    /// Separate from `ResourceMutation.accept` for the reason every create path
    /// is: the insert owns its transaction (each family's carries different
    /// quota and IAM work), so what is shared is the record and the dispatch,
    /// not the transaction.
    static func recordCapture<A: SnapshotArtifactResource>(
        _ artifact: A, actor: MutationActor, on db: any Database
    ) async throws -> ResourceMutation.Accepted {
        let event = try await ResourceEvent.record(
            .create,
            resourceKind: A.operationResourceKind,
            resourceID: try artifact.requireID(),
            actor: actor,
            on: db)
        return ResourceMutation.Accepted(
            mutationID: try event.requireID(), targetGeneration: artifact.generation)
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
    /// The row outlives this call. It goes only once the owning agent's
    /// observed report stops listing the artifact — which is what makes a
    /// delete durable across a control-plane restart, and what the old path
    /// could not offer at all: an RPC whose reply was lost left a row marked
    /// `.deleting` with nothing left to retry it.
    @discardableResult
    static func delete<A: SnapshotArtifactResource>(
        _ artifact: A,
        actor: MutationActor,
        on db: any Database,
        app: Application
    ) async throws -> ResourceMutation.Accepted {
        let artifactID = try artifact.requireID()

        // Unplaced, or placed on an agent that is offline or too old to speak
        // snapshot sync: nothing will ever confirm the teardown, so clear the
        // agent's finalizer here. A dead or un-upgraded agent must not make its
        // artifacts undeletable — the same rough edge the volume cutover names,
        // and the same answer.
        let agentCanConverge = await agentConvergesSnapshots(artifact.agentId, app: app)
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
                return outcome.isRemoved
            }

        return try await app.resourceMutation.accept(
            .delete, on: artifact, actor: actor, dispatch: strategy, on: db, app: app
        ) { @Sendable transaction in
            // Stamp before the mark: `stampForDeletion` reads whether the
            // artifact is already terminating, and re-stamping a second DELETE
            // would resurrect tokens their participants have already cleared.
            try await ResourceFinalizerService.stampForDeletion(artifact, on: transaction)
            artifact.setDesiredStatus(.absent)
        }
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
        on db: any Database,
        app: Application
    ) async throws -> ResourceMutation.Accepted {
        try await app.resourceMutation.accept(
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
        guard info.capabilities.contains(kind.agentCapability) else {
            throw Abort(
                .conflict,
                reason: "Agent '\(agentId)' cannot capture \(kind.rawValue) artifacts "
                    + "(capability '\(kind.agentCapability)' not advertised); "
                    + "upgrade the agent, or place the workload on a host with a backend that can.")
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
