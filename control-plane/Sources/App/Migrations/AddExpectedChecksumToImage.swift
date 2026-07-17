import Fluent

/// Adds the caller-supplied SHA-256 that a URL import must match. Nullable: the
/// checksum is optional, and pre-existing images were never checked against one.
///
/// Deliberately separate from the existing `checksum` column, which holds the
/// digest we computed from the bytes we stored and is handed to agents to verify
/// their own downloads — overwriting it with an unverified claim would corrupt
/// that contract.
struct AddExpectedChecksumToImage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("images")
            .field("expected_checksum", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("images")
            .deleteField("expected_checksum")
            .update()
    }
}
