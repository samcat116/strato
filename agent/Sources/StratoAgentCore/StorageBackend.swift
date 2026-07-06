import Foundation
import StratoShared

// MARK: - Disk Format

/// On-disk image formats the storage layer can produce. Distinct from the
/// wire-level format strings: parse those with `DiskFormat(rawValue:)` and
/// reject unknown values at the boundary instead of passing free-form strings
/// into qemu-img.
public enum DiskFormat: String, Codable, Sendable, CaseIterable {
    case qcow2
    case raw

    /// File extension used by the path layout (`volume.qcow2`, `rootfs.raw`).
    public var fileExtension: String { rawValue }

    /// Best-effort format inference for a disk referenced only by path. The
    /// storage layout names files after their format, so the extension is
    /// authoritative for backend-managed volumes; unknown extensions fall
    /// back to qcow2 (the historical assumption for pre-existing disks).
    public init(volumePath: String) {
        self = DiskFormat(rawValue: (volumePath as NSString).pathExtension) ?? .qcow2
    }
}

// MARK: - Disk Attachment Descriptor

/// What the storage layer hands a hypervisor driver: a disk that exists on
/// this host, with the format the driver must declare when attaching it.
/// Drivers add their own attach options (readonly, device names, interfaces).
public struct DiskAttachment: Sendable, Equatable {
    /// Host path of the disk image.
    public let path: String
    /// Actual format of the image at `path`.
    public let format: DiskFormat

    public init(path: String, format: DiskFormat) {
        self.path = path
        self.format = format
    }
}

// MARK: - Image Source

/// Provides a local file for an image referenced by `ImageInfo` (downloading
/// and caching as needed). Implemented by the agent's `ImageCacheService`;
/// abstracted here so the storage layer stays testable without networking.
public protocol ImageSource: Sendable {
    /// Returns a local filesystem path holding the image's bytes, downloading
    /// them first if they are not cached.
    func localImagePath(for imageInfo: ImageInfo) async throws -> String
}

// MARK: - Volume Info

/// Result of querying a volume's on-disk state.
public struct VolumeInfoResult: Codable, Sendable {
    public let actualSize: Int64
    public let virtualSize: Int64
    public let format: String
    public let dirty: Bool
    public let encrypted: Bool

    public init(actualSize: Int64, virtualSize: Int64, format: String, dirty: Bool, encrypted: Bool) {
        self.actualSize = actualSize
        self.virtualSize = virtualSize
        self.format = format
        self.dirty = dirty
        self.encrypted = encrypted
    }
}

// MARK: - Storage Backend Protocol

/// Storage driver interface: everything that turns images and empty space into
/// attachable disks. The counterpart of `HypervisorService` (compute) and
/// `NetworkServiceProtocol` (networking).
///
/// The backend owns volume placement: callers pass IDs, the backend decides
/// paths and reports them back through `DiskAttachment` (the control plane
/// stores whatever the agent reports and never derives paths itself).
/// Operations that hand back a disk return a typed `DiskAttachment` so
/// hypervisor drivers never guess at formats.
///
/// The first implementation is `FileSystemStorageBackend` (qemu-img on a local
/// directory). Future backends (LVM, Ceph RBD, ZFS) can implement
/// `createVolumeFromImage`/`cloneVolume` efficiently (backing files, reflinks,
/// COW snapshots) instead of full copies.
public protocol StorageBackend: Actor {
    /// Creates a new empty volume of `sizeBytes` and returns its attachment.
    func createVolume(volumeId: String, sizeBytes: Int64, format: DiskFormat) async throws -> DiskAttachment

    /// Creates a volume whose content comes from an image, converting between
    /// formats when the source image's format differs from `format`.
    func createVolumeFromImage(volumeId: String, imageInfo: ImageInfo, format: DiskFormat) async throws
        -> DiskAttachment

    /// Materializes an image as a disk at an explicit path — the single
    /// image → disk path used by hypervisor drivers for boot disks that live
    /// in VM directories rather than the volume store. Idempotent: an existing
    /// disk at `path` is returned as-is. Converts formats when the source
    /// image's format differs from `format`.
    func materializeDisk(at path: String, from imageInfo: ImageInfo, format: DiskFormat) async throws
        -> DiskAttachment

    /// Deletes a volume and everything under its directory (idempotent).
    func deleteVolume(volumeId: String) async throws

    /// Grows a volume to `newSizeBytes` (must be detached).
    func resizeVolume(volumePath: String, newSizeBytes: Int64) async throws

    /// Creates a point-in-time snapshot of a volume; returns the snapshot's path.
    func createSnapshot(volumeId: String, snapshotId: String, volumePath: String) async throws -> String

    /// Deletes a snapshot, deriving its location from the IDs (idempotent).
    func deleteSnapshot(volumeId: String, snapshotId: String) async throws

    /// Clones a volume into a new, independent volume (no shared backing chain)
    /// and returns the clone's attachment.
    func cloneVolume(sourceVolumeId: String, sourcePath: String, targetVolumeId: String) async throws
        -> DiskAttachment

    /// Queries a volume's on-disk state.
    func volumeInfo(volumePath: String) async throws -> VolumeInfoResult
}

// MARK: - Errors

public enum StorageBackendError: Error, LocalizedError, Sendable {
    case createFailed(String)
    case deleteFailed(String)
    case resizeFailed(String)
    case snapshotFailed(String)
    case cloneFailed(String)
    case infoFailed(String)
    case volumeNotFound(String)
    case imageSourceUnavailable
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let reason):
            return "Volume creation failed: \(reason)"
        case .deleteFailed(let reason):
            return "Volume deletion failed: \(reason)"
        case .resizeFailed(let reason):
            return "Volume resize failed: \(reason)"
        case .snapshotFailed(let reason):
            return "Snapshot creation failed: \(reason)"
        case .cloneFailed(let reason):
            return "Volume clone failed: \(reason)"
        case .infoFailed(let reason):
            return "Volume info query failed: \(reason)"
        case .volumeNotFound(let volumeId):
            return "Volume not found: \(volumeId)"
        case .imageSourceUnavailable:
            return "Image source not available: cannot materialize a disk from an image"
        case .unsupportedFormat(let format):
            return "Unsupported disk format: \(format)"
        }
    }
}
