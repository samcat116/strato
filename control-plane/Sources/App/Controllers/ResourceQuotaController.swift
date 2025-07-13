import Foundation
import Vapor
import Fluent

struct ResourceQuotaController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Global quota routes
        let quotas = routes.grouped("quotas")
        quotas.get(use: indexByLevel) // Add route for /quotas?level=...
        quotas.group(":quotaID") { quota in
            quota.get(use: show)
            quota.put(use: update)
            quota.delete(use: delete)
            quota.get("usage", use: getUsage)
        }
        
        // Organization context routes
        let organizations = routes.grouped("organizations")
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
        let projects = routes.grouped("projects")
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
            
            let ouProjects = !ouIDs.isEmpty ? try await Project.query(on: req.db)
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
        try await verifyQuotaAccess(user: user, quota: quota, on: req.db)
        
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
        try await verifyQuotaAdminAccess(user: user, quota: quota, on: req.db)
        
        // Update fields
        if let name = updateRequest.name {
            quota.name = name
        }
        
        if let maxVCPUs = updateRequest.maxVCPUs {
            // Ensure new limit isn't below current reservation
            if maxVCPUs < quota.reservedVCPUs {
                throw Abort(.badRequest, reason: "New vCPU limit (\(maxVCPUs)) cannot be below current reservation (\(quota.reservedVCPUs))")
            }
            quota.maxVCPUs = maxVCPUs
        }
        
        if let maxMemoryGB = updateRequest.maxMemoryGB {
            let maxMemoryBytes = Int64(maxMemoryGB * 1024 * 1024 * 1024)
            if maxMemoryBytes < quota.reservedMemory {
                let currentReservedGB = Double(quota.reservedMemory) / 1024 / 1024 / 1024
                throw Abort(.badRequest, reason: "New memory limit (\(String(format: "%.2f", maxMemoryGB))GB) cannot be below current reservation (\(String(format: "%.2f", currentReservedGB))GB)")
            }
            quota.maxMemory = maxMemoryBytes
        }
        
        if let maxStorageGB = updateRequest.maxStorageGB {
            let maxStorageBytes = Int64(maxStorageGB * 1024 * 1024 * 1024)
            if maxStorageBytes < quota.reservedStorage {
                let currentReservedGB = Double(quota.reservedStorage) / 1024 / 1024 / 1024
                throw Abort(.badRequest, reason: "New storage limit (\(String(format: "%.2f", maxStorageGB))GB) cannot be below current reservation (\(String(format: "%.2f", currentReservedGB))GB)")
            }
            quota.maxStorage = maxStorageBytes
        }
        
        if let maxVMs = updateRequest.maxVMs {
            if maxVMs < quota.vmCount {
                throw Abort(.badRequest, reason: "New VM limit (\(maxVMs)) cannot be below current count (\(quota.vmCount))")
            }
            quota.maxVMs = maxVMs
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
        try await verifyQuotaAdminAccess(user: user, quota: quota, on: req.db)
        
        // Check if quota has any reservations
        if quota.reservedVCPUs > 0 || quota.reservedMemory > 0 || quota.reservedStorage > 0 || quota.vmCount > 0 {
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
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)
        
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
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)
        
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
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }
        
        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)
        
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
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }
        
        let createRequest = try req.content.decode(CreateResourceQuotaRequest.self)
        
        // Verify user has admin access to organization
        try await verifyOrganizationAdminAccess(user: user, organizationID: organizationID, on: req.db)
        
        // Verify OU exists and belongs to organization
        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Organizational unit not found")
        }
        
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "OU does not belong to the specified organization")
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
        try await verifyProjectAccess(user: user, project: project, on: req.db)
        
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
        try await verifyProjectAdminAccess(user: user, project: project, on: req.db)
        
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
        try await verifyQuotaAccess(user: user, quota: quota, on: req.db)
        
        // Get actual usage based on quota scope
        let (actualUsage, vms) = try await calculateActualUsage(quota: quota, on: req.db)
        
        // Calculate VM breakdown by environment
        var vmsByEnvironment: [String: Int] = [:]
        var vmsByStatus: [String: Int] = [:]
        
        for vm in vms {
            vmsByEnvironment[vm.environment, default: 0] += 1
            vmsByStatus[vm.status.rawValue, default: 0] += 1
        }
        
        return QuotaUsageResponse(
            quotaId: quota.id!,
            quotaName: quota.name,
            limits: QuotaLimits(
                maxVCPUs: quota.maxVCPUs,
                maxMemoryGB: Double(quota.maxMemory) / 1024 / 1024 / 1024,
                maxStorageGB: Double(quota.maxStorage) / 1024 / 1024 / 1024,
                maxVMs: quota.maxVMs,
                maxNetworks: quota.maxNetworks
            ),
            reserved: QuotaUsage(
                vcpus: quota.reservedVCPUs,
                memoryGB: Double(quota.reservedMemory) / 1024 / 1024 / 1024,
                storageGB: Double(quota.reservedStorage) / 1024 / 1024 / 1024,
                vms: quota.vmCount,
                networks: quota.networkCount
            ),
            actual: actualUsage,
            utilization: QuotaUtilization(
                cpuPercent: quota.cpuUtilizationPercent,
                memoryPercent: quota.memoryUtilizationPercent,
                storagePercent: quota.storageUtilizationPercent,
                vmPercent: quota.vmUtilizationPercent
            ),
            vmsByEnvironment: vmsByEnvironment,
            vmsByStatus: vmsByStatus,
            isEnabled: quota.isEnabled,
            environment: quota.environment
        )
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
    
    private func verifyProjectAccess(user: User, project: Project, on db: Database) async throws {
        let organizationID = try await project.getRootOrganizationId(on: db)
        guard let orgID = organizationID else {
            throw Abort(.internalServerError, reason: "Project has no organization")
        }
        
        try await verifyOrganizationAccess(user: user, organizationID: orgID, on: db)
    }
    
    private func verifyProjectAdminAccess(user: User, project: Project, on db: Database) async throws {
        let organizationID = try await project.getRootOrganizationId(on: db)
        guard let orgID = organizationID else {
            throw Abort(.internalServerError, reason: "Project has no organization")
        }
        
        let userOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == orgID)
            .first()
        
        guard let userOrganization = userOrg, userOrganization.role == "admin" else {
            throw Abort(.forbidden, reason: "Admin access required")
        }
    }
    
    private func verifyQuotaAccess(user: User, quota: ResourceQuota, on db: Database) async throws {
        if let orgID = quota.$organization.id {
            try await verifyOrganizationAccess(user: user, organizationID: orgID, on: db)
        } else if let ouID = quota.$organizationalUnit.id {
            let ou = try await OrganizationalUnit.find(ouID, on: db)
            try await verifyOrganizationAccess(user: user, organizationID: ou!.$organization.id, on: db)
        } else if let projectID = quota.$project.id {
            let project = try await Project.find(projectID, on: db)
            try await verifyProjectAccess(user: user, project: project!, on: db)
        }
    }
    
    private func verifyQuotaAdminAccess(user: User, quota: ResourceQuota, on db: Database) async throws {
        if let orgID = quota.$organization.id {
            try await verifyOrganizationAdminAccess(user: user, organizationID: orgID, on: db)
        } else if let ouID = quota.$organizationalUnit.id {
            let ou = try await OrganizationalUnit.find(ouID, on: db)
            try await verifyOrganizationAdminAccess(user: user, organizationID: ou!.$organization.id, on: db)
        } else if let projectID = quota.$project.id {
            let project = try await Project.find(projectID, on: db)
            try await verifyProjectAdminAccess(user: user, project: project!, on: db)
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
        let maxMemoryBytes = Int64(createRequest.maxMemoryGB * 1024 * 1024 * 1024)
        let maxStorageBytes = Int64(createRequest.maxStorageGB * 1024 * 1024 * 1024)
        
        let quota = ResourceQuota(
            name: createRequest.name,
            organizationID: organizationID,
            organizationalUnitID: ouID,
            projectID: projectID,
            maxVCPUs: createRequest.maxVCPUs,
            maxMemory: maxMemoryBytes,
            maxStorage: maxStorageBytes,
            maxVMs: createRequest.maxVMs,
            maxNetworks: createRequest.maxNetworks ?? 10,
            environment: createRequest.environment,
            isEnabled: createRequest.isEnabled ?? true
        )
        
        try quota.validate()
        try await quota.save(on: db)
        
        return quota
    }
    
    private func calculateActualUsage(quota: ResourceQuota, on db: Database) async throws -> (QuotaUsage, [VM]) {
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
}

// MARK: - Additional DTOs

struct QuotaLimits: Content {
    let maxVCPUs: Int
    let maxMemoryGB: Double
    let maxStorageGB: Double
    let maxVMs: Int
    let maxNetworks: Int
}

struct QuotaUsage: Content {
    let vcpus: Int
    let memoryGB: Double
    let storageGB: Double
    let vms: Int
    let networks: Int
}

struct QuotaUtilization: Content {
    let cpuPercent: Double
    let memoryPercent: Double
    let storagePercent: Double
    let vmPercent: Double
}

struct QuotaUsageResponse: Content {
    let quotaId: UUID
    let quotaName: String
    let limits: QuotaLimits
    let reserved: QuotaUsage
    let actual: QuotaUsage
    let utilization: QuotaUtilization
    let vmsByEnvironment: [String: Int]
    let vmsByStatus: [String: Int]
    let isEnabled: Bool
    let environment: String?
}