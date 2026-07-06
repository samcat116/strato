import Foundation
import Vapor
import Fluent

/// Ensures every persisted project has its `project#parent` relationship in SpiceDB,
/// pointing at the project's *immediate* parent (the owning OU when OU-scoped, else
/// the organization). Backfills projects created before the creation path wrote the
/// tuple (issue #267) and re-derives tuples after a schema/tuple reset; without it,
/// project-scoped permissions (view_project/manage_project, image/VM/volume creation)
/// can't resolve and even the project's own admin gets 403s.
///
/// Uses a single chunked, idempotent OPERATION_TOUCH batch rather than one HTTP
/// round-trip per project, so re-running on every boot is cheap even at scale.
func backfillProjectOrganizationRelationships(_ app: Application) async throws {
    let projects = try await Project.query(on: app.db).all()

    var tuples: [RelationshipTuple] = []
    for project in projects {
        guard let projectId = project.id else { continue }
        guard let parent = project.spiceDBParentRef else {
            app.logger.warning(
                "Project has no resolvable parent; skipping SpiceDB backfill",
                metadata: ["project": .string(projectId.uuidString)]
            )
            continue
        }
        tuples.append(
            RelationshipTuple(
                entity: "project",
                entityId: projectId.uuidString,
                relation: "parent",
                subject: parent.subjectType,
                subjectId: parent.subjectId.uuidString
            )
        )
    }

    try await app.spicedb.touchRelationships(tuples)
    if !tuples.isEmpty {
        app.logger.notice(
            "Backfilled SpiceDB project#parent relationships", metadata: ["count": .stringConvertible(tuples.count)]
        )
    }
}

/// Ensures every persisted organizational unit has its `organizational_unit#parent`
/// relationship in SpiceDB (parent OU when nested, else the organization). This is
/// what lets OU-scoped projects inherit access up the chain
/// (project → parent(OU) → parent(org)); without it, an OU-scoped project's parent
/// tuple would dangle and even org admins would lose access.
func backfillOrganizationalUnitParentRelationships(_ app: Application) async throws {
    let ous = try await OrganizationalUnit.query(on: app.db).all()

    var tuples: [RelationshipTuple] = []
    for ou in ous {
        guard let ouId = ou.id else { continue }
        let parent = ou.spiceDBParentRef
        tuples.append(
            RelationshipTuple(
                entity: "organizational_unit",
                entityId: ouId.uuidString,
                relation: "parent",
                subject: parent.subjectType,
                subjectId: parent.subjectId.uuidString
            )
        )
    }

    try await app.spicedb.touchRelationships(tuples)
    if !tuples.isEmpty {
        app.logger.notice(
            "Backfilled SpiceDB organizational_unit#parent relationships",
            metadata: ["count": .stringConvertible(tuples.count)]
        )
    }
}
