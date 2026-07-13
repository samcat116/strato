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

        req.logger.info("ProjectController.index - User: \(user.username), ID: \(user.id?.uuidString ?? "nil")")

        // Get all organizations the user belongs to
        try await user.$organizations.load(on: req.db)
        let organizationIDs = user.organizations.compactMap { $0.id }

        req.logger.info(
            "ProjectController.index - Found \(organizationIDs.count) organizations: \(organizationIDs.map { $0.uuidString })"
        )

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
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

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
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

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
                    throw Abort(
                        .conflict,
                        reason:
                            "Cannot remove environments that are in use by VMs: \(removedEnvironments.joined(separator: ", "))"
                    )
                }

                let sandboxesUsingRemovedEnvs = try await Sandbox.query(on: req.db)
                    .filter(\.$project.$id == projectID)
                    .filter(\.$environment ~~ Array(removedEnvironments))
                    .count()

                if sandboxesUsingRemovedEnvs > 0 {
                    throw Abort(
                        .conflict,
                        reason:
                            "Cannot remove environments that are in use by sandboxes: \(removedEnvironments.joined(separator: ", "))"
                    )
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
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

        // Check for dependent resources
        let vmCount = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        if vmCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete project with VMs. Delete or move VMs first.")
        }

        let sandboxCount = try await Sandbox.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        if sandboxCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete project with sandboxes. Delete sandboxes first.")
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
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Return the full project set within the organization's hierarchy so
        // callers (e.g. the project switcher) can reach OU-scoped projects too.
        var projects = try await Project.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$name)
            .all()

        // Projects nested under organizational units within this organization.
        let ous = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()
        let ouIDs = ous.compactMap { $0.id }
        if !ouIDs.isEmpty {
            let ouProjects = try await Project.query(on: req.db)
                .filter(\.$organizationalUnit.$id ~~ ouIDs)
                .sort(\.$name)
                .all()
            projects.append(contentsOf: ouProjects)
        }

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
            throw Abort(
                .badRequest,
                reason: "Cannot specify organizationalUnitId when creating project directly in organization")
        }

        // Verify user has access to create projects in organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

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
            on: req
        )

        return ProjectResponse(from: project, vmCount: 0)
    }

    func indexForOU(req: Request) async throws -> [ProjectResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let organizationID = req.parameters.get("organizationID", as: UUID.self),
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        // Verify user has access to organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Verify the OU actually belongs to that organization. Without this a member
        // of org A could enumerate org B's projects by supplying B's OU id.
        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db),
            ou.$organization.id == organizationID
        else {
            throw Abort(.notFound, reason: "Organizational unit not found")
        }

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
            let ouID = req.parameters.get("ouID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid organization or OU ID")
        }

        let createRequest = try req.content.decode(CreateProjectRequest.self)

        // Verify user has access to create projects in organization
        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

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
            on: req
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
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

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
            let environment = req.parameters.get("environment")
        else {
            throw Abort(.badRequest, reason: "Invalid project ID or environment")
        }

        guard let project = try await Project.find(projectID, on: req.db) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Verify user has admin access to project
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

        // Check if any VMs use this environment
        let vmsUsingEnv = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$environment == environment)
            .count()

        if vmsUsingEnv > 0 {
            throw Abort(.conflict, reason: "Cannot remove environment that is in use by VMs")
        }

        let sandboxesUsingEnv = try await Sandbox.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .filter(\.$environment == environment)
            .count()

        if sandboxesUsingEnv > 0 {
            throw Abort(.conflict, reason: "Cannot remove environment that is in use by sandboxes")
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
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

        // Get all VMs in project
        let vms = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .all()

        return ProjectStatsService.stats(for: project, vms: vms)
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
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

        // Build full path with names
        var pathComponents: [ProjectPathComponent] = []

        if let orgID = project.$organization.id {
            if let org = try await Organization.find(orgID, on: req.db) {
                pathComponents.append(
                    ProjectPathComponent(
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
                        pathComponents.append(
                            ProjectPathComponent(
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
                pathComponents.append(
                    ProjectPathComponent(
                        id: ou.id!,
                        name: ou.name,
                        type: "organizational_unit"
                    ))
            }
        }

        // Add project itself
        pathComponents.append(
            ProjectPathComponent(
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
        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

        // Capture the current immediate parent so we can migrate the SpiceDB
        // project#parent tuple if the destination is a different parent.
        let oldParentRef = project.spiceDBParentRef

        // Resolve and validate the destination, deriving its root organization.
        let destinationOrganizationID: UUID?
        if let destOuID = transferRequest.organizationalUnitId {
            guard let destOU = try await OrganizationalUnit.find(destOuID, on: req.db) else {
                throw Abort(.notFound, reason: "Destination OU not found")
            }
            if let destOrgID = transferRequest.organizationId, destOU.$organization.id != destOrgID {
                throw Abort(.badRequest, reason: "OU does not belong to specified organization")
            }
            destinationOrganizationID = destOU.$organization.id
        } else {
            destinationOrganizationID = transferRequest.organizationId
        }

        guard let destinationOrganizationID else {
            throw Abort(.badRequest, reason: "Transfer must specify a destination organization or organizational unit")
        }

        // Moving a project requires admin on the destination organization, not
        // just membership — otherwise a member could relocate projects into orgs
        // they do not administer.
        try await OrganizationAccessService.requireAdmin(
            organizationID: destinationOrganizationID,
            on: req
        )

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

        // Migrate the project#parent SpiceDB tuple when the *immediate* parent
        // changes — including org→OU moves within the same root org, which a
        // root-org comparison would miss. Project-scoped permissions resolve through
        // this parent, so a stale tuple leaves destination admins with 403s and the
        // source retaining access (issue #267).
        let newParentRef = project.spiceDBParentRef
        if oldParentRef?.subjectType != newParentRef?.subjectType
            || oldParentRef?.subjectId != newParentRef?.subjectId
        {
            if let oldParentRef {
                try await req.spicedb.deleteRelationship(
                    entity: "project",
                    entityId: projectID.uuidString,
                    relation: "parent",
                    subject: oldParentRef.subjectType,
                    subjectId: oldParentRef.subjectId.uuidString
                )
            }
            if let newParentRef {
                try await req.spicedb.writeRelationship(
                    entity: "project",
                    entityId: projectID.uuidString,
                    relation: "parent",
                    subject: newParentRef.subjectType,
                    subjectId: newParentRef.subjectId.uuidString
                )
            }
        }

        let vmCount = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()

        return ProjectResponse(from: project, vmCount: Int(vmCount))
    }

    // MARK: - Helper Methods

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
        on req: Request
    ) async throws -> Project {
        let db = req.db
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
            path: "",  // Will be updated after save
            defaultEnvironment: defaultEnvironment,
            environments: environments
        )

        try project.validate()
        try await project.save(on: db)

        // Update path with actual ID
        project.path = try await project.buildPath(on: db)
        try await project.save(on: db)

        // Write the SpiceDB project#parent tuple against the *immediate* parent (the
        // OU when OU-scoped, else the organization) using the persisted project id.
        // Without it, project-scoped permissions can't resolve and even the creating
        // admin gets 403s; pointing at the immediate parent is what lets OU-scoped
        // projects inherit from the OU chain (see issue #267).
        guard let projectId = project.id else {
            throw Abort(.internalServerError, reason: "Project was not assigned an ID after save")
        }
        guard let parent = project.spiceDBParentRef else {
            throw Abort(.internalServerError, reason: "Project has no parent")
        }
        try await req.spicedb.writeRelationship(
            entity: "project",
            entityId: projectId.uuidString,
            relation: "parent",
            subject: parent.subjectType,
            subjectId: parent.subjectId.uuidString
        )

        return project
    }
}
