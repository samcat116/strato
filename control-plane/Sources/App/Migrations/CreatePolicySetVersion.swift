import Fluent
import SQLKit

/// IAM phase 2 (issue #479): the policy-set version log. Every change to the
/// platform policy, the guardrails, or the role registry appends a row; the
/// version is stamped into decision logs and drives compiled-policy-set cache
/// invalidation across replicas.
struct CreatePolicySetVersion: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("iam_policy_set_versions")
            .id()
            // Unique because the allocator is "read max, insert max + 1": the
            // constraint is what turns two replicas racing into one retry
            // instead of two rows claiming the same version.
            .field("version", .int, .required)
            .field("reason", .string, .required)
            .field("changed_by", .uuid)
            .field("created_at", .datetime)
            .unique(on: "version")
            .create()

        if let sql = database as? SQLDatabase {
            // Reads are always "the newest row".
            try await sql.raw(
                "CREATE INDEX IF NOT EXISTS idx_iam_policy_set_versions_version ON iam_policy_set_versions (version DESC)"
            ).run()
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema("iam_policy_set_versions").delete()
    }
}
