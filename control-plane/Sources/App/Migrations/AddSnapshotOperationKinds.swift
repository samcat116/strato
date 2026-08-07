import Fluent
import SQLKit

/// Widens the `resource_kind` `CHECK` constraints for the three enum cases
/// STR-150 adds: `OperationResourceKind.volumeSnapshot`, `.vmCheckpoint` and
/// `.sandboxSnapshot`.
///
/// Two tables and — crucially — two different install mechanisms, exactly as
/// `AddVolumeOperationKinds` documents. `resource_operations` goes through
/// `EnforcePersistedEnumValues.prepare`, which normalizes existing rows before
/// re-installing. `resource_events` cannot: that normalizing `UPDATE` is what
/// its append-only trigger exists to reject, so its constraints are
/// re-installed with a plain `ALTER TABLE`. Missing either half fails
/// `PersistedEnumConstraintTests` or `ResourceEventEnumConstraintTests`, which
/// is what those suites are for.
///
/// No `mutation` widening this time: an artifact's lifecycle is spelled with
/// `VMOperationKind.create`/`.delete`/`.snapshotExport`, all of which the
/// constraint already allows. The old `.snapshot`/`.snapshotDelete` values stay
/// in the enum so rows written before this change still decode.
///
/// Idempotent on both paths (drop-if-exists first).
struct AddSnapshotOperationKinds: AsyncMigration {
    private static var operationConstraints: [PersistedEnumConstraint] {
        EnforcePersistedEnumValues.constraints.filter {
            $0.table == "resource_operations" && $0.column == "resource_kind"
        }
    }

    private static var eventConstraints: [PersistedEnumConstraint] {
        CreateResourceEvent.enumConstraints.filter { $0.column == "resource_kind" }
    }

    func prepare(on database: any Database) async throws {
        for constraint in Self.operationConstraints {
            try await EnforcePersistedEnumValues.prepare(constraint, on: database)
        }

        let sql = try PostgresMigrationSQL.database(database)
        for constraint in Self.eventConstraints {
            let name = PostgresMigrationSQL.identifier(constraint.name)
            let column = PostgresMigrationSQL.identifier(constraint.column)
            let allowed = constraint.allowedValues.map(PostgresMigrationSQL.literal).joined(separator: ", ")
            try await PostgresMigrationSQL.execute(
                "ALTER TABLE \"resource_events\" DROP CONSTRAINT IF EXISTS \(name)", on: sql)
            try await PostgresMigrationSQL.execute(
                "ALTER TABLE \"resource_events\" ADD CONSTRAINT \(name) CHECK (\(column) IN (\(allowed)))",
                on: sql)
        }
    }

    func revert(on database: any Database) async throws {
        // Re-installs rather than drops, like `AddVolumeOperationKinds`: the
        // columns should stay guarded, and rows carrying the new values may
        // already exist.
        try await prepare(on: database)
    }
}
