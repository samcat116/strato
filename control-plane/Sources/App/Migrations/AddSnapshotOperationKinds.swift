import Fluent
import SQLKit

/// Widens every `resource_kind` `CHECK` constraint for the three enum cases
/// STR-150 adds: `OperationResourceKind.volumeSnapshot`, `.vmCheckpoint` and
/// `.sandboxSnapshot`.
///
/// Two tables, and two different install mechanisms. (It was three until
/// STR-152 dropped `resource_operations`.) `resource_events` cannot go through
/// `EnforcePersistedEnumValues.prepare`: that normalizing `UPDATE` is what its
/// append-only trigger exists to reject, so its constraints are re-installed
/// with a plain `ALTER TABLE`. And `agent_workload_claims` installs its own
/// guard inline in `CreateAgentWorkloadClaim`, which is why it was missed
/// twice.
///
/// That third table is not a completeness exercise. `AgentWorkloadClaim` is
/// where a tombstoned teardown is *recorded*, and its `CHECK` still listed only
/// `('virtual_machine', 'sandbox')` — so STR-148's `.volume` and this change's
/// three kinds would all violate it on insert. The failure is not confined to
/// the one row: `applyUnrecognizedWorkloads` runs inside the observed-report
/// path, so a constraint violation throws and *nothing* in that agent's report
/// is applied. The stray artifact is still there on the next report, so the
/// agent stops converging permanently — exactly the outcome the tombstone path
/// exists to prevent, arriving through the table that records it.
///
/// Its allowed list is derived from `OperationResourceKind.allCases` rather than
/// spelled out, so a fourth kind cannot reintroduce the gap;
/// `AgentWorkloadClaimEnumConstraintTests` pins that.
///
/// No `mutation` widening this time: an artifact's lifecycle is spelled with
/// `VMOperationKind.create`/`.delete`/`.snapshotExport`, all of which the
/// constraint already allows. The old `.snapshot`/`.snapshotDelete` values stay
/// in the enum so rows written before this change still decode.
///
/// Idempotent on every path (drop-if-exists first).
struct AddSnapshotOperationKinds: AsyncMigration {
    private static var eventConstraints: [PersistedEnumConstraint] {
        CreateResourceEvent.enumConstraints.filter { $0.column == "resource_kind" }
    }

    /// The claims table's guard. `PersistedEnumConstraint.name` derives
    /// `ck_agent_workload_claims_resource_kind_enum`, which is exactly what
    /// `CreateAgentWorkloadClaim` installed by hand — and `install` drops by
    /// that name before adding — so this replaces the narrow one rather than
    /// adding a second, contradictory constraint beside it.
    static let claimConstraint = PersistedEnumConstraint(
        table: "agent_workload_claims",
        column: "resource_kind",
        allowedValues: OperationResourceKind.allCases.map(\.rawValue)
    )

    func prepare(on database: any Database) async throws {
        // The claims table has no append-only trigger, so the normalizing pass
        // is safe and existing rows are already within the widened list.
        try await EnforcePersistedEnumValues.prepare(Self.claimConstraint, on: database)

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
