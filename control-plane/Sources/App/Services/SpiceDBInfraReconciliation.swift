import Fluent
import Foundation
import Vapor

/// Ensures every persisted agent and site has its `#parent` relationship in
/// SpiceDB, pointing at its org-or-OU owner. Backfills rows that predate
/// org-scoped infrastructure (whose DB scope the `BackfillInfraOrganizationScope`
/// migration assigned) and re-derives tuples after a schema/tuple reset;
/// without the tuples, org admins can't see or manage their own agents and
/// sites — only system admins could.
///
/// Uses a single chunked, idempotent OPERATION_TOUCH batch (the
/// SpiceDBProjectReconciliation pattern), so re-running on every boot is cheap.
func backfillInfraParentRelationships(_ app: Application) async throws {
    var tuples: [RelationshipTuple] = []

    for agent in try await Agent.query(on: app.db).all() {
        guard let agentId = agent.id else { continue }
        guard let parent = agent.organizationScope?.spiceDBParentRef else {
            app.logger.warning(
                "Agent has no organization scope; skipping SpiceDB backfill",
                metadata: ["agent": .string(agent.name)]
            )
            continue
        }
        tuples.append(
            RelationshipTuple(
                entity: "agent",
                entityId: agentId.uuidString,
                relation: "parent",
                subject: parent.subjectType,
                subjectId: parent.subjectId.uuidString
            )
        )
    }

    for site in try await Site.query(on: app.db).all() {
        guard let siteId = site.id else { continue }
        guard let parent = site.organizationScope?.spiceDBParentRef else {
            app.logger.warning(
                "Site has no organization scope; skipping SpiceDB backfill",
                metadata: ["site": .string(site.name)]
            )
            continue
        }
        tuples.append(
            RelationshipTuple(
                entity: "site",
                entityId: siteId.uuidString,
                relation: "parent",
                subject: parent.subjectType,
                subjectId: parent.subjectId.uuidString
            )
        )
    }

    try await app.spicedb.touchRelationships(tuples)
    if !tuples.isEmpty {
        app.logger.notice(
            "Backfilled SpiceDB agent/site #parent relationships",
            metadata: ["count": .stringConvertible(tuples.count)]
        )
    }
}
