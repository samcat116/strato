import Fluent
import SQLKit
import StratoShared

/// The append-only mutation audit trail (ADR 0001, stage 2).
///
/// Every id column is deliberately foreign-key-free, for the reason
/// `resource_operations.resource_id` is: the record must outlive the resource
/// it describes, and — since it can name a machine principal — the principal
/// that made it. Nothing updates or deletes these rows, so the table carries
/// no status column and no retention sweep.
struct CreateResourceEvent: AsyncMigration {
    /// The enum columns' `CHECK` guards, derived from the Swift enums so a new
    /// case is a compile-visible reason to write the follow-up migration that
    /// replaces the constraint (see `PersistedEnumConstraint`). This table
    /// postdates `EnforcePersistedEnumValues`, so it installs its own through
    /// that migration's reusable per-constraint entry point.
    static let enumConstraints: [PersistedEnumConstraint] = [
        PersistedEnumConstraint(
            table: "resource_events", column: "actor_type",
            allowedValues: ResourceEventActorType.allCases.map(\.rawValue)
        ),
        PersistedEnumConstraint(
            table: "resource_events", column: "resource_kind",
            allowedValues: OperationResourceKind.allCases.map(\.rawValue)
        ),
        PersistedEnumConstraint(
            table: "resource_events", column: "mutation",
            allowedValues: VMOperationKind.allCases.map(\.rawValue)
        ),
    ]

    func prepare(on database: Database) async throws {
        try await database.schema("resource_events")
            .id()
            .field("actor_type", .string, .required)
            .field("actor_id", .uuid)
            .field("resource_kind", .string, .required)
            .field("resource_id", .uuid, .required)
            .field("resource_name", .string)
            .field("mutation", .string, .required)
            .field("target_generation", .int64)
            .field("organization_id", .uuid)
            .field("project_id", .uuid)
            .field("created_at", .datetime)
            .create()

        if let sql = database as? any SQLDatabase {
            // "What happened to this resource", newest first — the read the
            // operations façade is built on (ADR 0001, stage 4).
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_resource_events_resource "
                    + "ON resource_events (resource_kind, resource_id, created_at DESC)"
            ).run()
            // "What happened in this organization", newest first — the same
            // browse axis `audit_events` is indexed for.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_resource_events_org_created "
                    + "ON resource_events (organization_id, created_at DESC)"
            ).run()
            // "What did this principal do" — the attribution question the
            // table exists to answer.
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_resource_events_actor "
                    + "ON resource_events (actor_type, actor_id, created_at DESC)"
            ).run()
        }

        for constraint in Self.enumConstraints {
            try await EnforcePersistedEnumValues.prepare(constraint, on: database)
        }
    }

    func revert(on database: Database) async throws {
        // The indexes and constraints belong to the table and go with it.
        try await database.schema("resource_events").delete()
    }
}
