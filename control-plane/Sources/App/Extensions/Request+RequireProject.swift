import Fluent
import Vapor

extension Request {
    /// The project named by a path parameter, or a 400/404 (issue #760).
    ///
    /// Sub-resource routes under `/projects/:projectID/...` all begin by
    /// resolving their parent project with the same two guards and the same
    /// status codes; ten independent copies meant any added check — org
    /// scoping, say — had to land in ten places. This is that lookup only:
    /// permission checks stay with the caller, since they differ per route.
    ///
    /// Distinct from `resolveProjectForCreate(...)`, which resolves the *target*
    /// project for a create (default-project fallback, org scoping, permission,
    /// environment) rather than reading one out of the path.
    func requireProject(paramName: String = "projectID") async throws -> Project {
        guard let projectID = parameters.get(paramName, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }
        return try await requireProject(id: projectID)
    }

    /// The project with `id`, or a 404 — for callers that already hold the id
    /// (a foreign key on another row, say) rather than reading it from the path.
    func requireProject(id: UUID) async throws -> Project {
        guard let project = try await Project.find(id, on: db) else {
            throw Abort(.notFound, reason: "Project not found")
        }
        return project
    }
}
