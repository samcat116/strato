import Fluent
import Foundation
import SQLKit

/// STR-195: give the database the length bound the API now applies.
///
/// Every one of these columns is declared `.string` in its own migration, which
/// is Postgres `TEXT` — no ceiling at all. That made the request boundary the
/// only thing standing between a caller and a multi-megabyte VM name, and the
/// request boundary is exactly what turned out to be applied by habit rather
/// than by rule. `Validate` fixes the habit; this makes the storage layer the
/// backstop, the way the unique indexes already are for IPAM.
///
/// A `CHECK` rather than `VARCHAR(n)`: it expresses the same bound, takes a
/// scan instead of a full table rewrite, and reverting is one statement.
/// `char_length` is Postgres's *character* count, which is what `Validate.length`
/// counts too (Unicode scalars) — measuring in bytes here would refuse strings
/// the API accepted.
///
/// Added `NOT VALID` and then validated in a second statement. A plain `ADD
/// CONSTRAINT … CHECK` validates immediately while holding `ACCESS EXCLUSIVE`,
/// so each of these columns would block every read and write to its table for
/// the length of a full scan — twenty-five times over, across `vms` and
/// `volumes` among others, during a rolling deploy. `NOT VALID` takes that
/// lock only for the catalog write; `VALIDATE CONSTRAINT` does the scan under
/// `SHARE UPDATE EXCLUSIVE`, which ordinary traffic does not contend with. The
/// end state is identical: a validated constraint enforced for every row.
///
/// Existing rows are confirmed, not assumed. Each column is scanned first, and
/// a row over the bound aborts the migration with the table, column, row id and
/// length rather than surfacing as a bare constraint violation — the operator
/// has to decide what a too-long name should become, and truncating user-authored
/// text on their behalf is not this migration's call. In practice nothing in a
/// real deployment is close: these are names people typed.
///
/// That pre-scan is advisory, not a guarantee: a row written between it and
/// `VALIDATE CONSTRAINT` still surfaces as the bare violation the scan exists
/// to pre-empt. Closing the window would mean locking the table for the whole
/// migration, which is the cost this arrangement is avoiding — and the API has
/// enforced the same bound since before this migration runs, so the only writer
/// that could lose the race is one bypassing it.
struct BoundResourceTextColumns: AsyncMigration {

    /// One bounded column.
    struct BoundedColumn {
        let table: String
        let column: String
        let limit: Int

        var constraintName: String { "ck_\(table)_\(column)_length" }
    }

    /// The columns the API bounds, and the ceiling each is held to. Sourced
    /// from `Validate` so the database and the request boundary cannot drift to
    /// different numbers.
    static let columns: [BoundedColumn] = {
        let names = [
            "vms", "volumes", "sandboxes", "images", "projects", "organizations",
            "organizational_units", "groups", "resource_quotas", "logical_networks",
            "security_groups", "volume_snapshots", "vm_snapshots", "sandbox_snapshots",
        ]
        let descriptions = [
            "vms", "volumes", "images", "projects", "organizations", "organizational_units",
            "groups", "security_groups", "volume_snapshots", "vm_snapshots",
        ]
        return names.map { BoundedColumn(table: $0, column: "name", limit: Validate.nameLength) }
            + descriptions.map {
                BoundedColumn(table: $0, column: "description", limit: Validate.textLength)
            }
            // Not a description, but the same order of magnitude and the same
            // reason to bound it: this one is rendered into the guest's
            // authorized_keys.
            + [BoundedColumn(table: "vms", column: "ssh_public_key", limit: Validate.textLength)]
    }()

    func prepare(on database: Database) async throws {
        try await Self.bound(Self.columns, on: database)
    }

    func revert(on database: Database) async throws {
        try await Self.unbound(Self.columns, on: database)
    }

    /// Install the length `CHECK` for each column, as described on the type.
    ///
    /// Static and taking its columns as an argument so a later migration
    /// bounding a table this one predates (`BoundDNSTextColumns`) inherits the
    /// pre-scan, the `NOT VALID` two-step and the retry-safe drop rather than
    /// re-deriving them — the parts of this that are easy to get subtly wrong.
    static func bound(_ columns: [BoundedColumn], on database: Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)

        for column in columns {
            try await assertRowsFit(column, on: sql)
            // Drop-then-add so a retry after an interrupted, non-transactional
            // run is safe.
            try await PostgresMigrationSQL.execute(
                "ALTER TABLE \(quoted(column.table)) DROP CONSTRAINT IF EXISTS \(quoted(column.constraintName))",
                on: sql)
            // A NULL fails no CHECK — `char_length(NULL)` is NULL, and only an
            // outright FALSE rejects a row — so the nullable columns here need
            // no `IS NULL` arm.
            try await PostgresMigrationSQL.execute(
                """
                ALTER TABLE \(quoted(column.table)) ADD CONSTRAINT \(quoted(column.constraintName)) \
                CHECK (char_length(\(quoted(column.column))) <= \(column.limit)) NOT VALID
                """,
                on: sql)
            // The scan, under a lock ordinary traffic does not contend with.
            try await PostgresMigrationSQL.execute(
                """
                ALTER TABLE \(quoted(column.table)) \
                VALIDATE CONSTRAINT \(quoted(column.constraintName))
                """,
                on: sql)
        }
    }

    /// Drop those constraints again. `IF EXISTS`, so reverting a partially
    /// applied run is not itself a failure.
    static func unbound(_ columns: [BoundedColumn], on database: Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)
        for column in columns {
            try await PostgresMigrationSQL.execute(
                "ALTER TABLE \(quoted(column.table)) DROP CONSTRAINT IF EXISTS \(quoted(column.constraintName))",
                on: sql)
        }
    }

    /// Refuses to add a constraint the table cannot satisfy, naming the rows
    /// that don't fit. Reported as an error rather than repaired: these are
    /// names and descriptions someone wrote, and shortening them is an
    /// operator's decision.
    ///
    /// Assumes the table's key is `id`, which every Fluent model here uses. A
    /// future bounded table keyed otherwise reports `<unreadable>` for the id
    /// and still names the table, column and length — degraded, not broken.
    private static func assertRowsFit(_ column: BoundedColumn, on sql: any SQLDatabase) async throws {
        let offenders = try await sql.raw(
            """
            SELECT "id", char_length(\(unsafeRaw: Self.quoted(column.column))) AS "length" \
            FROM \(unsafeRaw: Self.quoted(column.table)) \
            WHERE char_length(\(unsafeRaw: Self.quoted(column.column))) > \(unsafeRaw: String(column.limit)) \
            ORDER BY "length" DESC LIMIT 10
            """
        ).all()
        guard !offenders.isEmpty else { return }

        let described = offenders.map { row -> String in
            let id = (try? row.decode(column: "id", as: UUID.self))?.uuidString ?? "<unreadable>"
            let length = (try? row.decode(column: "length", as: Int.self)).map(String.init) ?? "?"
            return "\(id) (\(length) characters)"
        }
        throw BoundResourceTextColumnsError.rowsExceedLimit(
            table: column.table, column: column.column, limit: column.limit, rows: described)
    }

    private static func quoted(_ value: String) -> String { PostgresMigrationSQL.identifier(value) }
}

enum BoundResourceTextColumnsError: Error, CustomStringConvertible, Sendable {
    case rowsExceedLimit(table: String, column: String, limit: Int, rows: [String])

    var description: String {
        switch self {
        case .rowsExceedLimit(let table, let column, let limit, let rows):
            return """
                Cannot bound \(table).\(column) to \(limit) characters: rows are longer than that. \
                Up to ten, longest first: \(rows.joined(separator: ", ")). Shorten or clear these \
                values, then re-run the migration — truncating them automatically would silently \
                destroy text somebody authored.
                """
        }
    }
}
