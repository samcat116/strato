import Foundation
import Fluent
import Metrics
import SQLKit
import StratoShared
import Vapor

extension AgentMaintenanceLoop {
    func sweepStrandedVolumeAttachments(
        currentInstant: @escaping @Sendable (any Database) async throws -> ClusterInstant = {
            try await ClusterClock.read(on: $0)
        }
    ) async {
        // Never touch app.db (a fatal error, not a throw, after core
        // teardown) once shutdown has begun — this was the crashing frame of
        // the recurring "Core not configured" CI crash.
        guard !isShutDown, !app.didShutdown else { return }
        // Cluster-singleton: the repair is idempotent, but each pass bumps a
        // generation, so two replicas racing would churn the agent's sync for
        // nothing.
        guard await app.coordination.acquireSweepLock("stranded_attachments") else {
            app.logger.debug("Skipping stranded-attachment sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db

        do {
            // This mirrors the schema constraint column for column: the fields
            // describe one state, so they must agree.
            let strandedVolumes = try await Volume.query(on: db)
                .filter(\.$vm.$id == nil)
                .group(.or) { unresolved in
                    unresolved.filter(\.$deviceName != nil)
                    unresolved.filter(\.$bootOrder != nil)
                    unresolved.filter(\.$attachedAgentId != nil)
                    unresolved.filter(\.$readonly == true)
                }
                .all()

            for volume in strandedVolumes {
                guard let volumeID = volume.id else { continue }
                let repaired = try await db.transaction { tx -> Bool in
                    guard try await volume.lockAndRefresh(on: tx) else { return false }
                    guard volume.$vm.id == nil,
                        volume.deviceName != nil || volume.bootOrder != nil
                            || volume.attachedAgentId != nil || volume.readonly
                    else { return false }
                    let expectedGeneration = volume.generation
                    // The row lock may wait behind a live mutation. Sample
                    // after it so that wait cannot consume the repair's new
                    // detach convergence budget.
                    let repairInstant = try await currentInstant(tx)
                    VolumeAttachmentService.clearAttachment(volume, at: repairInstant)
                    guard
                        case .applied = try await volume.advanceDesiredStateGeneration(
                            expectedGeneration: expectedGeneration, on: tx)
                    else { return false }
                    try await volume.save(on: tx)
                    return true
                }
                guard repaired else { continue }

                app.logger.warning(
                    "Volume left attachment fields set with no VM; released",
                    metadata: [
                        "volumeId": .string(volumeID.uuidString),
                        "generation": .string("\(volume.generation)"),
                    ])
            }
        } catch {
            app.logger.error("Stranded-attachment sweep failed: \(error)")
        }
    }

    /// How long a terminating workload may sit with every finalizer cleared
    /// before this sweep reaps it. Generous on purpose: the delete path's own
    /// reap follows its finalizer clear by milliseconds, so anything this old
    /// lost the process that owed it (crash, drain, OOM kill) rather than
    /// being slow.
}
