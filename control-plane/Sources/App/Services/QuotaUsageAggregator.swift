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
    /// VM disks plus sandbox-snapshot artifacts. Sandboxes themselves reserve
    /// no storage, but their checkpoints persist real bytes in the same pool
    /// (issue #426).
    var storageBytes: Int64
    var vmCount: Int
    var sandboxCount: Int

    static let none = QuotaMeasuredUsage(
        vcpus: 0, memoryBytes: 0, storageBytes: 0, vmCount: 0, sandboxCount: 0)

    /// The API-facing projection.
    var asQuotaUsage: QuotaUsage {
        QuotaUsage(
            vcpus: vcpus,
            memoryGB: memoryBytes.bytesToGB,
            storageGB: storageBytes.bytesToGB,
            vms: vmCount,
            sandboxes: sandboxCount,
            networks: 0  // TODO: Implement network counting when networking is added
        )
    }
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
    /// and the snapshot artifacts that also occupy the storage pool.
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

        return QuotaMeasuredUsage(
            vcpus: Int(vms?.vcpus ?? 0) + Int(sandboxes?.vcpus ?? 0),
            memoryBytes: (vms?.memory_bytes ?? 0) + (sandboxes?.memory_bytes ?? 0),
            storageBytes: (vms?.disk_bytes ?? 0) + snapshotStorage,
            vmCount: Int(vms?.vm_count ?? 0),
            sandboxCount: Int(sandboxes?.sandbox_count ?? 0)
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
