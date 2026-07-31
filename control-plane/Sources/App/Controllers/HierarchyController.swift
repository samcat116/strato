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

        // Build the complete hierarchy — over the rows this caller may read,
        // not every row in the organization (issue #870).
        let snapshot = try await HierarchySnapshot.load(organizationID: organizationID, on: req.db)
            .readable(on: req)
        return try HierarchyTreeBuilder.buildCompleteHierarchy(organization: organization, snapshot: snapshot)
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

        // Every row the response reports on, in four flat queries, narrowed to
        // the ones this caller may read (issue #870).
        let snapshot = try await HierarchySnapshot.load(organizationID: organizationID, on: req.db)
            .readable(on: req)
        // A flat array, so it carries only folders decided in their own right —
        // the ancestors the tree retains for connectivity have nothing to
        // connect here.
        let allOUs = snapshot.decidedFolders.sorted { $0.path < $1.path }
        let allProjects = snapshot.projects
        let allVMs = snapshot.vms
        let allQuotas = snapshot.quotas

        // Group VMs by environment and status
        var vmsByEnvironment: [String: Int] = [:]
        var vmsByStatus: [String: Int] = [:]
        var vmsByProject: [String: Int] = [:]

        let projectNames = Dictionary(
            allProjects.compactMap { project in project.id.map { ($0, project.name) } },
            uniquingKeysWith: { first, _ in first })

        for vm in allVMs {
            vmsByEnvironment[vm.environment, default: 0] += 1
            vmsByStatus[vm.status.rawValue, default: 0] += 1

            if let projectName = projectNames[vm.$project.id] {
                vmsByProject[projectName, default: 0] += 1
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

        // Usage totals, the organization's quotas and the hierarchy stats all
        // come off one load instead of re-deriving the same rows three times —
        // and off the caller's own view of it, so the totals never count rows
        // the tree above would not show them (issue #870).
        let snapshot = try await HierarchySnapshot.load(organizationID: organizationID, on: req.db)
            .readable(on: req)

        // Compliance is measured, not stored: `calculateActualUsage` sums every
        // row beneath the quota's node, so an organization-scoped quota reports
        // the *whole organization's* vCPU, memory and VM consumption. Reporting
        // it for a caller whose `resourceUsage` above was just narrowed to their
        // own rows would hand back the same totals through the other field —
        // the org-wide inventory in scalar form.
        //
        // `quota:read` on the node the quota hangs on is the check: unlike the
        // `org:read` that admits the quota *row* to a list, it is role-derived,
        // so a bare member does not hold it, while anyone with a viewer role at
        // organization level already sees the rows the total is drawn from.
        let quotaCompliance = try await QuotaComplianceService.complianceInfos(
            for: try await readableUsageQuotas(snapshot.quotas, on: req), on: req.db)

        return ResourceSummaryResponse(
            organizationId: organizationID,
            organizationName: organization.name,
            resourceUsage: snapshot.resourceUsage,
            quotaCompliance: quotaCompliance,
            hierarchyStats: HierarchyTreeBuilder.stats(for: snapshot)
        )
    }

    /// The quotas whose measured usage the caller may be told, decided in one
    /// batch (#687) on the node each hangs on.
    ///
    /// A quota has no node of its own, so the check lands on its
    /// org/folder/project — the container types `quota:read` is declared
    /// against (`CedarSchemaBuilder.resourceTypes`).
    private func readableUsageQuotas(_ quotas: [ResourceQuota], on req: Request) async throws -> [ResourceQuota] {
        func node(of quota: ResourceQuota) -> IAMNode? {
            if let projectID = quota.$project.id { return IAMNode(type: .project, id: projectID) }
            if let folderID = quota.$organizationalUnit.id {
                return IAMNode(type: .organizationalUnit, id: folderID)
            }
            if let organizationID = quota.$organization.id {
                return IAMNode(type: .organization, id: organizationID)
            }
            // A scopeless row measures nothing anyone here owns.
            return nil
        }

        let readable = try await req.canFilter("quota:read", on: quotas.compactMap(node))
        return quotas.filter { node(of: $0).map(readable.contains) ?? false }
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

        let results = try await HierarchySearchService.readable(
            try await HierarchySearchService.search(
                organizationID: organizationID,
                query: query,
                entityType: entityType,
                on: req.db
            ),
            on: req
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

        let results = try await HierarchySearchService.readable(
            try await HierarchySearchService.globalSearch(
                organizationIDs: organizationIDs,
                query: query,
                entityType: entityType,
                on: req.db
            ),
            on: req
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

        let fullPath = try await HierarchyPathResolver.buildEntityPath(
            entityType: entityType,
            entityID: entityID,
            organizationID: organizationID,
            on: req.db
        )
        // Names, decided per component — the same filter the tree and the search
        // results next door apply (issue #870).
        let pathComponents = try await HierarchyPathResolver.visibleComponents(fullPath, on: req)

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
