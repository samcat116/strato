import Fluent

/// Security state used by SSF signal handlers (issue #38):
/// - `session_epoch` — bumped to invalidate every session the user holds.
///   Sessions record the epoch they were created under; a mismatch at
///   request time destroys the session. Sessions predating this column
///   carry no epoch and count as epoch 0.
/// - `disabled_at` — set to block all authentication for the account
///   (RISC account-disabled), cleared on account-enabled.
struct AddSecurityStateToUser: AsyncMigration {
    func prepare(on database: Database) async throws {
        // SQLite doesn't support multiple ADD clauses in a single ALTER TABLE statement
        try await database.schema("users")
            .field("session_epoch", .int64, .required, .custom("DEFAULT 0"))
            .update()

        try await database.schema("users")
            .field("disabled_at", .datetime)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("users")
            .deleteField("session_epoch")
            .update()

        try await database.schema("users")
            .deleteField("disabled_at")
            .update()
    }
}
