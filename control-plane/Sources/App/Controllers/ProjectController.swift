import Foundation
import Vapor
import Fluent

struct ProjectController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let projects = routes.grouped("api", "projects")

        // User's projects (across all organizations)
        projects.get(use: index)

        // Project-specific routes
        projects.group(":projectID") { project in
            project.get(use: show)
            project.put(use: update)
            project.delete(use: delete)
            project.get("stats", use: getStats)
            project.get("path", use: getPath)
            project.post("transfer", use: transfer)

            // Environment management
            project.post("environments", use: addEnvironment)
            project.delete("environments", ":environment", use: removeEnvironment)
        }

        // Organization context routes
        let organizations = routes.grouped("api", "organizations")
        organizations.group(":organizationID") { org in
            let orgProjects = org.grouped("projects")
            orgProjects.get(use: indexForOrganization)
            orgProjects.post(use: createInOrganization)

            // OU context routes
            org.group("ous", ":ouID", "projects") { ouProjects in
                ouProjects.get(use: indexForOU)
                ouProjects.post(use: createInOU)
            }
        }
    }

    // MARK: - Project CRUD Operations

    func index(req: Request) async throws -> [ProjectResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Get all organizations the user belongs to
        try await user.$organizations.load(on: req.db)
        let organizationIDs = user.organizations.compactMap { $0.id }

        if organizationIDs.isEmpty {
            return []
        }

        // Get all projects in user's organizations
        var allProjects: [Project] = []

        // Direct organization projects
        let directProjects = try await Project.query(on: req.db)
            .filter(\.$organization.$id ~~ organizationIDs)
            .sort(\.$name)
            .all()
        allProjects.append(contentsOf: directProjects)

        // Projects in OUs within user's organizations
        let ous = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id ~~ organizationIDs)
            .all()

        let ouIDs = ous.compactMap { $0.id }
        if !ouIDs.isEmpty {
            let ouProjects = try await Project.query(on: req.db)
                .filter(\.$organizationalUnit.$id ~~ ouIDs)
                .sort(\.$name)
                .all()
            allProjects.append(contentsOf: ouProjects)
        }

        // Convert to responses
        var responses: [ProjectResponse] = []
        for project in allProjects {
            guard let projectId = project.id else { continue }
            let vmCount = try await VM.query(on: req.db)
                .filter(\.$project.$id == projectId)
                .count()

            let response = ProjectResponse(from: project, vmCount: Int(vmCount))
            responses.append(response)
        }

        return responses
    }

    func show(req: Request) async throws -> ProjectResponse {
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

        // Get VM count
        let vmCount = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        // Get resource quotas
        let quotas = try await ResourceQuota.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .all()

        let quotaResponses = quotas.map { ResourceQuotaResponse(from: $0) }

        return ProjectResponse(from: project, vmCount: Int(vmCount), quotas: quotaResponses)
    }

    func update(req: Request) async throws -> ProjectResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        let updateRequest = try req.content.decode(UpdateProjectRequest.self)

        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Verify user has admin access to project
        try await verifyProjectAdminAccess(user: user, project: project, on: req.db)

        // Update fields
        if let name = updateRequest.name {
            // Check name uniqueness within parent scope
            try await validateProjectNameUniqueness(
                name: name,
                excludeProjectID: projectID,
                organizationID: project.$organization.id,
                ouID: project.$organizationalUnit.id,
                on: req.db
            )
            project.name = name
        }

        if let description = updateRequest.description {
            project.description = description
        }

        if let environments = updateRequest.environments {
            // Validate environments
            guard !environments.isEmpty else {
                throw Abort(.badRequest, reason: "Project must have at least one environment")
            }

            // Check if any VMs use environments that would be removed
            let currentEnvironments = Set(project.environments)
            let newEnvironments = Set(environments)
            let removedEnvironments = currentEnvironments.subtracting(newEnvironments)

            if !removedEnvironments.isEmpty {
                let vmsUsingRemovedEnvs = try await VM.query(on: req.db)
                    .filter(\.$project.$id == projectID)
                    .filter(\.$environment ~~ Array(removedEnvironments))
                    .count()

                if vmsUsingRemovedEnvs > 0 {
                    throw Abort(.conflict, reason: "Cannot remove environments that are in use by VMs: \(removedEnvironments.joined(separator: ", "))")
                }
            }

            project.environments = environments
        }

        if let defaultEnvironment = updateRequest.defaultEnvironment {
            // Ensure default environment is in environments list
            if !project.environments.contains(defaultEnvironment) {
                throw Abort(.badRequest, reason: "Default environment must be in the environments list")
            }
            project.defaultEnvironment = defaultEnvironment
        }

        try project.validate()
        try await project.save(on: req.db)

        // Update path if needed
        let newPath = try await project.buildPath(on: req.db)
        if newPath != project.path {
            project.path = newPath
            try await project.save(on: req.db)
        }

        // Get updated counts
        let vmCount = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        return ProjectResponse(from: project, vmCount: Int(vmCount))
    }

    func delete(req: Request) async throws -> HTTPStatus {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Verify user has admin access to project
        try await verifyProjectAdminAccess(user: user, project: project, on: req.db)

        // Check for dependent resources
        let vmCount = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        if vmCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete project with VMs. Delete or move VMs first.")
        }

        try await project.delete(on: req.db)
        return .noContent
    }

    // MARK: - Organization Context Operations

    func indexForOrganization(req: Request) async throws -> [ProjectResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        // Get direct projects in organization
        let projects = try await Project.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$name)
            .all()

        var responses: [ProjectResponse] = []
        for project in projects {
            guard let projectId = project.id else { continue }
            let vmCount = try await VM.query(on: req.db)
                .filter(\.$project.$id == projectId)
                .count()

            let response = ProjectResponse(from: project, vmCount: Int(vmCount))
            responses.append(response)
        }

        return responses
    }

    func createInOrganization(req: Request) async throws -> ProjectResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization ID")
        }

        let createRequest = try req.content.decode(CreateProjectRequest.self)

        // Verify organizationalUnitId is not provided for organization-level projects
        if createRequest.organizationalUnitId != nil {
            throw Abort(.badRequest, reason: "Cannot specify organizationalUnitId when creating project directly in organization")
        }

        // Verify user has access to create projects in organization
        try await verifyOrganizationMemberAccess(user: user, organizationID: organizationID, on: req.db)

        // Check name uniqueness within organization
        try await validateProjectNameUniqueness(
            name: createRequest.name,
            excludeProjectID: nil,
            organizationID: organizationID,
            ouID: nil,
            on: req.db
        )

        // Create project
        let project = try await createProject(
            createRequest: createRequest,
            organizationID: organizationID,
            ouID: nil,
            on: req.db
        )

        return ProjectResponse(from: project, vmCount: 0)
    }

    func indexForOU(req: Request) async throws -> [ProjectResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        // Verify user has access to organization
        try await verifyOrganizationAccess(user: user, organizationID: organizationID, on: req.db)

        // Get projects in OU
        let projects = try await Project.query(on: req.db)
            .filter(\.$organizationalUnit.$id == ouID)
            .sort(\.$name)
            .all()

        var responses: [ProjectResponse] = []
        for project in projects {
            guard let projectId = project.id else { continue }
            let vmCount = try await VM.query(on: req.db)
                .filter(\.$project.$id == projectId)
                .count()

            let response = ProjectResponse(from: project, vmCount: Int(vmCount))
            responses.append(response)
        }

        return responses
    }

    func createInOU(req: Request) async throws -> ProjectResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
              let ouID = req.parameters.get("ouID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        let createRequest = try req.content.decode(CreateProjectRequest.self)

        // Verify user has access to create projects in organization
        try await verifyOrganizationMemberAccess(user: user, organizationID: organizationID, on: req.db)

        // Verify OU exists and belongs to organization
        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Organizational unit not found")
        }

        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "OU does not belong to the specified organization")
        }

        // Check name uniqueness within OU
        try await validateProjectNameUniqueness(
            name: createRequest.name,
            excludeProjectID: nil,
            organizationID: nil,
            ouID: ouID,
            on: req.db
        )

        // Create project
        let project = try await createProject(
            createRequest: createRequest,
            organizationID: nil,
            ouID: ouID,
            on: req.db
        )

        return ProjectResponse(from: project, vmCount: 0)
    }

    // MARK: - Environment Management

    func addEnvironment(req: Request) async throws -> ProjectResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        let envRequest = try req.content.decode(ProjectEnvironmentRequest.self)

        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Verify user has admin access to project
        try await verifyProjectAdminAccess(user: user, project: project, on: req.db)

        // Add environment if not already present
        project.addEnvironment(envRequest.environment)
        try await project.save(on: req.db)

        let vmCount = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        return ProjectResponse(from: project, vmCount: Int(vmCount))
    }

    func removeEnvironment(req: Request) async throws -> ProjectResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self),
              let environment = req.parameters.get("environment") else {
            throw Abort(.badRequest, reason: "Invalid project ID or environment")
        }

        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Verify user has admin access to project
        try await verifyProjectAdminAccess(user: user, project: project, on: req.db)

        // Check if any VMs use this environment
        let vmsUsingEnv = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$environment == environment)
            .count()

        if vmsUsingEnv > 0 {
            throw Abort(.conflict, reason: "Cannot remove environment that is in use by VMs")
        }

        // Remove environment
        if !project.removeEnvironment(environment) {
            throw Abort(.badRequest, reason: "Cannot remove default environment or environment does not exist")
        }

        try await project.save(on: req.db)

        let vmCount = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        return ProjectResponse(from: project, vmCount: Int(vmCount))
    }

    // MARK: - Additional Operations

    func getStats(req: Request) async throws -> ProjectStatsResponse {
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

        // Get all VMs in project
        let vms = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .all()

        // Calculate stats by environment
        var vmsByEnvironment: [String: Int] = [:]
        for environment in project.environments {
            vmsByEnvironment[environment] = 0
        }

        var totalVCPUs = 0
        var totalMemory: Int64 = 0
        var totalStorage: Int64 = 0

        for vm in vms {
            vmsByEnvironment[vm.environment, default: 0] += 1
            totalVCPUs += vm.cpu
            totalMemory += vm.memory
            totalStorage += vm.disk
        }

        let resourceUsage = ResourceUsageResponse(
            totalVCPUs: totalVCPUs,
            totalMemoryGB: Double(totalMemory) / 1024 / 1024 / 1024,
            totalStorageGB: Double(totalStorage) / 1024 / 1024 / 1024,
            totalVMs: vms.count
        )

        return ProjectStatsResponse(
            totalVMs: vms.count,
            vmsByEnvironment: vmsByEnvironment,
            resourceUsage: resourceUsage
        )
    }

    func getPath(req: Request) async throws -> ProjectPathResponse {
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

        // Build full path with names
        var pathComponents: [ProjectPathComponent] = []

        if let orgID = project.$organization.id {
            if let org = try await Organization.find(orgID, on: req.db) {
                pathComponents.append(ProjectPathComponent(
                    id: orgID,
                    name: org.name,
                    type: "organization"
                ))
            }
        } else if let ouID = project.$organizationalUnit.id {
            // Build OU path
            var ouPath: [OrganizationalUnit] = []
            var currentOU = try await OrganizationalUnit.find(ouID, on: req.db)

            while let ou = currentOU {
                ouPath.insert(ou, at: 0)
                if let parentID = ou.$parentOU.id {
                    currentOU = try await OrganizationalUnit.find(parentID, on: req.db)
                } else {
                    // Add root organization
                    if let org = try await Organization.find(ou.$organization.id, on: req.db) {
                        pathComponents.append(ProjectPathComponent(
                            id: ou.$organization.id,
                            name: org.name,
                            type: "organization"
                        ))
                    }
                    break
                }
            }

            // Add all OUs in path
            for ou in ouPath {
                pathComponents.append(ProjectPathComponent(
                    id: ou.id!,
                    name: ou.name,
                    type: "organizational_unit"
                ))
            }
        }

        // Add project itself
        pathComponents.append(ProjectPathComponent(
            id: project.id!,
            name: project.name,
            type: "project"
        ))

        return ProjectPathResponse(
            projectId: project.id!,
            path: project.path,
            components: pathComponents
        )
    }

    func transfer(req: Request) async throws -> ProjectResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        let transferRequest = try req.content.decode(TransferProjectRequest.self)

        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Verify user has admin access to current location
        try await verifyProjectAdminAccess(user: user, project: project, on: req.db)

        // Verify user has access to destination
        if let destOrgID = transferRequest.organizationId {
            try await verifyOrganizationMemberAccess(user: user, organizationID: destOrgID, on: req.db)
        }

        // Validate destination
        if let destOuID = transferRequest.organizationalUnitId {
            guard let destOU = try await OrganizationalUnit.find(destOuID, on: req.db) else {
                throw Abort(.notFound, reason: "Destination OU not found")
            }

            if let destOrgID = transferRequest.organizationId {
                if destOU.$organization.id != destOrgID {
                    throw Abort(.badRequest, reason: "OU does not belong to specified organization")
                }
            }
        }

        // Check name uniqueness at destination
        try await validateProjectNameUniqueness(
            name: project.name,
            excludeProjectID: projectID,
            organizationID: transferRequest.organizationId,
            ouID: transferRequest.organizationalUnitId,
            on: req.db
        )

        // Update project
        project.$organization.id = transferRequest.organizationId
        project.$organizationalUnit.id = transferRequest.organizationalUnitId
        project.path = try await project.buildPath(on: req.db)

        try project.validate()
        try await project.save(on: req.db)

        let vmCount = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        return ProjectResponse(from: project, vmCount: Int(vmCount))
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

    private func verifyOrganizationMemberAccess(user: User, organizationID: UUID, on db: Database) async throws {
        let userOrg = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == organizationID)
            .first()

        guard userOrg != nil else {
            throw Abort(.forbidden, reason: "Not a member of this organization")
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

    private func validateProjectNameUniqueness(
        name: String,
        excludeProjectID: UUID?,
        organizationID: UUID?,
        ouID: UUID?,
        on db: Database
    ) async throws {
        let query = Project.query(on: db)
            .filter(\.$name == name)

        if let excludeID = excludeProjectID {
            query.filter(\.$id != excludeID)
        }

        if let orgID = organizationID {
            query.filter(\.$organization.$id == orgID)
        } else if let ouID = ouID {
            query.filter(\.$organizationalUnit.$id == ouID)
        }

        let existingProject = try await query.first()
        if existingProject != nil {
            throw Abort(.conflict, reason: "Project name already exists in this scope")
        }
    }

    private func createProject(
        createRequest: CreateProjectRequest,
        organizationID: UUID?,
        ouID: UUID?,
        on db: Database
    ) async throws -> Project {
        let environments = createRequest.environments ?? DeploymentEnvironment.defaults.map { $0.name }
        let defaultEnvironment = createRequest.defaultEnvironment ?? "development"

        // Validate default environment is in environments list
        if !environments.contains(defaultEnvironment) {
            throw Abort(.badRequest, reason: "Default environment must be in the environments list")
        }

        let project = Project(
            name: createRequest.name,
            description: createRequest.description,
            organizationID: organizationID,
            organizationalUnitID: ouID,
            path: "", // Will be updated after save
            defaultEnvironment: defaultEnvironment,
            environments: environments
        )

        try project.validate()
        try await project.save(on: db)

        // Update path with actual ID
        project.path = try await project.buildPath(on: db)
        try await project.save(on: db)

        return project
    }
}

// MARK: - Additional DTOs

struct TransferProjectRequest: Content {
    let organizationId: UUID?
    let organizationalUnitId: UUID?
}

struct ProjectPathComponent: Content {
    let id: UUID
    let name: String
    let type: String // "organization", "organizational_unit", "project"
}

struct ProjectPathResponse: Content {
    let projectId: UUID
    let path: String
    let components: [ProjectPathComponent]
}
