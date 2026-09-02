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

        // Projects nested under folders (OUs) within those organizations.
        let ous = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id ~~ organizationIDs)
            .all()
        let ouIDs = ous.compactMap { $0.id }
        let allProjects = try await Project.all(
            inOrganizations: organizationIDs, folders: ouIDs, on: req.db)

        return .ok(.init(body: .json(try await readableSummaries(for: allProjects, on: req))))
    }

    func getProject(_ input: Operations.GetProject.Input) async throws -> Operations.GetProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let project = try await req.requireProject(id: projectID)

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
        let project = try await req.requireProject(id: projectID)

        try await OrganizationAccessService.requireProjectAction("project:update", project: project, on: req)

        let destinationOrganizationIDParam = try update.organizationId.map {
            try Self.uuid($0, name: "organization ID")
        }
        let destinationOUID = try update.organizationalUnitId.map {
            try Self.uuid($0, name: "folder ID")
        }
        let destination = try await Self.resolveDestination(
            organizationID: destinationOrganizationIDParam,
            ouID: destinationOUID,
            required: false,
            on: req.db)

        if let destination {
            try await OrganizationAccessService.requireProjectAction(
                "project:transfer", project: project, on: req)
            try await OrganizationAccessService.requireAdmin(
                organizationID: destination.rootOrganizationID, on: req)
        }

        // Metadata and parentage are one edit operation. Keep every validation,
        // save, and quota reservation update on the same connection so a
        // refused destination cannot leave the metadata half-applied.
        try await req.db.transaction { db in
            let name = try update.name.map { try Validate.name($0) } ?? project.name
            if update.name != nil || destination != nil {
                let targetOrganizationID: UUID?
                let targetOUID: UUID?
                if let destination {
                    targetOrganizationID = destination.organizationID
                    targetOUID = destination.ouID
                } else {
                    targetOrganizationID = project.$organization.id
                    targetOUID = project.$organizationalUnit.id
                }
                try await Self.validateNameUniqueness(
                    name: name,
                    excludeProjectID: projectID,
                    organizationID: targetOrganizationID,
                    ouID: targetOUID,
                    on: db
                )
            }
            project.name = name

            if let description = update.description {
                project.description = description
            }

            if let requestedEnvironments = update.environments {
                let environments = try Self.normalizedEnvironments(requestedEnvironments)
                guard !environments.isEmpty else {
                    throw Abort(.badRequest, reason: "Project must have at least one environment")
                }

                // Environments still in use by a VM or sandbox cannot be dropped.
                let removed = Set(project.environments).subtracting(Set(environments))
                if !removed.isEmpty {
                    let vmsUsingRemoved = try await VM.query(on: db)
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

                    let sandboxesUsingRemoved = try await Sandbox.query(on: db)
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

            if let requestedDefault = update.defaultEnvironment {
                let defaultEnvironment = try Validate.name(requestedDefault, "defaultEnvironment")
                if !project.environments.contains(defaultEnvironment) {
                    throw Abort(.badRequest, reason: "Default environment must be in the environments list")
                }
                project.defaultEnvironment = defaultEnvironment
            }

            try project.validate()
            if let destination {
                try await Self.moveProject(
                    project, projectID: projectID, to: destination, on: db)
            } else {
                project.path = try await project.buildPath(on: db)
                try await project.save(on: db)
            }
        }

        let vmCount = try await Self.vmCount(projectID, on: req.db)
        return .ok(.init(body: .json(try .init(project: project, vmCount: vmCount))))
    }

    func deleteProject(_ input: Operations.DeleteProject.Input) async throws -> Operations.DeleteProject.Output {
        let req = try OpenAPIRequestContext.require()
        try Self.requireAuthenticated(req)
        let projectID = try Self.uuid(input.path.projectID, name: "project ID")
        let project = try await req.requireProject(id: projectID)

        try await OrganizationAccessService.requireProjectAction("project:delete", project: project, on: req)

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

        let cephAccessCount = try await CephProjectAccess.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .count()
        if cephAccessCount > 0 {
            throw Abort(
                .conflict,
                reason:
                    "Cannot delete project with Ceph storage access. Delete its Ceph volumes and project access first."
            )
        }

        // IAM dual-write (issue #477): bindings have no FK to the nodes they
        // protect, so drop the project node's bindings with the row — and the
        // roles it owns (issue #605), which would otherwise be bindable
        // nowhere while still shaping the Cedar schema. Removing roles is a
        // policy-set change and bumps the version.
        let removed = try await PolicySetVersionService.withPolicySetChange(on: req.db) { db in
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
            let cephAccessCount = try await CephProjectAccess.query(on: db)
                .filter(\.$project.$id == projectID)
                .count()
            guard cephAccessCount == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Cannot delete project with Ceph storage access. Delete its Ceph volumes and project access first."
                )
            }
            try await ResourceBindingCleanup.revokeBindings(forDeletedProject: projectID, on: db)

            // A security group's owner-side FK cascades its rules, but a
            // default group's ingress rules also point back to that same group
            // through `remote_group_id` (NO ACTION). PostgreSQL checks that
            // self-reference before the cascade can remove the row, so every
            // otherwise-empty project became undeletable. Mirror the explicit
            // rule teardown in SecurityGroupController before deleting the
            // project and letting its groups cascade.
            let securityGroupIDs = try await SecurityGroup.query(on: db)
                .filter(\.$project.$id == projectID)
                .all(\.$id)
            if !securityGroupIDs.isEmpty {
                try await SecurityGroupRule.query(on: db)
                    .filter(\.$securityGroup.$id ~~ securityGroupIDs)
                    .delete()
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
            } catch let error as any DatabaseError where error.isConstraintFailure {
                throw Abort(
                    .conflict,
                    reason:
                        "Cannot delete project: a VM, sandbox, or Ceph storage access was created in it. "
                        + "Delete or move its workloads and remove Ceph project access first."
                )
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

        // The full project set within the organization's hierarchy, so callers
        // (e.g. the project switcher) can reach folder-scoped projects too.
        let ous = try await OrganizationalUnit.query(on: req.db)
            .filter(\.$organization.$id == organizationID)
            .all()
        let ouIDs = ous.compactMap { $0.id }
        let projects = try await Project.all(
            inOrganization: organizationID, folders: ouIDs, on: req.db)

        return .ok(.init(body: .json(try await readableSummaries(for: projects, on: req))))
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
        try await Self.validateNameUniqueness(
            name: name,
            excludeProjectID: nil,
            organizationID: organizationID,
            ouID: nil,
            on: req.db
        )

        let project = try await Self.createProject(
            create,
            name: name,
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

        return .ok(.init(body: .json(try await readableSummaries(for: projects, on: req))))
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

        let name = try Validate.name(create.name)
        try await Self.validateNameUniqueness(
            name: name,
            excludeProjectID: nil,
            organizationID: nil,
            ouID: ouID,
            on: req.db
        )

        let project = try await Self.createProject(
            create,
            name: name,
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
        let project = try await req.requireProject(id: projectID)

        try await OrganizationAccessService.requireProjectAction("project:update", project: project, on: req)

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
        let project = try await req.requireProject(id: projectID)

        try await OrganizationAccessService.requireProjectAction("project:update", project: project, on: req)

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
        let project = try await req.requireProject(id: projectID)

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
        let project = try await req.requireProject(id: projectID)

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
        let project = try await req.requireProject(id: projectID)

        try await OrganizationAccessService.requireProjectAction("project:transfer", project: project, on: req)

        let destination = try await Self.resolveDestination(
            organizationID: destinationOrganizationIDParam,
            ouID: destinationOUID,
            required: true,
            on: req.db)
        guard let destination else {
            throw Abort(.badRequest, reason: "Transfer must specify a destination organization or folder")
        }

        // Moving a project requires admin on the destination organization, not
        // just membership — otherwise a member could relocate projects into orgs
        // they do not administer.
        try await OrganizationAccessService.requireAdmin(
            organizationID: destination.rootOrganizationID, on: req)

        try await Self.validateNameUniqueness(
            name: project.name,
            excludeProjectID: projectID,
            organizationID: destination.organizationID,
            ouID: destination.ouID,
            on: req.db
        )

        try await req.db.transaction { db in
            try await Self.moveProject(
                project, projectID: projectID, to: destination, on: db)
        }

        let vmCount = try await Self.vmCount(projectID, on: req.db)
        return .ok(.init(body: .json(try .init(project: project, vmCount: vmCount))))
    }

    // MARK: - Helpers

    /// `GET /api/projects` backs the frontend's project switcher, so its VM
    /// counts come from one grouped aggregate rather than a `COUNT` per project.
    private func summaries(for projects: [Project], on db: any Database) async throws
        -> [Components.Schemas.ProjectSummary]
    {
        let projectIDs = projects.compactMap { $0.id }
        let vmCounts = try await VM.counts(groupedBy: \.$project, in: projectIDs, on: db)

        var summaries: [Components.Schemas.ProjectSummary] = []
        for project in projects {
            guard let projectID = project.id else { continue }
            summaries.append(try .init(project: project, vmCount: vmCounts[projectID] ?? 0))
        }
        return summaries
    }

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
    private func readableSummaries(for projects: [Project], on req: Request) async throws
        -> [Components.Schemas.ProjectSummary]
    {
        let visibility = try await ProjectVisibility.resolve(on: req)
        if visibility.reachesNoProject { return [] }

        // Bound the candidates to the SQL-narrowed set before deciding, when
        // one exists (nil = no bound, e.g. a system admin).
        let narrowed: [Project]
        if let candidateIDs = visibility.candidateProjectIDs.map(Set.init) {
            narrowed = projects.filter { $0.id.map(candidateIDs.contains) ?? false }
        } else {
            narrowed = projects
        }

        let readable = try await visibility.readableProjects(
            among: narrowed.compactMap(\.id), on: req)
        let filtered = narrowed.filter { project in
            project.id.map(readable.contains) ?? false
        }
        return try await summaries(for: filtered, on: req.db)
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

    private struct ProjectDestination: Sendable {
        let organizationID: UUID?
        let ouID: UUID?
        let rootOrganizationID: UUID
    }

    private static func resolveDestination(
        organizationID: UUID?,
        ouID: UUID?,
        required: Bool,
        on db: any Database
    ) async throws -> ProjectDestination? {
        if let ouID {
            guard let ou = try await OrganizationalUnit.find(ouID, on: db) else {
                throw Abort(.notFound, reason: "Destination folder not found")
            }
            if let organizationID, ou.$organization.id != organizationID {
                throw Abort(.badRequest, reason: "Folder does not belong to the specified organization")
            }
            return .init(
                organizationID: nil,
                ouID: ouID,
                rootOrganizationID: ou.$organization.id)
        }

        if let organizationID {
            guard try await Organization.find(organizationID, on: db) != nil else {
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

    private static func moveProject(
        _ project: Project,
        projectID: UUID,
        to destination: ProjectDestination,
        on db: any Database
    ) async throws {
        let cephAccessCount = try await CephProjectAccess.query(on: db)
            .filter(\.$project.$id == projectID)
            .count()
        guard cephAccessCount == 0 else {
            throw Abort(
                .conflict,
                reason:
                    "Cannot transfer project with Ceph storage access. Delete its Ceph volumes and project access first."
            )
        }
        try await QuotaEnforcementService.lockProjectNetworkMutations(
            for: project, on: db)
        let sourceQuotas = try await QuotaEnforcementService.applicableProjectWideQuotas(
            for: project, on: db)
        let networkCount = try await LogicalNetwork.query(on: db)
            .filter(\.$project.$id == projectID)
            .count()
        let loadBalancerCount = try await LoadBalancer.query(on: db)
            .filter(\.$project.$id == projectID)
            .count()

        project.$organization.id = destination.organizationID
        project.$organizationalUnit.id = destination.ouID
        project.path = try await project.buildPath(on: db)
        try project.validate()

        let destinationQuotas = try await QuotaEnforcementService.applicableProjectWideQuotas(
            for: project, on: db)
        let affectedQuotas = try await QuotaEnforcementService.validateNetworkTransfer(
            networkCount: networkCount,
            loadBalancerCount: loadBalancerCount,
            sourceQuotas: sourceQuotas,
            destinationQuotas: destinationQuotas,
            on: db)

        try await project.save(on: db)
        try await QuotaEnforcementService.resyncAndSaveReservations(
            affectedQuotas, on: db)
    }

    private static func vmCount(_ projectID: UUID, on db: any Database) async throws -> Int {
        Int(
            try await VM.query(on: db)
                .filter(\.$project.$id == projectID)
                .count())
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

    /// Refuses a project name already taken in the same scope.
    ///
    /// `name` must already be normalized (STR-195): the comparison is an exact
    /// match, and `Project.validate()` trims before the row is saved, so
    /// checking a raw value here would let `"Foo "` past a scope that already
    /// holds `"Foo"` and then save it as `"Foo"` — two projects with the same
    /// name, and no unique index to catch it. Every caller runs its input
    /// through `Validate.name` first and hands the same string to the save.
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
        name: String,
        organizationID: UUID?,
        ouID: UUID?,
        on req: Request
    ) async throws -> Project {
        let environments = try Self.normalizedEnvironments(
            create.environments ?? DeploymentEnvironment.defaults.map { $0.name })
        let defaultEnvironment = try Validate.name(
            create.defaultEnvironment ?? "development", "defaultEnvironment")

        if !environments.contains(defaultEnvironment) {
            throw Abort(.badRequest, reason: "Default environment must be in the environments list")
        }

        let project = Project(
            // Already normalized by the caller, which had to normalize before
            // its uniqueness query — see `validateNameUniqueness`.
            name: name,
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
            // Every project carries its mandatory default security group from
            // birth; paths that assume it (VM create) also ensure it
            // defensively.
            _ = try await SecurityGroupService.ensureDefaultGroup(
                projectID: try project.requireID(), on: transaction)
        }

        return project
    }
}
