import Fluent
import SQLKit

/// Converts `projects.environments` from a JSON-encoded text column to a native
/// Postgres `text[]` (issue #641).
///
/// The JSON encoding existed only so the array would fit a SQLite text column;
/// the SQLite backend is gone, so the column now matches the model's `[String]`
/// field directly. Rows whose value isn't a JSON array (there shouldn't be any —
/// every write went through `JSONEncoder`) fall back to `{development}`, which is
/// what the old computed property returned when decoding failed.
///
/// The conversion goes through a scratch column rather than `ALTER COLUMN ... USING`
/// because unpacking the JSON needs `ARRAY(SELECT jsonb_array_elements_text(...))`,
/// and Postgres rejects subqueries in a transform expression.
struct ConvertProjectEnvironmentsToArray: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        try await sql.raw("ALTER TABLE projects ADD COLUMN environments_array text[]").run()
        try await sql.raw(
            """
            UPDATE projects SET environments_array = CASE
                WHEN btrim(environments) LIKE '[%'
                    THEN ARRAY(SELECT jsonb_array_elements_text(environments::jsonb))
                ELSE ARRAY['development']::text[]
            END
            """
        ).run()
        try await sql.raw("ALTER TABLE projects ALTER COLUMN environments_array SET NOT NULL").run()
        try await sql.raw("ALTER TABLE projects DROP COLUMN environments").run()
        try await sql.raw("ALTER TABLE projects RENAME COLUMN environments_array TO environments").run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        try await sql.raw(
            "ALTER TABLE projects ALTER COLUMN environments TYPE text USING (to_jsonb(environments)::text)"
        ).run()
    }
}
