import Fluent
import Vapor

// IAM phase 5 (issue #482): `req.can` is Cedar. This legacy-vocabulary form
// (the permission names the pre-Cedar authorizer used) survives so the ~55
// handler sites need not churn: it translates the (permission, resourceType)
// pair to the IAM action naming the act being gated — the same mapping shadow
// evaluation validated — and evaluates it through `IAMAuthorizer`. The
// Cedar-native form lives in IAMAuthorizer.swift; new code should prefer it.

extension Request {
    /// Whether the current user holds `permission` on the given resource, in
    /// the legacy permission vocabulary.
    ///
    /// There is no system-admin short-circuit anymore: admins are allowed by
    /// the `platform-system-admin` tier-1 policy, which lands their decisions
    /// in the decision log and lets guardrail forbids bind them.
    ///
    /// A pair the translator cannot map fails closed — denied, logged, and
    /// recorded as `untranslated` in the decision log — because an
    /// untranslatable check is a check site nobody mapped, not an allowance.
    ///
    /// - Throws: `.unauthorized` if the request is unauthenticated.
    func can(_ permission: String, on resourceType: String, id: String) async throws -> Bool {
        guard let user = auth.get(User.self), let userID = user.id else {
            throw Abort(.unauthorized)
        }
        return try await IAMAuthorizer.checkLegacyVocabulary(
            userID: userID,
            permission: permission,
            resourceType: resourceType,
            resourceID: id,
            context: IAMCheckContext(path: url.path, method: method.rawValue, requestID: self.id),
            state: iamAuthState,
            app: application,
            db: db
        )
    }

    /// Enforce `permission` on the given resource, throwing `.forbidden` when
    /// the current user lacks it.
    ///
    /// - Throws: `.unauthorized` if unauthenticated, `.forbidden` if the check fails.
    func authorize(_ permission: String, on resourceType: String, id: String) async throws {
        guard try await can(permission, on: resourceType, id: id) else {
            throw Abort(.forbidden, reason: "Insufficient permissions for this operation")
        }
    }

    /// Convenience overload taking a `UUID` resource id.
    func authorize(_ permission: String, on resourceType: String, id: UUID) async throws {
        try await authorize(permission, on: resourceType, id: id.uuidString)
    }

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
        let environment = requestedEnvironment ?? project.defaultEnvironment
        if !project.hasEnvironment(environment) {
            throw Abort(
                .badRequest,
                reason:
                    "Environment '\(environment)' not available in project. Available: \(project.environments.joined(separator: ", "))"
            )
        }

        return (project, environment)
    }
}
