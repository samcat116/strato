import ControlPlanePostgres
import Foundation
import Vapor

struct ResourceQuotaController: RouteCollection {
    let quotas: ResourceQuotasPersistence
    let hierarchy: HierarchyPersistence
    let iam: IAMPersistence
    let projects: ProjectsPersistence

    func boot(routes: RoutesBuilder) throws {
        let quotas = routes.grouped("api", "quotas")
        quotas.get(use: indexByLevel)
        quotas.group(":quotaID") { quota in
            quota.get(use: show)
            quota.put(use: update)
            quota.delete(use: delete)
            quota.get("usage", use: getUsage)
        }
        routes.grouped("api", "organizations").group(":organizationID") { organization in
            organization.group("quotas") { scoped in
                scoped.get(use: indexForOrganization)
                scoped.post(use: createForOrganization)
            }
            organization.group("ous", ":ouID", "quotas") { scoped in
                scoped.get(use: indexForOU)
                scoped.post(use: createForOU)
            }
        }
        routes.grouped("api", "projects").group(":projectID", "quotas") { scoped in
            scoped.get(use: indexForProject)
            scoped.post(use: createForProject)
        }
    }

    func indexByLevel(req: Request) async throws -> PagedResponse<ResourceQuotaResponse> {
        let paging = try ListPaging.decode(from: req)
        guard let user = req.auth.get(User.self) else { throw Abort(.unauthorized) }
        let organizations = try await hierarchy.organizations(forUser: user.requireID())
        let organizationIDs = organizations.map(\.organization.id)
        let organizationalUnitIDs = try await hierarchy.organizationalUnitIDs(
            organizationIDs: organizationIDs
        )
        let visibility = try await ProjectVisibility.resolve(on: req, using: iam, projects: projects)
        let candidates = try await quotas.visibleCandidates(
            organizationIDs: organizationIDs,
            organizationalUnitIDs: organizationalUnitIDs,
            projectIDs: visibility.candidateProjectIDs,
            level: req.query[String.self, at: "level"]
        )
        var readable: [ResourceQuotaResponse] = []
        readable.reserveCapacity(candidates.count)
        for quota in candidates {
            guard let node = measuredNode(of: quota), try await req.can("quota:read", on: node) else {
                continue
            }
            readable.append(ResourceQuotaResponse(from: quota))
        }
        return paging.page(readable)
    }

    func show(req: Request) async throws -> ResourceQuotaResponse {
        _ = try req.auth.require(User.self)
        let quota = try await requireQuota(req)
        try await verifyRead(quota, req: req)
        return ResourceQuotaResponse(from: quota)
    }

    func update(req: Request) async throws -> ResourceQuotaResponse {
        _ = try req.auth.require(User.self)
        let existing = try await requireQuota(req)
        try await verifyAdmin(existing, req: req)
        let request = try req.content.decodeValidated(UpdateResourceQuotaRequest.self)
        if existing.environment != nil,
            request.maxNetworks != nil || request.maxLoadBalancers != nil
        {
            throw Abort(
                .badRequest,
                reason:
                    "Environment-scoped quotas cannot set network or load-balancer limits because those resources are project-wide"
            )
        }

        let usage = try await quotas.measure(existing)
        let maxVCPUs = request.maxVCPUs ?? existing.maxVCPUs
        let maxMemory = request.maxMemoryGB?.gbToBytes ?? existing.maxMemory
        let maxStorage = request.maxStorageGB?.gbToBytes ?? existing.maxStorage
        let maxVMs = request.maxVMs ?? existing.maxVMs
        let maxSandboxes = request.maxSandboxes ?? existing.maxSandboxes
        let maxVolumes = request.maxVolumes.map { $0 == 0 ? nil : $0 } ?? existing.maxVolumes
        let maxNetworks = request.maxNetworks ?? existing.maxNetworks
        let maxLoadBalancers = request.maxLoadBalancers ?? existing.maxLoadBalancers

        try validateLimits(
            maxVCPUs: maxVCPUs, maxMemory: maxMemory, maxStorage: maxStorage,
            maxVMs: maxVMs, maxSandboxes: maxSandboxes, maxVolumes: maxVolumes,
            maxNetworks: maxNetworks, maxLoadBalancers: maxLoadBalancers
        )
        try requireNotBelowUsage(
            usage, request: request, maxVCPUs: maxVCPUs, maxMemory: maxMemory,
            maxStorage: maxStorage, maxVMs: maxVMs, maxSandboxes: maxSandboxes,
            maxVolumes: maxVolumes, maxNetworks: maxNetworks,
            maxLoadBalancers: maxLoadBalancers
        )

        let name = request.name ?? existing.name
        if try await quotas.nameExists(
            name: name,
            organizationID: existing.organizationID,
            organizationalUnitID: existing.organizationalUnitID,
            projectID: existing.projectID,
            environment: existing.environment,
            excluding: existing.id
        ) {
            throw duplicateName(environment: existing.environment)
        }
        let write = ResourceQuotaWrite(
            id: existing.id, name: name,
            organizationID: existing.organizationID,
            organizationalUnitID: existing.organizationalUnitID,
            projectID: existing.projectID,
            maxVCPUs: maxVCPUs, maxMemory: maxMemory, maxStorage: maxStorage,
            maxVMs: maxVMs, maxSandboxes: maxSandboxes, maxVolumes: maxVolumes,
            maxNetworks: maxNetworks, maxLoadBalancers: maxLoadBalancers,
            isEnabled: request.isEnabled ?? existing.isEnabled,
            environment: existing.environment
        )
        do {
            guard let updated = try await quotas.replace(write, usage: usage) else {
                throw Abort(.notFound, reason: "Resource quota not found")
            }
            return ResourceQuotaResponse(from: updated)
        } catch ResourceQuotaPersistenceError.duplicateName {
            throw duplicateName(environment: existing.environment)
        }
    }

    func delete(req: Request) async throws -> HTTPStatus {
        _ = try req.auth.require(User.self)
        let quota = try await requireQuota(req)
        try await verifyAdmin(quota, req: req)
        do {
            guard try await quotas.deleteIfUnused(id: quota.id) else {
                throw Abort(.conflict, reason: "Cannot delete quota with active resource reservations")
            }
        } catch ResourceQuotaPersistenceError.notFound {
            throw Abort(.notFound, reason: "Resource quota not found")
        }
        return .noContent
    }

    func indexForOrganization(req: Request) async throws -> [ResourceQuotaResponse] {
        _ = try req.auth.require(User.self)
        let organizationID = try requireID("organizationID", reason: "Invalid organization ID", req: req)
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        return try await quotas.quotas(organizationID: organizationID)
            .map(ResourceQuotaResponse.init(from:))
    }

    func createForOrganization(req: Request) async throws -> ResourceQuotaResponse {
        _ = try req.auth.require(User.self)
        let organizationID = try requireID("organizationID", reason: "Invalid organization ID", req: req)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        let request = try req.content.decodeValidated(CreateResourceQuotaRequest.self)
        return try await create(
            request, organizationID: organizationID, organizationalUnitID: nil, projectID: nil)
    }

    func indexForOU(req: Request) async throws -> [ResourceQuotaResponse] {
        _ = try req.auth.require(User.self)
        let (organizationID, folder) = try await requireFolder(req)
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)
        return try await quotas.quotas(organizationalUnitID: folder.id)
            .map(ResourceQuotaResponse.init(from:))
    }

    func createForOU(req: Request) async throws -> ResourceQuotaResponse {
        _ = try req.auth.require(User.self)
        let (organizationID, folder) = try await requireFolder(req)
        try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        let request = try req.content.decodeValidated(CreateResourceQuotaRequest.self)
        return try await create(
            request, organizationID: nil, organizationalUnitID: folder.id, projectID: nil)
    }

    func indexForProject(req: Request) async throws -> [ResourceQuotaResponse] {
        _ = try req.auth.require(User.self)
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectMember(projectID: project.id, on: req)
        return try await quotas.quotas(projectID: project.id).map(ResourceQuotaResponse.init(from:))
    }

    func createForProject(req: Request) async throws -> ResourceQuotaResponse {
        _ = try req.auth.require(User.self)
        let project = try await requireProject(req)
        try await OrganizationAccessService.requireProjectQuotaAdmin(projectID: project.id, on: req)
        let request = try req.content.decodeValidated(CreateResourceQuotaRequest.self)
        if let environment = request.environment, !project.environments.contains(environment) {
            throw Abort(
                .badRequest,
                reason: "Environment '\(environment)' does not exist in this project"
            )
        }
        return try await create(
            request, organizationID: nil, organizationalUnitID: nil, projectID: project.id)
    }

    func getUsage(req: Request) async throws -> QuotaUsageResponse {
        _ = try req.auth.require(User.self)
        let quota = try await requireQuota(req)
        try await verifyRead(quota, req: req)
        return QuotaUsageService.usageResponse(
            for: quota,
            measured: try await quotas.usage(quota)
        )
    }

    private func create(
        _ request: CreateResourceQuotaRequest,
        organizationID: UUID?,
        organizationalUnitID: UUID?,
        projectID: UUID?
    ) async throws -> ResourceQuotaResponse {
        if request.environment != nil,
            request.maxNetworks != nil || request.maxLoadBalancers != nil
        {
            throw Abort(
                .badRequest,
                reason:
                    "Environment-scoped quotas cannot set network or load-balancer limits because those resources are project-wide"
            )
        }
        let maxSandboxes = request.maxSandboxes ?? request.maxVMs
        let maxNetworks = request.maxNetworks ?? 10
        let maxLoadBalancers = request.maxLoadBalancers ?? request.maxVMs
        try validateLimits(
            maxVCPUs: request.maxVCPUs, maxMemory: request.maxMemoryGB.gbToBytes,
            maxStorage: request.maxStorageGB.gbToBytes, maxVMs: request.maxVMs,
            maxSandboxes: maxSandboxes, maxVolumes: request.maxVolumes,
            maxNetworks: maxNetworks, maxLoadBalancers: maxLoadBalancers
        )
        if try await quotas.nameExists(
            name: request.name, organizationID: organizationID,
            organizationalUnitID: organizationalUnitID, projectID: projectID,
            environment: request.environment
        ) {
            throw duplicateName(environment: request.environment)
        }
        do {
            let quota = try await quotas.create(
                ResourceQuotaWrite(
                    name: request.name, organizationID: organizationID,
                    organizationalUnitID: organizationalUnitID, projectID: projectID,
                    maxVCPUs: request.maxVCPUs, maxMemory: request.maxMemoryGB.gbToBytes,
                    maxStorage: request.maxStorageGB.gbToBytes, maxVMs: request.maxVMs,
                    maxSandboxes: maxSandboxes, maxVolumes: request.maxVolumes,
                    maxNetworks: maxNetworks, maxLoadBalancers: maxLoadBalancers,
                    isEnabled: request.isEnabled ?? true, environment: request.environment
                )
            )
            return ResourceQuotaResponse(from: quota)
        } catch ResourceQuotaPersistenceError.duplicateName {
            throw duplicateName(environment: request.environment)
        }
    }

    private func verifyRead(_ quota: ResourceQuotaSnapshot, req: Request) async throws {
        guard let node = measuredNode(of: quota) else {
            _ = try await req.requireSystemAdmin("Quota has no scope")
            return
        }
        guard try await req.can("quota:read", on: node) else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }
    }

    private func verifyAdmin(_ quota: ResourceQuotaSnapshot, req: Request) async throws {
        if let organizationID = quota.organizationID {
            try await OrganizationAccessService.requireAdmin(organizationID: organizationID, on: req)
        } else if let folderID = quota.organizationalUnitID {
            guard let folder = try await hierarchy.organizationalUnit(id: folderID)?.organizationalUnit else {
                throw Abort(.notFound, reason: "Folder not found")
            }
            try await OrganizationAccessService.requireAdmin(
                organizationID: folder.organizationID, on: req)
        } else if let projectID = quota.projectID {
            try await OrganizationAccessService.requireProjectQuotaAdmin(projectID: projectID, on: req)
        } else {
            _ = try await req.requireSystemAdmin("Quota has no scope")
        }
    }

    private func measuredNode(of quota: ResourceQuotaSnapshot) -> IAMNode? {
        if let id = quota.projectID { return IAMNode(type: .project, id: id) }
        if let id = quota.organizationalUnitID { return IAMNode(type: .organizationalUnit, id: id) }
        if let id = quota.organizationID { return IAMNode(type: .organization, id: id) }
        return nil
    }

    private func requireQuota(_ req: Request) async throws -> ResourceQuotaSnapshot {
        let id = try requireID("quotaID", reason: "Invalid quota ID", req: req)
        guard let quota = try await quotas.quota(id: id) else {
            throw Abort(.notFound, reason: "Resource quota not found")
        }
        return quota
    }

    private func requireProject(_ req: Request) async throws -> ProjectSnapshot {
        let id = try requireID("projectID", reason: "Invalid project ID", req: req)
        guard let project = try await projects.project(id: id) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }

    private func requireFolder(_ req: Request) async throws -> (UUID, OrganizationalUnitSnapshot) {
        let organizationID = try requireID(
            "organizationID", reason: "Invalid organization or folder ID", req: req)
        let folderID = try requireID("ouID", reason: "Invalid organization or folder ID", req: req)
        guard let folder = try await hierarchy.organizationalUnit(id: folderID)?.organizationalUnit else {
            throw Abort(.notFound, reason: "Folder not found")
        }
        guard folder.organizationID == organizationID else {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }
        return (organizationID, folder)
    }

    private func requireID(_ name: String, reason: String, req: Request) throws -> UUID {
        guard let id = req.parameters.get(name, as: UUID.self) else {
            throw Abort(.badRequest, reason: reason)
        }
        return id
    }

    private func validateLimits(
        maxVCPUs: Int, maxMemory: Int64, maxStorage: Int64, maxVMs: Int,
        maxSandboxes: Int, maxVolumes: Int?, maxNetworks: Int,
        maxLoadBalancers: Int
    ) throws {
        guard maxVCPUs > 0, maxMemory > 0, maxStorage > 0, maxVMs > 0,
            maxSandboxes > 0, maxNetworks > 0, maxLoadBalancers > 0
        else { throw Abort(.badRequest, reason: "All resource limits must be positive") }
        if let maxVolumes, maxVolumes <= 0 {
            throw Abort(.badRequest, reason: "The volume limit must be positive when set")
        }
    }

    private func requireNotBelowUsage(
        _ usage: ResourceQuotaMeasuredUsage,
        request: UpdateResourceQuotaRequest,
        maxVCPUs: Int, maxMemory: Int64, maxStorage: Int64, maxVMs: Int,
        maxSandboxes: Int, maxVolumes: Int?, maxNetworks: Int,
        maxLoadBalancers: Int
    ) throws {
        if request.maxVCPUs != nil, maxVCPUs < usage.vcpus {
            throw Abort(.badRequest, reason: "New vCPU limit (\(maxVCPUs)) cannot be below current reservation (\(usage.vcpus))")
        }
        if let requested = request.maxMemoryGB, maxMemory < usage.memoryBytes {
            throw Abort(.badRequest, reason: "New memory limit (\(String(format: "%.2f", requested))GiB) cannot be below current reservation (\(String(format: "%.2f", usage.memoryBytes.bytesToGB))GiB)")
        }
        if let requested = request.maxStorageGB, maxStorage < usage.storageBytes {
            throw Abort(.badRequest, reason: "New storage limit (\(String(format: "%.2f", requested))GiB) cannot be below current reservation (\(String(format: "%.2f", usage.storageBytes.bytesToGB))GiB)")
        }
        if request.maxVMs != nil, maxVMs < usage.vmCount {
            throw Abort(.badRequest, reason: "New VM limit (\(maxVMs)) cannot be below current count (\(usage.vmCount))")
        }
        if request.maxSandboxes != nil, maxSandboxes < usage.sandboxCount {
            throw Abort(.badRequest, reason: "New sandbox limit (\(maxSandboxes)) cannot be below current count (\(usage.sandboxCount))")
        }
        if let requested = request.maxVolumes, requested != 0,
            let maxVolumes, maxVolumes < usage.volumeCount
        {
            throw Abort(.badRequest, reason: "New volume limit (\(maxVolumes)) cannot be below current count (\(usage.volumeCount))")
        }
        if request.maxNetworks != nil, maxNetworks < usage.networkCount {
            throw Abort(.badRequest, reason: "New network limit (\(maxNetworks)) cannot be below current count (\(usage.networkCount))")
        }
        if request.maxLoadBalancers != nil, maxLoadBalancers < usage.loadBalancerCount {
            throw Abort(.badRequest, reason: "New load balancer limit (\(maxLoadBalancers)) cannot be below current count (\(usage.loadBalancerCount))")
        }
    }

    private func duplicateName(environment: String?) -> Abort {
        let scope = environment.map { " for environment '\($0)'" } ?? ""
        return Abort(.conflict, reason: "Quota name already exists in this scope\(scope)")
    }
}
