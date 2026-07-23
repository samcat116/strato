import Foundation
import Vapor
import Fluent

struct HierarchyController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let organizations = routes.grouped("api", "organizations")

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
        let hierarchy = routes.grouped("api", "hierarchy")
        hierarchy.get("search", use: globalSearchHierarchy)
        hierarchy.get("validate", use: validateHierarchy)
        hierarchy.post("repair", use: repairHierarchy)
    }

    // MARK: - Hierarchy Navigation

    func getFullHierarchy(req: Request) async throws -> OrganizationHierarchyResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        // Build complete hierarchy
        let hierarchy = try await HierarchyTreeBuilder.buildCompleteHierarchy(organization: organization, on: req.db)

        return hierarchy
    }

    func getAllResources(req: Request) async throws -> OrganizationResourcesResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

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
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        guard let organization = try await Organization.find(organizationID, on: req.db) else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        // Calculate resource usage
        let resourceUsage = try await organization.getResourceUsage(on: req.db)

        // Get quota information and calculate compliance
        let quotas = try await QuotaComplianceService.organizationQuotas(organizationID: organizationID, on: req.db)
        let quotaCompliance = try await QuotaComplianceService.complianceInfos(for: quotas, on: req.db)

        return ResourceSummaryResponse(
            organizationId: organizationID,
            organizationName: organization.name,
            resourceUsage: resourceUsage,
            quotaCompliance: quotaCompliance,
            hierarchyStats: try await HierarchyTreeBuilder.hierarchyStats(organizationID: organizationID, on: req.db)
        )
    }

    // MARK: - Search and Navigation

    func searchHierarchy(req: Request) async throws -> HierarchySearchResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        guard let query = req.query[String.self, at: "q"] else {
            throw Abort(.badRequest, reason: "Search query parameter 'q' is required")
        }

        let entityType = req.query[String.self, at: "type"]  // Optional filter by entity type

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        let results = try await HierarchySearchService.search(
            organizationID: organizationID,
            query: query,
            entityType: entityType,
            on: req.db
        )

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

        let entityType = req.query[String.self, at: "type"]  // Optional filter by entity type

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

        let results = try await HierarchySearchService.globalSearch(
            organizationIDs: organizationIDs,
            query: query,
            entityType: entityType,
            on: req.db
        )

        return HierarchySearchResponse(
            query: query,
            organizationId: nil,  // Global search across organizations
            results: results,
            totalResults: results.count
        )
    }

    func getEntityPath(req: Request) async throws -> EntityPathResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let entityType = req.parameters.get("entityType"),
            let entityID = req.parameters.get("entityID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid parameters")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        let pathComponents = try await HierarchyPathResolver.buildEntityPath(
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
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let mergeRequest = try req.content.decode(MergeOrganizationsRequest.self)

        // Verify user has admin access to both organizations
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: mergeRequest.sourceOrganizationId, on: req)

        guard let targetOrg = try await Organization.find(organizationID, on: req.db),
            let sourceOrg = try await Organization.find(mergeRequest.sourceOrganizationId, on: req.db)
        else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        return try await HierarchyMaintenanceService.performOrganizationMerge(
            sourceOrg: sourceOrg,
            targetOrg: targetOrg,
            mergeRequest: mergeRequest,
            on: req.db
        )
    }

    func bulkTransferResources(req: Request) async throws -> BulkTransferResponse {
        guard req.auth.get(User.self) != nil else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let transferRequest = try req.content.decode(BulkTransferRequest.self)

        // Verify user has admin access
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        return try await HierarchyMaintenanceService.performBulkTransfer(
            organizationID: organizationID,
            transferRequest: transferRequest,
            on: req.db
        )
    }

    // MARK: - Validation and Repair

    func validateHierarchy(req: Request) async throws -> HierarchyValidationResponse {
        // Platform plumbing with no node to attach a policy to: the
        // decision-marking admin gate, not a bypass.
        _ = try req.requireSystemAdmin()

        let issues = try await HierarchyMaintenanceService.findHierarchyIssues(on: req.db)

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
        // Platform plumbing with no node to attach a policy to: the
        // decision-marking admin gate, not a bypass.
        _ = try req.requireSystemAdmin()

        let repairRequest = try req.content.decode(HierarchyRepairRequest.self)

        return try await HierarchyMaintenanceService.performHierarchyRepair(
            repairRequest: repairRequest,
            on: req.db
        )
    }
}
