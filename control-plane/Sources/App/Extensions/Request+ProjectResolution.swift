import Fluent
import Vapor

extension Request {
    /// The refusal both create-side resolvers give a request that names no
    /// project (issue #1059).
    ///
    /// **There is no default project.** There used to be two guesses at one, and
    /// they disagreed: VM and sandbox creation took the project *named* "Default
    /// Project", while the five infrastructure creates took the organization's
    /// oldest. So `POST /api/vms` and `POST /api/volumes` with the same empty
    /// body landed in different places, and neither answer was one anybody
    /// chose — the first is a magic string an organization can rename out from
    /// under (`strato bootstrap --project-name Foo` already produced an
    /// installation where VM create refused and volume create quietly worked),
    /// the second was `.first()` with no `ORDER BY` until issue #1049 sorted it,
    /// and that sort only made the guess *repeatable*, not right. Both also
    /// filtered on `organization_id`, so a project living under a folder was
    /// invisible to them, and an organization whose projects were all foldered
    /// could not create anything without naming one.
    ///
    /// What replaced them is not a third guess. A create says where it lands.
    /// This is the same move networks made in issue #765 — "nothing provisions a
    /// network with a project, and no network is privileged, so 'attach to
    /// whatever is lying around' has no honest answer" — and the reasoning
    /// transfers intact: nothing privileges the project an organization is
    /// provisioned with either.
    ///
    /// Rejected on the way here: an explicit `organizations.default_project_id`
    /// column, which swaps one inferred answer for a nullable one that still
    /// needs a rule for when it is unset; and adopting the sole project when an
    /// organization holds exactly one, which makes the API's behavior depend on
    /// how many rows a table happens to hold — the same request starts failing
    /// the day somebody adds a second project.
    ///
    /// - Parameters:
    ///   - verb: What the endpoint calls the act (floating IPs are *allocated*).
    ///   - resourceKind: Plural noun for the resource being created.
    static func projectIsRequired(verb: String = "create", _ resourceKind: String) -> Abort {
        Abort(.badRequest, reason: "projectId is required — name the project to \(verb) \(resourceKind) in.")
    }

    /// The project a project-scoped create lands in — named, authorized, and
    /// confirmed to exist (issues #1049, #1059).
    ///
    /// Every create routes through here: the five infrastructure creates
    /// (volume, network, security group, floating IP, DNS zone) call it
    /// directly, and `resolveProjectForCreate` — the VM/sandbox spine — is
    /// built on it. Route new project-scoped creates through it too rather than
    /// writing a copy; the four inline copies this replaced had already drifted
    /// over whether the resolved project must exist.
    ///
    /// **It asserts the project exists**, so no create hands an unbacked
    /// `project_id` to an insert for the foreign key to reject. The three steps
    /// run in this order, and the order is the load-bearing part:
    ///
    /// 1. Read the id, refusing if there is none — a body-shape check that
    ///    consults nothing, so it discloses nothing.
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
    /// `ProjectResolutionTests` pins both, at all seven endpoints: what a caller
    /// inventing a UUID actually gets is `403`.
    ///
    /// Note what this function does *not* take: a `User`. It used to, for the
    /// sole purpose of reading `currentOrganizationId` to pick a default
    /// project. With the default gone the only principal this resolution has an
    /// opinion about is the one the evaluator already holds, and keeping the
    /// parameter would suggest otherwise. The `created_at`/`id` sort that made
    /// the old fallback repeatable went with it — it was deleted rather than
    /// moved, because with nothing being guessed there is nothing left to make
    /// repeatable.
    ///
    /// - Parameters:
    ///   - requestedProjectId: The project named by the request body. Required;
    ///     `nil` is refused, since there is no default project to fall back to.
    ///   - action: The create permission to check on the resolved project
    ///     (e.g. `"create_volume"`).
    ///   - resourceKind: Plural noun for the resource being created
    ///     (e.g. `"volumes"`), used in the permission and missing-project
    ///     messages.
    ///   - verb: The verb those messages read with, for the endpoints that don't
    ///     call it creating (floating IPs are *allocated*).
    func authorizedProjectForCreate(
        requested requestedProjectId: UUID?,
        action: String,
        resourceKind: String,
        verb: String = "create"
    ) async throws -> Project {
        guard let projectId = requestedProjectId else {
            throw Self.projectIsRequired(verb: verb, resourceKind)
        }

        let allowed = try await can(action, on: "project", id: projectId.uuidString)
        guard allowed else {
            throw Abort(
                .forbidden, reason: "You don't have permission to \(verb) \(resourceKind) in this project")
        }

        guard let project = try await Project.find(projectId, on: db) else {
            throw Abort(.badRequest, reason: "Project \(projectId) does not exist")
        }
        return project
    }

    /// Resolve the target project and environment for a VM or sandbox create,
    /// enforcing the `create_resources` permission, the caller's current
    /// organization, and environment validity.
    ///
    /// This is the shared spine behind VM and sandbox creation (issue #675):
    /// both paths must scope a create identically, and any divergence between
    /// them is a latent authorization bug.
    ///
    /// **It is now built on `authorizedProjectForCreate` rather than sitting
    /// beside it.** The two used to be siblings because their fallbacks
    /// disagreed and neither could stand on the other; with no fallback left,
    /// this one is simply that resolution plus two extra steps. Composing them
    /// is what makes the guarantee structural: the thing that must never drift
    /// again — what a create does when it is told no project, and in what order
    /// it checks things — now exists in exactly one place. The cost, stated
    /// plainly: a future change to `authorizedProjectForCreate`'s policy reaches
    /// VM and sandbox create silently. That is the point, but it is worth
    /// knowing.
    ///
    /// Composition also **closed a disclosure leak here**. This function used to
    /// look the project up first (`400 "Project not found"`), then check the
    /// organization (`403 "Access denied to project"`), and only then ask the
    /// evaluator — exactly the ordering `authorizedProjectForCreate` was written
    /// to avoid, so `POST /api/vms` was an existence oracle over other tenants'
    /// projects. It answers `403` now, like the other five. That is a visible
    /// status change for a caller sending a project id nothing backs.
    ///
    /// **The current-organization check is kept, and kept here.** It could have
    /// been dropped to make the seven identical, but that would be a *widening*:
    /// a principal holding `create_resources` on a project in organization B
    /// could create there while their current organization is A — and the
    /// middleware, which gates the `/api/vms` and `/api/sandboxes` collections
    /// against the current organization, would have admitted the request on
    /// behalf of A. That may be the right end state; it is a separate decision
    /// with its own blast radius, not one to smuggle into "remove the default
    /// project". Behind the permission check it discloses nothing: its `403`
    /// only ever reaches a caller the evaluator already agreed may create here.
    /// One operator-facing consequence — the decision log shows an *allow*
    /// followed by a `403`, which is the organization scope refusing a create
    /// the evaluator would otherwise permit.
    ///
    /// Reading `user.currentOrganizationId` is now that check's only job. It
    /// used to seed the default-project lookup as well, so after this nothing on
    /// a create path *chooses* anything from request-scoped user state; it only
    /// narrows.
    ///
    /// - Parameter resourceKind: Plural noun for the resource being created
    ///   (e.g. `"VMs"`, `"sandboxes"`), used in the permission and
    ///   missing-project messages.
    func resolveProjectForCreate(
        requestedProjectId: UUID?,
        requestedEnvironment: String?,
        user: User,
        resourceKind: String
    ) async throws -> (project: Project, environment: String) {
        let project = try await authorizedProjectForCreate(
            requested: requestedProjectId,
            action: "create_resources",
            resourceKind: resourceKind)

        // Current-organization scope, deliberately *after* the permission
        // check — ahead of it, "not found" told apart from "denied" is an
        // existence oracle.
        let rootOrgId = try await project.getRootOrganizationId(on: db)
        guard let orgId = rootOrgId, user.currentOrganizationId == orgId else {
            throw Abort(.forbidden, reason: "Access denied to project")
        }

        return (project, try project.resolveEnvironment(requestedEnvironment))
    }
}
