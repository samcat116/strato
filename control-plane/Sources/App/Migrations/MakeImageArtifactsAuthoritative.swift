import Fluent
import Foundation
import StratoShared

enum ImageArtifactCutoverError: Error, CustomStringConvertible, Sendable {
    case incompleteReadyImages([UUID])

    var description: String {
        switch self {
        case .incompleteReadyImages(let ids):
            return "Cannot remove legacy image storage columns; ready image(s) have no valid typed artifact set: "
                + ids.map(\.uuidString).sorted().joined(separator: ", ")
        }
    }
}

/// Makes `image_artifacts` the only persisted description of image bytes.
///
/// The migration first inventories every image and repairs a missing/incomplete
/// disk artifact from the legacy columns when those columns contain a complete
/// stored-file record. It then refuses to cut over if any ready image still
/// lacks either a valid disk image or a valid kernel/rootfs pair. Only after
/// that safety boundary passes are the duplicate image columns removed.
struct MakeImageArtifactsAuthoritative: AsyncMigration {
    func prepare(on database: Database) async throws {
        let images = try await AuthoritativeImageLegacyRow.query(on: database).all()
        var incompleteReadyImages: [UUID] = []

        for image in images {
            guard let imageID = image.id else { continue }
            var artifacts = try await AuthoritativeImageArtifactRow.query(on: database)
                .filter(\.$imageID == imageID)
                .all()

            let legacyComplete =
                image.storagePath?.isEmpty == false
                && image.checksum?.isEmpty == false
                && !image.filename.isEmpty
                && ImageFormat(rawValue: image.format) != nil

            var disk = artifacts.first { $0.kind == ArtifactKind.diskImage.rawValue }
            if disk == nil, legacyComplete || image.sourceURL != nil {
                let row = AuthoritativeImageArtifactRow()
                row.imageID = imageID
                row.kind = ArtifactKind.diskImage.rawValue
                row.format = legacyComplete ? image.format : nil
                row.architecture = image.architecture
                row.filename = image.filename
                row.size = image.size
                row.checksum = image.checksum ?? ""
                row.storagePath =
                    image.storagePath
                    ?? ImageObjectKey.artifact(
                        projectId: image.projectID, imageId: imageID,
                        kind: ArtifactKind.diskImage.rawValue, filename: image.filename)
                row.status =
                    legacyComplete && image.status == ImageStatus.ready.rawValue
                    ? ArtifactStatus.ready.rawValue
                    : artifactStatus(for: image.status)
                row.sourceURL = image.sourceURL
                row.downloadProgress = image.downloadProgress
                row.errorMessage = image.errorMessage
                row.expectedChecksum = image.expectedChecksum
                try await row.save(on: database)
                artifacts.append(row)
                disk = row
            }

            if let disk {
                var changed = false
                if disk.expectedChecksum == nil, let expected = image.expectedChecksum {
                    disk.expectedChecksum = expected
                    changed = true
                }
                if disk.sourceURL == nil, let sourceURL = image.sourceURL {
                    disk.sourceURL = sourceURL
                    changed = true
                }

                // A ready image's complete legacy facts can repair a partial
                // disk artifact left by an interrupted historical dual write.
                if image.status == ImageStatus.ready.rawValue, legacyComplete,
                    !Self.isValid(disk, architecture: image.architecture)
                {
                    disk.format = image.format
                    disk.architecture = image.architecture
                    disk.filename = image.filename
                    disk.size = image.size
                    disk.checksum = image.checksum ?? ""
                    disk.storagePath = image.storagePath ?? disk.storagePath
                    disk.status = ArtifactStatus.ready.rawValue
                    changed = true
                }
                if changed { try await disk.save(on: database) }
            }

            if image.status == ImageStatus.ready.rawValue {
                let refreshed = try await AuthoritativeImageArtifactRow.query(on: database)
                    .filter(\.$imageID == imageID)
                    .all()
                let validKinds = Set(
                    refreshed.filter { Self.isValid($0, architecture: image.architecture) }.map(\.kind))
                let bootable =
                    validKinds.contains(ArtifactKind.diskImage.rawValue)
                    || (validKinds.contains(ArtifactKind.kernel.rawValue)
                        && validKinds.contains(ArtifactKind.rootfs.rawValue))
                if !bootable { incompleteReadyImages.append(imageID) }
            }
        }

        guard incompleteReadyImages.isEmpty else {
            throw ImageArtifactCutoverError.incompleteReadyImages(incompleteReadyImages)
        }

        try await database.schema("images")
            .deleteField("filename")
            .deleteField("size")
            .deleteField("format")
            .deleteField("checksum")
            .deleteField("expected_checksum")
            .deleteField("storage_path")
            .deleteField("source_url")
            .deleteField("download_progress")
            .deleteField("error_message")
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("images")
            .field("filename", .string, .required, .sql(.default("")))
            .field("size", .int64, .required, .sql(.default("0")))
            .field("format", .string, .required, .sql(.default("qcow2")))
            .field("checksum", .string)
            .field("expected_checksum", .string)
            .field("storage_path", .string)
            .field("source_url", .string)
            .field("download_progress", .int)
            .field("error_message", .string)
            .update()

        let images = try await AuthoritativeImageLegacyRow.query(on: database).all()
        for image in images {
            guard let imageID = image.id,
                let disk = try await AuthoritativeImageArtifactRow.query(on: database)
                    .filter(\.$imageID == imageID)
                    .filter(\.$kind == ArtifactKind.diskImage.rawValue)
                    .first()
            else { continue }
            image.filename = disk.filename
            image.size = disk.size
            image.format = disk.format ?? ImageFormat.raw.rawValue
            image.checksum = disk.checksum.isEmpty ? nil : disk.checksum
            image.expectedChecksum = disk.expectedChecksum
            image.storagePath = disk.storagePath
            image.sourceURL = disk.sourceURL
            image.downloadProgress = disk.downloadProgress
            image.errorMessage = disk.errorMessage
            try await image.save(on: database)
        }
    }

    private static func isValid(
        _ artifact: AuthoritativeImageArtifactRow, architecture: String
    ) -> Bool {
        guard artifact.status == ArtifactStatus.ready.rawValue,
            artifact.architecture == architecture,
            !artifact.filename.isEmpty,
            !artifact.storagePath.isEmpty,
            artifact.size >= 0,
            artifact.checksum.count == 64,
            artifact.checksum.allSatisfy(\.isHexDigit)
        else { return false }

        if artifact.kind == ArtifactKind.diskImage.rawValue
            || artifact.kind == ArtifactKind.rootfs.rawValue
        {
            return artifact.format != nil
        }
        return true
    }

    private func artifactStatus(for imageStatus: String) -> String {
        switch imageStatus {
        case ImageStatus.downloading.rawValue:
            return ArtifactStatus.downloading.rawValue
        case ImageStatus.error.rawValue:
            return ArtifactStatus.error.rawValue
        default:
            return ArtifactStatus.pending.rawValue
        }
    }
}

/// Snapshot of the image schema immediately before the cutover.
final class AuthoritativeImageLegacyRow: Model, @unchecked Sendable {
    static let schema = "images"

    @ID(key: .id) var id: UUID?
    @Field(key: "project_id") var projectID: UUID
    @Field(key: "filename") var filename: String
    @Field(key: "size") var size: Int64
    @Field(key: "format") var format: String
    @Field(key: "architecture") var architecture: String
    @OptionalField(key: "checksum") var checksum: String?
    @OptionalField(key: "expected_checksum") var expectedChecksum: String?
    @OptionalField(key: "storage_path") var storagePath: String?
    @Field(key: "status") var status: String
    @OptionalField(key: "source_url") var sourceURL: String?
    @OptionalField(key: "download_progress") var downloadProgress: Int?
    @OptionalField(key: "error_message") var errorMessage: String?

    init() {}
}

/// Snapshot of the artifact schema after adding `expected_checksum`.
final class AuthoritativeImageArtifactRow: Model, @unchecked Sendable {
    static let schema = "image_artifacts"

    @ID(key: .id) var id: UUID?
    @Field(key: "image_id") var imageID: UUID
    @Field(key: "kind") var kind: String
    @OptionalField(key: "format") var format: String?
    @Field(key: "architecture") var architecture: String
    @Field(key: "filename") var filename: String
    @Field(key: "size") var size: Int64
    @Field(key: "checksum") var checksum: String
    @OptionalField(key: "expected_checksum") var expectedChecksum: String?
    @Field(key: "storage_path") var storagePath: String
    @Field(key: "status") var status: String
    @OptionalField(key: "source_url") var sourceURL: String?
    @OptionalField(key: "download_progress") var downloadProgress: Int?
    @OptionalField(key: "error_message") var errorMessage: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}
