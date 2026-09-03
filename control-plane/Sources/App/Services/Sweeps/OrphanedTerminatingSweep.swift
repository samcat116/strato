import Foundation
import Fluent
import Metrics
import SQLKit
import StratoShared
import Vapor

extension AgentMaintenanceLoop {
    static let orphanedTerminatingBudgetSeconds: TimeInterval = 60

    /// Reaps workloads whose finalizers all cleared but whose row survived
    /// (STR-144). Clearing a token and removing the row are two commits; a
    /// crash between them leaves a terminating row with an empty list, which
    /// still holds quota and still appears in listings.
    ///
    /// Participants with a repeating trigger heal themselves — every
    /// observed-state report re-drives `agent.absent`. This is the backstop for
    /// the ones that do not: the offline/unplaced direct path is a one-shot
    /// background task, and the sandbox expiry sweep's deletions are unattended,
    /// so without this a drained replica could strand a row with nobody left to
    /// notice. It is also what lets a future participant be added without each
    /// one inventing its own retry.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepOrphanedTerminatingResources() async {
        guard !isShutDown, !app.didShutdown else { return }
        // Cluster-singleton like the other sweeps: the reap claim would make
        // concurrent passes safe anyway, but there is no reason to pay for
        // every replica scanning.
        guard await app.coordination.acquireSweepLock("orphaned_terminating") else { return }

        let db = app.db
        let cutoff = Date().addingTimeInterval(-Self.orphanedTerminatingBudgetSeconds)

        do {
            // `finalizers` is filtered in Swift, not SQL: Fluent cannot express
            // array cardinality, and the scanned set is only workloads that
            // have been terminating for at least a minute — normally empty.
            let vms = try await VM.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(vms.filter { $0.finalizers.isEmpty }, kind: "VM", on: db)

            let sandboxes = try await Sandbox.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(
                sandboxes.filter { $0.finalizers.isEmpty }, kind: "sandbox", on: db)

            let volumes = try await Volume.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(
                volumes.filter { $0.finalizers.isEmpty }, kind: "volume", on: db)

            // Snapshot artifacts (STR-150). Their `agent.absent` trigger is the
            // same repeating observed-state report, but the retention sweep's
            // deletions are unattended in exactly the way the sandbox expiry
            // sweep's are, so they need the same backstop.
            //
            // No age cutoff here, unlike the three above, and it is not an
            // oversight: `finalizers.isEmpty` on a terminating row already
            // means nobody owes cleanup — either the token cleared, or none was
            // stamped because the artifact never reached an agent. The cutoff
            // exists to keep the workload scan cheap on a large table, and the
            // terminating set here is normally empty.
            try await reapOrphanedTerminatingSnapshots(
                VolumeSnapshot.self, kind: "volume snapshot", on: db)
            try await reapOrphanedTerminatingSnapshots(
                VMSnapshot.self, kind: "checkpoint", on: db)
            try await reapOrphanedTerminatingSnapshots(
                SandboxSnapshot.self, kind: "sandbox snapshot", on: db)
        } catch {
            app.logger.error("Orphaned-terminating sweep failed: \(error)")
        }
    }

    /// The snapshot-artifact half of the orphan sweep. Separate from the
    /// workload half only because `desired_status` is a different enum type per
    /// family, which Fluent's field projection cannot be abstracted over.
    func reapOrphanedTerminatingSnapshots<A: SnapshotArtifactResource>(
        _ type: A.Type, kind: String, on db: any Database
    ) async throws {
        let terminating = try await A.terminating(on: db).filter { $0.finalizers.isEmpty }
        await reapOrphanedTerminating(terminating, kind: kind, on: db)
    }

    /// Drives one kind's orphans through the ordinary clear path — clearing an
    /// already-cleared token on an empty list reaps — so the sweep shares the
    /// reap claim and per-kind teardown instead of re-spelling either.
    func reapOrphanedTerminating<R: FinalizableResource>(
        _ resources: [R], kind: String, on db: any Database
    ) async {
        for resource in resources {
            guard let id = resource.id else { continue }
            do {
                let outcome = try await ResourceFinalizerService.clear(
                    .agentAbsent, from: resource, on: db, app: app)
                guard case .reaped = outcome else { continue }
                app.logger.warning(
                    "Reaped a terminating \(kind) whose row outlived its last finalizer",
                    metadata: ["resourceId": .string(id.uuidString)])
            } catch {
                app.logger.error(
                    "Failed to reap orphaned terminating \(kind): \(error)",
                    metadata: ["resourceId": .string(id.uuidString)])
            }
        }
    }

    // The transitional-status backstop — VMs and sandboxes sitting in
    // `.starting`/`.stopping` past 120s with no pending operation, marked
    // `.error` — went with the operations table (STR-152). It predated
    // generations: with no `observedGeneration` to compare against, "stuck" had
    // to be inferred from a status and a clock, and the pending-operation query
    // existed only to stop the two backstops fighting. `sweepStuckConvergence`
    // says the same thing from the deadline every accepted mutation stamps, and
    // resolves through the same per-kind `resolveForStuckOperation`.

}
