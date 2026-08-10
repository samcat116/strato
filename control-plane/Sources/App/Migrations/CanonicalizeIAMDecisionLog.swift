import Fluent
import SQLKit

/// STR-228: retire the shadow-evaluator and legacy-permission columns from the
/// authorization decision log. Evaluated rows now name their canonical action
/// and IAM node directly; node-less credential denials keep those fields nil.
struct CanonicalizeIAMDecisionLog: AsyncMigration {
    struct UnsupportedDatabase: Error {}

    func prepare(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        try await sql.raw("DROP INDEX IF EXISTS idx_iam_decision_logs_match_created").run()
        try await sql.raw("ALTER TABLE iam_decision_logs RENAME COLUMN iam_action TO action").run()
        try await sql.raw("ALTER TABLE iam_decision_logs RENAME COLUMN cedar_decision TO decision").run()
        try await sql.raw(
            """
            ALTER TABLE iam_decision_logs
                DROP COLUMN spicedb_permission,
                DROP COLUMN resource_type,
                DROP COLUMN resource_id,
                DROP COLUMN spicedb_decision,
                DROP COLUMN decisions_match
            """
        ).run()
    }

    func revert(on database: Database) async throws {
        guard let sql = database as? SQLDatabase else { throw UnsupportedDatabase() }

        try await sql.raw("ALTER TABLE iam_decision_logs RENAME COLUMN action TO iam_action").run()
        try await sql.raw("ALTER TABLE iam_decision_logs RENAME COLUMN decision TO cedar_decision").run()
        try await sql.raw(
            """
            ALTER TABLE iam_decision_logs
                ADD COLUMN spicedb_permission TEXT NOT NULL DEFAULT '',
                ADD COLUMN resource_type TEXT NOT NULL DEFAULT '',
                ADD COLUMN resource_id TEXT NOT NULL DEFAULT '',
                ADD COLUMN spicedb_decision TEXT NOT NULL DEFAULT 'none',
                ADD COLUMN decisions_match BOOLEAN
            """
        ).run()
        try await sql.raw(
            """
            UPDATE iam_decision_logs
            SET spicedb_permission = COALESCE(iam_action, 'credential:unknown'),
                resource_type = COALESCE(node_type, 'route'),
                resource_id = COALESCE(node_id::text, CONCAT_WS(' ', method, path))
            """
        ).run()
        try await sql.raw(
            """
            ALTER TABLE iam_decision_logs
                ALTER COLUMN spicedb_permission DROP DEFAULT,
                ALTER COLUMN resource_type DROP DEFAULT,
                ALTER COLUMN resource_id DROP DEFAULT,
                ALTER COLUMN spicedb_decision DROP DEFAULT
            """
        ).run()
        try await sql.raw(
            """
            CREATE INDEX IF NOT EXISTS idx_iam_decision_logs_match_created
            ON iam_decision_logs (decisions_match, created_at)
            """
        ).run()
    }
}
