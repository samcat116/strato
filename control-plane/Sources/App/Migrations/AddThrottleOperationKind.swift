import Fluent
import SQLKit

/// Widens the `resource_events.mutation` `CHECK` constraint for
/// `VMOperationKind.throttle` (STR-19).
///
/// It widened the matching `resource_operations.kind` constraint too, until
/// that table was dropped in STR-152. What is left is the `resource_events`
/// half, and its mechanism is the interesting one: the constraint cannot go
/// through `EnforcePersistedEnumValues.prepare`, because its normalizing
/// `UPDATE` is exactly what the table's append-only trigger exists to reject.
/// It is re-installed with a plain `ALTER TABLE`, the way
/// `CreateResourceEvent` installs it.
///
/// Missing it fails `ResourceEventEnumConstraintTests` — which is what that
/// suite is for, since nothing in the type system can catch it.
///
/// Idempotent (drop-if-exists first), so a database whose base migrations
/// already carried the wider list is unaffected.
struct AddThrottleOperationKind: AsyncMigration {
    private static var eventConstraints: [PersistedEnumConstraint] {
        CreateResourceEvent.enumConstraints.filter { $0.column == "mutation" }
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
        // Re-installs rather than drops, like `AddVolumeOperationKinds`: the
        // columns should stay guarded, and rows carrying the new value may
        // already exist.
        try await prepare(on: database)
    }
}
