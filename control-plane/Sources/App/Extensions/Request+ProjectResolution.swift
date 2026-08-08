import Fluent
import Vapor

extension Request {
    /// Resolve the target project and environment for a resource-create request,
    /// enforcing organization membership, the `create_resources` permission, and
    /// environment validity.
    ///
    /// This is the shared spine behind VM and sandbox creation (issue #675): both
    /// paths must scope a create identically, and any divergence between them is a
    /// latent authorization bug. The logic:
    ///
    /// 1. If `requestedProjectId` is set, the project must exist and its root
    ///    organization must match the user's current organization; otherwise fall
    ///    back to the organization's "Default Project".
    /// 2. Require `create_resources` on the resolved project — org membership alone
    ///    is not enough, since `<resource>.create` resolves to
    ///    `project->create_resources`.
    /// 3. Resolve the environment (`requestedEnvironment ?? project.defaultEnvironment`)
    ///    and validate it exists on the project.
    ///
    /// Distinct from `authorizedProjectForCreate(...)`, which is the spine
    /// behind the project-scoped infrastructure creates (volume, network,
    /// security group, floating IP, DNS zone): those have no environment and
    /// each carries its own create action.
    ///
    /// **The two fallbacks disagree, and that is not by design.** This one
    /// takes the project *named* "Default Project"; the other takes the
    /// organization's oldest project. So in an organization holding more than
    /// one project, `POST /api/vms` and `POST /api/volumes` with no `projectId`
    /// can land in different places. Reconciling them is issue #1059 — until
    /// then, do not read either as the installation's answer to "the default
    /// project".
    ///
    /// - Parameter resourceKind: Plural noun for the resource being created
    ///   (e.g. `"VMs"`, `"sandboxes"`), used only in the forbidden-permission message.
    func resolveProjectForCreate(
        requestedProjectId: UUID?,
        requestedEnvironment: String?,
        user: User,
        resourceKind: String
    ) async throws -> (project: Project, environment: String) {
        // Determine project context.
        let projectId: UUID
        if let requestedProjectId {
            // Verify user has access to the requested project.
            guard let project = try await Project.find(requestedProjectId, on: db) else {
                throw Abort(.badRequest, reason: "Project not found")
            }

            // Verify user belongs to the project's organization.
            let rootOrgId = try await project.getRootOrganizationId(on: db)
            guard let orgId = rootOrgId, user.currentOrganizationId == orgId else {
                throw Abort(.forbidden, reason: "Access denied to project")
            }

            projectId = requestedProjectId
        } else {
            guard let currentOrgId = user.currentOrganizationId else {
                throw Abort(.badRequest, reason: "No current organization set. Please specify a project.")
            }

            // Fall back to the organization's default project.
            let defaultProject = try await Project.query(on: db)
                .filter(\Project.$organization.$id, .equal, currentOrgId)
                .filter(\Project.$name, .equal, "Default Project")
                .first()

            guard let project = defaultProject else {
                throw Abort(.badRequest, reason: "No default project found. Please specify a project.")
            }
            projectId = project.id!
        }

        // Re-fetch the resolved project to validate the environment.
        guard let project = try await Project.find(projectId, on: db) else {
            throw Abort(.internalServerError, reason: "Project not found")
        }

        // Require create permission on the target project. Org membership alone
        // (checked above) is not enough: `<resource>.create` resolves to
        // `project->create_resources`, so a user who only inherits `view_project`
        // as an org member — with no role in this project — must not be able to
        // create resources here.
        let canCreate = try await can("create_resources", on: "project", id: projectId.uuidString)
        guard canCreate else {
            throw Abort(.forbidden, reason: "You don't have permission to create \(resourceKind) in this project")
        }

        // Determine and validate the environment.
        return (project, try project.resolveEnvironment(requestedEnvironment))
    }

    /// The project a project-scoped create lands in — resolved, authorized, and
    /// confirmed to exist (issue #1049).
    ///
    /// Five endpoints ask the same question: take the request's `projectId`,
    /// else the first project in the caller's current organization, else refuse.
    /// Four of them — volume, network, security-group and floating-IP create —
    /// carried the same seventeen lines inline while DNS zone create had already
    /// extracted a private copy of them, and what the copies had drifted over is
    /// whether the resolved project must exist: DNS zone, security group and
    /// floating IP confirmed it, network only when the request also pinned a
    /// site, and `createVolume` never — it went from the permission check
    /// straight to the insert and left a bad id to the foreign key. Route new
    /// project-scoped creates through here rather than writing a sixth copy.
    ///
    /// **It asserts the project exists**, which is the per-controller question
    /// this settles: no create is left handing an unbacked `project_id` to an
    /// insert for the foreign key to reject. The three steps run in this order,
    /// and the order is the load-bearing part:
    ///
    /// 1. Resolve the id — no lookup, no decision.
    /// 2. Authorize `action` on it.
    /// 3. *Then* confirm the row exists.
    ///
    /// Confirming existence first would make the endpoint an oracle: "Project
    /// {id} does not exist" told apart from a `403` reveals that an opaque UUID
    /// names a real project in an organization the caller cannot see. Behind the
    /// permission check that message only ever reaches a caller the evaluator
    /// already allowed to create here — the same ordering rule
    /// `ProjectContainment` documents for containment refusals.
    ///
    /// Being behind the permission check is also why the assertion is a
    /// backstop and not the refusal a caller meets. An id with no row resolves
    /// to a chain that never reaches an organization, and a truncated chain is
    /// denied outright, before evaluation, by the rule
    /// `docs/architecture/iam.md` states — system admins included, since their
    /// reach is the tier-1 policy rather than a bypass, and a role binding
    /// pinned directly at the missing id does not rescue it either.
    /// `ProjectResolutionTests` pins both, at all five endpoints: what a caller
    /// inventing a UUID actually gets is `403`.
    ///
    /// Keeping a check nothing currently reaches is a trade, and it is not free
    /// or uniform: the fallback path drops from two queries to one at all five
    /// endpoints (the resolved row is reused), while a request that names its
    /// project costs one `SELECT` more than it did at volume create and at
    /// site-less network create — the two that were not already looking the
    /// project up. That is worth paying for the failure it stands in front of,
    /// which is an insert against a dangling foreign key surfacing as a `500`
    /// mid-create rather than a `400` before anything is written.
    ///
    /// **The fallback is stable, not decided.** It used to be `.first()` with
    /// no sort at all, so across an organization with more than one project two
    /// identical requests by the same user could land in different projects —
    /// Postgres is free to return a different row. The `created_at`/`id` sort
    /// removes that, and nothing more: it makes the answer repeatable without
    /// claiming the oldest project *ought* to be the default. Which project
    /// should be — an explicit default-project field, or refusing when the
    /// choice is ambiguous — is issue #1059, along with the fact that this
    /// fallback and `resolveProjectForCreate`'s disagree.
    ///
    /// - Parameters:
    ///   - requestedProjectId: The project named by the request body, if any.
    ///   - action: The create permission to check on the resolved project
    ///     (e.g. `"create_volume"`).
    ///   - resourceKind: Plural noun for the resource being created
    ///     (e.g. `"volumes"`), used only in the forbidden-permission message.
    ///   - verb: The verb that message reads with, for the endpoints that don't
    ///     call it creating (floating IPs are *allocated*).
    func authorizedProjectForCreate(
        requested requestedProjectId: UUID?,
        user: User,
        action: String,
        resourceKind: String,
        verb: String = "create"
    ) async throws -> Project {
        // Resolved by fallback, so it exists by construction and needs no
        // second lookup below.
        var fallbackProject: Project?

        let projectId: UUID
        if let requestedProjectId {
            projectId = requestedProjectId
        } else if let currentOrgId = user.currentOrganizationId {
            guard
                let defaultProject = try await Project.query(on: db)
                    .filter(\.$organization.$id == currentOrgId)
                    .sort(\.$createdAt, .ascending)
                    .sort(\.$id, .ascending)
                    .first()
            else {
                throw Abort(.badRequest, reason: "No project specified and no default project found")
            }
            fallbackProject = defaultProject
            projectId = try defaultProject.requireID()
        } else {
            throw Abort(.badRequest, reason: "No project specified and user has no current organization")
        }

        let allowed = try await can(action, on: "project", id: projectId.uuidString)
        guard allowed else {
            throw Abort(
                .forbidden, reason: "You don't have permission to \(verb) \(resourceKind) in this project")
        }

        if let fallbackProject { return fallbackProject }
        guard let project = try await Project.find(projectId, on: db) else {
            throw Abort(.badRequest, reason: "Project \(projectId) does not exist")
        }
        return project
    }
}
