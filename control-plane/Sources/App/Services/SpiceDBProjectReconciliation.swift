import Foundation
import Vapor
import Fluent

/// Ensures every persisted project has its `project#organization` relationship in
/// SpiceDB. This backfills projects created before the creation path wrote the
/// tuple (see issue #267): without it, project-scoped permissions that resolve
/// via `organization->admin` (update_project, image/VM/volume creation, ...) can't
/// resolve and the project's own org admin gets 403s.
///
/// The write is idempotent — an already-present tuple returns a 409 that we treat
/// as success — so this is safe to run on every startup.
func backfillProjectOrganizationRelationships(_ app: Application) async throws {
    let projects = try await Project.query(on: app.db).all()

    var backfilled = 0
    for project in projects {
        guard let projectId = project.id else { continue }
        guard let organizationId = try await project.getRootOrganizationId(on: app.db) else {
            app.logger.warning(
                "Project has no resolvable organization; skipping SpiceDB backfill",
                metadata: ["project": .string(projectId.uuidString)]
            )
            continue
        }

        do {
            try await app.spicedb.writeRelationship(
                entity: "project",
                entityId: projectId.uuidString,
                relation: "organization",
                subject: "organization",
                subjectId: organizationId.uuidString
            )
            backfilled += 1
        } catch SpiceDBError.relationshipWriteFailed(let status) where status == .conflict {
            // Relationship already exists, which is the common case.
        }
    }

    if backfilled > 0 {
        app.logger.notice(
            "Backfilled SpiceDB project→organization relationships", metadata: ["count": .stringConvertible(backfilled)]
        )
    }
}
