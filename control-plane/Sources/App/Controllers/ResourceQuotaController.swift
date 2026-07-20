import Foundation
import Vapor
import Fluent

struct ResourceQuotaController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Global quota routes
        let quotas = routes.grouped("api", "quotas")
        quotas.get(use: indexByLevel)  // Add route for /quotas?level=...
        quotas.group(":quotaID") { quota in
            quota.get(use: show)
            quota.put(use: update)
            quota.delete(use: delete)
            quota.get("usage", use: getUsage)
        }

        // Organization context routes
        let organizations = routes.grouped("api", "organizations")
        organizations.group(":organizationID") { org in
            let orgQuotas = org.grouped("quotas")
            orgQuotas.get(use: indexForOrganization)
            orgQuotas.post(use: createForOrganization)

            // OU context routes
            org.group("ous", ":ouID", "quotas") { ouQuotas in
                ouQuotas.get(use: indexForOU)
                ouQuotas.post(use: createForOU)
            }
        }

        // Project context routes
        let projects = routes.grouped("api", "projects")
        projects.group(":projectID", "quotas") { projQuotas in
            projQuotas.get(use: indexForProject)
            projQuotas.post(use: createForProject)
        }
    }

    // MARK: - Resource Quota CRUD Operations

    func indexByLevel(req: Request) async throws -> [ResourceQuotaResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        let level = req.query[String.self, at: "level"]

        // Get all organizations the user belongs to
        try await user.$organizations.load(on: req.db)
        let organizationIDs = user.organizations.compactMap { $0.id }

        if organizationIDs.isEmpty {
            return []
        }

        var query = ResourceQuota.query(on: req.db)

        switch level {
        case "organization":
            query = query.filter(\.$organization.$id ~~ organizationIDs)
                .filter(\.$organizationalUnit.$id == nil)
                .filter(\.$project.$id == nil)
        case "project":
            // Get all projects in user's organizations
            let directProjects = try await Project.query(on: req.db)
                .filter(\.$organization.$id ~~ organizationIDs)
                .all()

            // Get all OUs in user's organizations
            let ous = try await OrganizationalUnit.query(on: req.db)
                .filter(\.$organization.$id ~~ organizationIDs)
                .all()
            let ouIDs = ous.compactMap { $0.id }

            let ouProjects =
                !ouIDs.isEmpty
                ? try await Project.query(on: req.db)
                    .filter(\.$organizationalUnit.$id ~~ ouIDs)
                    .all() : []

            let allProjects = directProjects + ouProjects
            let projectIDs = allProjects.compactMap { $0.id }

            if projectIDs.isEmpty {
                return []
            }
            query = query.filter(\.$project.$id ~~ projectIDs)
        case "organizational_unit":
            // Get all OUs in user's organizations
            let ous = try await OrganizationalUnit.query(on: req.db)
                .filter(\.$organization.$id ~~ organizationIDs)
                .all()
            let ouIDs = ous.compactMap { $0.id }
            if ouIDs.isEmpty {
                return []
            }
            query = query.filter(\.$organizationalUnit.$id ~~ ouIDs)
                .filter(\.$project.$id == nil)
        default:
            // No level specified, return all quotas in user's organizations
            query = query.group(.or) { or in
                or.filter(\.$organization.$id ~~ organizationIDs)
                // TODO: Add project and OU quota filtering for user access
            }
        }

        let quotas = try await query.sort(\.$name).all()
        return quotas.map { ResourceQuotaResponse(from: $0) }
    }

    func show(req: Request) async throws -> ResourceQuotaResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let quotaID = req.parameters.get("quotaID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid quota ID")
        }

        guard let quota = try await ResourceQuota.find(quotaID, on: req.db) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }

        // Verify user has access to quota
        try await verifyQuotaAccess(quota: quota, on: req)

        return ResourceQuotaResponse(from: quota)
    }

    func update(req: Request) async throws -> ResourceQuotaResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let quotaID = req.parameters.get("quotaID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid quota ID")
        }

        let updateRequest = try req.content.decode(UpdateResourceQuotaRequest.self)

        guard let quota = try await ResourceQuota.find(quotaID, on: req.db) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }

        // Verify user has admin access to quota
        try await verifyQuotaAdminAccess(quota: quota, on: req)

        // Update fields
        if let name = updateRequest.name {
            quota.name = name
        }

        if let maxVCPUs = updateRequest.maxVCPUs {
            // Ensure new limit isn't below current reservation
            if maxVCPUs < quota.reservedVCPUs {
                throw Abort(
                    .badRequest,
                    reason: "New vCPU limit (\(maxVCPUs)) cannot be below current reservation (\(quota.reservedVCPUs))")
            }
            quota.maxVCPUs = maxVCPUs
        }

        if let maxMemoryGB = updateRequest.maxMemoryGB {
            let maxMemoryBytes = maxMemoryGB.gbToBytes
            if maxMemoryBytes < quota.reservedMemory {
                let currentReservedGB = Double(quota.reservedMemory) / 1024 / 1024 / 1024
                throw Abort(
                    .badRequest,
                    reason:
                        "New memory limit (\(String(format: "%.2f", maxMemoryGB))GB) cannot be below current reservation (\(String(format: "%.2f", currentReservedGB))GB)"
                )
            }
            quota.maxMemory = maxMemoryBytes
        }

        if let maxStorageGB = updateRequest.maxStorageGB {
            let maxStorageBytes = maxStorageGB.gbToBytes
            if maxStorageBytes < quota.reservedStorage {
                let currentReservedGB = Double(quota.reservedStorage) / 1024 / 1024 / 1024
                throw Abort(
                    .badRequest,
                    reason:
                        "New storage limit (\(String(format: "%.2f", maxStorageGB))GB) cannot be below current reservation (\(String(format: "%.2f", currentReservedGB))GB)"
                )
            }
            quota.maxStorage = maxStorageBytes
        }

        if let maxVMs = updateRequest.maxVMs {
            if maxVMs < quota.vmCount {
                throw Abort(
                    .badRequest, reason: "New VM limit (\(maxVMs)) cannot be below current count (\(quota.vmCount))")
            }
            quota.maxVMs = maxVMs
        }

        if let maxSandboxes = updateRequest.maxSandboxes {
            if maxSandboxes < quota.sandboxCount {
                throw Abort(
                    .badRequest,
                    reason:
                        "New sandbox limit (\(maxSandboxes)) cannot be below current count (\(quota.sandboxCount))")
            }
            quota.maxSandboxes = maxSandboxes
        }

        if let maxNetworks = updateRequest.maxNetworks {
            quota.maxNetworks = maxNetworks
        }

        if let isEnabled = updateRequest.isEnabled {
            quota.isEnabled = isEnabled
        }

        try quota.validate()
        try await quota.save(on: req.db)

        return ResourceQuotaResponse(from: quota)
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let quotaID = req.parameters.get("quotaID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid quota ID")
        }

        guard let quota = try await ResourceQuota.find(quotaID, on: req.db) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }

        // Verify user has admin access to quota
        try await verifyQuotaAdminAccess(quota: quota, on: req)

        // Check if quota has any reservations
        if quota.reservedVCPUs > 0 || quota.reservedMemory > 0 || quota.reservedStorage > 0 || quota.vmCount > 0
            || quota.sandboxCount > 0
        {
            throw Abort(.conflict, reason: "Cannot delete quota with active resource reservations")
        }

        try await quota.delete(on: req.db)
        return .noContent
    }

    // MARK: - Organization Context Operations

    func indexForOrganization(req: Request) async throws -> [ResourceQuotaResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Get all quotas for the organization
        let quotas = try await ResourceQuota.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$name)
            .all()

        return quotas.map { ResourceQuotaResponse(from: $0) }
    }

    func createForOrganization(req: Request) async throws -> ResourceQuotaResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let createRequest = try req.content.decode(CreateResourceQuotaRequest.self)

        // Verify user has admin access to organization
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        // Check for duplicate quota name within organization
        try await validateQuotaNameUniqueness(
            name: createRequest.name,
            organizationID: organizationID,
            ouID: nil,
            projectID: nil,
            environment: createRequest.environment,
            excludeQuotaID: nil,
            on: req.db
        )

        // Create quota
        let quota = try await createQuota(
            createRequest: createRequest,
            organizationID: organizationID,
            ouID: nil,
            projectID: nil,
            on: req.db
        )

        return ResourceQuotaResponse(from: quota)
    }

    func indexForOU(req: Request) async throws -> [ResourceQuotaResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Verify the OU actually belongs to that organization. Membership in the
        // path org does not grant visibility into another org's OU — without this
        // check a member of org A could read org B's OU quotas by supplying B's OU id.
        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db),
            ou.$organization.id == organizationID
        else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        // Get all quotas for the OU
        let quotas = try await ResourceQuota.query(on: req.db)
            .filter(\.$organizationalUnit.$id == ouID)
            .sort(\.$name)
            .all()

        return quotas.map { ResourceQuotaResponse(from: $0) }
    }

    func createForOU(req: Request) async throws -> ResourceQuotaResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or folder ID")
        }

        let createRequest = try req.content.decode(CreateResourceQuotaRequest.self)

        // Verify user has admin access to organization
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)

        // Verify OU exists and belongs to organization
        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        // Check for duplicate quota name within OU
        try await validateQuotaNameUniqueness(
            name: createRequest.name,
            organizationID: nil,
            ouID: ouID,
            projectID: nil,
            environment: createRequest.environment,
            excludeQuotaID: nil,
            on: req.db
        )

        // Create quota
        let quota = try await createQuota(
            createRequest: createRequest,
            organizationID: nil,
            ouID: ouID,
            projectID: nil,
            on: req.db
        )

        return ResourceQuotaResponse(from: quota)
    }

    func indexForProject(req: Request) async throws -> [ResourceQuotaResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Verify user has access to project
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

        // Get all quotas for the project
        let quotas = try await ResourceQuota.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .sort(\.$name)
            .all()

        return quotas.map { ResourceQuotaResponse(from: $0) }
    }

    func createForProject(req: Request) async throws -> ResourceQuotaResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        let createRequest = try req.content.decode(CreateResourceQuotaRequest.self)

        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Verify user has admin access to project
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

        // Validate environment if specified
        if let environment = createRequest.environment {
            if !project.hasEnvironment(environment) {
                throw Abort(.badRequest, reason: "Environment '\(environment)' does not exist in this project")
            }
        }

        // Check for duplicate quota name within project
        try await validateQuotaNameUniqueness(
            name: createRequest.name,
            organizationID: nil,
            ouID: nil,
            projectID: projectID,
            environment: createRequest.environment,
            excludeQuotaID: nil,
            on: req.db
        )

        // Create quota
        let quota = try await createQuota(
            createRequest: createRequest,
            organizationID: nil,
            ouID: nil,
            projectID: projectID,
            on: req.db
        )

        return ResourceQuotaResponse(from: quota)
    }

    // MARK: - Usage Tracking

    func getUsage(req: Request) async throws -> QuotaUsageResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let quotaID = req.parameters.get("quotaID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid quota ID")
        }

        guard let quota = try await ResourceQuota.find(quotaID, on: req.db) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }

        // Verify user has access to quota
        try await verifyQuotaAccess(quota: quota, on: req)

        // Get actual usage based on quota scope
        let (actualUsage, vms, _) = try await quota.calculateActualUsage(on: req.db)

        return QuotaUsageService.usageResponse(for: quota, actualUsage: actualUsage, vms: vms)
    }

    // MARK: - Helper Methods

    private func verifyQuotaAccess(quota: ResourceQuota, on req: Request) async throws {
        if let orgID = quota.$organization.id {
            try await OrganizationAccessService.requireMember(organizationID: orgID, on: req)
        } else if let ouID = quota.$organizationalUnit.id {
            guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
                throw Abort(.notFound, reason: "Folder not found")
            }
            try await OrganizationAccessService.requireMember(organizationID: ou.$organization.id, on: req)
        } else if let projectID = quota.$project.id {
            guard let project = try await Project.find(projectID, on: req.db) else {
                throw Abort(.notFound, reason: "Project not found")
            }
            try await OrganizationAccessService.requireProjectMember(project: project, on: req)
        }
    }

    private func verifyQuotaAdminAccess(quota: ResourceQuota, on req: Request) async throws {
        if let orgID = quota.$organization.id {
            try await OrganizationAccessService.requireAdmin(organizationID: orgID, on: req)
        } else if let ouID = quota.$organizationalUnit.id {
            guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
                throw Abort(.notFound, reason: "Folder not found")
            }
            try await OrganizationAccessService.requireAdmin(organizationID: ou.$organization.id, on: req)
        } else if let projectID = quota.$project.id {
            guard let project = try await Project.find(projectID, on: req.db) else {
                throw Abort(.notFound, reason: "Project not found")
            }
            try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)
        }
    }

    private func validateQuotaNameUniqueness(
        name: String,
        organizationID: UUID?,
        ouID: UUID?,
        projectID: UUID?,
        environment: String?,
        excludeQuotaID: UUID?,
        on db: Database
    ) async throws {
        let query = ResourceQuota.query(on: db)
            .filter(\.$name == name)

        if let excludeID = excludeQuotaID {
            query.filter(\.$id != excludeID)
        }

        if let orgID = organizationID {
            query.filter(\.$organization.$id == orgID)
        } else if let ouID = ouID {
            query.filter(\.$organizationalUnit.$id == ouID)
        } else if let projID = projectID {
            query.filter(\.$project.$id == projID)
        }

        if let env = environment {
            query.filter(\.$environment == env)
        } else {
            query.filter(\.$environment == nil)
        }

        let existingQuota = try await query.first()
        if existingQuota != nil {
            let scope = environment.map { " for environment '\($0)'" } ?? ""
            throw Abort(.conflict, reason: "Quota name already exists in this scope\(scope)")
        }
    }

    private func createQuota(
        createRequest: CreateResourceQuotaRequest,
        organizationID: UUID?,
        ouID: UUID?,
        projectID: UUID?,
        on db: Database
    ) async throws -> ResourceQuota {
        let maxMemoryBytes = createRequest.maxMemoryGB.gbToBytes
        let maxStorageBytes = createRequest.maxStorageGB.gbToBytes

        let quota = ResourceQuota(
            name: createRequest.name,
            organizationID: organizationID,
            organizationalUnitID: ouID,
            projectID: projectID,
            maxVCPUs: createRequest.maxVCPUs,
            maxMemory: maxMemoryBytes,
            maxStorage: maxStorageBytes,
            maxVMs: createRequest.maxVMs,
            maxSandboxes: createRequest.maxSandboxes,
            maxNetworks: createRequest.maxNetworks ?? 10,
            environment: createRequest.environment,
            isEnabled: createRequest.isEnabled ?? true
        )

        try quota.validate()
        try await quota.save(on: db)

        return quota
    }

}
