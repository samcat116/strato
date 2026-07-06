import Fluent

struct CreateImageArtifact: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("image_artifacts")
            .id()
            .field("image_id", .uuid, .required, .references("images", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            // Optional: kernel/initramfs are opaque blobs with no disk format.
            .field("format", .string)
            .field("architecture", .string, .required)
            .field("filename", .string, .required)
            .field("size", .int64, .required, .sql(.default("0")))
            .field("checksum", .string, .required)
            .field("storage_path", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // One artifact of a given kind per image.
            .unique(on: "image_id", "kind")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("image_artifacts").delete()
    }
}
