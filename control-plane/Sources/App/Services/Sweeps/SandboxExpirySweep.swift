import Foundation
import Fluent
import Metrics
import SQLKit
import StratoShared
import Vapor

extension AgentMaintenanceLoop {
    // MARK: - Sandbox expiry (issue #424)

    /// How long a terminal sandbox's record is kept by default.
    static let defaultSandboxRetentionHours = 24

    /// The retention window for terminal sandboxes, or nil when retention is
    /// off. `SANDBOX_RETENTION_HOURS` overrides the default; a non-positive
    /// value keeps terminal records — and the quota they still hold — forever,
    /// which is a deliberate opt-in, not the default.
    static func sandboxRetentionHours(configuration: ControlPlaneConfiguration) -> Int? {
        let raw = configuration.int(.sandboxRetentionHours)
        return raw > 0 ? raw : nil
    }

    /// Why the expiry sweep is deleting a sandbox. Both reasons end in the
    /// same deletion; they differ only in what started the clock.
    enum SandboxExpiryReason {
        /// The lifetime budget ran out (`ttl_seconds` from `createdAt`).
        case ttl(seconds: Int)
        /// A terminal sandbox outlived the retention window for its record.
        case retention(hours: Int)

        var description: String {
            switch self {
            case .ttl(let seconds):
                return "TTL of \(seconds)s elapsed"
            case .retention(let hours):
                return "terminal record retained for \(hours)h"
            }
        }
    }

    /// Deletes sandboxes that have outlived either clock (issue #424):
    ///
    /// - **TTL** — `ttl_seconds` past `createdAt`. Sandboxes are ephemeral;
    ///   this is what makes the stored budget real.
    /// - **Retention** — an exited or errored sandbox keeps its terminal
    ///   record (status and exit code) for `SANDBOX_RETENTION_HOURS` so the
    ///   result stays inspectable, then the row goes. Errored sandboxes are
    ///   included because they are terminal too and would otherwise hold their
    ///   quota indefinitely.
    ///
    /// Cluster-singleton via the sweep lock, and level-triggered like every
    /// other sweep: a skipped or crashed pass costs latency, never
    /// correctness, because the next tick recomputes both clocks from scratch.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepExpiredSandboxes(at instant: ClusterInstant) async {
        // Never touch app.db once shutdown has begun — after core teardown
        // that is a process-killing fatal error, not a throw.
        guard !isShutDown, !app.didShutdown else { return }
        guard instant.permitsDestructiveSweeps else {
            app.logger.error(
                "Skipping sandbox expiry because this replica's clock is too far from PostgreSQL",
                metadata: [
                    "offsetSeconds": .stringConvertible(instant.localClockOffsetSeconds),
                    "limitSeconds": .stringConvertible(
                        ClusterClock.destructiveSweepOffsetLimitSeconds),
                ])
            return
        }
        guard await app.coordination.acquireSweepLock("sandbox_expiry") else {
            app.logger.debug("Skipping sandbox expiry sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = instant.date

        do {
            var expiring: [(sandbox: Sandbox, reason: SandboxExpiryReason)] = []

            // A sandbox already heading for `.absent` is being deleted by
            // something else; leave it to that operation.
            let budgeted = try await Sandbox.query(on: db)
                .filter(\.$desiredStatus != .absent)
                .filter(\.$ttlSeconds != nil)
                .all()
            for sandbox in budgeted where sandbox.isExpired(at: instant) {
                expiring.append((sandbox, .ttl(seconds: sandbox.ttlSeconds ?? 0)))
            }

            if let hours = Self.sandboxRetentionHours(configuration: app.controlPlaneConfiguration) {
                let window = TimeInterval(hours) * 3600
                // A sandbox already expiring on TTL must not be queued twice:
                // the second `begin` would collide with the first's pending
                // operation and log a spurious conflict.
                let alreadyExpiring = Set(expiring.compactMap(\.sandbox.id))
                // Terminal sandboxes are what accumulates, so the retention
                // window is a SQL predicate rather than a Swift filter over
                // every terminal row ever kept.
                let expiredBefore = now.addingTimeInterval(-window)
                let terminal = try await Sandbox.query(on: db)
                    .filter(\.$desiredStatus != .absent)
                    .filter(\.$status ~~ [.exited, .error])
                    .filterAged(before: expiredBefore, by: \.$statusChangedAt, fallingBackTo: \.$updatedAt)
                    .all()

                for sandbox in terminal {
                    guard let sandboxID = sandbox.id, !alreadyExpiring.contains(sandboxID) else { continue }
                    expiring.append((sandbox, .retention(hours: hours)))
                }
            }

            for (sandbox, reason) in expiring {
                await expireSandbox(sandbox, reason: reason, on: db)
            }
        } catch {
            app.logger.error("Sandbox expiry sweep failed: \(error)")
        }
    }

    /// Deletes one expired sandbox down the same path as `DELETE
    /// /api/sandboxes/:id`: desired `.absent` plus its attribution event in one
    /// transaction, then either agent teardown (the row goes once a report
    /// confirms absence) or — with no agent to converge on — a direct record
    /// delete. Sharing the path is the point: quota release, reservation
    /// release, and the audit trail all come for free, and the `system` actor
    /// on the event makes the unattended deletion attributable.
    func expireSandbox(_ sandbox: Sandbox, reason: SandboxExpiryReason, on db: Database) async {
        guard let sandboxID = sandbox.id else { return }

        var onlineAgentID: String?
        if let agentId = sandbox.hypervisorId,
            let agentUUID = UUID(uuidString: agentId),
            let agent = try? await Agent.find(agentUUID, on: app.db),
            agent.status == .online
        {
            onlineAgentID = agentId
        }

        // With no agent to converge on, the expiry owns the teardown itself;
        // otherwise `.stateSync` nudges the agent holding it.
        let strategy: ResourceMutation.Dispatch =
            onlineAgentID == nil
            ? .directResolution { @Sendable [app = self.app] db in
                _ = try await SandboxController.performDirectDeletion(sandbox: sandbox, on: db, app: app)
            }
            : .stateSync

        do {
            let accepted = try await app.resourceMutation.accept(
                .delete, on: sandbox, actor: .system, dispatch: strategy, on: db, app: app
            ) { db in
                try await SandboxController.requireSnapshotLineageDeletable(
                    for: sandboxID, on: db)
                // Same stamp-then-mark order as the user-initiated delete: an
                // expiry that races a user's DELETE must not re-stamp a token
                // its participant already cleared.
                try await ResourceFinalizerService.stampForDeletion(sandbox, on: db)
                sandbox.setDesiredStatus(.absent)
            }

            app.logger.info(
                "Expiring sandbox",
                metadata: [
                    "strato.sandbox.id": .string(sandboxID.uuidString),
                    "reason": .string(reason.description),
                    "strato.operation.id": .string(accepted.mutationID.uuidString),
                ])
        } catch {
            // The "operation already pending" `409` that used to defer an
            // expiry racing a user action is gone with the operation row
            // (STR-147), and is not missed: marking `.absent` is idempotent and
            // level-triggered, so an expiry landing on top of a user's own
            // delete converges on the same thing. What remains here is a real
            // failure — a snapshot lineage that refuses deletion, or a write
            // that did not commit — and the next tick recomputes both clocks,
            // so an expired sandbox is deferred rather than dropped.
            app.logger.debug(
                "Skipping sandbox expiry: \(error)",
                metadata: ["strato.sandbox.id": .string(sandboxID.uuidString)])
        }
    }

}
