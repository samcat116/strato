import Fluent

/// CHECK-constraint hardening for `sites.status`.
///
/// `EnforcePersistedEnumValues` guards every other string-backed `@Enum`
/// column, but `sites.status` was added afterward (see `AddSiteMetadata`), so
/// that migration had already run and won't pick it up. This installs the same
/// normalize → validate → CHECK guard through its reusable per-constraint entry
/// point, keeping the process-trap protection consistent for the new column.
///
/// The allowed values derive from `SiteStatus.allCases`, so adding a case only
/// needs a follow-up migration that replaces the constraint (as the doc on
/// `PersistedEnumConstraint` notes).
struct EnforceSiteStatusEnum: AsyncMigration {
    static let constraint = PersistedEnumConstraint(
        table: "sites",
        column: "status",
        allowedValues: SiteStatus.allCases.map(\.rawValue),
        defaultValue: SiteStatus.active.rawValue
    )

    func prepare(on database: Database) async throws {
        try await EnforcePersistedEnumValues.prepare(Self.constraint, on: database)
    }

    func revert(on database: Database) async throws {
        try await EnforcePersistedEnumValues.revert(Self.constraint, on: database)
    }
}
