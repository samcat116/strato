import Fluent
import Vapor

extension Request {
    /// Resolves the explicitly named project for a project-scoped create.
    /// Authorization must precede the existence lookup so an unauthorized
    /// caller cannot use the response to discover another tenant's project IDs.
    func authorizedProjectForCreate(
        requested requestedProjectId: UUID?,
        action: String,
        resourceKind: String,
        verb: String = "create"
    ) async throws -> Project {
        guard let projectId = requestedProjectId else {
            throw Abort(
                .badRequest,
                reason: "projectId is required — name the project to \(verb) \(resourceKind) in."
            )
        }

        let allowed = try await can(action, on: IAMNode(type: .project, id: projectId))
        guard allowed else {
            throw Abort(
                .forbidden, reason: "You don't have permission to \(verb) \(resourceKind) in this project")
        }

        guard let project = try await Project.find(projectId, on: db) else {
            throw Abort(.badRequest, reason: "Project \(projectId) does not exist")
        }
        return project
    }

    /// Resolves the project and environment for VM and sandbox creation, then
    /// narrows the authorized project to the caller's current organization.
    /// The organization check deliberately remains after authorization to
    /// preserve the same cross-tenant disclosure protection as the base lookup.
    func resolveProjectForCreate(
        requestedProjectId: UUID?,
        requestedEnvironment: String?,
        user: User,
        action: String,
        resourceKind: String
    ) async throws -> (project: Project, environment: String) {
        let project = try await authorizedProjectForCreate(
            requested: requestedProjectId,
            action: action,
            resourceKind: resourceKind)

        let rootOrgId = try await project.getRootOrganizationId(on: db)
        guard let orgId = rootOrgId, user.currentOrganizationId == orgId else {
            throw Abort(.forbidden, reason: "Access denied to project")
        }

        return (project, try project.resolveEnvironment(requestedEnvironment))
    }
}
