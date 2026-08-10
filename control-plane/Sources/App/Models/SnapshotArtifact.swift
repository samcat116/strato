import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// A durable, agent-held copy of a point in time: a volume snapshot, a full-VM
/// checkpoint, or a sandbox snapshot (ADR 0001 stage 8, STR-150).
///
/// The three stay three tables — three quota paths, three IAM node types, three
/// public route trees — but everything the *reconciliation loop* does with one
/// is identical, so the assembler, the applier, the retention sweep and the
/// finalizer reap are written once against this protocol instead of three times
/// against three models.
///
/// Every conformer is also a `ConvergingResource` and a `FinalizableResource`,
/// exactly like `VM`, `Sandbox` and `Volume`: mutations answer `202`, clients
/// poll `conditions`, and the row outlives its `DELETE` until an agent confirms
/// the bytes are gone.
protocol SnapshotArtifactResource: ConvergingResource, FinalizableResource {
    /// Which family this table holds. A static because a table holds one.
    static var artifactKind: SnapshotArtifactKind { get }

    /// The Cedar node type authorization is evaluated against.
    static var iamNodeType: IAMNodeType { get }

    /// The volume/VM/sandbox the artifact was captured from. The agent derives
    /// the artifact's location from (parent, snapshot), which is why no path
    /// ever travels on the wire and why a delete works for a capture whose
    /// report was lost.
    var parentID: UUID { get }

    /// The agent holding the bytes.
    var agentId: String? { get set }

    var desiredStatus: DesiredSnapshotStatus { get set }

    /// Settable so the shared SQL writer can refresh the database-assigned
    /// generation and the observed-state applier can advance the observation.
    var generation: Int64 { get set }
    var observedGeneration: Int64 { get set }

    /// When the retention sweep should mark this artifact `.absent`, or nil to
    /// keep it until someone deletes it. See `SnapshotRetentionSweep`.
    var expiresAt: Date? { get set }

    /// Whether the control plane wants an exported copy in object storage.
    /// False for the families that have no off-node representation.
    var wantsExport: Bool { get }

    /// Whether the owning agent's last report said the bytes are here. Derived
    /// from the table's own status enum, whose spelling differs per family;
    /// `applyObservedPresence` is its only writer.
    var isPresentOnAgent: Bool { get }

    /// Whether the copy this artifact's desired state asks for exists too.
    /// Vacuously true for a family with nothing to export.
    var exportSatisfied: Bool { get }

    /// The quota pool this artifact's footprint is charged to, or nil for a
    /// family that draws on none.
    ///
    /// Admission reserves an *estimate* — a checkpoint's memory grant, a
    /// sandbox's guest RAM — and the agent's report replaces it with a figure
    /// that can be much larger (a sandbox snapshot adds vmstate and, without
    /// reflink support, a full rootfs copy). This is what lets the applier
    /// re-check the pool at the moment the real number lands.
    var storageQuotaScope: (projectID: UUID, environment: String)? { get }

    /// Records what the capturing agent measured. Called from the observed-state
    /// applier; does not persist.
    /// - Returns: whether anything changed.
    func applyCapturedFacts(_ facts: ObservedSnapshotFacts) -> Bool

    /// Records that the agent finished streaming the artifact to object
    /// storage. Does not persist. Returns whether anything changed.
    func applyExported(_ exported: Bool) -> Bool

    /// Mirrors the artifact's presence onto the table's own status enum. Does
    /// not persist. Returns whether anything changed.
    func applyObservedPresence(present: Bool, failed: Bool) -> Bool

    /// Rows this agent holds, for sync assembly.
    static func placed(onAgent agentId: String, on db: any Database) async throws -> [Self]

    /// Rows whose retention deadline has passed, for the sweep.
    static func expired(at now: Date, on db: any Database) async throws -> [Self]

    /// Rows whose deletion has been accepted, for the orphaned-terminating
    /// backstop. A protocol requirement for `overdueForConvergence`'s reason:
    /// Fluent filters on the model's own field *projection*, which a protocol
    /// cannot name.
    static func terminating(on db: any Database) async throws -> [Self]
}

extension SnapshotArtifactResource {
    func placementAgentIDs(on db: any Database) async throws -> [String] {
        agentId.map { [$0] } ?? []
    }
    var isTerminating: Bool { desiredStatus == .absent }

    /// Nothing to export, so nothing outstanding. Overridden by the one family
    /// that has an off-node representation.
    var exportSatisfied: Bool { true }

    /// Most families draw on no storage pool; the two that do override this.
    var storageQuotaScope: (projectID: UUID, environment: String)? { nil }

    /// Records a new desired state in memory. The owning mutation service
    /// advances the generation in SQL before saving it.
    func setDesiredStatus(_ newDesired: DesiredSnapshotStatus) {
        desiredStatus = newDesired
    }

    /// Everything the desired state asks for exists on the agent.
    ///
    /// The presence clause is the artifact's analogue of
    /// `DesiredVMStatus.isSatisfied(by:)`, and it is what the generation clause
    /// alone cannot say: an artifact whose files were removed out of band would
    /// otherwise stay "converged", because nothing bumps a generation to notice.
    ///
    /// `exportSatisfied` is here because a bare export request would otherwise
    /// read satisfied the moment the agent's generation caught up, while the
    /// client was still correctly waiting for the copy it asked for.
    var desiredSatisfied: Bool {
        desiredStatus == .present && isPresentOnAgent && exportSatisfied
    }

    /// The failure resolution for an artifact is deliberately *nothing*.
    ///
    /// A volume reverts a failed attachment because an unachieved attach
    /// replays destructively on every later sync. An artifact has no equivalent:
    /// its only desired states are "exists" and "gone", a failed capture leaves
    /// nothing to undo, and a stuck delete keeps its `.absent` for the reason a
    /// VM's does — reverting it would resurrect something the user deleted (and
    /// the retention sweep would only ask again).
    @discardableResult
    func resolveForStuckOperation(mutation: VMOperationKind, telemetryReason: String) -> Bool {
        false
    }
}

/// Shared retention policy for snapshot artifacts.
///
/// This is the `Job.ttlSecondsAfterFinished` answer ADR 0001 asks stage 8 to
/// supply. Fire-and-forget RPCs never raised the question: nothing on the agent
/// outlived the request. A durable artifact object does, and without an expiry
/// story every checkpoint a CI pipeline takes lives until a human deletes it.
///
/// The policy is deliberately **time-based only**. Count-based retention
/// ("keep the last N per parent") is the other obvious shape and is *not*
/// implemented here, because it needs a per-parent ordering that a delete has
/// to re-evaluate transactionally, and because the interesting failure — a
/// snapshot deleted out from under a fork that depends on it — is one the
/// lineage guard already refuses. Time is enough to bound the leak; count can
/// be layered on later without changing the artifact model.
enum SnapshotRetention {
    /// Environment key for the fleet-wide default TTL, in seconds. Unset — the
    /// default — means artifacts are kept until deleted, which is the behavior
    /// every snapshot taken before this change had, so an upgrade changes
    /// nothing until an operator opts in.
    static let defaultTTLEnvironmentKey = "SNAPSHOT_DEFAULT_TTL_SECONDS"

    /// Upper bound on a caller-supplied TTL: ten years. Generous enough never
    /// to bind in practice, and low enough that a bad `ttlSeconds` cannot
    /// overflow the date arithmetic.
    static let maxTTLSeconds: Int = 10 * 365 * 24 * 3600

    /// The fleet default, or nil when none is configured.
    static var defaultTTLSeconds: Int? {
        guard let raw = Environment.get(defaultTTLEnvironmentKey), let seconds = Int(raw), seconds > 0
        else { return nil }
        return min(seconds, maxTTLSeconds)
    }

    /// Resolves a create request's `ttlSeconds` into an absolute expiry.
    ///
    /// Absolute, not relative, for the reason every other deadline in this
    /// codebase is: a relative TTL re-evaluated against "now" on each pass
    /// drifts with every restart, and an artifact whose expiry keeps moving is
    /// one that never expires.
    ///
    /// - Parameter requested: the caller's `ttlSeconds`. `nil` falls back to the
    ///   fleet default; `0` is an explicit "keep forever" that overrides it,
    ///   because an operator who set a fleet default still needs a way to keep
    ///   one artifact.
    static func expiry(requested: Int?, from now: Date = Date()) throws -> Date? {
        let seconds: Int?
        if let requested {
            guard requested >= 0 else {
                throw Abort(.badRequest, reason: "ttlSeconds must not be negative")
            }
            guard requested <= maxTTLSeconds else {
                throw Abort(
                    .badRequest,
                    reason: "ttlSeconds must not exceed \(maxTTLSeconds) (ten years)")
            }
            seconds = requested == 0 ? nil : requested
        } else {
            seconds = defaultTTLSeconds
        }
        guard let seconds else { return nil }
        return now.addingTimeInterval(TimeInterval(seconds))
    }
}
