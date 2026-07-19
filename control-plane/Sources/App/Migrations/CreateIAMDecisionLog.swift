import Fluent
import SQLKit

/// IAM phase 4 (issue #481): the authorization decision log. Append-only and,
/// like the audit trail, free of foreign keys — decisions must outlive the
/// users and resources they describe.
struct CreateIAMDecisionLog: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("iam_decision_logs")
            .id()
            .field("request_id", .string)
            .field("path", .string)
            .field("method", .string)
            .field("subject", .string, .required)
            .field("spicedb_permission", .string, .required)
            .field("resource_type", .string, .required)
            .field("resource_id", .string, .required)
            .field("iam_action", .string)
            .field("node_type", .string)
            .field("node_id", .uuid)
            .field("organization_id", .uuid)
            .field("spicedb_decision", .string, .required)
            .field("cedar_decision", .string, .required)
            .field("decisions_match", .bool)
            .field("determining_policies", .string)
            .field("tier", .string)
            .field("cedar_errors", .string)
            .field("policy_version", .int)
            .field("skipped_conditioned_bindings", .int)
            .field("created_at", .datetime)
            .create()

        // Newest-first listing, the mismatch burn-down filter, and the
        // retention sweep all hit created_at; mismatches are additionally
        // narrowed by decisions_match.
        if let sql = database as? SQLDatabase {
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_iam_decision_logs_created "
                    + "ON iam_decision_logs (created_at)"
            ).run()
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_iam_decision_logs_match_created "
                    + "ON iam_decision_logs (decisions_match, created_at)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        if let sql = database as? SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_iam_decision_logs_created").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_iam_decision_logs_match_created").run()
        }
        try await database.schema("iam_decision_logs").delete()
    }
}
