import Fluent
import SQLKit

/// Persists the guest-visible size measured from disk-image bytes at ingestion.
/// Existing raw artifacts are exactly their stored length and can be backfilled;
/// sparse legacy formats remain unknown and fail closed for new volume sources.
struct AddImageArtifactVirtualSize: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("AddImageArtifactVirtualSize requires SQLKit")
        }
        try await sql.raw(
            """
            ALTER TABLE image_artifacts
            ADD COLUMN virtual_size bigint
            """
        ).run()
        try await sql.raw(
            """
            UPDATE image_artifacts
            SET virtual_size = size
            WHERE format = 'raw'
            """
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            preconditionFailure("AddImageArtifactVirtualSize requires SQLKit")
        }
        try await sql.raw(
            """
            ALTER TABLE image_artifacts
            DROP COLUMN virtual_size
            """
        ).run()
    }
}
