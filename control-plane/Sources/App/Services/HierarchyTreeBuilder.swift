import Foundation
import Vapor
import Fluent

/// Builds the nested organization → OU → project → VM tree and the aggregate
/// statistics used by the hierarchy endpoints. Extracted from `HierarchyController`
/// so the tree-walking logic can be tested and reused independently of routing.
///
/// Everything is assembled from a single ``HierarchySnapshot``: the queries all
/// happen up front and the tree, its counts and its totals are pure functions of
/// the rows already in hand (issue #692).
struct HierarchyTreeBuilder {
    /// Builds the complete hierarchy response for an organization.
    static func buildCompleteHierarchy(organization: Organization, on db: Database) async throws
        -> OrganizationHierarchyResponse
    {
        let organizationID = try organization.requireID()
        let snapshot = try await HierarchySnapshot.load(organizationID: organizationID, on: db)

        let orgNode = OrganizationNode(
            id: organizationID,
            name: organization.name,
            description: organization.description,
            organizationalUnits: snapshot.topLevelFolders.map { folderNode(for: $0, in: snapshot) },
            projects: snapshot.directProjects.map { projectNode(for: $0, in: snapshot) },
            quotas: snapshot.quotas(forOrganization: organizationID).map { ResourceQuotaResponse(from: $0) }
        )

        return OrganizationHierarchyResponse(
            organization: orgNode,
            stats: stats(for: snapshot)
        )
    }

    /// Computes aggregate counts and resource utilization for an organization.
    static func hierarchyStats(organizationID: UUID, on db: Database) async throws -> HierarchyStats {
        stats(for: try await HierarchySnapshot.load(organizationID: organizationID, on: db))
    }

    /// Aggregate counts and resource utilization over an already-loaded snapshot.
    static func stats(for snapshot: HierarchySnapshot) -> HierarchyStats {
        HierarchyStats(
            totalOUs: snapshot.folders.count,
            totalProjects: snapshot.projects.count,
            totalVMs: snapshot.vms.count,
            // Every quota in the organization, folder-scoped ones included —
            // they are shown in the tree, so leaving them out of the count
            // (as the query-per-sub-computation version did) understated it.
            totalQuotas: snapshot.quotas.count,
            maxDepth: snapshot.maxDepth,
            resourceUtilization: snapshot.resourceUsage
        )
    }

    private static func folderNode(
        for folder: OrganizationalUnit, in snapshot: HierarchySnapshot
    ) -> OrganizationalUnitNode {
        let folderID = folder.id!
        return OrganizationalUnitNode(
            id: folderID,
            name: folder.name,
            description: folder.description,
            path: folder.path,
            depth: folder.depth,
            childOUs: snapshot.childFolders(of: folderID).map { folderNode(for: $0, in: snapshot) },
            projects: snapshot.projects(in: folderID).map { projectNode(for: $0, in: snapshot) },
            quotas: snapshot.quotas(forFolder: folderID).map { ResourceQuotaResponse(from: $0) }
        )
    }

    private static func projectNode(for project: Project, in snapshot: HierarchySnapshot) -> ProjectNode {
        let projectID = project.id!
        let vmSummaries = snapshot.vms(in: projectID).map { vm in
            VMSummary(
                id: vm.id!,
                name: vm.name,
                environment: vm.environment,
                status: vm.status.rawValue,
                cpu: vm.cpu,
                memoryGB: vm.memory.bytesToGB,
                diskGB: vm.disk.bytesToGB
            )
        }

        return ProjectNode(
            id: projectID,
            name: project.name,
            description: project.description,
            path: project.path,
            environments: project.environments,
            defaultEnvironment: project.defaultEnvironment,
            vms: vmSummaries,
            quotas: snapshot.quotas(forProject: projectID).map { ResourceQuotaResponse(from: $0) }
        )
    }
}
