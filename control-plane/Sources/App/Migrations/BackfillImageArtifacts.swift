import Fluent
import Foundation
import StratoShared

/// Creates a `disk-image` artifact for each existing ready image, mirroring the
/// image's legacy single-file columns. The artifact points at the same stored
/// file (`storage_path`), so this adds metadata without moving bytes. Images
/// that never finished (no `storage_path` / checksum) are skipped — a later
/// successful upload will create their artifact.
struct BackfillImageArtifacts: AsyncMigration {
    func prepare(on database: Database) async throws {
        let images = try await ImageArtifactBackfillRow.query(on: database)
            .filter(\.$status == ImageStatus.ready.rawValue)
            .all()

        for image in images {
            guard let imageID = image.id,
                let storagePath = image.storagePath,
                let checksum = image.checksum
            else {
                continue
            }

            let artifact = ImageArtifactBackfillArtifactRow()
            artifact.imageID = imageID
            artifact.kind = ArtifactKind.diskImage.rawValue
            artifact.format = image.format
            artifact.architecture = image.architecture
            artifact.filename = image.filename
            artifact.size = image.size
            artifact.checksum = checksum
            artifact.storagePath = storagePath
            try await artifact.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        // Drop the backfilled disk-image artifacts. Other kinds (kernel/rootfs)
        // are not created by this migration, so scope the delete to disk-image.
        try await ImageArtifactBackfillArtifactRow.query(on: database)
            .filter(\.$kind == ArtifactKind.diskImage.rawValue)
            .delete()
    }
}

/// Column-snapshot of `images` as it stands at this point in the migration
/// chain, pinned to the fields the backfill reads.
///
/// Using the live `Image` model here would make this migration re-break every
/// time a later migration adds a column: Fluent selects every field the model
/// declares, so a column that doesn't exist yet turns into `no such column` and
/// aborts the whole chain — taking every downstream migration with it.
final class ImageArtifactBackfillRow: Model, @unchecked Sendable {
    static let schema = "images"

    @ID(key: .id) var id: UUID?
    @Field(key: "filename") var filename: String
    @Field(key: "size") var size: Int64
    // Deliberately use raw strings here. This migration runs before the enum
    // repair/enforcement migration, so decoding through `@Enum` could trap on
    // a malformed historical value before startup has a chance to repair or
    // diagnose it (issue #527).
    @Field(key: "format") var format: String
    @Field(key: "architecture") var architecture: String
    @OptionalField(key: "checksum") var checksum: String?
    @OptionalField(key: "storage_path") var storagePath: String?
    @Field(key: "status") var status: String

    init() {}
}

/// Column-snapshot of `image_artifacts` as created by `CreateImageArtifact`.
///
/// Notably this has no `status`: that column arrives in
/// `AddFetchStateToImageArtifact`, which runs *after* this migration. Declaring
/// it here would fail exactly the way a live model does. The default it later
/// gets (`'ready'`) is the right value for a backfilled artifact anyway.
///
/// `image_id` is a plain field rather than a `@Parent` so this row type doesn't
/// reference the live `Image` model at all.
final class ImageArtifactBackfillArtifactRow: Model, @unchecked Sendable {
    static let schema = "image_artifacts"

    @ID(key: .id) var id: UUID?
    @Field(key: "image_id") var imageID: UUID
    // These stay raw for the same reason as the source snapshot above. The
    // final enforcement migration validates both tables before live models
    // can access them.
    @Field(key: "kind") var kind: String
    @OptionalField(key: "format") var format: String?
    @Field(key: "architecture") var architecture: String
    @Field(key: "filename") var filename: String
    @Field(key: "size") var size: Int64
    @Field(key: "checksum") var checksum: String
    @Field(key: "storage_path") var storagePath: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
