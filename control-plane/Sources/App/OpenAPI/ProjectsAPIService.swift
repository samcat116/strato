import Fluent
import Foundation
import Vapor

/// The projects surface, served by the handlers swift-openapi-generator derives
/// from `openapi.yaml` (issue #583, the first controller migrated off
/// hand-written Vapor routes).
///
/// The generator emits `APIProtocol` from the operations listed in
/// `openapi-generator-config.yaml`, so the compiler — not a test — is what
/// guarantees this type serves exactly the operations the spec describes, with
/// the parameter and body types the spec declares. Routing, parameter decoding,
/// body decoding, and response encoding all come from the spec; what remains
/// here is the behaviour.
///
/// Errors are thrown as `Abort` rather than returned as typed
/// `.badRequest`/`.notFound` outputs. `OpenAPIRequestInjectionMiddleware`
/// unwraps them back out of `ServerError` so Vapor's `ErrorMiddleware` renders
/// the same envelope as every hand-written controller; the shared access-control
/// helpers throw `Abort` too, so this keeps one error path for the whole API.
struct ProjectsAPIService: APIProtocol {

    // MARK: - Project CRUD

    func listProjects(_ input: Operations.ListProjects.Input) async throws -> Operations.ListProjects.Output {
        let req = try OpenAPIRequestContext.require()
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Every organization the caller belongs to.
        try await user.$organizations.load(on: req.db)
        let organizationIDs = user.organizations.compactMap { $0.id }
        if organizationIDs.isEmpty {
            return .ok(.init(body: .json([])))
        }

        var allProjects = try await Project.query(on: req.db)
            .filter(\.$organization.$id ~~ organizationIDs)
            .sort(\.$name)
            .all()

        // Projects nested under folders (OUs) within those organizations.
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

        return .ok(.init(body: .json(try await summaries(for: allProjects, on: req.db))))
    }

    func getProject(_ input: Operations.GetProject.Input) async throws -> Operations.GetProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let project = try await Self.findProject(projectID, on: req.db)

        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

        let vmCount = try await Self.vmCount(projectID, on: req.db)
        let quotas = try await ResourceQuota.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .all()

        return .ok(.init(body: .json(try .init(project: project, vmCount: vmCount, quotas: quotas))))
    }

    func updateProject(_ input: Operations.UpdateProject.Input) async throws -> Operations.UpdateProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let update =
            switch input.body {
            case .json(let payload): payload
            }
        let project = try await Self.findProject(projectID, on: req.db)

        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

        if let name = update.name {
            try await Self.validateNameUniqueness(
                name: name,
                excludeProjectID: projectID,
                organizationID: project.$organization.id,
                ouID: project.$organizationalUnit.id,
                on: req.db
            )
            project.name = name
        }

        if let description = update.description {
            project.description = description
        }

        if let environments = update.environments {
            guard !environments.isEmpty else {
                throw Abort(.badRequest, reason: "Project must have at least one environment")
            }

            // Environments still in use by a VM or sandbox cannot be dropped.
            let removed = Set(project.environments).subtracting(Set(environments))
            if !removed.isEmpty {
                let vmsUsingRemoved = try await VM.query(on: req.db)
                    .filter(\.$project.$id == projectID)
                    .filter(\.$environment ~~ Array(removed))
                    .count()
                if vmsUsingRemoved > 0 {
                    throw Abort(
                        .conflict,
                        reason:
                            "Cannot remove environments that are in use by VMs: \(removed.joined(separator: ", "))"
                    )
                }

                let sandboxesUsingRemoved = try await Sandbox.query(on: req.db)
                    .filter(\.$project.$id == projectID)
                    .filter(\.$environment ~~ Array(removed))
                    .count()
                if sandboxesUsingRemoved > 0 {
                    throw Abort(
                        .conflict,
                        reason:
                            "Cannot remove environments that are in use by sandboxes: \(removed.joined(separator: ", "))"
                    )
                }
            }

            project.environments = environments
        }

        if let defaultEnvironment = update.defaultEnvironment {
            if !project.environments.contains(defaultEnvironment) {
                throw Abort(.badRequest, reason: "Default environment must be in the environments list")
            }
            project.defaultEnvironment = defaultEnvironment
        }

        try project.validate()
        try await project.save(on: req.db)

        // A rename moves the project within the hierarchy path.
        let newPath = try await project.buildPath(on: req.db)
        if newPath != project.path {
            project.path = newPath
            try await project.save(on: req.db)
        }

        let vmCount = try await Self.vmCount(projectID, on: req.db)
        return .ok(.init(body: .json(try .init(project: project, vmCount: vmCount))))
    }

    func deleteProject(_ input: Operations.DeleteProject.Input) async throws -> Operations.DeleteProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let project = try await Self.findProject(projectID, on: req.db)

        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

        let vmCount = try await Self.vmCount(projectID, on: req.db)
        if vmCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete project with VMs. Delete or move VMs first.")
        }

        let sandboxCount = try await Sandbox.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()
        if sandboxCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete project with sandboxes. Delete sandboxes first.")
        }

        // IAM dual-write (issue #477): bindings have no FK to the nodes they
        // protect, so drop the project node's bindings with the row — and the
        // roles it owns (issue #605), which would otherwise be bindable
        // nowhere while still shaping the Cedar schema. Removing roles is a
        // policy-set change and bumps the version.
        let removed = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
            // Service accounts cascade away with the project row, but their
            // bindings do not (no FK on either side): each account carries at
            // least its creator's binding on its own node, and may hold
            // bindings elsewhere as a principal. Sweep both directions before
            // the cascade, the same cleanup the account's own delete endpoint
            // performs (issue #491).
            let serviceAccountIDs = try await ServiceAccount.query(on: db)
                .filter(\.$project.$id == projectID)
                .all()
                .compactMap(\.id)
            for accountID in serviceAccountIDs {
                try await RoleBindingService.revokeAll(nodeType: .serviceAccount, nodeID: accountID, on: db)
                try await RoleBindingService.revokeAll(
                    principalType: .serviceAccount, principalID: accountID, on: db)
            }
            try await project.delete(on: db)
            try await RoleBindingService.revokeAll(nodeType: .project, nodeID: projectID, on: db)
            let removedRoles = try await RoleStore.deleteOwned(by: .project, ownerID: projectID, on: db)
            let removedPolicies = try await PolicyStore.deleteOwned(by: .project, ownerID: projectID, on: db)
            let removed = removedRoles + removedPolicies
            if removed > 0 {
                try await PolicySetVersionService.bump(
                    reason:
                        "project deleted: \(removedRoles) owned role(s), \(removedPolicies) owned policy(ies) removed",
                    on: db)
            }
            return removed
        }
        if removed > 0 {
            await req.application.announcePolicySetChange()
        }
        return .noContent(.init())
    }

    // MARK: - Organization and folder context

    func listOrganizationProjects(
        _ input: Operations.ListOrganizationProjects.Input
    ) async throws -> Operations.ListOrganizationProjects.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let organizationID = try Self.uuid(input.path.organizationID, name: "organization ID")

        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // The full project set within the organization's hierarchy, so callers
        // (e.g. the project switcher) can reach folder-scoped projects too.
        var projects = try await Project.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .sort(\.$name)
            .all()

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

        return .ok(.init(body: .json(try await summaries(for: projects, on: req.db))))
    }

    func createOrganizationProject(
        _ input: Operations.CreateOrganizationProject.Input
    ) async throws -> Operations.CreateOrganizationProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let organizationID = try Self.uuid(input.path.organizationID, name: "organization ID")
        let create =
            switch input.body {
            case .json(let payload): payload
            }

        if create.organizationalUnitId != nil {
            throw Abort(
                .badRequest,
                reason: "Cannot specify organizationalUnitId when creating project directly in organization")
        }

        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        try await Self.validateNameUniqueness(
            name: create.name,
            excludeProjectID: nil,
            organizationID: organizationID,
            ouID: nil,
            on: req.db
        )

        let project = try await Self.createProject(
            create,
            organizationID: organizationID,
            ouID: nil,
            on: req
        )
        return .ok(.init(body: .json(try .init(project: project, vmCount: 0))))
    }

    func listFolderProjects(
        _ input: Operations.ListFolderProjects.Input
    ) async throws -> Operations.ListFolderProjects.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let organizationID = try Self.uuid(input.path.organizationID, name: "organization ID")
        let ouID = try Self.uuid(input.path.ouID, name: "folder ID")

        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        // Verify the folder belongs to that organization. Without this a member
        // of org A could enumerate org B's projects by supplying B's folder id.
        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db),
            ou.$organization.id == organizationID
        else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        let projects = try await Project.query(on: req.db)
            .filter(\.$organizationalUnit.$id == ouID)
            .sort(\.$name)
            .all()

        return .ok(.init(body: .json(try await summaries(for: projects, on: req.db))))
    }

    func createFolderProject(
        _ input: Operations.CreateFolderProject.Input
    ) async throws -> Operations.CreateFolderProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let organizationID = try Self.uuid(input.path.organizationID, name: "organization ID")
        let ouID = try Self.uuid(input.path.ouID, name: "folder ID")
        let create =
            switch input.body {
            case .json(let payload): payload
            }

        try await OrganizationAccessService.requireMember(organizationID: organizationID, on: req)

        guard let ou = try await OrganizationalUnit.find(ouID, on: req.db) else {
            throw Abort(.notFound, reason: "Folder not found")
        }
        if ou.$organization.id != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        try await Self.validateNameUniqueness(
            name: create.name,
            excludeProjectID: nil,
            organizationID: nil,
            ouID: ouID,
            on: req.db
        )

        let project = try await Self.createProject(
            create,
            organizationID: nil,
            ouID: ouID,
            on: req
        )
        return .ok(.init(body: .json(try .init(project: project, vmCount: 0))))
    }

    // MARK: - Environments

    func addProjectEnvironment(
        _ input: Operations.AddProjectEnvironment.Input
    ) async throws -> Operations.AddProjectEnvironment.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let environment =
            switch input.body {
            case .json(let payload): payload.environment
            }
        let project = try await Self.findProject(projectID, on: req.db)

        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

        project.addEnvironment(environment)
        try await project.save(on: req.db)

        let vmCount = try await Self.vmCount(projectID, on: req.db)
        return .ok(.init(body: .json(try .init(project: project, vmCount: vmCount))))
    }

    func removeProjectEnvironment(
        _ input: Operations.RemoveProjectEnvironment.Input
    ) async throws -> Operations.RemoveProjectEnvironment.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let environment = input.path.environment
        let project = try await Self.findProject(projectID, on: req.db)

        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

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

        if !project.removeEnvironment(environment) {
            throw Abort(.badRequest, reason: "Cannot remove default environment or environment does not exist")
        }
        try await project.save(on: req.db)

        let vmCount = try await Self.vmCount(projectID, on: req.db)
        return .ok(.init(body: .json(try .init(project: project, vmCount: vmCount))))
    }

    // MARK: - Stats, path, transfer

    func getProjectStats(
        _ input: Operations.GetProjectStats.Input
    ) async throws -> Operations.GetProjectStats.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let project = try await Self.findProject(projectID, on: req.db)

        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

        let vms = try await VM.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .all()

        return .ok(.init(body: .json(.init(stats: ProjectStatsService.stats(for: project, vms: vms)))))
    }

    func getProjectPath(_ input: Operations.GetProjectPath.Input) async throws -> Operations.GetProjectPath.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let project = try await Self.findProject(projectID, on: req.db)

        try await OrganizationAccessService.requireProjectMember(project: project, on: req)

        var components: [Components.Schemas.ProjectPathComponent] = []

        if let orgID = project.$organization.id {
            if let org = try await Organization.find(orgID, on: req.db) {
                components.append(.init(id: orgID.uuidString, name: org.name, _type: .organization))
            }
        } else if let ouID = project.$organizationalUnit.id {
            // Walk up to the root organization, then emit the folders top-down.
            var ouPath: [OrganizationalUnit] = []
            var currentOU = try await OrganizationalUnit.find(ouID, on: req.db)

            while let ou = currentOU {
                ouPath.insert(ou, at: 0)
                if let parentID = ou.$parentOU.id {
                    currentOU = try await OrganizationalUnit.find(parentID, on: req.db)
                } else {
                    if let org = try await Organization.find(ou.$organization.id, on: req.db) {
                        components.append(
                            .init(id: ou.$organization.id.uuidString, name: org.name, _type: .organization))
                    }
                    break
                }
            }

            for ou in ouPath {
                components.append(
                    .init(id: try ou.requireID().uuidString, name: ou.name, _type: .organizationalUnit))
            }
        }

        components.append(.init(id: projectID.uuidString, name: project.name, _type: .project))

        return .ok(
            .init(
                body: .json(
                    .init(
                        projectId: projectID.uuidString,
                        path: project.path,
                        components: components
                    ))))
    }

    func transferProject(_ input: Operations.TransferProject.Input) async throws -> Operations.TransferProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let transfer =
            switch input.body {
            case .json(let payload): payload
            }
        let destinationOrganizationIDParam = try transfer.organizationId.map {
            try Self.uuid($0, name: "organization ID")
        }
        let destinationOUID = try transfer.organizationalUnitId.map { try Self.uuid($0, name: "folder ID") }
        let project = try await Self.findProject(projectID, on: req.db)

        try await OrganizationAccessService.requireProjectAdmin(project: project, on: req)

        // Resolve and validate the destination, deriving its root organization.
        let destinationOrganizationID: UUID?
        if let destOuID = destinationOUID {
            guard let destOU = try await OrganizationalUnit.find(destOuID, on: req.db) else {
                throw Abort(.notFound, reason: "Destination folder not found")
            }
            if let destOrgID = destinationOrganizationIDParam, destOU.$organization.id != destOrgID {
                throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
            }
            destinationOrganizationID = destOU.$organization.id
        } else {
            destinationOrganizationID = destinationOrganizationIDParam
        }

        guard let destinationOrganizationID else {
            throw Abort(.badRequest, reason: "Transfer must specify a destination organization or folder")
        }

        // Moving a project requires admin on the destination organization, not
        // just membership — otherwise a member could relocate projects into orgs
        // they do not administer.
        try await OrganizationAccessService.requireAdmin(organizationID: destinationOrganizationID, on: req)

        try await Self.validateNameUniqueness(
            name: project.name,
            excludeProjectID: projectID,
            organizationID: destinationOrganizationIDParam,
            ouID: destinationOUID,
            on: req.db
        )

        project.$organization.id = destinationOrganizationIDParam
        project.$organizationalUnit.id = destinationOUID
        project.path = try await project.buildPath(on: req.db)

        try project.validate()
        try await project.save(on: req.db)

        let vmCount = try await Self.vmCount(projectID, on: req.db)
        return .ok(.init(body: .json(try .init(project: project, vmCount: vmCount))))
    }

    // MARK: - Helpers

    private func summaries(for projects: [Project], on db: any Database) async throws
        -> [Components.Schemas.ProjectSummary]
    {
        var summaries: [Components.Schemas.ProjectSummary] = []
        for project in projects {
            guard let projectID = project.id else { continue }
            let vmCount = try await Self.vmCount(projectID, on: db)
            summaries.append(try .init(project: project, vmCount: vmCount))
        }
        return summaries
    }

    /// The authentication middlewares run ahead of every API route, so this only
    /// fires if one is ever removed — kept so an unauthenticated request answers
    /// `401` rather than the `403` the authorization helpers would produce.
    private static func requireAuthenticated(_ req: Request) throws {
        guard req.auth.has(User.self) else {
            throw Abort(.unauthorized)
        }
    }

    /// Path parameters are `format: uuid` strings on the wire; the spec cannot
    /// express the parse, so a malformed id is a 400 like it was before.
    private static func uuid(_ raw: String, name: String) throws -> UUID {
        guard let uuid = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name)")
        }
        return uuid
    }

    private static func findProject(_ projectID: UUID, on db: any Database) async throws -> Project {
        guard let project = try await Project.find(projectID, on: db) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }

    private static func vmCount(_ projectID: UUID, on db: any Database) async throws -> Int {
        Int(
            try await VM.query(on: db)
                .filter(\.$project.$id == projectID)
                .count())
    }

    private static func validateNameUniqueness(
        name: String,
        excludeProjectID: UUID?,
        organizationID: UUID?,
        ouID: UUID?,
        on db: any Database
    ) async throws {
        let query = Project.query(on: db)
            .filter(\.$name == name)

        if let excludeProjectID {
            query.filter(\.$id != excludeProjectID)
        }

        if let organizationID {
            query.filter(\.$organization.$id == organizationID)
        } else if let ouID {
            query.filter(\.$organizationalUnit.$id == ouID)
        }

        if try await query.first() != nil {
            throw Abort(.conflict, reason: "Project name already exists in this scope")
        }
    }

    private static func createProject(
        _ create: Components.Schemas.CreateProjectRequest,
        organizationID: UUID?,
        ouID: UUID?,
        on req: Request
    ) async throws -> Project {
        let environments = create.environments ?? DeploymentEnvironment.defaults.map { $0.name }
        let defaultEnvironment = create.defaultEnvironment ?? "development"

        if !environments.contains(defaultEnvironment) {
            throw Abort(.badRequest, reason: "Default environment must be in the environments list")
        }

        let project = Project(
            name: create.name,
            description: create.description,
            organizationID: organizationID,
            organizationalUnitID: ouID,
            path: "",  // Filled in after save: the path embeds the generated id.
            defaultEnvironment: defaultEnvironment,
            environments: environments
        )

        try project.validate()

        // Persist the project (two saves, for the path) and the creator's
        // explicit admin binding in one transaction, so a member-created project
        // always has an administrator besides org admins.
        let creatorID = req.auth.get(User.self)?.id
        try await req.db.transaction { transaction in
            try await project.save(on: transaction)
            project.path = try await project.buildPath(on: transaction)
            try await project.save(on: transaction)
            if let creatorID {
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: creatorID,
                    role: .admin,
                    nodeType: .project,
                    nodeID: try project.requireID(),
                    createdBy: creatorID,
                    on: transaction
                )
            }
        }

        return project
    }
}
