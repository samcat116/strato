import Foundation
import Logging
import StratoShared

/// Runs a subprocess to completion. Injectable so tests can stub qemu-img.
public typealias SubprocessRunner =
    @Sendable (_ executableURL: URL, _ arguments: [String]) async throws -> ProcessResult

/// The "qemu-img on a filesystem directory" storage backend.
///
/// Owns the on-disk layout for managed volumes:
///
///     <volumeStoragePath>/<volumeId>/volume.<format>
///     <volumeStoragePath>/<volumeId>/snapshots/<snapshotId>.qcow2
///
/// and the single image → disk materialization path: sources are inspected
/// with `qemu-img info` and converted with `qemu-img convert` whenever the
/// requested format differs, so every hypervisor driver gets a correctly
/// formatted disk (a qcow2 cloud image becomes a raw rootfs for Firecracker,
/// not a byte-for-byte copy with the wrong name).
public actor FileSystemStorageBackend: StorageBackend {
    private let logger: Logger
    private let volumeStoragePath: String
    private let qemuImgPath: String
    private let imageSource: (any ImageSource)?
    private let runSubprocess: SubprocessRunner

    /// Default storage path for volumes (platform-specific)
    public static var defaultStoragePath: String {
        #if os(macOS)
        // On macOS, use user's data directory (writable without root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/volumes"
        #else
        // On Linux, use system data directory
        return "/var/lib/strato/volumes"
        #endif
    }

    /// Default qemu-img path (platform-specific)
    public static var defaultQemuImgPath: String {
        #if os(macOS)
        // Homebrew typically installs qemu-img here
        return "/opt/homebrew/bin/qemu-img"
        #else
        return "/usr/bin/qemu-img"
        #endif
    }

    public init(
        logger: Logger,
        volumeStoragePath: String? = nil,
        qemuImgPath: String? = nil,
        imageSource: (any ImageSource)? = nil,
        runSubprocess: @escaping SubprocessRunner = { try await ProcessRunner.run(executableURL: $0, arguments: $1) }
    ) {
        self.logger = logger
        self.volumeStoragePath = volumeStoragePath ?? Self.defaultStoragePath
        self.qemuImgPath = qemuImgPath ?? Self.defaultQemuImgPath
        self.imageSource = imageSource
        self.runSubprocess = runSubprocess

        // Ensure storage directory exists
        do {
            try FileManager.default.createDirectory(
                atPath: self.volumeStoragePath,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.info(
                "Storage backend initialized",
                metadata: [
                    "storagePath": .string(self.volumeStoragePath),
                    "qemuImgPath": .string(self.qemuImgPath),
                ])
        } catch {
            logger.error(
                "Failed to create volume storage directory: \(error)",
                metadata: [
                    "storagePath": .string(self.volumeStoragePath)
                ])
        }
    }

    // MARK: - Path Layout

    /// The canonical path for a volume. The agent is the sole authority on
    /// this layout; the control plane only stores what gets reported back.
    public func volumePath(volumeId: String, format: DiskFormat) -> String {
        "\(volumeStoragePath)/\(volumeId)/volume.\(format.fileExtension)"
    }

    private func volumeDirectory(volumeId: String) -> String {
        "\(volumeStoragePath)/\(volumeId)"
    }

    private func snapshotPath(volumeId: String, snapshotId: String) -> String {
        "\(volumeStoragePath)/\(volumeId)/snapshots/\(snapshotId).qcow2"
    }

    // MARK: - Volume Creation

    public func createVolume(volumeId: String, sizeBytes: Int64, format: DiskFormat) async throws -> DiskAttachment {
        let path = volumePath(volumeId: volumeId, format: format)

        logger.info(
            "Creating volume",
            metadata: [
                "volumeId": .string(volumeId),
                "size": .stringConvertible(sizeBytes),
                "format": .string(format.rawValue),
            ])

        try FileManager.default.createDirectory(
            atPath: volumeDirectory(volumeId: volumeId),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let result = try await runQemuImg(["create", "-f", format.rawValue, path, "\(sizeBytes)"])
        if result.terminationStatus != 0 {
            let output = result.combinedOutput
            logger.error(
                "qemu-img create failed",
                metadata: [
                    "volumeId": .string(volumeId),
                    "output": .string(output),
                ])
            throw StorageBackendError.createFailed("qemu-img create failed: \(output)")
        }

        logger.info(
            "Volume created successfully",
            metadata: [
                "volumeId": .string(volumeId),
                "path": .string(path),
            ])

        return DiskAttachment(path: path, format: format)
    }

    public func createVolumeFromImage(volumeId: String, imageInfo: ImageInfo, format: DiskFormat) async throws
        -> DiskAttachment
    {
        logger.info(
            "Creating volume from image",
            metadata: [
                "volumeId": .string(volumeId),
                "imageId": .string(imageInfo.imageId.uuidString),
                "format": .string(format.rawValue),
            ])

        return try await materializeDisk(
            at: volumePath(volumeId: volumeId, format: format),
            from: imageInfo,
            format: format
        )
    }

    // MARK: - Image Materialization

    public func materializeDisk(at path: String, from imageInfo: ImageInfo, format: DiskFormat) async throws
        -> DiskAttachment
    {
        // Idempotent: a disk already materialized for this path (e.g. a VM
        // re-create after an agent restart) is reused, not overwritten. The
        // final path only ever holds a complete disk because materialization
        // writes to a temporary path and publishes via atomic rename below —
        // an interrupted copy/convert can never satisfy this check.
        if FileManager.default.fileExists(atPath: path) {
            logger.debug("Disk already materialized", metadata: ["path": .string(path)])
            return DiskAttachment(path: path, format: format)
        }

        guard let imageSource else {
            throw StorageBackendError.imageSourceUnavailable
        }

        let sourcePath = try await imageSource.localImagePath(for: imageInfo)
        let sourceFormat = try await detectFormat(of: sourcePath)

        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Discard any partial output left by a previous crashed materialization.
        let stagingPath = path + ".partial"
        try? FileManager.default.removeItem(atPath: stagingPath)

        do {
            if sourceFormat == format.rawValue {
                try FileManager.default.copyItem(atPath: sourcePath, toPath: stagingPath)
            } else {
                // Source and target formats differ — convert instead of copying,
                // so e.g. a qcow2 image really becomes a raw disk.
                let result = try await runQemuImg([
                    "convert",
                    "-f", sourceFormat,
                    "-O", format.rawValue,
                    sourcePath,
                    stagingPath,
                ])
                if result.terminationStatus != 0 {
                    let output = result.combinedOutput
                    logger.error(
                        "qemu-img convert failed",
                        metadata: [
                            "source": .string(sourcePath),
                            "target": .string(path),
                            "output": .string(output),
                        ])
                    throw StorageBackendError.createFailed("qemu-img convert failed: \(output)")
                }
            }

            // Atomic publish: rename within the same directory, so the disk
            // appears at its final path all-or-nothing.
            try FileManager.default.moveItem(atPath: stagingPath, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            throw error
        }

        logger.info(
            "Disk materialized from image",
            metadata: [
                "path": .string(path),
                "sourceImage": .string(sourcePath),
                "sourceFormat": .string(sourceFormat),
                "targetFormat": .string(format.rawValue),
            ])

        return DiskAttachment(path: path, format: format)
    }

    // MARK: - Volume Deletion

    public func deleteVolume(volumeId: String) async throws {
        let volumeDir = volumeDirectory(volumeId: volumeId)

        logger.info("Deleting volume", metadata: ["volumeId": .string(volumeId)])

        if FileManager.default.fileExists(atPath: volumeDir) {
            try FileManager.default.removeItem(atPath: volumeDir)
            logger.info("Volume deleted", metadata: ["volumeId": .string(volumeId)])
        } else {
            logger.warning(
                "Volume directory not found",
                metadata: [
                    "volumeId": .string(volumeId),
                    "path": .string(volumeDir),
                ])
        }
    }

    // MARK: - Volume Resize

    public func resizeVolume(volumePath: String, newSizeBytes: Int64) async throws {
        logger.info(
            "Resizing volume",
            metadata: [
                "path": .string(volumePath),
                "newSize": .stringConvertible(newSizeBytes),
            ])

        let result = try await runQemuImg(["resize", volumePath, "\(newSizeBytes)"])
        if result.terminationStatus != 0 {
            let output = result.combinedOutput
            logger.error(
                "qemu-img resize failed",
                metadata: [
                    "path": .string(volumePath),
                    "output": .string(output),
                ])
            throw StorageBackendError.resizeFailed("qemu-img resize failed: \(output)")
        }

        logger.info(
            "Volume resized successfully",
            metadata: [
                "path": .string(volumePath),
                "newSize": .stringConvertible(newSizeBytes),
            ])
    }

    // MARK: - Snapshots

    /// Creates an external snapshot as a qcow2 overlay whose backing file is
    /// the volume. The backing format is detected rather than assumed, so raw
    /// volumes snapshot correctly too.
    public func createSnapshot(volumeId: String, snapshotId: String, volumePath: String) async throws -> String {
        let snapshotPath = snapshotPath(volumeId: volumeId, snapshotId: snapshotId)

        logger.info(
            "Creating snapshot",
            metadata: [
                "volumeId": .string(volumeId),
                "snapshotId": .string(snapshotId),
                "volumePath": .string(volumePath),
            ])

        let backingFormat = try await detectFormat(of: volumePath)

        try FileManager.default.createDirectory(
            atPath: (snapshotPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let result = try await runQemuImg([
            "create",
            "-f", "qcow2",
            "-b", volumePath,
            "-F", backingFormat,
            snapshotPath,
        ])
        if result.terminationStatus != 0 {
            let output = result.combinedOutput
            logger.error(
                "qemu-img snapshot create failed",
                metadata: [
                    "volumeId": .string(volumeId),
                    "output": .string(output),
                ])
            throw StorageBackendError.snapshotFailed("qemu-img create snapshot failed: \(output)")
        }

        logger.info(
            "Snapshot created successfully",
            metadata: [
                "volumeId": .string(volumeId),
                "snapshotId": .string(snapshotId),
                "path": .string(snapshotPath),
            ])

        return snapshotPath
    }

    /// Deletes a snapshot. The path is derived from the IDs — the same
    /// derivation `createSnapshot` uses — rather than trusted from the wire,
    /// so deletion works even when the control plane never recorded the path
    /// (e.g. the create succeeded but its response was lost). A missing file
    /// is not an error: deletion is idempotent.
    public func deleteSnapshot(volumeId: String, snapshotId: String) async throws {
        let snapshotPath = snapshotPath(volumeId: volumeId, snapshotId: snapshotId)

        logger.info(
            "Deleting snapshot",
            metadata: [
                "volumeId": .string(volumeId),
                "snapshotId": .string(snapshotId),
                "path": .string(snapshotPath),
            ])

        if FileManager.default.fileExists(atPath: snapshotPath) {
            try FileManager.default.removeItem(atPath: snapshotPath)
            logger.info("Snapshot deleted", metadata: ["path": .string(snapshotPath)])
        } else {
            logger.warning("Snapshot not found", metadata: ["path": .string(snapshotPath)])
        }
    }

    // MARK: - Volume Clone

    /// Clones a volume into a new, fully independent volume of the same
    /// format. `qemu-img convert` produces a flattened copy, so the clone
    /// shares no backing chain with the source.
    public func cloneVolume(sourceVolumeId: String, sourcePath: String, targetVolumeId: String) async throws
        -> DiskAttachment
    {
        let sourceFormatString = try await detectFormat(of: sourcePath)
        guard let format = DiskFormat(rawValue: sourceFormatString) else {
            throw StorageBackendError.unsupportedFormat(sourceFormatString)
        }
        let targetPath = volumePath(volumeId: targetVolumeId, format: format)

        logger.info(
            "Cloning volume",
            metadata: [
                "sourceVolumeId": .string(sourceVolumeId),
                "targetVolumeId": .string(targetVolumeId),
                "sourcePath": .string(sourcePath),
                "format": .string(format.rawValue),
            ])

        try FileManager.default.createDirectory(
            atPath: volumeDirectory(volumeId: targetVolumeId),
            withIntermediateDirectories: true,
            attributes: nil
        )

        let result = try await runQemuImg([
            "convert",
            "-f", format.rawValue,
            "-O", format.rawValue,
            sourcePath,
            targetPath,
        ])
        if result.terminationStatus != 0 {
            let output = result.combinedOutput
            logger.error(
                "qemu-img clone failed",
                metadata: [
                    "sourceVolumeId": .string(sourceVolumeId),
                    "output": .string(output),
                ])
            throw StorageBackendError.cloneFailed("qemu-img convert failed: \(output)")
        }

        logger.info(
            "Volume cloned successfully",
            metadata: [
                "sourceVolumeId": .string(sourceVolumeId),
                "targetVolumeId": .string(targetVolumeId),
                "targetPath": .string(targetPath),
            ])

        return DiskAttachment(path: targetPath, format: format)
    }

    // MARK: - Volume Info

    public func volumeInfo(volumePath: String) async throws -> VolumeInfoResult {
        logger.debug("Getting volume info", metadata: ["path": .string(volumePath)])

        let info = try await queryImageInfo(path: volumePath)

        return VolumeInfoResult(
            actualSize: info.actualSize,
            virtualSize: info.virtualSize,
            format: info.format,
            dirty: info.dirty ?? false,
            encrypted: info.encrypted ?? false
        )
    }

    /// Checks if a volume exists
    public func volumeExists(volumeId: String) -> Bool {
        FileManager.default.fileExists(atPath: volumeDirectory(volumeId: volumeId))
    }

    // MARK: - qemu-img Helpers

    private func runQemuImg(_ arguments: [String]) async throws -> ProcessResult {
        try await runSubprocess(URL(fileURLWithPath: qemuImgPath), arguments)
    }

    /// Detects an image's format string (e.g. "qcow2", "raw") via qemu-img info.
    private func detectFormat(of path: String) async throws -> String {
        try await queryImageInfo(path: path).format
    }

    private func queryImageInfo(path: String) async throws -> QemuImgInfo {
        let result = try await runQemuImg(["info", "--output=json", path])
        if result.terminationStatus != 0 {
            throw StorageBackendError.infoFailed("qemu-img info failed: \(result.combinedOutput)")
        }
        return try JSONDecoder().decode(QemuImgInfo.self, from: result.standardOutput)
    }
}

// MARK: - Supporting Types

/// JSON structure from qemu-img info --output=json
private struct QemuImgInfo: Decodable {
    let filename: String
    let format: String
    let virtualSize: Int64
    let actualSize: Int64
    let dirty: Bool?
    let encrypted: Bool?
    let backingFilename: String?
    let backingFilenameFormat: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case format
        case virtualSize = "virtual-size"
        case actualSize = "actual-size"
        case dirty = "dirty-flag"
        case encrypted
        case backingFilename = "backing-filename"
        case backingFilenameFormat = "backing-filename-format"
    }
}
