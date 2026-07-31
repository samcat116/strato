import Fluent

/// CHECK-constraint hardening for the two string-backed `@Enum` columns on
/// `dns_records` (issue #770).
///
/// `EnforcePersistedEnumValues` guards every enum column that existed when it
/// ran; these were added afterward, so — like `sites.status` before them —
/// they need the same normalize → validate → CHECK treatment through that
/// migration's reusable per-constraint entry point. Without it a single
/// unexpected value in the column traps the process on first decode rather
/// than failing one request (see `PersistedEnumConstraint`).
///
/// Allowed values derive from the enums' `allCases`, so adding a record type
/// or view needs a follow-up migration that replaces the constraint.
struct EnforceDNSRecordEnums: AsyncMigration {
    static let typeConstraint = PersistedEnumConstraint(
        table: "dns_records",
        column: "type",
        allowedValues: DNSRecordType.allCases.map(\.rawValue)
    )

    static let viewConstraint = PersistedEnumConstraint(
        table: "dns_records",
        column: "view",
        allowedValues: DNSRecordView.allCases.map(\.rawValue),
        defaultValue: DNSRecordView.both.rawValue
    )

    func prepare(on database: Database) async throws {
        try await EnforcePersistedEnumValues.prepare(Self.typeConstraint, on: database)
        try await EnforcePersistedEnumValues.prepare(Self.viewConstraint, on: database)
    }

    func revert(on database: Database) async throws {
        try await EnforcePersistedEnumValues.revert(Self.viewConstraint, on: database)
        try await EnforcePersistedEnumValues.revert(Self.typeConstraint, on: database)
    }
}
