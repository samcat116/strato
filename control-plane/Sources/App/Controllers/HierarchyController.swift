import Foundation
import Vapor
import Fluent

struct HierarchyController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("organizations")

        organizations.group(":organizationID") { org in
            // Full hierarchy view
            org.get("hierarchy", use: getFullHierarchy)

            // Resource aggregation
            org.get("resources", use: getAllResources)
            org.get("resources", "summary", use: getResourceSummary)

            // Bulk operations
            org.post("merge", use: mergeOrganizations)
            org.post("bulk-transfer", use: bulkTransferResources)

            // Search and navigation
            org.get("search", use: searchHierarchy)
            org.get("path", ":entityType", ":entityID", use: getEntityPath)
        }

        // Global hierarchy utilities
        let hierarchy = routes.grouped("hierarchy")
        hierarchy.get("search", use: globalSearchHierarchy)
        hierarchy.get("validate", use: validateHierarchy)
        hierarchy.post("repair", use: repairHierarchy)
    }

    // MARK: - Hierarchy Navigation

    func getFullHierarchy(req: Request) async throws -> OrganizationHierarchyResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        // Build complete hierarchy
        let hierarchy = try await buildCompleteHierarchy(organization: organization, on: req.db)

        return hierarchy
    }

    func getAllResources(req: Request) async throws -> OrganizationResourcesResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        // Get all resources
        let allOUs = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$path)
            .all()

        let allProjects = try await organization.getAllProjects(on: req.db)
        let allVMs = try await organization.getAllVMs(on: req.db)

        let allQuotas = try await ResourceQuota.query(on: req.db)
            .group(.or) { or in
                or.filter(\.$organization.$id == organizationID)
                if !allOUs.isEmpty {
                    or.filter(\.$organizationalUnit.$id ~~ allOUs.compactMap { $0.id })
                }
                if !allProjects.isEmpty {
                    or.filter(\.$project.$id ~~ allProjects.compactMap { $0.id })
                }
            }
            .all()

        // Group VMs by environment and status
        var vmsByEnvironment: [String: Int] = [:]
        var vmsByStatus: [String: Int] = [:]
        var vmsByProject: [String: Int] = [:]

        for vm in allVMs {
            vmsByEnvironment[vm.environment, default: 0] += 1
            vmsByStatus[vm.status.rawValue, default: 0] += 1

            // Get project name for grouping
            if let project = allProjects.first(where: { $0.id == vm.$project.id }) {
                vmsByProject[project.name, default: 0] += 1
            }
        }

        return OrganizationResourcesResponse(
            organizationId: organizationID,
            organizationName: organization.name,
            organizationalUnits: allOUs.map { OrganizationalUnitResponse(from: $0) },
            projects: allProjects.map { ProjectResponse(from: $0) },
            vms: allVMs.map { VMResponse(from: $0) },
            quotas: allQuotas.map { ResourceQuotaResponse(from: $0) },
            summary: ResourceSummary(
                totalOUs: allOUs.count,
                totalProjects: allProjects.count,
                totalVMs: allVMs.count,
                totalQuotas: allQuotas.count,
                vmsByEnvironment: vmsByEnvironment,
                vmsByStatus: vmsByStatus,
                vmsByProject: vmsByProject
            )
        )
    }

    func getResourceSummary(req: Request) async throws -> ResourceSummaryResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        // Calculate resource usage
        let resourceUsage = try await organization.getResourceUsage(on: req.db)

        // Get quota information
        let quotas = try await getOrganizationQuotas(organizationID: organizationID, on: req.db)

        // Calculate quota compliance
        var quotaCompliance: [QuotaComplianceInfo] = []
        for quota in quotas {
            let (actualUsage, _) = try await calculateActualUsageForQuota(quota: quota, on: req.db)

            let cpuCompliance = QuotaComplianceDetail(
                used: actualUsage.vcpus,
                limit: quota.maxVCPUs,
                percentage: Double(actualUsage.vcpus) / Double(quota.maxVCPUs) * 100
            )

            let memoryLimitGB = Int(Double(quota.maxMemory) / 1024 / 1024 / 1024)
            let memoryCompliance = QuotaComplianceDetail(
                used: Int(actualUsage.memoryGB),
                limit: memoryLimitGB,
                percentage: actualUsage.memoryGB / (Double(quota.maxMemory) / 1024 / 1024 / 1024) * 100
            )

            let vmCompliance = QuotaComplianceDetail(
                used: actualUsage.vms,
                limit: quota.maxVMs,
                percentage: Double(actualUsage.vms) / Double(quota.maxVMs) * 100
            )

            let compliance = QuotaComplianceInfo(
                quotaId: quota.id!,
                quotaName: quota.name,
                scope: getQuotaScope(quota: quota),
                environment: quota.environment,
                cpuCompliance: cpuCompliance,
                memoryCompliance: memoryCompliance,
                vmCompliance: vmCompliance,
                isEnabled: quota.isEnabled
            )
            quotaCompliance.append(compliance)
        }

        return ResourceSummaryResponse(
            organizationId: organizationID,
            organizationName: organization.name,
            resourceUsage: resourceUsage,
            quotaCompliance: quotaCompliance,
            hierarchyStats: try await getHierarchyStats(organizationID: organizationID, on: req.db)
        )
    }

    // MARK: - Search and Navigation

    func searchHierarchy(req: Request) async throws -> HierarchySearchResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let query = req.query[String.self, at: "q"] else {
            throw Abort(.badRequest, reason: "Search query parameter 'q' is required")
        }

        let entityType = req.query[String.self, at: "type"] // Optional filter by entity type

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        var results: [HierarchySearchResult] = []

        // Search OUs if not filtered to specific type
        if entityType == nil || entityType == "ou" {
            let ous = try await OrganizationalUnit.query(on: req.db)
                .filter(\.$organization.$id == organizationID)
                .group(.or) { or in
                    or.filter(\.$name ~~ query)
                    or.filter(\.$description ~~ query)
                }
                .limit(10)
                .all()

            for ou in ous {
                results.append(HierarchySearchResult(
                    id: ou.id!,
                    name: ou.name,
                    type: "organizational_unit",
                    path: ou.path,
                    description: ou.description,
                    parentId: ou.$parentOU.id,
                    parentType: ou.$parentOU.id != nil ? "organizational_unit" : "organization"
                ))
            }
        }

        // Search Projects
        if entityType == nil || entityType == "project" {
            let projects = try await Project.query(on: req.db)
                .group(.or) { or in
                    or.filter(\.$organization.$id == organizationID)
                    or.join(OrganizationalUnit.self, on: \Project.$organizationalUnit.$id == \OrganizationalUnit.$id)
                        .filter(OrganizationalUnit.self, \.$organization.$id == organizationID)
                }
                .group(.or) { or in
                    or.filter(\.$name ~~ query)
                    or.filter(\.$description ~~ query)
                }
                .limit(10)
                .all()

            for project in projects {
                let parentId = project.$organization.id ?? project.$organizationalUnit.id
                let parentType = project.$organization.id != nil ? "organization" : "organizational_unit"

                results.append(HierarchySearchResult(
                    id: project.id!,
                    name: project.name,
                    type: "project",
                    path: project.path,
                    description: project.description,
                    parentId: parentId,
                    parentType: parentType
                ))
            }
        }

        // Search VMs
        if entityType == nil || entityType == "vm" {
            let vms = try await VM.query(on: req.db)
                .join(Project.self, on: \VM.$project.$id == \Project.$id)
                .group(.or) { or in
                    or.filter(Project.self, \.$organization.$id == organizationID)
                    or.join(OrganizationalUnit.self, on: \Project.$organizationalUnit.$id == \OrganizationalUnit.$id)
                        .filter(OrganizationalUnit.self, \.$organization.$id == organizationID)
                }
                .group(.or) { or in
                    or.filter(\.$name ~~ query)
                    or.filter(\.$description ~~ query)
                }
                .limit(10)
                .all()

            for vm in vms {
                results.append(HierarchySearchResult(
                    id: vm.id!,
                    name: vm.name,
                    type: "vm",
                    path: "", // VMs don't have paths, but we could build one
                    description: vm.description,
                    parentId: vm.$project.id,
                    parentType: "project"
                ))
            }
        }

        return HierarchySearchResponse(
            query: query,
            organizationId: organizationID,
            results: results,
            totalResults: results.count
        )
    }

    func globalSearchHierarchy(req: Request) async throws -> HierarchySearchResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let query = req.query[String.self, at: "q"] else {
            throw Abort(.badRequest, reason: "Search query parameter 'q' is required")
        }

        let entityType = req.query[String.self, at: "type"] // Optional filter by entity type

        // Get all organizations the user belongs to
        try await user.$organizations.load(on: req.db)
        let organizationIDs = user.organizations.compactMap { $0.id }

        if organizationIDs.isEmpty {
            return HierarchySearchResponse(
                query: query,
                organizationId: nil,
                results: [],
                totalResults: 0
            )
        }

        var results: [HierarchySearchResult] = []

        // Search OUs if not filtered to specific type
        if entityType == nil || entityType == "ou" {
            let ous = try await OrganizationalUnit.query(on: req.db)
                .filter(\.$organization.$id ~~ organizationIDs)
                .group(.or) { or in
                    or.filter(\.$name ~~ query)
                    or.filter(\.$description ~~ query)
                }
                .limit(10)
                .all()

            for ou in ous {
                results.append(HierarchySearchResult(
                    id: ou.id!,
                    name: ou.name,
                    type: "organizational_unit",
                    path: ou.path,
                    description: ou.description,
                    parentId: ou.$parentOU.id,
                    parentType: ou.$parentOU.id != nil ? "organizational_unit" : "organization"
                ))
            }
        }

        // Search Projects
        if entityType == nil || entityType == "project" {
            // Get projects directly in organizations
            let directProjects = try await Project.query(on: req.db)
                .filter(\.$organization.$id ~~ organizationIDs)
                .group(.or) { or in
                    or.filter(\.$name ~~ query)
                    or.filter(\.$description ~~ query)
                }
                .limit(10)
                .all()

            // Get projects in OUs within user organizations
            let ouProjects = try await Project.query(on: req.db)
                .join(OrganizationalUnit.self, on: \Project.$organizationalUnit.$id == \OrganizationalUnit.$id)
                .filter(OrganizationalUnit.self, \.$organization.$id ~~ organizationIDs)
                .group(.or) { or in
                    or.filter(\.$name ~~ query)
                    or.filter(\.$description ~~ query)
                }
                .limit(10)
                .all()

            for project in directProjects + ouProjects {
                let (parentId, parentType): (UUID?, String) = {
                    if let ouId = project.$organizationalUnit.id {
                        return (ouId, "organizational_unit")
                    } else if let orgId = project.$organization.id {
                        return (orgId, "organization")
                    } else {
                        return (nil, "unknown")
                    }
                }()

                results.append(HierarchySearchResult(
                    id: project.id!,
                    name: project.name,
                    type: "project",
                    path: project.path,
                    description: project.description,
                    parentId: parentId,
                    parentType: parentType
                ))
            }
        }

        return HierarchySearchResponse(
            query: query,
            organizationId: nil, // Global search across organizations
            results: results,
            totalResults: results.count
        )
    }

    func getEntityPath(req: Request) async throws -> EntityPathResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let entityType = req.parameters.get("entityType"),
              let entityID = req.parameters.get("entityID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        let pathComponents = try await buildEntityPath(
            entityType: entityType,
            entityID: entityID,
            organizationID: organizationID,
            on: req.db
        )

        return EntityPathResponse(
            entityId: entityID,
            entityType: entityType,
            organizationId: organizationID,
            pathComponents: pathComponents
        )
    }

    // MARK: - Bulk Operations

    func mergeOrganizations(req: Request) async throws -> MergeOrganizationsResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let mergeRequest = try req.content.decode(MergeOrganizationsRequest.self)

        // Verify user has admin access to both organizations
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)
        try await verifyOrganizationAdminAccess(user: user, organizationID: mergeRequest.sourceOrganizationId, on: req.db)

        guard let targetOrg = try await Organization.find(organizationID, on: req.db),
              let sourceOrg = try await Organization.find(mergeRequest.sourceOrganizationId, on: req.db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        // Perform merge in transaction
        let mergeResult = try await req.db.transaction { transactionDB in
            return try await performOrganizationMerge(
                sourceOrg: sourceOrg,
                targetOrg: targetOrg,
                mergeRequest: mergeRequest,
                on: transactionDB
            )
        }

        return mergeResult
    }

    func bulkTransferResources(req: Request) async throws -> BulkTransferResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let transferRequest = try req.content.decode(BulkTransferRequest.self)

        // Verify user has admin access
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)

        // Perform bulk transfer in transaction
        let transferResult = try await req.db.transaction { transactionDB in
            return try await performBulkTransfer(
                organizationID: organizationID,
                transferRequest: transferRequest,
                on: transactionDB
            )
        }

        return transferResult
    }

    // MARK: - Validation and Repair

    func validateHierarchy(req: Request) async throws -> HierarchyValidationResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Only system admins can validate hierarchy
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System admin access required")
        }

        let issues = try await findHierarchyIssues(on: req.db)

        return HierarchyValidationResponse(
            isValid: issues.isEmpty,
            issues: issues,
            summary: HierarchyValidationSummary(
                totalIssues: issues.count,
                criticalIssues: issues.filter { $0.severity == "critical" }.count,
                warningIssues: issues.filter { $0.severity == "warning" }.count,
                infoIssues: issues.filter { $0.severity == "info" }.count
            )
        )
    }

    func repairHierarchy(req: Request) async throws -> HierarchyRepairResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Only system admins can repair hierarchy
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System admin access required")
        }

        let repairRequest = try req.content.decode(HierarchyRepairRequest.self)

        let repairResult = try await req.db.transaction { transactionDB in
            return try await performHierarchyRepair(
                repairRequest: repairRequest,
                on: transactionDB
            )
        }

        return repairResult
    }

    // MARK: - Helper Methods

    private func verifyOrganizationAccess(user: User, organizationID: UUID, on db: Database) async throws {
        let userOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
        }
    }

    private func verifyOrganizationAdminAccess(user: User, organizationID: UUID, on db: Database) async throws {
        let userOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard let userOrganization = userOrg, userOrganization.role == "admin" else {
            throw Abort(.forbidden, reason: "Admin access required")
        }
    }

    private func buildCompleteHierarchy(organization: Organization, on db: Database) async throws -> OrganizationHierarchyResponse {
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

        let stats = try await getHierarchyStats(organizationID: organization.id!, on: db)

        return OrganizationHierarchyResponse(
            organization: orgNode,
            stats: stats
        )
    }

    private func buildOUNode(ou: OrganizationalUnit, allOUs: [OrganizationalUnit], allProjects: [Project], on db: Database) async throws -> OrganizationalUnitNode {
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

    private func buildProjectNode(project: Project, on db: Database) async throws -> ProjectNode {
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
                memoryGB: Double(vm.memory) / 1024 / 1024 / 1024,
                diskGB: Double(vm.disk) / 1024 / 1024 / 1024
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

    private func getHierarchyStats(organizationID: UUID, on db: Database) async throws -> HierarchyStats {
        let ouCount = try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .count()

        let organization = try await Organization.find(organizationID, on: db)!
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

        let maxDepth = try await OrganizationalUnit.query(on: db)
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

    private func getOrganizationQuotas(organizationID: UUID, on db: Database) async throws -> [ResourceQuota] {
        let organization = try await Organization.find(organizationID, on: db)!
        let allProjects = try await organization.getAllProjects(on: db)
        let allOUs = try await OrganizationalUnit.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .all()

        return try await ResourceQuota.query(on: db)
            .group(.or) { or in
                or.filter(\.$organization.$id == organizationID)
                if !allOUs.isEmpty {
                    or.filter(\.$organizationalUnit.$id ~~ allOUs.compactMap { $0.id })
                }
                if !allProjects.isEmpty {
                    or.filter(\.$project.$id ~~ allProjects.compactMap { $0.id })
                }
            }
            .all()
    }

    private func calculateActualUsageForQuota(quota: ResourceQuota, on db: Database) async throws -> (QuotaUsage, [VM]) {
        // This is the same as calculateActualUsage from ResourceQuotaController
        var vms: [VM] = []

        // Get VMs based on quota scope
        if let projectID = quota.$project.id {
            let query = VM.query(on: db).filter(\.$project.$id == projectID)
            if let environment = quota.environment {
                query.filter(\.$environment == environment)
            }
            vms = try await query.all()
        } else if let ouID = quota.$organizationalUnit.id {
            // Get all projects in this OU
            let projects = try await Project.query(on: db)
                .filter(\.$organizationalUnit.$id == ouID)
                .all()

            let projectIDs = projects.compactMap { $0.id }
            if !projectIDs.isEmpty {
                let query = VM.query(on: db).filter(\.$project.$id ~~ projectIDs)
                if let environment = quota.environment {
                    query.filter(\.$environment == environment)
                }
                vms = try await query.all()
            }
        } else if let orgID = quota.$organization.id {
            // Get all projects in this organization (direct and via OUs)
            let org = try await Organization.find(orgID, on: db)!
            let allProjects = try await org.getAllProjects(on: db)

            let projectIDs = allProjects.compactMap { $0.id }
            if !projectIDs.isEmpty {
                let query = VM.query(on: db).filter(\.$project.$id ~~ projectIDs)
                if let environment = quota.environment {
                    query.filter(\.$environment == environment)
                }
                vms = try await query.all()
            }
        }

        // Calculate actual usage
        let totalVCPUs = vms.reduce(0) { $0 + $1.cpu }
        let totalMemory = vms.reduce(0) { $0 + $1.memory }
        let totalStorage = vms.reduce(0) { $0 + $1.disk }

        let actualUsage = QuotaUsage(
            vcpus: totalVCPUs,
            memoryGB: Double(totalMemory) / 1024 / 1024 / 1024,
            storageGB: Double(totalStorage) / 1024 / 1024 / 1024,
            vms: vms.count,
            networks: 0 // TODO: Implement network counting when networking is added
        )

        return (actualUsage, vms)
    }

    private func getQuotaScope(quota: ResourceQuota) -> String {
        if quota.$organization.id != nil {
            return "organization"
        } else if quota.$organizationalUnit.id != nil {
            return "organizational_unit"
        } else if quota.$project.id != nil {
            return "project"
        } else {
            return "unknown"
        }
    }

    private func buildEntityPath(entityType: String, entityID: UUID, organizationID: UUID, on db: Database) async throws -> [PathComponent] {
        var components: [PathComponent] = []

        // Add organization as root
        if let org = try await Organization.find(organizationID, on: db) {
            components.append(PathComponent(id: organizationID, name: org.name, type: "organization"))
        }

        switch entityType {
        case "organizational_unit":
            if let ou = try await OrganizationalUnit.find(entityID, on: db) {
                // Build path up to root
                var currentOU = ou
                var ouChain: [OrganizationalUnit] = []

                while let parentID = currentOU.$parentOU.id {
                    ouChain.insert(currentOU, at: 0)
                    if let parentOU = try await OrganizationalUnit.find(parentID, on: db) {
                        currentOU = parentOU
                    } else {
                        break
                    }
                }
                ouChain.append(ou)

                for ou in ouChain {
                    components.append(PathComponent(id: ou.id!, name: ou.name, type: "organizational_unit"))
                }
            }

        case "project":
            if let project = try await Project.find(entityID, on: db) {
                // Add OU path if project belongs to OU
                if let ouID = project.$organizationalUnit.id {
                    let ouComponents = try await buildEntityPath(entityType: "organizational_unit", entityID: ouID, organizationID: organizationID, on: db)
                    components.append(contentsOf: ouComponents.dropFirst()) // Remove duplicate org
                }
                components.append(PathComponent(id: entityID, name: project.name, type: "project"))
            }

        case "vm":
            if let vm = try await VM.find(entityID, on: db) {
                // Add project path
                let projectComponents = try await buildEntityPath(entityType: "project", entityID: vm.$project.id, organizationID: organizationID, on: db)
                components.append(contentsOf: projectComponents.dropFirst()) // Remove duplicate org
                components.append(PathComponent(id: entityID, name: vm.name, type: "vm"))
            }

        default:
            break
        }

        return components
    }

    // Stub implementations for complex operations
    private func performOrganizationMerge(sourceOrg: Organization, targetOrg: Organization, mergeRequest: MergeOrganizationsRequest, on db: Database) async throws -> MergeOrganizationsResponse {
        // This would be a complex implementation
        // For now, return a basic response
        return MergeOrganizationsResponse(
            success: false,
            targetOrganizationId: targetOrg.id!,
            mergedResourceCounts: MergeOrganizationsResponse.MergedResourceCounts(
                organizationalUnits: 0,
                projects: 0,
                vms: 0,
                quotas: 0,
                users: 0
            ),
            conflicts: [],
            warnings: ["Organization merger not yet implemented"],
            summary: "Organization merger feature is not yet implemented"
        )
    }

    private func performBulkTransfer(organizationID: UUID, transferRequest: BulkTransferRequest, on db: Database) async throws -> BulkTransferResponse {
        // This would be a complex implementation
        // For now, return a basic response
        return BulkTransferResponse(
            success: false,
            transferredCount: 0,
            failedTransfers: [],
            warnings: ["Bulk transfer not yet implemented"],
            summary: "Bulk transfer feature is not yet implemented"
        )
    }

    private func findHierarchyIssues(on db: Database) async throws -> [HierarchyIssue] {
        // This would check for various hierarchy issues
        // For now, return empty array
        return []
    }

    private func performHierarchyRepair(repairRequest: HierarchyRepairRequest, on db: Database) async throws -> HierarchyRepairResponse {
        // This would perform actual repairs
        // For now, return a basic response
        return HierarchyRepairResponse(
            success: false,
            repairedIssues: [],
            remainingIssues: [],
            summary: "Hierarchy repair feature is not yet implemented"
        )
    }
}

// MARK: - DTOs for Hierarchy Management

struct OrganizationHierarchyResponse: Content {
    let organization: OrganizationNode
    let stats: HierarchyStats
}

struct OrganizationNode: Content {
    let id: UUID
    let name: String
    let description: String
    let organizationalUnits: [OrganizationalUnitNode]
    let projects: [ProjectNode]
    let quotas: [ResourceQuotaResponse]
}

struct OrganizationalUnitNode: Content {
    let id: UUID
    let name: String
    let description: String
    let path: String
    let depth: Int
    let childOUs: [OrganizationalUnitNode]
    let projects: [ProjectNode]
    let quotas: [ResourceQuotaResponse]
}

struct ProjectNode: Content {
    let id: UUID
    let name: String
    let description: String
    let path: String
    let environments: [String]
    let defaultEnvironment: String
    let vms: [VMSummary]
    let quotas: [ResourceQuotaResponse]
}

struct VMSummary: Content {
    let id: UUID
    let name: String
    let environment: String
    let status: String
    let cpu: Int
    let memoryGB: Double
    let diskGB: Double
}

struct VMResponse: Content {
    let id: UUID
    let name: String
    let description: String
    let environment: String
    let status: String
    let cpu: Int
    let memory: Int64
    let disk: Int64
    let projectId: UUID

    init(from vm: VM) {
        self.id = vm.id!
        self.name = vm.name
        self.description = vm.description
        self.environment = vm.environment
        self.status = vm.status.rawValue
        self.cpu = vm.cpu
        self.memory = vm.memory
        self.disk = vm.disk
        self.projectId = vm.$project.id
    }
}

struct HierarchyStats: Content {
    let totalOUs: Int
    let totalProjects: Int
    let totalVMs: Int
    let totalQuotas: Int
    let maxDepth: Int
    let resourceUtilization: ResourceUsageResponse
}

struct OrganizationResourcesResponse: Content {
    let organizationId: UUID
    let organizationName: String
    let organizationalUnits: [OrganizationalUnitResponse]
    let projects: [ProjectResponse]
    let vms: [VMResponse]
    let quotas: [ResourceQuotaResponse]
    let summary: ResourceSummary
}

struct ResourceSummary: Content {
    let totalOUs: Int
    let totalProjects: Int
    let totalVMs: Int
    let totalQuotas: Int
    let vmsByEnvironment: [String: Int]
    let vmsByStatus: [String: Int]
    let vmsByProject: [String: Int]
}

struct ResourceSummaryResponse: Content {
    let organizationId: UUID
    let organizationName: String
    let resourceUsage: ResourceUsageResponse
    let quotaCompliance: [QuotaComplianceInfo]
    let hierarchyStats: HierarchyStats
}

struct QuotaComplianceInfo: Content {
    let quotaId: UUID
    let quotaName: String
    let scope: String
    let environment: String?
    let cpuCompliance: QuotaComplianceDetail
    let memoryCompliance: QuotaComplianceDetail
    let vmCompliance: QuotaComplianceDetail
    let isEnabled: Bool
}

struct QuotaComplianceDetail: Content {
    let used: Int
    let limit: Int
    let percentage: Double
}

struct HierarchySearchResponse: Content {
    let query: String
    let organizationId: UUID?
    let results: [HierarchySearchResult]
    let totalResults: Int
}

struct HierarchySearchResult: Content {
    let id: UUID
    let name: String
    let type: String
    let path: String
    let description: String
    let parentId: UUID?
    let parentType: String?
}

struct EntityPathResponse: Content {
    let entityId: UUID
    let entityType: String
    let organizationId: UUID
    let pathComponents: [PathComponent]
}

struct PathComponent: Content {
    let id: UUID
    let name: String
    let type: String
}

// Additional DTOs for bulk operations and validation would be defined here...
