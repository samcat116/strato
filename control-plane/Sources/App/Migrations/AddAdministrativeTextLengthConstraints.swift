import Fluent
import SQLKit

/// Backstops the request bounds on the three IAM name indexes whose oversized
/// entries otherwise fail as PostgreSQL `54000` and surface as a 500 (STR-256).
/// Fresh databases already receive these checks from `CurrentSchema.sql`; the
/// catalog guard keeps this repair safe when it runs after that baseline.
struct AddAdministrativeTextLengthConstraints: AsyncMigration {
    var name: String { "App.AddAdministrativeTextLengthConstraints" }

    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase, sql.dialect.name == "postgresql" else {
            throw AddAdministrativeTextLengthConstraintsError.postgresRequired
        }

        let invalidTables = try await sql.raw(
            """
            SELECT table_name
            FROM (
                SELECT 'iam_guardrails' AS table_name
                FROM iam_guardrails
                WHERE char_length(name) > 128 OR char_length(description) > 4096
                UNION ALL
                SELECT 'iam_policies' AS table_name
                FROM iam_policies
                WHERE char_length(name) > 128 OR char_length(description) > 4096
                UNION ALL
                SELECT 'iam_roles' AS table_name
                FROM iam_roles
                WHERE char_length(name) > 128 OR char_length(description) > 4096
            ) AS invalid_rows
            GROUP BY table_name
            ORDER BY table_name
            """
        ).all(decodingColumn: "table_name", as: String.self)
        guard invalidTables.isEmpty else {
            throw AddAdministrativeTextLengthConstraintsError.existingRowsExceedLimits(
                tables: invalidTables)
        }

        for statement in Self.constraintStatements {
            try await sql.raw("\(unsafeRaw: statement)").run()
        }
    }

    /// The checks may predate this migration because the fresh-schema baseline
    /// owns them too. Retaining the compatible safety invariant is the only
    /// revert behavior that is correct for both database histories.
    func revert(on database: Database) async throws {}

    private static let constraintStatements = [
        statement(
            table: "iam_guardrails", constraint: "ck_iam_guardrails_name_length",
            expression: "char_length(name) <= 128"),
        statement(
            table: "iam_guardrails", constraint: "ck_iam_guardrails_description_length",
            expression: "char_length(description) <= 4096"),
        statement(
            table: "iam_policies", constraint: "ck_iam_policies_name_length",
            expression: "char_length(name) <= 128"),
        statement(
            table: "iam_policies", constraint: "ck_iam_policies_description_length",
            expression: "char_length(description) <= 4096"),
        statement(
            table: "iam_roles", constraint: "ck_iam_roles_name_length",
            expression: "char_length(name) <= 128"),
        statement(
            table: "iam_roles", constraint: "ck_iam_roles_description_length",
            expression: "char_length(description) <= 4096"),
    ]

    private static func statement(table: String, constraint: String, expression: String) -> String {
        """
        DO $str256$
        BEGIN
            IF NOT EXISTS (
                SELECT 1
                FROM pg_constraint
                WHERE conname = '\(constraint)'
                  AND conrelid = 'public.\(table)'::regclass
            ) THEN
                ALTER TABLE public.\(table)
                    ADD CONSTRAINT \(constraint) CHECK (\(expression));
            END IF;
        END
        $str256$
        """
    }
}

private enum AddAdministrativeTextLengthConstraintsError: Error, CustomStringConvertible {
    case postgresRequired
    case existingRowsExceedLimits(tables: [String])

    var description: String {
        switch self {
        case .postgresRequired:
            return "Administrative text-length constraints require PostgreSQL"
        case .existingRowsExceedLimits(let tables):
            return
                "Cannot add administrative text-length constraints: existing rows exceed the 128-character name "
                + "or 4096-character description limit in \(tables.joined(separator: ", "))"
        }
    }
}
