import Fluent

/// Adds `snapshot_export` (issue #428) to the enforced value set of
/// `resource_operations.kind`.
///
/// `EnforcePersistedEnumValues` installed a CHECK constraint (Postgres) /
/// validation triggers (SQLite) for the column; deployments that migrated
/// before this kind existed would reject every export operation insert at
/// the database. Re-installing the constraint with the extended list is the
/// documented follow-up for adding an enum case — install is idempotent
/// (drop-if-exists first), so fresh databases whose base migration already
/// carried the new value are unaffected.
struct AddSnapshotExportOperationKind: AsyncMigration {
    private static var constraint: PersistedEnumConstraint {
        // The canonical definition, which already includes `snapshot_export`.
        EnforcePersistedEnumValues.constraints.first {
            $0.table == "resource_operations" && $0.column == "kind"
        }!
    }

    func prepare(on database: any Database) async throws {
        try await EnforcePersistedEnumValues.prepare(Self.constraint, on: database)
    }

    func revert(on database: any Database) async throws {
        // Reverting re-installs rather than drops: the column should stay
        // guarded, and rows with `snapshot_export` may exist — narrowing the
        // constraint underneath them would fail validation anyway.
        try await EnforcePersistedEnumValues.prepare(Self.constraint, on: database)
    }
}
