import Fluent
import SQLKit

enum ConditionedRoleBindingMigrationError: Error, CustomStringConvertible, Sendable {
    case unsupportedDatabase(String)

    var description: String {
        switch self {
        case .unsupportedDatabase(let dialect):
            return "Cannot constrain role_bindings.condition on unsupported SQL dialect '\(dialect)'"
        }
    }
}

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
/// still holds invisible dead grants. The count is logged so an operator who
/// wrote one sees it go.
///
/// Lift this when conditions are actually compiled into the Cedar `when`
/// clause; until then the column stays for that future, guarded.
struct RejectConditionedRoleBindings: AsyncMigration {
    static let constraintName = "ck_role_bindings_condition_unsupported"

    func prepare(on database: Database) async throws {
        let sql = try Self.sqlDatabase(database)

        let deleted = try await sql.raw(
            "DELETE FROM \"role_bindings\" WHERE \"condition\" IS NOT NULL RETURNING \"id\""
        ).all()
        if !deleted.isEmpty {
            database.logger.warning(
                """
                Deleted \(deleted.count) role binding(s) carrying a condition. Binding conditions are \
                not implemented — the evaluator has always skipped these rows, so they granted nothing \
                and no access changes. Re-grant unconditionally if the access was intended.
                """
            )
        }

        // Drop-then-add so a retry after an interrupted, non-transactional run
        // is safe.
        try await Self.execute("ALTER TABLE \"role_bindings\" DROP CONSTRAINT IF EXISTS \(Self.quotedName)", on: sql)
        try await Self.execute(
            "ALTER TABLE \"role_bindings\" ADD CONSTRAINT \(Self.quotedName) CHECK (\"condition\" IS NULL)",
            on: sql
        )
    }

    func revert(on database: Database) async throws {
        let sql = try Self.sqlDatabase(database)
        try await Self.execute("ALTER TABLE \"role_bindings\" DROP CONSTRAINT IF EXISTS \(Self.quotedName)", on: sql)
    }

    private static var quotedName: String { "\"\(constraintName)\"" }

    private static func sqlDatabase(_ database: Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else {
            throw ConditionedRoleBindingMigrationError.unsupportedDatabase("non-SQL")
        }
        guard sql.dialect.name == "postgresql" else {
            throw ConditionedRoleBindingMigrationError.unsupportedDatabase(sql.dialect.name)
        }
        return sql
    }

    private static func execute(_ statement: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("\(unsafeRaw: statement)").run()
    }
}
