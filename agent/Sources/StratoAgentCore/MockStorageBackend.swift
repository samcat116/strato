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
///
/// That metadata is persisted, because the real backend's is. `qemu-img` reads a
/// volume's format and size back off the disk, so `FileSystemStorageBackend`
/// holds no volume registry at all and a restart costs it nothing. A purely
/// in-memory mock would instead come back empty while the control plane still
/// has the volume placed here, and every later resize/snapshot/clone/info would
/// fail `volumeNotFound` — a failure mode no real agent has. The metadata file
/// is this backend's equivalent of the bytes on disk; it holds tens of bytes per
/// volume, not gigabytes.
public actor MockStorageBackend: StorageBackend {
    private let logger: Logger
    private let volumeStoragePath: String
    /// Where the volume metadata is persisted across restarts. Nil disables
    /// persistence (tests, and any caller that does not need restart parity).
    ///
    /// Must be per-agent: `volumeStoragePath` defaults to one host-wide
    /// directory, so a fleet of simulated agents sharing this machine would
    /// otherwise write over each other's metadata. The agent points it at its
    /// own storage dir, alongside the VM manifest.
    private let metadataPath: String?

    /// Recorded volumes, keyed by id. `path` is the reported location — nothing
    /// exists there.
    private struct MockVolume: Codable {
        var path: String
        var format: DiskFormat
        var sizeBytes: Int64
    }

    private struct Metadata: Codable {
        var volumes: [String: MockVolume]
        var snapshots: [String]
    }

    private var volumes: [String: MockVolume] = [:]
    private var snapshots: Set<String> = []

    public init(logger: Logger, volumeStoragePath: String? = nil, metadataPath: String? = nil) {
        self.logger = logger
        self.volumeStoragePath = volumeStoragePath ?? FileSystemStorageBackend.defaultStoragePath
        self.metadataPath = metadataPath
        logger.warning("Storage running in mock mode - no volumes will be written to disk")

        // Recover volumes recorded by a previous incarnation, so the control
        // plane's existing placements still resolve after a restart.
        guard let metadataPath, FileManager.default.fileExists(atPath: metadataPath) else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
            let loaded = try JSONDecoder().decode(Metadata.self, from: data)
            volumes = loaded.volumes
            snapshots = Set(loaded.snapshots)
            // Bind the count first: the logger's metadata is an autoclosure, and
            // actor-isolated state cannot be read from one during init.
            let recovered = loaded.volumes.count
            if recovered > 0 {
                logger.info(
                    "Recovered mock volume metadata from a previous run",
                    metadata: ["volumes": .stringConvertible(recovered)])
            }
        } catch {
            // Same posture as the VM manifest: a corrupt file is not fatal, it
            // just costs the volumes it recorded.
            logger.error("Failed to read mock volume metadata at \(metadataPath): \(error)")
        }
    }

    /// Persists the current metadata. Best effort: a failure here costs restart
    /// parity for these volumes, but must not fail the operation that triggered
    /// it — the operation itself succeeded.
    private func persist() {
        guard let metadataPath else { return }
        do {
            let directory = (metadataPath as NSString).deletingLastPathComponent
            if !directory.isEmpty {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(Metadata(volumes: volumes, snapshots: Array(snapshots)))
            // Atomic, so a crash mid-write cannot leave a truncated file.
            try data.write(to: URL(fileURLWithPath: metadataPath), options: .atomic)
        } catch {
            logger.error("Failed to write mock volume metadata at \(metadataPath): \(error)")
        }
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
        persist()
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
        persist()
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
        persist()
    }

    public func resizeVolume(volumePath: String, newSizeBytes: Int64) async throws {
        guard let id = volumes.first(where: { $0.value.path == volumePath })?.key else {
            throw StorageBackendError.volumeNotFound(volumePath)
        }
        logger.info(
            "Resizing mock volume (mock mode)",
            metadata: ["volumePath": .string(volumePath), "newSizeBytes": .stringConvertible(newSizeBytes)])
        volumes[id]?.sizeBytes = newSizeBytes
        persist()
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
        persist()
        return path
    }

    public func deleteSnapshot(volumeId: String, snapshotId: String) async throws {
        logger.info(
            "Deleting mock snapshot (mock mode)",
            metadata: ["volumeId": .string(volumeId), "snapshotId": .string(snapshotId)])
        snapshots.remove(snapshotPath(volumeId: volumeId, snapshotId: snapshotId))  // idempotent
        persist()
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
        persist()
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
