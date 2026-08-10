import Fluent
import Foundation
import SQLKit
import Vapor

/// What a resource quota measures: which projects' workloads count against it,
/// and which environment (if any) narrows them.
///
/// The project set is kept as the *shape* of the scope rather than as a list of
/// ids, and is turned into a SQL predicate at measurement time. A folder or
/// organization scope therefore costs nothing to resolve beyond the folder's
/// own row: the recursive walk this replaced spent 2 queries per folder and 1
/// per project building that list, three times per quota per create — under the
/// org-wide advisory lock (issue #692).
struct QuotaScope: Sendable {
    /// The projects a quota measures.
    enum Projects: Sendable {
        case project(UUID)
        /// Every project in the folder with this materialized `path` *and in
        /// its descendants*, so a quota on an intermediate folder measures
        /// every workload beneath it (issue #645).
        case folderSubtree(path: String)
        case organization(UUID)
        /// Nothing is in scope: the quota names no entity, or the entity it
        /// names was deleted concurrently.
        case none
    }

    let projects: Projects
    /// Nil for a quota that applies to every environment.
    let environment: String?
}

/// Byte-accurate usage measured over a ``QuotaScope``.
///
/// Bytes, not the GB doubles of `QuotaUsage`: a quota's reservation counters
/// are raw `Int64` byte fields, and resyncing them from a lossy projection
/// would let reserved and actual figures drift apart.
struct QuotaMeasuredUsage: Sendable {
    var vcpus: Int
    var memoryBytes: Int64
    /// Everything in the shared storage pool: VM disks, sandbox-snapshot
    /// artifacts and VM checkpoints (issues #426, #564), and volumes and their
    /// snapshots (STR-181). Sandboxes themselves reserve no storage; their
    /// checkpoints persist real bytes in the same pool.
    var storageBytes: Int64
    var vmCount: Int
    var sandboxCount: Int
    var volumeCount: Int

    static let none = QuotaMeasuredUsage(
        vcpus: 0, memoryBytes: 0, storageBytes: 0, vmCount: 0, sandboxCount: 0, volumeCount: 0)

    /// The API-facing projection.
    var asQuotaUsage: QuotaUsage {
        QuotaUsage(
            vcpus: vcpus,
            memoryGB: memoryBytes.bytesToGB,
            storageGB: storageBytes.bytesToGB,
            vms: vmCount,
            sandboxes: sandboxCount,
            volumes: volumeCount,
            networks: 0  // TODO: Implement network counting when networking is added
        )
    }
}

/// What a scope's volumes and volume snapshots add to it (STR-181): the bytes
/// they occupy in the shared storage pool, and how many volumes there are for
/// the optional count limit.
struct QuotaVolumeTotals: Sendable {
    let storageBytes: Int64
    let volumeCount: Int

    static let none = QuotaVolumeTotals(storageBytes: 0, volumeCount: 0)
}

/// A breakdown of a scope's VMs by environment and by status, for the quota
/// usage endpoint.
struct QuotaVMBreakdown: Sendable {
    var byEnvironment: [String: Int] = [:]
    var byStatus: [String: Int] = [:]
}

/// Measures what a resource quota is using, without hydrating the workloads it
/// measures.
///
/// Every figure is a SQL `SUM`/`COUNT` over the workload tables — three
/// round-trips for a full measurement regardless of how many folders, projects
/// or VMs the scope spans. The previous implementation loaded every VM and
/// sandbox row in scope and reduced in Swift, on every VM/sandbox create
/// (issue #692).
struct QuotaUsageAggregator {

    /// Resolves what `quota` measures. Costs one indexed row lookup for a
    /// folder-scoped quota (to read its materialized path) and nothing at all
    /// for the other scopes.
    static func scope(of quota: ResourceQuota, on db: Database) async throws -> QuotaScope {
        QuotaScope(
            projects: try await projects(of: quota, on: db),
            environment: quota.environment
        )
    }

    private static func projects(of quota: ResourceQuota, on db: Database) async throws -> QuotaScope.Projects {
        if let projectID = quota.$project.id {
            return .project(projectID)
        }
        if let folderID = quota.$organizationalUnit.id {
            guard let folder = try await OrganizationalUnit.find(folderID, on: db) else { return .none }
            return .folderSubtree(path: folder.path)
        }
        if let organizationID = quota.$organization.id {
            return .organization(organizationID)
        }
        return .none
    }

    /// Convenience for callers that hold a quota rather than a resolved scope.
    static func measure(quota: ResourceQuota, on db: Database) async throws -> QuotaMeasuredUsage {
        try await measure(try await scope(of: quota, on: db), on: db)
    }

    /// Measures `scope` with one aggregate per workload table: VMs, sandboxes,
    /// the snapshot artifacts that also occupy the storage pool, and volumes
    /// with their own snapshots (STR-181, which shares a single round trip).
    static func measure(_ scope: QuotaScope, on db: Database) async throws -> QuotaMeasuredUsage {
        if case .none = scope.projects { return .none }
        let sql = try requireSQL(db)
        let inScope = scope.predicate

        struct VMTotals: Decodable {
            let vcpus: Int64
            let memory_bytes: Int64
            let disk_bytes: Int64
            let vm_count: Int64
        }
        let vms = try await sql.raw(
            """
            SELECT COALESCE(SUM(cpu), 0)::bigint AS vcpus,
                   COALESCE(SUM(memory), 0)::bigint AS memory_bytes,
                   COALESCE(SUM(disk), 0)::bigint AS disk_bytes,
                   COUNT(*)::bigint AS vm_count
            FROM vms
            WHERE \(inScope)
            """
        ).first(decoding: VMTotals.self)

        struct SandboxTotals: Decodable {
            let vcpus: Int64
            let memory_bytes: Int64
            let sandbox_count: Int64
        }
        let sandboxes = try await sql.raw(
            """
            SELECT COALESCE(SUM(vcpus), 0)::bigint AS vcpus,
                   COALESCE(SUM(memory), 0)::bigint AS memory_bytes,
                   COUNT(*)::bigint AS sandbox_count
            FROM sandboxes
            WHERE \(inScope)
            """
        ).first(decoding: SandboxTotals.self)

        let snapshotStorage = try await snapshotStorageBytes(in: scope, on: db)
        let checkpointStorage = try await vmCheckpointStorageBytes(in: scope, on: db)
        let volumes = try await volumeTotals(in: scope, on: db)

        return QuotaMeasuredUsage(
            vcpus: Int(vms?.vcpus ?? 0) + Int(sandboxes?.vcpus ?? 0),
            memoryBytes: (vms?.memory_bytes ?? 0) + (sandboxes?.memory_bytes ?? 0),
            storageBytes: (vms?.disk_bytes ?? 0) + snapshotStorage + checkpointStorage
                + volumes.storageBytes,
            vmCount: Int(vms?.vm_count ?? 0),
            sandboxCount: Int(sandboxes?.sandbox_count ?? 0),
            volumeCount: volumes.volumeCount
        )
    }

    /// Total sandbox-snapshot storage in scope (issue #426): the sum of `size`
    /// over non-error snapshots. `creating` rows carry the admission estimate
    /// (the sandbox's guest memory) until the agent reports actual sizes;
    /// `error` rows are excluded — a failed checkpoint removes its partial
    /// artifacts.
    ///
    /// An exported snapshot (issue #428) exists twice — on its agent and in
    /// control-plane object storage — and both copies draw from this pool, so
    /// the recorded per-artifact sizes are added on top. Counting the
    /// *recorded* bytes rather than a flag makes the figure track a partial
    /// export as its artifacts land, and fall away with the row on delete.
    static func snapshotStorageBytes(in scope: QuotaScope, on db: Database) async throws -> Int64 {
        if case .none = scope.projects { return 0 }
        let sql = try requireSQL(db)

        // `unnest` over the exported-artifact array yields no rows for a NULL
        // array, so a never-exported snapshot contributes its `size` alone.
        struct StorageTotal: Decodable {
            let storage_bytes: Int64
        }
        let total = try await sql.raw(
            """
            SELECT COALESCE(SUM(size), 0)::bigint
                 + COALESCE(SUM((
                       SELECT COALESCE(SUM((artifact->>'sizeBytes')::bigint), 0)
                       FROM unnest(exported_artifacts) AS artifact
                   )), 0)::bigint AS storage_bytes
            FROM sandbox_snapshots
            WHERE \(scope.predicate)
              AND status::text <> \(bind: SandboxSnapshotStatus.error.rawValue)
            """
        ).first(decoding: StorageTotal.self)
        return total?.storage_bytes ?? 0
    }

    /// Total full-VM checkpoint storage in scope (issue #564): the sum of
    /// `size` over non-error checkpoints, where `size` is the machine state
    /// (RAM + devices) each one added.
    ///
    /// Only the machine state is counted, deliberately. A checkpoint is an
    /// *internal* qcow2 snapshot living inside disks whose provisioned size
    /// this quota already charges under the VM — adding the disks again would
    /// double-count them. `creating` rows carry the admission estimate (the
    /// VM's memory grant, which bounds the machine state) until the agent
    /// reports the real figure; `error` rows are excluded, since a failed
    /// checkpoint's partial state is deleted.
    static func vmCheckpointStorageBytes(in scope: QuotaScope, on db: Database) async throws -> Int64 {
        if case .none = scope.projects { return 0 }
        let sql = try requireSQL(db)

        struct StorageTotal: Decodable {
            let storage_bytes: Int64
        }
        let total = try await sql.raw(
            """
            SELECT COALESCE(SUM(size), 0)::bigint AS storage_bytes
            FROM vm_snapshots
            WHERE \(scope.predicate)
              AND status::text <> \(bind: VMSnapshotStatus.error.rawValue)
            """
        ).first(decoding: StorageTotal.self)
        return total?.storage_bytes ?? 0
    }

    /// What volumes and their snapshots occupy in scope, and how many volumes
    /// there are (STR-181).
    ///
    /// Both tables in one round trip, and both figures from one statement,
    /// because this runs under the per-quota advisory lock on every workload
    /// create: a query not issued here is lock time every other create in the
    /// organization does not wait for (issue #692).
    ///
    /// Three things about what is counted:
    ///
    /// * **A volume is charged its desired size**, not raw
    ///   `observed_size_bytes`. Normally that is the size it asked for. A
    ///   source-backed attachment first admits any larger materialized virtual
    ///   size and raises the desired value to match. The other mismatch is an
    ///   outstanding grow — STR-199's refused-because-the-guest-is-running case
    ///   — and that grow is blocked, not withdrawn: it lands the moment the
    ///   guest stops, with no admission point in between. Charging the smaller
    ///   observed size would make it free until then.
    /// * **A volume that *is* a VM's boot disk is deduplicated**, because
    ///   `SUM(vms.disk)` already charges the VM's original size. Only the rows
    ///   `MigrateVMDisksToVolumes` backfilled can match — nothing since inserts a
    ///   volume for a VM's boot disk — but for a deployment upgraded from before
    ///   volumes existed, counting both would double every legacy VM's disk and
    ///   the symptom would be creates refused against a quota nobody changed.
    ///   Matching by path rather than the mutable `vm_id` keeps the deduction
    ///   after that compatibility volume is detached. Only the overlapping
    ///   bytes are deducted: a later volume resize is still charged above the
    ///   VM row's original `disk` value. The compatibility row stays out of
    ///   `volume_count`, since it is still the VM's one boot disk rather than a
    ///   separately created volume. This is the agent's own identity rule:
    ///   `LibvirtService.resolveDisks` dedupes the pair by path into one disk.
    /// * **A snapshot keeps the parent volume's whole size reserved.** Its live
    ///   overlay footprint is exposed separately for observability and billing,
    ///   but it cannot replace the reservation: the overlay can grow toward the
    ///   parent's size with no later API call at which to admit that growth. If
    ///   a small first report released the bound, callers could admit several
    ///   snapshots sequentially and oversubscribe the pool as they diverged.
    ///   `error` rows are excluded, matching the other two artifact families.
    ///
    /// No status filter on `volumes`, deliberately: a row existing means the
    /// bytes are either asked for or not yet reclaimed. A volume being deleted
    /// keeps its row precisely until the agent confirms the data is gone.
    static func volumeTotals(in scope: QuotaScope, on db: Database) async throws -> QuotaVolumeTotals {
        if case .none = scope.projects { return .none }
        let sql = try requireSQL(db)
        let inScope = scope.predicate

        struct Totals: Decodable {
            let volume_bytes: Int64
            let volume_count: Int64
            let snapshot_bytes: Int64
        }
        let totals = try await sql.raw(
            """
            SELECT
                (SELECT COALESCE(SUM(\(Self.volumeReservedBytes)), 0)::bigint FROM volumes
                 WHERE \(inScope)) AS volume_bytes,
                (SELECT COUNT(*)::bigint FROM volumes
                 WHERE \(inScope) AND \(Self.volumeIsNotAVMBootDisk)) AS volume_count,
                (SELECT COALESCE(SUM(size), 0)::bigint
                 FROM volume_snapshots
                 WHERE \(inScope) AND status::text <> \(bind: SnapshotStatus.error.rawValue)
                ) AS snapshot_bytes
            """
        ).first(decoding: Totals.self)

        return QuotaVolumeTotals(
            storageBytes: (totals?.volume_bytes ?? 0) + (totals?.snapshot_bytes ?? 0),
            volumeCount: Int(totals?.volume_count ?? 0))
    }

    /// Bytes this volume adds after deducting any VM-disk reservation for the
    /// same physical path. `MAX` keeps a malformed duplicate VM path from
    /// multiplying the deduction; the floor keeps a legacy row whose desired
    /// size is stale below `vms.disk` from crediting storage back.
    private static let volumeReservedBytes: SQLQueryString = """
        GREATEST(
            volumes.size - COALESCE(
                (
                    SELECT MAX(vms.disk)::bigint FROM vms
                    WHERE vms.project_id = volumes.project_id
                      AND EXISTS (
                          SELECT 1 FROM volume_replicas
                          WHERE volume_replicas.volume_id = volumes.id
                            AND volume_replicas.dataset_path = vms.disk_path
                      )
                ),
                0
            ),
            0
        )
        """

    /// A compatibility boot-volume row does not consume a volume-count slot,
    /// even after detachment clears its mutable `vm_id`.
    private static let volumeIsNotAVMBootDisk: SQLQueryString = """
        NOT EXISTS (
            SELECT 1 FROM vms
            WHERE vms.project_id = volumes.project_id
              AND EXISTS (
                  SELECT 1 FROM volume_replicas
                  WHERE volume_replicas.volume_id = volumes.id
                    AND volume_replicas.dataset_path = vms.disk_path
              )
        )
        """

    /// Counts the scope's VMs by environment and by status in one grouped
    /// aggregate, for the per-quota usage endpoint.
    static func vmBreakdown(in scope: QuotaScope, on db: Database) async throws -> QuotaVMBreakdown {
        if case .none = scope.projects { return QuotaVMBreakdown() }
        let sql = try requireSQL(db)

        struct GroupRow: Decodable {
            let environment: String
            let status: String
            let vm_count: Int64
        }
        let rows = try await sql.raw(
            """
            SELECT environment, status::text AS status, COUNT(*)::bigint AS vm_count
            FROM vms
            WHERE \(scope.predicate)
            GROUP BY environment, status
            """
        ).all(decoding: GroupRow.self)

        var breakdown = QuotaVMBreakdown()
        for row in rows {
            breakdown.byEnvironment[row.environment, default: 0] += Int(row.vm_count)
            breakdown.byStatus[row.status, default: 0] += Int(row.vm_count)
        }
        return breakdown
    }

    private static func requireSQL(_ db: Database) throws -> any SQLDatabase {
        guard let sql = db as? SQLDatabase else {
            // Fail closed. A zero measurement here would resync every quota's
            // reservations down to nothing and wave through the create that
            // asked for them.
            throw Abort(.internalServerError, reason: "Quota accounting requires an SQL database")
        }
        return sql
    }
}

extension QuotaScope {
    /// A predicate over a workload table's `project_id` and `environment`,
    /// shared by every aggregate so all of them measure exactly the same rows.
    ///
    /// Folder and organization scopes resolve their projects in a subquery
    /// rather than in Swift: a project hangs off exactly one of an organization
    /// or a folder (`Project.validate`), and every folder both denormalizes its
    /// organization and materializes its `path`, so one join covers both
    /// shapes with no tree walk.
    fileprivate var predicate: SQLQueryString {
        var predicate: SQLQueryString
        switch projects {
        case .project(let projectID):
            predicate = "project_id = \(bind: projectID)"
        case .folderSubtree(let path):
            // The path is `/orgId/folderId/…/selfId`, so the subtree is the
            // folder itself plus everything whose path extends it. A prefix
            // match, unlike the `LIKE '%<id>%'` it replaced, can use an index.
            predicate = """
                project_id IN (
                    SELECT p.id FROM projects p
                    JOIN organizational_units ou ON ou.id = p.organizational_unit_id
                    WHERE ou.path = \(bind: path) OR ou.path LIKE \(bind: path + "/%")
                )
                """
        case .organization(let organizationID):
            predicate = """
                project_id IN (
                    SELECT p.id FROM projects p
                    LEFT JOIN organizational_units ou ON ou.id = p.organizational_unit_id
                    WHERE p.organization_id = \(bind: organizationID)
                       OR ou.organization_id = \(bind: organizationID)
                )
                """
        case .none:
            predicate = "FALSE"
        }

        if let environment {
            predicate += " AND environment = \(bind: environment)"
        }
        return predicate
    }
}
