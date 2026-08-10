import Fluent

/// Removes the unused `restoring` value from `volume_snapshots.status`.
///
/// The reusable enum-constraint migration validates every stored value before
/// it drops the old CHECK constraint. A deployment with even one legacy
/// `restoring` row therefore fails startup with the row value named in the
/// diagnostic, leaving the wider constraint in place for operator repair.
struct RemoveVolumeSnapshotRestoringStatus: AsyncMigration {
    static let constraint = PersistedEnumConstraint(
        table: VolumeSnapshot.schema,
        column: "status",
        allowedValues: SnapshotStatus.allCases.map(\.rawValue),
        defaultValue: SnapshotStatus.creating.rawValue
    )

    static let legacyConstraint = PersistedEnumConstraint(
        table: VolumeSnapshot.schema,
        column: "status",
        allowedValues: ["creating", "available", "restoring", "deleting", "error"],
        defaultValue: SnapshotStatus.creating.rawValue
    )

    func prepare(on database: any Database) async throws {
        try await EnforcePersistedEnumValues.prepare(Self.constraint, on: database)
    }

    func revert(on database: any Database) async throws {
        try await EnforcePersistedEnumValues.prepare(Self.legacyConstraint, on: database)
    }
}
