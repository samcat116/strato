import Fluent

/// Adds the guest CPU architecture to images. Existing single-file images are
/// overwhelmingly x86_64, so the column defaults to `x86_64`; any pre-existing
/// arm64 image must be corrected after migration or it will be scheduled onto
/// x86_64 hosts. New uploads set the architecture explicitly.
struct AddArchitectureToImage: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("images")
            .field("architecture", .string, .required, .sql(.default("x86_64")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("images")
            .deleteField("architecture")
            .update()
    }
}
