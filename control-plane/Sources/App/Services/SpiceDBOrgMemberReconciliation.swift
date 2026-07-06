import Foundation
import Vapor
import Fluent

/// Ensures every relational `UserOrganization` membership has a matching
/// `organization#<role>@user` tuple in SpiceDB.
///
/// SpiceDB is the sole authorization source, but the relational `role` column is the
/// system of record for who-belongs-to-what (it drives the org switcher, member
/// lists, and the "last admin" integrity guard). This backfill re-derives the SpiceDB
/// tuples from those rows so existing members keep access after a schema/tuple reset,
/// and so any membership created out-of-band (migrations, fixtures) is reflected.
///
/// Uses a single chunked, idempotent OPERATION_TOUCH batch rather than one HTTP
/// round-trip per membership, so re-running on every boot stays cheap even at scale.
func backfillOrganizationMemberRelationships(_ app: Application) async throws {
    let memberships = try await UserOrganization.query(on: app.db).all()

    let tuples = memberships.map { membership in
        RelationshipTuple(
            entity: "organization",
            entityId: membership.$organization.id.uuidString,
            relation: membership.role,
            subject: "user",
            subjectId: membership.$user.id.uuidString
        )
    }

    try await app.spicedb.touchRelationships(tuples)
    if !tuples.isEmpty {
        app.logger.notice(
            "Backfilled SpiceDB organization→member relationships",
            metadata: ["count": .stringConvertible(tuples.count)]
        )
    }
}
