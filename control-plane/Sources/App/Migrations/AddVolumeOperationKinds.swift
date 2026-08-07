import Fluent
import SQLKit

/// Widens four `CHECK` constraints for the enum cases STR-148 adds:
/// `OperationResourceKind.volume`, and `VMOperationKind.attach`/`.detach`.
///
/// Four, across two tables and — crucially — two different install mechanisms.
/// `resource_operations` goes through `EnforcePersistedEnumValues.prepare`,
/// which normalizes existing rows before re-installing. `resource_events`
/// cannot: that normalizing `UPDATE` is exactly what its append-only trigger
/// exists to reject, so its constraints are re-installed with a plain
/// `ALTER TABLE`, the way `CreateResourceEvent` installs them. Missing either
/// half fails `PersistedEnumConstraintTests` or
/// `ResourceEventEnumConstraintTests` — which is what those suites are for,
/// since nothing in the type system can catch it.
///
/// Idempotent on both paths (drop-if-exists first), so a database whose base
/// migrations already carried the wider lists is unaffected.
struct AddVolumeOperationKinds: AsyncMigration {
    private static var operationConstraints: [PersistedEnumConstraint] {
        EnforcePersistedEnumValues.constraints.filter {
            $0.table == "resource_operations" && ($0.column == "kind" || $0.column == "resource_kind")
        }
    }

    private static var eventConstraints: [PersistedEnumConstraint] {
        CreateResourceEvent.enumConstraints.filter {
            $0.column == "resource_kind" || $0.column == "mutation"
        }
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
        // Re-installs rather than drops, like `AddResizeOperationKind`: the
        // columns should stay guarded, and rows carrying the new values may
        // already exist.
        try await prepare(on: database)
    }
}
