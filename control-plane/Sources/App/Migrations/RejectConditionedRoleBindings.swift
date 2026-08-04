import Fluent
import Foundation
import SQLKit

/// STR-108: make the database refuse a conditioned role binding.
///
/// The condition vocabulary is declared but not compiled. `EntitySliceLoader`
/// skips any binding carrying a `condition` rather than flattening it as if it
/// were unconditional — flattening would turn a restricted grant into an open
/// one — so a conditioned binding grants *nothing*. That is fail-closed and
/// stays; what was missing is any signal at the write boundary. No API exposes
/// the field, so the only way a row got one was direct SQL, and such a row is
/// indistinguishable from a live grant in every members/bindings listing while
/// conferring no access at all.
///
/// Pre-existing conditioned rows are deleted rather than grandfathered. They
/// grant nothing today, so removing them changes no principal's access, and
/// keeping them would mean an invalid-forever constraint guarding a table that
/// still holds invisible dead grants. Each deleted row is logged in full —
/// principal, role, node, condition — because `revert()` can restore the
/// constraint but not the rows, so this log is the only record of what an
/// operator meant to grant.
///
/// This deliberately differs from the closest precedent, `EnforcePersistedEnumValues`,
/// which *aborts startup* when existing rows would violate the constraint it is
/// about to add. There the offending value is load-bearing — a row the app will
/// try to decode and trap on — so refusing to proceed is the only safe move.
/// Here the offending rows are inert by construction, and failing every boot
/// over a grant that confers nothing would be the worse outcome; logging them
/// keeps the operator's intent recoverable without holding the deploy hostage.
///
/// Lift this when conditions are actually compiled into the Cedar `when`
/// clause; until then the column stays for that future, guarded.
struct RejectConditionedRoleBindings: AsyncMigration {
    static let constraintName = "ck_role_bindings_condition_unsupported"

    func prepare(on database: Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)

        // Return the identifying columns, not just a count: this statement is
        // the last place the row's contents exist.
        let deleted = try await sql.raw(
            """
            DELETE FROM "role_bindings" WHERE "condition" IS NOT NULL
            RETURNING "principal_type", "principal_id", "role", "node_type", "node_id", "condition"
            """
        ).all()
        if !deleted.isEmpty {
            database.logger.warning(
                """
                Deleting \(deleted.count) role binding(s) carrying a condition. Binding conditions are \
                not implemented — the evaluator has always skipped these rows, so they granted nothing \
                and no access changes. Each is logged below; re-grant unconditionally if the access was \
                intended.
                """
            )
            for row in deleted {
                database.logger.warning("Deleted conditioned role binding: \(Self.describe(row))")
            }
        }

        // Drop-then-add so a retry after an interrupted, non-transactional run
        // is safe.
        try await PostgresMigrationSQL.execute(
            "ALTER TABLE \"role_bindings\" DROP CONSTRAINT IF EXISTS \(Self.quotedName)", on: sql)
        try await PostgresMigrationSQL.execute(
            "ALTER TABLE \"role_bindings\" ADD CONSTRAINT \(Self.quotedName) CHECK (\"condition\" IS NULL)",
            on: sql
        )
    }

    func revert(on database: Database) async throws {
        let sql = try PostgresMigrationSQL.database(database)
        try await PostgresMigrationSQL.execute(
            "ALTER TABLE \"role_bindings\" DROP CONSTRAINT IF EXISTS \(Self.quotedName)", on: sql)
    }

    static var quotedName: String { PostgresMigrationSQL.identifier(constraintName) }

    /// One deleted row, rendered so the grant can be reconstructed by hand.
    /// Decoding is per-column and lenient: a row this cannot fully read is
    /// still worth logging in part, and a log line is no place to throw.
    private static func describe(_ row: any SQLRow) -> String {
        func text(_ column: String) -> String {
            (try? row.decode(column: column, as: String.self))
                ?? (try? row.decode(column: column, as: UUID.self))?.uuidString
                ?? "<unreadable>"
        }
        return "principal=\(text("principal_type")):\(text("principal_id")) role=\(text("role")) "
            + "node=\(text("node_type")):\(text("node_id")) condition=\(text("condition"))"
    }
}
