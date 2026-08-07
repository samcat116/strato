import Fluent
import SQLKit

/// STR-115: name the credential a decision was made under.
///
/// Before this, the only decision row that knew about a credential was the
/// scope denial, and it said so by overwriting `resource_type`/`resource_id`
/// with the credential's type and id — which made "which token did this?"
/// unanswerable for every *allowed* request, and made the denial rows lie about
/// what resource was being reached. These two columns are populated for any
/// decision made under an API key or CLI session, allow or deny, so a decision
/// log can answer "what has this token been doing" directly.
struct AddCredentialToIAMDecisionLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("iam_decision_logs")
            .field("credential_type", .string)
            .field("credential_id", .uuid)
            .update()

        // "Everything this credential did, newest first" — the audit question
        // the columns exist for.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_iam_decision_logs_credential "
                    + "ON iam_decision_logs (credential_id, created_at)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_iam_decision_logs_credential").run()
        }
        try await database.schema("iam_decision_logs")
            .deleteField("credential_type")
            .deleteField("credential_id")
            .update()
    }
}
