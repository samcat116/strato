import ControlPlanePostgres
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
    let database: PostgresStoreContext
    let projects: ProjectsPersistence
    let quotas: ResourceQuotasPersistence
    let iam: IAMPersistence
    let hierarchy: HierarchyPersistence

    // MARK: - Project CRUD

    func listProjects(_ input: Operations.ListProjects.Input) async throws -> Operations.ListProjects.Output {
        let req = try OpenAPIRequestContext.require()
        guard let user = req.auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }

        // Preserve the existing membership boundary of this unscoped endpoint:
        // a direct binding in an unrelated organization does not make that
        // organization's project appear in the global project switcher.
        let organizationIDs = try await hierarchy.organizations(forUser: userID)
            .map(\.organization.id)
        if organizationIDs.isEmpty {
            return .ok(.init(body: .json([])))
        }

        let membershipCandidates = Set(
            try await projects.candidateProjectIDs(
                organizationIDs: organizationIDs,
                organizationalUnitIDs: [],
                projectIDs: []
            )
        )
        let visibility = try await ProjectVisibility.resolve(
            on: req, using: iam, projects: projects)
        if visibility.reachesNoProject {
            return .ok(.init(body: .json([])))
        }
        let candidateIDs: [UUID]
        if let visibleCandidates = visibility.candidateProjectIDs {
            candidateIDs = Array(membershipCandidates.intersection(visibleCandidates))
        } else {
            candidateIDs = Array(membershipCandidates)
        }
        let overviews = try await projects.projectOverviews(ids: candidateIDs)
        let readable = try await visibility.readableProjects(
            among: overviews.map(\.project.id), on: req)
        return .ok(.init(body: .json(
            overviews.compactMap { overview in
                guard readable.contains(overview.project.id) else { return nil }
                return .init(
                    project: overview.project,
                    vmCount: overview.virtualMachineCount
                )
            }
        )))
    }

    func getProject(_ input: Operations.GetProject.Input) async throws -> Operations.GetProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        guard let overview = try await projects.projectOverview(id: projectID) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        try await OrganizationAccessService.requireProjectMember(projectID: projectID, on: req)
        let projectQuotas = try await quotas.quotas(projectID: projectID)

        return .ok(.init(body: .json(.init(
            project: overview.project,
            vmCount: overview.virtualMachineCount,
            quotas: projectQuotas
        ))))
    }

    func updateProject(_ input: Operations.UpdateProject.Input) async throws -> Operations.UpdateProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let update =
            switch input.body {
            case .json(let payload): payload
            }
        guard let current = try await projects.project(id: projectID) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        try await OrganizationAccessService.requireProjectAction(
            "project:update", projectID: projectID, on: req)

        let destinationOrganizationIDParam = try update.organizationId.map {
            try Self.uuid($0, name: "organization ID")
        }
        let destinationOUID = try update.organizationalUnitId.map {
            try Self.uuid($0, name: "folder ID")
        }

        if destinationOrganizationIDParam == nil, destinationOUID == nil {
            let name = try update.name.map { try Validate.name($0) } ?? current.name
            let description = update.description ?? current.description
            try Validate.text(description)
            let environments = try update.environments.map(Self.normalizedEnvironments)
                ?? current.environments
            guard !environments.isEmpty else {
                throw Abort(.badRequest, reason: "Project must have at least one environment")
            }
            let defaultEnvironment = try update.defaultEnvironment.map {
                try Validate.name($0, "defaultEnvironment")
            } ?? current.defaultEnvironment
            guard environments.contains(defaultEnvironment) else {
                throw Abort(.badRequest, reason: "Default environment must be in the environments list")
            }
            switch try await projects.updateMetadata(.init(
                id: projectID,
                name: name,
                description: description,
                defaultEnvironment: defaultEnvironment,
                environments: environments
            )) {
            case .updated(let overview):
                return .ok(.init(body: .json(.init(
                    project: overview.project,
                    vmCount: overview.virtualMachineCount
                ))))
            case .notFound:
                throw Abort(.notFound, reason: "Project not found")
            case .duplicateName:
                throw Abort(.conflict, reason: "Project name already exists in this scope")
            case .environmentsInUseByVirtualMachines(let removed):
                throw Abort(
                    .conflict,
                    reason: "Cannot remove environments that are in use by VMs: \(removed.joined(separator: ", "))"
                )
            case .environmentsInUseBySandboxes(let removed):
                throw Abort(
                    .conflict,
                    reason: "Cannot remove environments that are in use by sandboxes: \(removed.joined(separator: ", "))"
                )
            }
        }

        let destination = try await resolveDestination(
            organizationID: destinationOrganizationIDParam,
            ouID: destinationOUID,
            required: true)
        guard let destination else {
            throw Abort(.badRequest, reason: "Transfer must specify a destination organization or folder")
        }
        try await OrganizationAccessService.requireProjectAction(
            "project:transfer", projectID: projectID, on: req)
        try await OrganizationAccessService.requireAdmin(
            organizationID: destination.rootOrganizationID, on: req)

        let metadata = try Self.projectMetadata(current: current, update: update)
        let overview = try Self.requireTransferredProject(
            try await projects.transfer(.init(
                project: metadata,
                organizationID: destination.organizationID,
                organizationalUnitID: destination.ouID
            )))
        return .ok(.init(body: .json(.init(
            project: overview.project,
            vmCount: overview.virtualMachineCount
        ))))
    }

    func deleteProject(_ input: Operations.DeleteProject.Input) async throws -> Operations.DeleteProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let project = try await Self.findProject(projectID, on: database)

        try await OrganizationAccessService.requireProjectAction("project:delete", project: project, on: req)

        let vmCount = try await Self.vmCount(projectID, on: database)
        if vmCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete project with VMs. Delete or move VMs first.")
        }

        let sandboxCount = try await LegacySandboxStore.sandboxes(
            projectID: projectID, on: database).count
        if sandboxCount > 0 {
            throw Abort(.conflict, reason: "Cannot delete project with sandboxes. Delete sandboxes first.")
        }

        // IAM dual-write (issue #477): bindings have no FK to the nodes they
        // protect, so drop the project node's bindings with the row — and the
        // roles it owns (issue #605), which would otherwise be bindable
        // nowhere while still shaping the Cedar schema. Removing roles is a
        // policy-set change and bumps the version.
        let removed = try await PolicySetVersionService.withPolicySetChange(on: database) { db in
            // Global organization/OU quotas survive this project and must be
            // refreshed after its networks cascade away. Resolve and lock them
            // while the project still exists; project-scoped quotas are part of
            // the cascade and deliberately absent from this set (STR-236).
            let projectWideAncestorQuotas =
                try await QuotaEnforcementService.lockedProjectWideAncestorQuotas(
                    for: project, on: db)

            // The project node's bindings, and those of every resource that
            // cascades away with it — service accounts (in both directions),
            // images, networks, security groups, floating IPs, DNS zones and
            // records, volumes and their snapshots (STR-137). This reads rows
            // the delete below removes, so it runs first — which also means a
            // child committed between the sweep and the delete is invisible to
            // it. `vms.project_id` being RESTRICT backstops the *workload*
            // race below; nothing backstops this one, and closing it needs the
            // project row locked rather than merely read.
            try await ResourceBindingCleanup.revokeBindings(forDeletedProject: projectID, on: db)

            // A security group's owner-side FK cascades its rules, but a
            // default group's ingress rules also point back to that same group
            // through `remote_group_id` (NO ACTION). PostgreSQL checks that
            // self-reference before the cascade can remove the row, so every
            // otherwise-empty project became undeletable. Mirror the explicit
            // rule teardown in SecurityGroupController before deleting the
            // project and letting its groups cascade.
            let securityGroupIDs = try await LegacySecurityGroupStore.ids(
                projectIDs: [projectID], on: db)
            if !securityGroupIDs.isEmpty {
                try await LegacySecurityGroupRuleStore.delete(
                    securityGroupIDs: securityGroupIDs, on: db)
            }

            // The emptiness checks above and this delete are not one atomic
            // step, and read-committed Postgres will happily commit a VM
            // created in between. `vms.project_id` is RESTRICT (STR-98), so
            // the database refuses rather than cascading a live VM row out of
            // existence — which used to leave a running guest with no record,
            // and then an agent tearing it down for having none. Translate
            // that refusal into the same answer the check gives.
            do {
                try await project.delete(on: db)
            } catch let error as any PostgresConstraintError where error.isConstraintFailure {
                throw Abort(
                    .conflict,
                    reason: "Cannot delete project: a VM or sandbox was created in it. "
                        + "Delete or move its workloads first.")
            }
            try await QuotaEnforcementService.resyncAndSaveReservations(
                projectWideAncestorQuotas, on: db)
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

        let projectIDs = try await projects.candidateProjectIDs(
            organizationIDs: [organizationID], organizationalUnitIDs: [], projectIDs: [])
        let overviews = try await projects.projectOverviews(ids: projectIDs)
        return .ok(.init(body: .json(try await readableOverviews(overviews, on: req))))
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

        let name = try Validate.name(create.name)
        let project = try await createProject(
            create,
            name: name,
            organizationID: organizationID,
            ouID: nil,
            on: req
        )
        return .ok(.init(body: .json(.init(project: project, vmCount: 0))))
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
        guard let ou = try await hierarchy.organizationalUnit(id: ouID),
            ou.organizationalUnit.organizationID == organizationID
        else {
            throw Abort(.notFound, reason: "Folder not found")
        }

        let overviews = try await projects.projectOverviews(organizationalUnitID: ouID)
        return .ok(.init(body: .json(try await readableOverviews(overviews, on: req))))
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

        guard let ou = try await hierarchy.organizationalUnit(id: ouID) else {
            throw Abort(.notFound, reason: "Folder not found")
        }
        if ou.organizationalUnit.organizationID != organizationID {
            throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
        }

        let name = try Validate.name(create.name)
        let project = try await createProject(
            create,
            name: name,
            organizationID: nil,
            ouID: ouID,
            on: req
        )
        return .ok(.init(body: .json(.init(project: project, vmCount: 0))))
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
        guard try await projects.project(id: projectID) != nil else {
            throw Abort(.notFound, reason: "Project not found")
        }
        try await OrganizationAccessService.requireProjectAction(
            "project:update", projectID: projectID, on: req)

        switch try await projects.addEnvironment(projectID: projectID, environment: environment) {
        case .updated(let overview):
            return .ok(.init(body: .json(.init(
                project: overview.project,
                vmCount: overview.virtualMachineCount
            ))))
        case .notFound:
            throw Abort(.notFound, reason: "Project not found")
        case .inUseByVirtualMachines, .inUseBySandboxes, .cannotRemove:
            preconditionFailure("Add environment returned a removal-only result")
        }
    }

    func removeProjectEnvironment(
        _ input: Operations.RemoveProjectEnvironment.Input
    ) async throws -> Operations.RemoveProjectEnvironment.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let environment = input.path.environment
        guard try await projects.project(id: projectID) != nil else {
            throw Abort(.notFound, reason: "Project not found")
        }
        try await OrganizationAccessService.requireProjectAction(
            "project:update", projectID: projectID, on: req)

        switch try await projects.removeEnvironment(projectID: projectID, environment: environment) {
        case .updated(let overview):
            return .ok(.init(body: .json(.init(
                project: overview.project,
                vmCount: overview.virtualMachineCount
            ))))
        case .notFound:
            throw Abort(.notFound, reason: "Project not found")
        case .inUseByVirtualMachines:
            throw Abort(.conflict, reason: "Cannot remove environment that is in use by VMs")
        case .inUseBySandboxes:
            throw Abort(.conflict, reason: "Cannot remove environment that is in use by sandboxes")
        case .cannotRemove:
            throw Abort(
                .badRequest,
                reason: "Cannot remove default environment or environment does not exist"
            )
        }
    }

    // MARK: - Stats, path, transfer

    func getProjectStats(
        _ input: Operations.GetProjectStats.Input
    ) async throws -> Operations.GetProjectStats.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        guard let project = try await projects.project(id: projectID) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        try await OrganizationAccessService.requireProjectMember(projectID: projectID, on: req)

        return .ok(.init(body: .json(.init(stats: try await projects.stats(project: project)))))
    }

    func getProjectPath(_ input: Operations.GetProjectPath.Input) async throws -> Operations.GetProjectPath.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        guard let project = try await projects.project(id: projectID) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        try await OrganizationAccessService.requireProjectMember(projectID: projectID, on: req)

        var components: [Components.Schemas.ProjectPathComponent] = []

        if let orgID = project.organizationID {
            if let org = try await hierarchy.organization(id: orgID) {
                components.append(.init(id: orgID.uuidString, name: org.name, _type: .organization))
            }
        } else if let ouID = project.organizationalUnitID {
            let ouPath = try await hierarchy.organizationalUnitAncestors(id: ouID)
            if let organizationID = project.rootOrganizationID,
                let organization = try await hierarchy.organization(id: organizationID)
            {
                components.append(
                    .init(
                        id: organizationID.uuidString,
                        name: organization.name,
                        _type: .organization
                    ))
            }

            for ou in ouPath {
                components.append(
                    .init(id: ou.id.uuidString, name: ou.name, _type: .organizationalUnit))
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
        guard let project = try await projects.project(id: projectID) else {
            throw Abort(.notFound, reason: "Project not found")
        }

        try await OrganizationAccessService.requireProjectAction(
            "project:transfer", projectID: projectID, on: req)

        let destination = try await resolveDestination(
            organizationID: destinationOrganizationIDParam,
            ouID: destinationOUID,
            required: true)
        guard let destination else {
            throw Abort(.badRequest, reason: "Transfer must specify a destination organization or folder")
        }

        // Moving a project requires admin on the destination organization, not
        // just membership — otherwise a member could relocate projects into orgs
        // they do not administer.
        try await OrganizationAccessService.requireAdmin(
            organizationID: destination.rootOrganizationID, on: req)

        let overview = try Self.requireTransferredProject(
            try await projects.transfer(.init(
                project: .init(
                    id: project.id,
                    name: project.name,
                    description: project.description,
                    defaultEnvironment: project.defaultEnvironment,
                    environments: project.environments
                ),
                organizationID: destination.organizationID,
                organizationalUnitID: destination.ouID
            )))
        return .ok(.init(body: .json(.init(
            project: overview.project,
            vmCount: overview.virtualMachineCount
        ))))
    }

    // MARK: - Helpers

    /// Summarize only the projects the caller may actually read.
    ///
    /// The list endpoints load a *candidate* set by organization/folder
    /// membership — a superset — and then this hands the evaluator the last
    /// word per row, exactly as the item route's `view_project` check would
    /// (STR-113). Bare org membership grants `org:read` and `project:create`
    /// and nothing else (docs/architecture/iam.md), so a member with no
    /// project binding gets an empty list here rather than the organization's
    /// entire project inventory. `project:read` is what `view_project`
    /// translates to, so a listed project and the object read that follows it
    /// are the same decision, answered once from the request memo (#686).
    ///
    /// `ProjectVisibility` is used the way every other list endpoint uses it:
    /// its SQL narrowing bounds the set *before* the evaluator decides, so a
    /// caller whose bindings reach only a handful of projects sends a
    /// handful-sized Cedar batch — not one node per project in the org — and
    /// writes only that many decision rows. `nil` candidates means "no bound"
    /// (a system admin, an unbounded authored permit), and every candidate is
    /// still decided below.
    private func readableOverviews(_ overviews: [ProjectOverview], on req: Request) async throws
        -> [Components.Schemas.ProjectSummary]
    {
        let visibility = try await ProjectVisibility.resolve(
            on: req, using: iam, projects: projects)
        if visibility.reachesNoProject { return [] }

        // Bound the candidates to the SQL-narrowed set before deciding, when
        // one exists (nil = no bound, e.g. a system admin).
        let narrowed: [ProjectOverview]
        if let candidateIDs = visibility.candidateProjectIDs.map(Set.init) {
            narrowed = overviews.filter { candidateIDs.contains($0.project.id) }
        } else {
            narrowed = overviews
        }

        let readable = try await visibility.readableProjects(
            among: narrowed.map(\.project.id), on: req)
        return narrowed.compactMap { overview in
            guard readable.contains(overview.project.id) else { return nil }
            return .init(
                project: overview.project,
                vmCount: overview.virtualMachineCount
            )
        }
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

    private static func findProject(_ projectID: UUID, on db: PostgresStoreContext) async throws -> Project {
        guard let project = try await Project.find(projectID, on: db) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }

    private struct ProjectDestination: Sendable {
        let organizationID: UUID?
        let ouID: UUID?
        let rootOrganizationID: UUID
    }

    private func resolveDestination(
        organizationID: UUID?,
        ouID: UUID?,
        required: Bool
    ) async throws -> ProjectDestination? {
        if let ouID {
            guard let ou = try await hierarchy.organizationalUnit(id: ouID) else {
                throw Abort(.notFound, reason: "Destination folder not found")
            }
            if let organizationID, ou.organizationalUnit.organizationID != organizationID {
                throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
            }
            return .init(
                organizationID: nil,
                ouID: ouID,
                rootOrganizationID: ou.organizationalUnit.organizationID)
        }

        if let organizationID {
            guard try await hierarchy.organization(id: organizationID) != nil else {
                throw Abort(.notFound, reason: "Destination organization not found")
            }
            return .init(
                organizationID: organizationID,
                ouID: nil,
                rootOrganizationID: organizationID)
        }

        if required {
            throw Abort(.badRequest, reason: "Transfer must specify a destination organization or folder")
        }
        return nil
    }

    private static func vmCount(_ projectID: UUID, on db: PostgresStoreContext) async throws -> Int {
        try await LegacyVMStore.vms(projectID: projectID, on: db).count
    }

    /// The caller's environment list, normalized the way `name` is: every label
    /// trimmed and bounded, and duplicates collapsed with order preserved,
    /// because the trim itself can create them (`["prod", "prod "]`).
    ///
    /// Normalized here rather than in `Project.validate()` so the
    /// `environments.contains(defaultEnvironment)` guards compare the strings
    /// that will actually be stored.
    private static func normalizedEnvironments(_ environments: [String]) throws -> [String] {
        try Validate.list(environments, "environments", max: Project.maxEnvironments)
        var seen: Set<String> = []
        return try environments.compactMap { environment in
            let normalized = try Validate.name(environment, "environments")
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }


    private static func projectMetadata(
        current: ProjectSnapshot,
        update: Components.Schemas.UpdateProjectRequest
    ) throws -> ProjectMetadataWrite {
        let name = try update.name.map { try Validate.name($0) } ?? current.name
        let description = update.description ?? current.description
        try Validate.text(description)
        let environments = try update.environments.map(normalizedEnvironments)
            ?? current.environments
        guard !environments.isEmpty else {
            throw Abort(.badRequest, reason: "Project must have at least one environment")
        }
        let defaultEnvironment = try update.defaultEnvironment.map {
            try Validate.name($0, "defaultEnvironment")
        } ?? current.defaultEnvironment
        guard environments.contains(defaultEnvironment) else {
            throw Abort(.badRequest, reason: "Default environment must be in the environments list")
        }
        return .init(
            id: current.id,
            name: name,
            description: description,
            defaultEnvironment: defaultEnvironment,
            environments: environments
        )
    }

    private static func requireTransferredProject(_ result: ProjectTransferResult) throws
        -> ProjectOverview
    {
        switch result {
        case .updated(let overview): return overview
        case .notFound: throw Abort(.notFound, reason: "Project not found")
        case .invalidDestination:
            throw Abort(.badRequest, reason: "Transfer must specify a destination organization or folder")
        case .organizationNotFound:
            throw Abort(.notFound, reason: "Destination organization not found")
        case .organizationalUnitNotFound:
            throw Abort(.notFound, reason: "Destination folder not found")
        case .duplicateName:
            throw Abort(.conflict, reason: "Project name already exists in this scope")
        case .environmentsInUseByVirtualMachines(let removed):
            throw Abort(
                .conflict,
                reason: "Cannot remove environments that are in use by VMs: \(removed.joined(separator: ", "))"
            )
        case .environmentsInUseBySandboxes(let removed):
            throw Abort(
                .conflict,
                reason: "Cannot remove environments that are in use by sandboxes: \(removed.joined(separator: ", "))"
            )
        case .networkQuotaExceeded(let name, let limit):
            throw Abort(
                .forbidden,
                reason: "Quota '\(name)' exceeded: Network limit reached: \(limit) networks allowed"
            )
        case .loadBalancerQuotaExceeded(let name, let limit):
            throw Abort(
                .forbidden,
                reason: "Quota '\(name)' exceeded: Load balancer limit reached: \(limit) load balancers allowed"
            )
        }
    }

    private func createProject(
        _ create: Components.Schemas.CreateProjectRequest,
        name: String,
        organizationID: UUID?,
        ouID: UUID?,
        on req: Request
    ) async throws -> ProjectSnapshot {
        let environments = try Self.normalizedEnvironments(
            create.environments ?? DeploymentEnvironment.defaults.map { $0.name })
        let defaultEnvironment = try Validate.name(
            create.defaultEnvironment ?? "development", "defaultEnvironment")
        try Validate.text(create.description)

        if !environments.contains(defaultEnvironment) {
            throw Abort(.badRequest, reason: "Default environment must be in the environments list")
        }

        switch try await projects.create(.init(
            name: name,
            description: create.description,
            organizationID: organizationID,
            organizationalUnitID: ouID,
            defaultEnvironment: defaultEnvironment,
            environments: environments,
            creatorID: req.auth.get(User.self)?.id,
            administratorRoleID: IAMRole.admin.seededID
        )) {
        case .created(let project):
            return project
        case .duplicateName:
            throw Abort(.conflict, reason: "Project name already exists in this scope")
        case .organizationNotFound:
            throw Abort(.notFound, reason: "Destination organization not found")
        case .organizationalUnitNotFound:
            throw Abort(.notFound, reason: "Destination folder not found")
        case .invalidScope:
            throw Abort(.badRequest, reason: "Project must belong to either an organization or a folder")
        }
    }
}
