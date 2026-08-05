import Fluent
import SQLKit
import StratoShared

/// The append-only mutation audit trail (ADR 0001, stage 2).
///
/// Every id column is deliberately foreign-key-free, for the reason
/// `resource_operations.resource_id` is: the record must outlive the resource
/// it describes, and — since it can name a machine principal — the principal
/// that made it. Nothing updates or deletes these rows, so the table carries
/// no status column and no retention sweep; the trigger below is what makes
/// that a property of the schema rather than a promise in a doc comment.
struct CreateResourceEvent: AsyncMigration {
    /// The enum columns' `CHECK` guards. `allowedValues` derives from
    /// `allCases`, which keeps a fresh database correct automatically but does
    /// **not** repair an already-migrated one: adding a case installs the wider
    /// constraint only where this migration has yet to run.
    ///
    /// Adding a `VMOperationKind` (or `OperationResourceKind`) case therefore
    /// needs a follow-up migration re-installing *both* the
    /// `resource_operations` constraint from `EnforcePersistedEnumValues` and
    /// the one here — the existing `AddResizeOperationKind` /
    /// `AddSnapshotExportOperationKind` pair looks its constraint up by
    /// `table == "resource_operations"` and would silently cover only half.
    /// `ResourceEventEnumConstraintTests` fails the moment a case is added
    /// without that follow-up, because nothing in the type system can.
    ///
    /// A follow-up must install with plain `ALTER TABLE ... ADD CONSTRAINT`,
    /// as below, and not `EnforcePersistedEnumValues.prepare`: that path first
    /// runs a normalizing `UPDATE` over every row, which the append-only
    /// trigger rejects.
    static let enumConstraints: [PersistedEnumConstraint] = [
        PersistedEnumConstraint(
            table: "resource_events", column: "actor_type",
            allowedValues: MutationActorType.allCases.map(\.rawValue)
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

    static let triggerName = "trg_resource_events_append_only"
    static let triggerFunctionName = "resource_events_reject_row_change"

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
            // Required, unlike `audit_events.created_at`: it is the sort key on
            // every index below, and `@Timestamp(on: .create)` always populates
            // it, so the column may as well refuse a row that has no time.
            .field("created_at", .datetime, .required)
            .create()

        let sql = try PostgresMigrationSQL.database(database)

        // "What happened to this resource", newest first — the read the
        // operations façade is built on (ADR 0001, stage 4).
        try await PostgresMigrationSQL.execute(
            "CREATE INDEX IF NOT EXISTS idx_resource_events_resource "
                + "ON resource_events (resource_kind, resource_id, created_at DESC)",
            on: sql)
        // "What happened in this organization", newest first — the same browse
        // axis `audit_events` is indexed for.
        try await PostgresMigrationSQL.execute(
            "CREATE INDEX IF NOT EXISTS idx_resource_events_org_created "
                + "ON resource_events (organization_id, created_at DESC)",
            on: sql)
        // "What did this principal do" — the attribution question the table
        // exists to answer.
        try await PostgresMigrationSQL.execute(
            "CREATE INDEX IF NOT EXISTS idx_resource_events_actor "
                + "ON resource_events (actor_type, actor_id, created_at DESC)",
            on: sql)

        // The table is created empty, so there is nothing to normalize or
        // validate first — the `EnforcePersistedEnumValues` flow exists for
        // columns with history, and its normalizing `UPDATE` would fight the
        // trigger installed below. Drop-then-add so a retry after an
        // interrupted run is safe.
        for constraint in Self.enumConstraints {
            let name = PostgresMigrationSQL.identifier(constraint.name)
            let column = PostgresMigrationSQL.identifier(constraint.column)
            let allowed = constraint.allowedValues.map(PostgresMigrationSQL.literal).joined(separator: ", ")
            try await PostgresMigrationSQL.execute(
                "ALTER TABLE \"resource_events\" DROP CONSTRAINT IF EXISTS \(name)", on: sql)
            try await PostgresMigrationSQL.execute(
                "ALTER TABLE \"resource_events\" ADD CONSTRAINT \(name) CHECK (\(column) IN (\(allowed)))",
                on: sql)
        }

        // Append-only, enforced. Three doc sites and the whole point of the
        // table rest on rows never changing after they commit; a convention
        // that only code respects is one an incident-time `UPDATE` breaks
        // silently. A retention policy, if volume ever demands one, replaces
        // this trigger in the migration that adds the sweep — which is exactly
        // the deliberate, reviewable act it should be.
        try await PostgresMigrationSQL.execute(
            """
            CREATE OR REPLACE FUNCTION \(Self.triggerFunctionName)() RETURNS trigger AS $$
            BEGIN
                RAISE EXCEPTION 'resource_events is append-only; % is not permitted', TG_OP;
            END;
            $$ LANGUAGE plpgsql
            """,
            on: sql)
        try await PostgresMigrationSQL.execute(
            "DROP TRIGGER IF EXISTS \(Self.triggerName) ON \"resource_events\"", on: sql)
        try await PostgresMigrationSQL.execute(
            "CREATE TRIGGER \(Self.triggerName) BEFORE UPDATE OR DELETE ON \"resource_events\" "
                + "FOR EACH ROW EXECUTE FUNCTION \(Self.triggerFunctionName)()",
            on: sql)
    }

    func revert(on database: Database) async throws {
        // Dropping the table takes its indexes, constraints, and trigger with
        // it; the trigger's function is schema-level and has to go explicitly.
        try await database.schema("resource_events").delete()
        let sql = try PostgresMigrationSQL.database(database)
        try await PostgresMigrationSQL.execute(
            "DROP FUNCTION IF EXISTS \(Self.triggerFunctionName)()", on: sql)
    }
}
