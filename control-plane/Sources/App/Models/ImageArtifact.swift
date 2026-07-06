import Fluent
import Vapor
import Foundation
import StratoShared

/// Lifecycle of a single artifact. Uploaded artifacts are born `.ready`;
/// URL-sourced artifacts move through `.pending` → `.downloading` →
/// `.ready`/`.error`. Only `.ready` artifacts count toward image compatibility
/// and are sent to agents.
public enum ArtifactStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case downloading
    case ready
    case error
}

/// One typed file within an image's artifact set (see `ArtifactKind`).
///
/// Artifacts reference the same stored files as the image's legacy single-file
/// columns; a disk-image artifact for an uploaded image points at the same
/// `storage_path`. Kernel/rootfs/initramfs artifacts are what make an image
/// usable by direct-kernel-boot hypervisors like Firecracker.
final class ImageArtifact: Model, @unchecked Sendable {
    static let schema = "image_artifacts"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "image_id")
    var image: Image

    @Enum(key: "kind")
    var kind: ArtifactKind

    /// Disk format for `diskImage`/`rootfs`; nil for opaque blobs (`kernel`/`initramfs`).
    @OptionalEnum(key: "format")
    var format: ImageFormat?

    @Enum(key: "architecture")
    var architecture: CPUArchitecture

    @Field(key: "filename")
    var filename: String

    @Field(key: "size")
    var size: Int64

    @Field(key: "checksum")
    var checksum: String

    /// Storage location (relative path from IMAGE_STORAGE_PATH).
    @Field(key: "storage_path")
    var storagePath: String

    /// Fetch lifecycle. `.ready` for uploaded artifacts; URL-sourced artifacts
    /// progress through pending/downloading before becoming `.ready`.
    @Enum(key: "status")
    var status: ArtifactStatus

    /// Source URL for URL-fetched artifacts; nil for uploaded ones.
    @OptionalField(key: "source_url")
    var sourceURL: String?

    @OptionalField(key: "download_progress")
    var downloadProgress: Int?

    @OptionalField(key: "error_message")
    var errorMessage: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        imageID: UUID,
        kind: ArtifactKind,
        format: ImageFormat?,
        architecture: CPUArchitecture,
        filename: String,
        size: Int64,
        checksum: String,
        storagePath: String,
        status: ArtifactStatus = .ready,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.$image.id = imageID
        self.kind = kind
        self.format = format
        self.architecture = architecture
        self.filename = filename
        self.size = size
        self.checksum = checksum
        self.storagePath = storagePath
        self.status = status
        self.sourceURL = sourceURL
    }
}

extension ImageArtifact: Content {}

// MARK: - Public DTO

extension ImageArtifact {
    struct Public: Content {
        let id: UUID?
        let kind: ArtifactKind
        let format: ImageFormat?
        let architecture: CPUArchitecture
        let filename: String
        let size: Int64
        let checksum: String
        let status: ArtifactStatus
        let sourceURL: String?
        let downloadProgress: Int?
        let errorMessage: String?
    }

    func asPublic() -> Public {
        Public(
            id: self.id,
            kind: self.kind,
            format: self.format,
            architecture: self.architecture,
            filename: self.filename,
            size: self.size,
            checksum: self.checksum,
            status: self.status,
            sourceURL: self.sourceURL,
            downloadProgress: self.downloadProgress,
            errorMessage: self.errorMessage
        )
    }
}
