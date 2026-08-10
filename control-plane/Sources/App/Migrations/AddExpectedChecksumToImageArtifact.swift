import Fluent

/// Adds URL-import checksum expectations to the authoritative artifact row.
///
/// This is deliberately separate from `MakeImageArtifactsAuthoritative`: Fluent
/// records this schema change before the cutover inventories data, so an
/// operator can repair an invalid ready image and safely retry the cutover.
struct AddExpectedChecksumToImageArtifact: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("image_artifacts")
            .field("expected_checksum", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("image_artifacts")
            .deleteField("expected_checksum")
            .update()
    }
}
