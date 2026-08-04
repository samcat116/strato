import Fluent
import SQLKit

enum PostgresMigrationError: Error, CustomStringConvertible, Sendable {
    /// The configured database is not the Postgres this migration writes raw
    /// SQL against — a non-SQL driver, or another SQL dialect.
    case unsupportedDatabase(String)

    var description: String {
        switch self {
        case .unsupportedDatabase(let description):
            return "This migration requires PostgreSQL; the configured database is \(description)"
        }
    }
}

/// The plumbing a migration needs when Fluent's schema builder cannot express
/// what it wants — constraints, in practice — and it drops to raw Postgres:
/// the dialect guard, statement execution, and identifier/literal quoting.
///
/// Extracted from `EnforcePersistedEnumValues` when `RejectConditionedRoleBindings`
/// turned out to need the same four pieces (PR #910 review). Two copies of a
/// dialect guard is how a third gets written.
enum PostgresMigrationSQL {
    /// The database as a Postgres `SQLDatabase`, or a diagnostic naming what it
    /// actually is. Migrations that build raw SQL must go through this rather
    /// than silently skipping their work on a database they cannot write.
    static func database(_ database: Database) throws -> any SQLDatabase {
        guard let sql = database as? any SQLDatabase else {
            throw PostgresMigrationError.unsupportedDatabase("not a SQL database")
        }
        guard sql.dialect.name == "postgresql" else {
            throw PostgresMigrationError.unsupportedDatabase("the '\(sql.dialect.name)' dialect")
        }
        return sql
    }

    static func execute(_ statement: String, on sql: any SQLDatabase) async throws {
        try await sql.raw("\(unsafeRaw: statement)").run()
    }

    /// A quoted SQL identifier (table, column, constraint name).
    static func identifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// A quoted SQL string literal. For values a migration composes itself —
    /// anything request-shaped belongs in a bind parameter.
    static func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
