import Fluent

/// Creates the `account_claim_tokens` table backing the passkey-claim invite
/// flow for admin-created (`.local`) users. The token row is deleted with its
/// user (cascade); `created_by_id` nulls out if the inviting admin is removed.
struct CreateAccountClaimToken: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("account_claim_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("token_prefix", .string, .required)
            .field("expires_at", .datetime)
            .field("claimed_at", .datetime)
            .field("created_by_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("account_claim_tokens").delete()
    }
}
