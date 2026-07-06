import Fluent

/// Creates a `disk-image` artifact for each existing ready image, mirroring the
/// image's legacy single-file columns. The artifact points at the same stored
/// file (`storage_path`), so this adds metadata without moving bytes. Images
/// that never finished (no `storage_path` / checksum) are skipped — a later
/// successful upload will create their artifact.
struct BackfillImageArtifacts: AsyncMigration {
    func prepare(on database: Database) async throws {
        let images = try await Image.query(on: database)
            .filter(\.$status == .ready)
            .all()

        for image in images {
            guard let imageID = image.id,
                  let storagePath = image.storagePath,
                  let checksum = image.checksum else {
                continue
            }

            let artifact = ImageArtifact(
                imageID: imageID,
                kind: .diskImage,
                format: image.format,
                architecture: image.architecture,
                filename: image.filename,
                size: image.size,
                checksum: checksum,
                storagePath: storagePath
            )
            try await artifact.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        // Drop the backfilled disk-image artifacts. Other kinds (kernel/rootfs)
        // are not created by this migration, so scope the delete to disk-image.
        try await ImageArtifact.query(on: database)
            .filter(\.$kind == .diskImage)
            .delete()
    }
}
