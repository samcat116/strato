import Foundation
import Logging
import StratoShared

/// A storage backend that reports volumes without creating any: the counterpart
/// of the mock hypervisor, used by the agent's simulation mode.
///
/// A simulated agent advertises QEMU, and volume placement
/// (`VolumeService.selectVolumeAgent`) picks any online agent supporting it, so
/// a dummy will be handed real volume create/clone/snapshot work. Backing that
/// with `FileSystemStorageBackend` would defeat the point of simulation: every
/// volume would `qemu-img create` a real file under the agent's storage dir, and
/// `createVolumeFromImage` would pull the whole image through the image cache
/// first. Across a fleet of hundreds that is enough disk and network traffic to
/// take out the host — and it would make the simulated disk figures a fiction
/// about a filesystem actually filling up.
///
/// So this tracks volume *metadata* only, and touches neither the filesystem nor
/// the network. It mirrors `FileSystemStorageBackend`'s path layout so the paths
/// reported to the control plane look like the real thing (the agent is the sole
/// authority on layout; the control plane stores whatever it is told), and keeps
/// the same "unknown volume throws" behavior so callers exercise the same code
/// paths they would against a real backend.
public actor MockStorageBackend: StorageBackend {
    private let logger: Logger
    private let volumeStoragePath: String

    /// Recorded volumes, keyed by id. `path` is the reported location — nothing
    /// exists there.
    private struct MockVolume {
        var path: String
        var format: DiskFormat
        var sizeBytes: Int64
    }
    private var volumes: [String: MockVolume] = [:]
    private var snapshots: Set<String> = []

    public init(logger: Logger, volumeStoragePath: String? = nil) {
        self.logger = logger
        self.volumeStoragePath = volumeStoragePath ?? FileSystemStorageBackend.defaultStoragePath
        logger.warning("Storage running in mock mode - no volumes will be written to disk")
    }

    // MARK: - Path layout (mirrors FileSystemStorageBackend)

    private func volumePath(volumeId: String, format: DiskFormat) -> String {
        "\(volumeStoragePath)/\(volumeId)/volume.\(format.fileExtension)"
    }

    private func snapshotPath(volumeId: String, snapshotId: String) -> String {
        "\(volumeStoragePath)/\(volumeId)/snapshots/\(snapshotId).qcow2"
    }

    // MARK: - Volume lifecycle

    public func createVolume(volumeId: String, sizeBytes: Int64, format: DiskFormat) async throws -> DiskAttachment {
        let path = volumePath(volumeId: volumeId, format: format)
        logger.info(
            "Creating mock volume (mock mode)",
            metadata: ["volumeId": .string(volumeId), "sizeBytes": .stringConvertible(sizeBytes)])
        volumes[volumeId] = MockVolume(path: path, format: format, sizeBytes: sizeBytes)
        return DiskAttachment(path: path, format: format)
    }

    /// Records the volume without fetching the image. Deliberately never touches
    /// the `ImageSource`: a real materialization would download the full image
    /// on every simulated agent it lands on.
    public func createVolumeFromImage(volumeId: String, imageInfo: ImageInfo, format: DiskFormat) async throws
        -> DiskAttachment
    {
        let path = volumePath(volumeId: volumeId, format: format)
        logger.info(
            "Creating mock volume from image (mock mode; image not downloaded)",
            metadata: ["volumeId": .string(volumeId), "imageId": .string(imageInfo.imageId.uuidString)])
        volumes[volumeId] = MockVolume(path: path, format: format, sizeBytes: imageInfo.size)
        return DiskAttachment(path: path, format: format)
    }

    /// Reports the disk as materialized at `path` without writing it. Idempotent,
    /// like the real backend.
    public func materializeDisk(
        at path: String, from imageInfo: ImageInfo, format: DiskFormat, artifactKind: ArtifactKind
    ) async throws -> DiskAttachment {
        logger.info(
            "Materializing mock disk (mock mode; image not downloaded)",
            metadata: [
                "path": .string(path),
                "imageId": .string(imageInfo.imageId.uuidString),
                "artifactKind": .string(artifactKind.rawValue),
            ])
        return DiskAttachment(path: path, format: format)
    }

    public func deleteVolume(volumeId: String) async throws {
        logger.info("Deleting mock volume (mock mode)", metadata: ["volumeId": .string(volumeId)])
        volumes.removeValue(forKey: volumeId)  // idempotent, like the real backend
    }

    public func resizeVolume(volumePath: String, newSizeBytes: Int64) async throws {
        guard let id = volumes.first(where: { $0.value.path == volumePath })?.key else {
            throw StorageBackendError.volumeNotFound(volumePath)
        }
        logger.info(
            "Resizing mock volume (mock mode)",
            metadata: ["volumePath": .string(volumePath), "newSizeBytes": .stringConvertible(newSizeBytes)])
        volumes[id]?.sizeBytes = newSizeBytes
    }

    // MARK: - Snapshots

    public func createSnapshot(volumeId: String, snapshotId: String, volumePath: String) async throws -> String {
        guard volumes[volumeId] != nil else {
            throw StorageBackendError.volumeNotFound(volumeId)
        }
        let path = snapshotPath(volumeId: volumeId, snapshotId: snapshotId)
        logger.info(
            "Creating mock snapshot (mock mode)",
            metadata: ["volumeId": .string(volumeId), "snapshotId": .string(snapshotId)])
        snapshots.insert(path)
        return path
    }

    public func deleteSnapshot(volumeId: String, snapshotId: String) async throws {
        logger.info(
            "Deleting mock snapshot (mock mode)",
            metadata: ["volumeId": .string(volumeId), "snapshotId": .string(snapshotId)])
        snapshots.remove(snapshotPath(volumeId: volumeId, snapshotId: snapshotId))  // idempotent
    }

    // MARK: - Clone / info

    public func cloneVolume(sourceVolumeId: String, sourcePath: String, targetVolumeId: String) async throws
        -> DiskAttachment
    {
        guard let source = volumes[sourceVolumeId] else {
            throw StorageBackendError.volumeNotFound(sourceVolumeId)
        }
        let path = volumePath(volumeId: targetVolumeId, format: source.format)
        logger.info(
            "Cloning mock volume (mock mode)",
            metadata: ["sourceVolumeId": .string(sourceVolumeId), "targetVolumeId": .string(targetVolumeId)])
        volumes[targetVolumeId] = MockVolume(path: path, format: source.format, sizeBytes: source.sizeBytes)
        return DiskAttachment(path: path, format: source.format)
    }

    public func volumeInfo(volumePath: String) async throws -> VolumeInfoResult {
        guard let volume = volumes.first(where: { $0.value.path == volumePath })?.value else {
            throw StorageBackendError.volumeNotFound(volumePath)
        }
        // A simulated volume consumes nothing, so actualSize is 0 — the honest
        // answer for a disk that does not exist, and it keeps a simulated fleet
        // from reporting fabricated consumption.
        return VolumeInfoResult(
            actualSize: 0,
            virtualSize: volume.sizeBytes,
            format: volume.format.rawValue,
            dirty: false,
            encrypted: false
        )
    }
}
