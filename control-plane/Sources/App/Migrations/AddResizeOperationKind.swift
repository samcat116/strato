import Fluent

/// Adds `resize` (issue #568) to the enforced value set of
/// `resource_operations.kind`, the documented follow-up for a new operation
/// kind: `EnforcePersistedEnumValues` guards the column, so a deployment that
/// migrated before this kind existed would reject every online-resize insert
/// at the database. Re-installing the constraint with the extended list is
/// idempotent (drop-if-exists first), so fresh databases whose base migration
/// already carried the value are unaffected.
struct AddResizeOperationKind: AsyncMigration {
    private static var constraint: PersistedEnumConstraint {
        // The canonical definition, which already includes `resize`.
        EnforcePersistedEnumValues.constraints.first {
            $0.table == "resource_operations" && $0.column == "kind"
        }!
    }

    func prepare(on database: any Database) async throws {
        try await EnforcePersistedEnumValues.prepare(Self.constraint, on: database)
    }

    func revert(on database: any Database) async throws {
        // Reverting re-installs rather than drops, for the same reason
        // `AddSnapshotExportOperationKind` does: the column should stay
        // guarded, and rows with `resize` may exist.
        try await EnforcePersistedEnumValues.prepare(Self.constraint, on: database)
    }
}
