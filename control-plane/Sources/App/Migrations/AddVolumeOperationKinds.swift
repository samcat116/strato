import Fluent
import SQLKit

/// Widens the `resource_events` `CHECK` constraints for the enum cases STR-148
/// adds: `OperationResourceKind.volume`, and `VMOperationKind.attach`/`.detach`.
///
/// It widened the matching `resource_operations` constraints too, until that
/// table was dropped in STR-152. What is left is the `resource_events` half,
/// and its mechanism is the interesting one: those constraints cannot go
/// through `EnforcePersistedEnumValues.prepare`, because its normalizing
/// `UPDATE` is exactly what the table's append-only trigger exists to reject.
/// They are re-installed with a plain `ALTER TABLE`, the way
/// `CreateResourceEvent` installs them. Missing that fails
/// `ResourceEventEnumConstraintTests` — which is what that suite is for, since
/// nothing in the type system can catch it.
///
/// Idempotent (drop-if-exists first), so a database whose base migrations
/// already carried the wider lists is unaffected.
struct AddVolumeOperationKinds: AsyncMigration {
    private static var eventConstraints: [PersistedEnumConstraint] {
        CreateResourceEvent.enumConstraints.filter {
            $0.column == "resource_kind" || $0.column == "mutation"
        }
    }

    func prepare(on database: any Database) async throws {
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
