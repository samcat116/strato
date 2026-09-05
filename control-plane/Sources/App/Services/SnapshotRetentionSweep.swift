import Fluent
import Foundation
import StratoShared
import Vapor

/// Deletes snapshot artifacts past their retention deadline (ADR 0001 stage 8,
/// STR-150).
///
/// This is the half of the conversion that had no counterpart before it. An
/// imperative `vm_checkpoint` left nothing behind that the control plane owned
/// — the agent wrote some bytes and the RPC ended. A durable artifact *object*
/// is a row with an owner, a footprint charged to a quota pool, and no natural
/// end, which is exactly the problem Kubernetes answered for `Job` with
/// `ttlSecondsAfterFinished`. The ADR names that lesson as a cost of this stage;
/// this is the payment.
///
/// The deletion goes down the same path an operator's `DELETE` takes — desired
/// `.absent`, a finalizer, an attribution event, then agent convergence — for
/// the reason `expireSandbox` shares its path: quota release, the audit trail
/// and the tombstone dance all come for free, and the `system` actor on the
/// event makes the unattended deletion attributable to something.
///
/// Cluster-singleton via the sweep lock, and level-triggered like every other
/// sweep: a skipped or crashed pass costs latency, never correctness, because
/// the next tick recomputes the deadline from the row.
enum SnapshotRetentionSweep {

    static func run(app: Application, at instant: ClusterInstant) async {
        guard instant.permitsDestructiveSweeps else {
            app.logger.error(
                "Skipping snapshot retention because this replica's clock is too far from PostgreSQL",
                metadata: [
                    "offsetSeconds": .stringConvertible(instant.localClockOffsetSeconds),
                    "limitSeconds": .stringConvertible(
                        ClusterClock.destructiveSweepOffsetLimitSeconds),
                ])
            return
        }
        guard await app.coordination.acquireSweepLock("snapshot_retention") else {
            app.logger.debug("Skipping snapshot retention sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        do {
            try await expire(VolumeSnapshot.self, at: instant, on: db, app: app)
            try await expire(VMSnapshot.self, at: instant, on: db, app: app)
            try await expire(SandboxSnapshot.self, at: instant, on: db, app: app)
        } catch {
            app.logger.error("Snapshot retention sweep failed: \(error)")
        }
    }

    private static func expire<A: SnapshotArtifactResource>(
        _ type: A.Type, at instant: ClusterInstant, on db: any Database, app: Application
    ) async throws {
        for artifact in try await A.expired(at: instant, on: db) {
            guard let artifactID = artifact.id else { continue }

            // Deleting a snapshot a live fork depends on would break the fork,
            // so retention is refused for exactly the cases an operator's
            // `DELETE` is refused for. Logged rather than swallowed: an
            // artifact that cannot expire is something an operator needs to
            // know about, and the sweep says so again on the next pass rather
            // than silently keeping it forever.
            if let blocker = try await SnapshotDeletionGuard.blocker(for: artifact, on: db) {
                app.logger.warning(
                    "Snapshot artifact is past its retention deadline but cannot be deleted yet",
                    metadata: [
                        "resourceKind": .string(A.operationResourceKind.rawValue),
                        "resourceId": .string(artifactID.uuidString),
                        "reason": .string(blocker),
                    ])
                continue
            }

            do {
                _ = try await SnapshotArtifactMutation.delete(
                    artifact, actor: .system, on: db, app: app)
                app.logger.notice(
                    "Deleting a snapshot artifact past its retention deadline",
                    metadata: [
                        "resourceKind": .string(A.operationResourceKind.rawValue),
                        "resourceId": .string(artifactID.uuidString),
                    ])
            } catch {
                app.logger.error(
                    "Failed to expire a snapshot artifact: \(error)",
                    metadata: ["resourceId": .string(artifactID.uuidString)])
            }
        }
    }
}
