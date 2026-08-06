import Fluent
import SQLKit

/// Splits `resource_events` into "a mutation was asked for" and "it finished"
/// (ADR 0001 stage 4, STR-147).
///
/// Every row until now recorded a request. That is enough for attribution, and
/// enough for the operations façade to answer any mutation whose resource
/// still exists — the resource's own `conditions` say whether it converged.
/// It is not enough for a **delete**, whose success is defined by the row
/// ceasing to exist: once the finalizers empty and the row goes, a client
/// polling the resource gets a `404` that means deleted, never-existed, and
/// not-authorized alike, and `404`-means-success is a dangerous default to
/// build into a client.
///
/// So the reap appends a second, terminal row, and the façade answers deletes
/// off that positive record instead of inferring success from absence. Adding
/// a row rather than updating the first one is what keeps the table (and its
/// append-only trigger) intact.
///
/// The column is added with a `DEFAULT`, not backfilled: `ALTER TABLE ... ADD
/// COLUMN ... DEFAULT` is catalog-only on PostgreSQL 11+, so it neither
/// rewrites the table nor fires the append-only trigger — which rejects every
/// `UPDATE`, including a migration's.
struct AddPhaseToResourceEvents: AsyncMigration {
    static let constraint = PersistedEnumConstraint(
        table: "resource_events", column: "phase",
        allowedValues: ResourceEventPhase.allCases.map(\.rawValue)
    )

    /// Terminal rows are a small minority — one per completed delete against
    /// every request ever recorded — so the façade's "did this delete finish?"
    /// read gets a partial index rather than a wider version of the existing
    /// `(resource_kind, resource_id, created_at DESC)` one.
    static let terminalIndexName = "idx_resource_events_terminal"

    func prepare(on database: Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)

        try await PostgresMigrationSQL.execute(
            "ALTER TABLE \"resource_events\" ADD COLUMN IF NOT EXISTS phase text NOT NULL "
                + "DEFAULT \(PostgresMigrationSQL.literal(ResourceEventPhase.requested.rawValue))",
            on: sql)

        // Drop-then-add so a retry after an interrupted run is safe, exactly as
        // `CreateResourceEvent` installs its own three. Plain `ALTER TABLE`
        // rather than `EnforcePersistedEnumValues.prepare`, for the same reason
        // it gives: that path opens with a normalizing `UPDATE`, which the
        // append-only trigger rejects.
        let name = PostgresMigrationSQL.identifier(Self.constraint.name)
        let column = PostgresMigrationSQL.identifier(Self.constraint.column)
        let allowed = Self.constraint.allowedValues.map(PostgresMigrationSQL.literal).joined(separator: ", ")
        try await PostgresMigrationSQL.execute(
            "ALTER TABLE \"resource_events\" DROP CONSTRAINT IF EXISTS \(name)", on: sql)
        try await PostgresMigrationSQL.execute(
            "ALTER TABLE \"resource_events\" ADD CONSTRAINT \(name) CHECK (\(column) IN (\(allowed)))",
            on: sql)

        try await PostgresMigrationSQL.execute(
            "CREATE INDEX IF NOT EXISTS \(Self.terminalIndexName) "
                + "ON resource_events (resource_kind, resource_id, created_at DESC) "
                + "WHERE phase <> \(PostgresMigrationSQL.literal(ResourceEventPhase.requested.rawValue))",
            on: sql)
    }

    func revert(on database: Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)
        try await PostgresMigrationSQL.execute(
            "DROP INDEX IF EXISTS \(Self.terminalIndexName)", on: sql)
        try await PostgresMigrationSQL.execute(
            "ALTER TABLE \"resource_events\" DROP CONSTRAINT IF EXISTS "
                + "\(PostgresMigrationSQL.identifier(Self.constraint.name))",
            on: sql)
        try await PostgresMigrationSQL.execute(
            "ALTER TABLE \"resource_events\" DROP COLUMN IF EXISTS phase", on: sql)
    }
}
