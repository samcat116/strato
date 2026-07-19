import Fluent

/// Adds background-fetch tracking to individual artifacts so a kernel/rootfs/
/// initramfs (or a replacement disk-image) can be pulled from a URL the same way
/// whole images are. Existing artifacts are fully materialized, so `status`
/// defaults to `ready`; only URL-sourced artifacts move through
/// pending → downloading → ready/error.
///
/// Columns are added one `.update()` at a time: SQLite's ALTER TABLE cannot
/// combine multiple actions in a single migration step.
struct AddFetchStateToImageArtifact: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("image_artifacts")
            .field("status", .string, .required, .sql(.default("ready")))
            .update()
        try await database.schema("image_artifacts")
            .field("source_url", .string)
            .update()
        try await database.schema("image_artifacts")
            .field("download_progress", .int)
            .update()
        try await database.schema("image_artifacts")
            .field("error_message", .string)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("image_artifacts")
            .deleteField("status")
            .update()
        try await database.schema("image_artifacts")
            .deleteField("source_url")
            .update()
        try await database.schema("image_artifacts")
            .deleteField("download_progress")
            .update()
        try await database.schema("image_artifacts")
            .deleteField("error_message")
            .update()
    }
}
