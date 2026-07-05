import Foundation
import Vapor
import Fluent

/// Builds the nested organization → OU → project → VM tree and the aggregate
/// statistics used by the hierarchy endpoints. Extracted from `HierarchyController`
/// so the tree-walking logic can be tested and reused independently of routing.
struct HierarchyTreeBuilder {
    /// Builds the complete hierarchy response for an organization.
    static func buildCompleteHierarchy(organization: Organization, on db: Database) async throws
        -> OrganizationHierarchyResponse
    {
        // Get all OUs for the organization
        let allOUs = try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organization.id!)
            .sort(\.$depth)
            .sort(\.$name)
            .all()

        // Get all projects
        let allProjects = try await organization.getAllProjects(on: db)

        // Get organization quotas
        let orgQuotas = try await ResourceQuota.query(on: db)
            .filter(\.$organization.$id == organization.id!)
            .all()

        // Build OU tree
        let topLevelOUs = allOUs.filter { $0.$parentOU.id == nil }
        var ouNodes: [OrganizationalUnitNode] = []

        for ou in topLevelOUs {
            let ouNode = try await buildOUNode(ou: ou, allOUs: allOUs, allProjects: allProjects, on: db)
            ouNodes.append(ouNode)
        }

        // Get direct organization projects
        let directProjects = allProjects.filter { $0.$organization.id == organization.id! }
        var projectNodes: [ProjectNode] = []

        for project in directProjects {
            let projectNode = try await buildProjectNode(project: project, on: db)
            projectNodes.append(projectNode)
        }

        let orgNode = OrganizationNode(
            id: organization.id!,
            name: organization.name,
            description: organization.description,
            organizationalUnits: ouNodes,
            projects: projectNodes,
            quotas: orgQuotas.map { ResourceQuotaResponse(from: $0) }
        )

        let stats = try await hierarchyStats(organizationID: organization.id!, on: db)

        return OrganizationHierarchyResponse(
            organization: orgNode,
            stats: stats
        )
    }

    /// Computes aggregate counts and resource utilization for an organization.
    static func hierarchyStats(organizationID: UUID, on db: Database) async throws -> HierarchyStats {
        let ouCount = try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .count()

        guard let organization = try await Organization.find(organizationID, on: db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }
        let allProjects = try await organization.getAllProjects(on: db)
        let allVMs = try await organization.getAllVMs(on: db)

        let quotaCount = try await ResourceQuota.query(on: db)
            .group(.or) { or in
                or.filter(\.$organization.$id == organizationID)
                if !allProjects.isEmpty {
                    or.filter(\.$project.$id ~~ allProjects.compactMap { $0.id })
                }
            }
            .count()

        let maxDepth =
            try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .max(\.$depth) ?? 0

        let resourceUsage = try await organization.getResourceUsage(on: db)

        return HierarchyStats(
            totalOUs: Int(ouCount),
            totalProjects: allProjects.count,
            totalVMs: allVMs.count,
            totalQuotas: Int(quotaCount),
            maxDepth: maxDepth,
            resourceUtilization: resourceUsage
        )
    }

    private static func buildOUNode(
        ou: OrganizationalUnit, allOUs: [OrganizationalUnit], allProjects: [Project], on db: Database
    ) async throws -> OrganizationalUnitNode {
        // Get child OUs
        let childOUs = allOUs.filter { $0.$parentOU.id == ou.id }
        var childNodes: [OrganizationalUnitNode] = []

        for childOU in childOUs {
            let childNode = try await buildOUNode(ou: childOU, allOUs: allOUs, allProjects: allProjects, on: db)
            childNodes.append(childNode)
        }

        // Get projects in this OU
        let ouProjects = allProjects.filter { $0.$organizationalUnit.id == ou.id }
        var projectNodes: [ProjectNode] = []

        for project in ouProjects {
            let projectNode = try await buildProjectNode(project: project, on: db)
            projectNodes.append(projectNode)
        }

        // Get OU quotas
        let ouQuotas = try await ResourceQuota.query(on: db)
            .filter(\.$organizationalUnit.$id == ou.id!)
            .all()

        return OrganizationalUnitNode(
            id: ou.id!,
            name: ou.name,
            description: ou.description,
            path: ou.path,
            depth: ou.depth,
            childOUs: childNodes,
            projects: projectNodes,
            quotas: ouQuotas.map { ResourceQuotaResponse(from: $0) }
        )
    }

    private static func buildProjectNode(project: Project, on db: Database) async throws -> ProjectNode {
        // Get VMs in project
        let vms = try await VM.query(on: db)
            .filter(\.$project.$id == project.id!)
            .all()

        let vmSummaries = vms.map { vm in
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

        // Get project quotas
        let projectQuotas = try await ResourceQuota.query(on: db)
            .filter(\.$project.$id == project.id!)
            .all()

        return ProjectNode(
            id: project.id!,
            name: project.name,
            description: project.description,
            path: project.path,
            environments: project.environments,
            defaultEnvironment: project.defaultEnvironment,
            vms: vmSummaries,
            quotas: projectQuotas.map { ResourceQuotaResponse(from: $0) }
        )
    }
}
