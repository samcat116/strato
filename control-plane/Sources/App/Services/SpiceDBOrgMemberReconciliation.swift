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
/// The write is idempotent — an already-present tuple returns a 409 that we treat as
/// success — so this is safe to run on every startup.
func backfillOrganizationMemberRelationships(_ app: Application) async throws {
    let memberships = try await UserOrganization.query(on: app.db).all()

    var backfilled = 0
    for membership in memberships {
        let userID = membership.$user.id
        let organizationID = membership.$organization.id

        do {
            try await app.spicedb.writeRelationship(
                entity: "organization",
                entityId: organizationID.uuidString,
                relation: membership.role,
                subject: "user",
                subjectId: userID.uuidString
            )
            backfilled += 1
        } catch SpiceDBError.relationshipWriteFailed(let status) where status == .conflict {
            // Relationship already exists, which is the common case.
        }
    }

    if backfilled > 0 {
        app.logger.notice(
            "Backfilled SpiceDB organization→member relationships",
            metadata: ["count": .stringConvertible(backfilled)]
        )
    }
}
