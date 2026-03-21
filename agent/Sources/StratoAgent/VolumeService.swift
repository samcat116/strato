import Foundation
import Logging
import StratoShared

/// Service for managing volumes on the agent using qemu-img
actor VolumeService {
    private let logger: Logger
    private let volumeStoragePath: String
    private let qemuImgPath: String
    private let imageCacheService: ImageCacheService?

    /// Default storage path for volumes (platform-specific)
    static var defaultStoragePath: String {
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
    static var defaultQemuImgPath: String {
        #if os(macOS)
        // Homebrew typically installs qemu-img here
        return "/opt/homebrew/bin/qemu-img"
        #else
        return "/usr/bin/qemu-img"
        #endif
    }

    init(
        logger: Logger,
        volumeStoragePath: String? = nil,
        qemuImgPath: String? = nil,
        imageCacheService: ImageCacheService? = nil
    ) {
        self.logger = logger
        self.volumeStoragePath = volumeStoragePath ?? Self.defaultStoragePath
        self.qemuImgPath = qemuImgPath ?? Self.defaultQemuImgPath
        self.imageCacheService = imageCacheService

        // Ensure storage directory exists
        do {
            try FileManager.default.createDirectory(
                atPath: self.volumeStoragePath,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.info("Volume service initialized", metadata: [
                "storagePath": .string(self.volumeStoragePath),
                "qemuImgPath": .string(self.qemuImgPath)
            ])
        } catch {
            logger.error("Failed to create volume storage directory: \(error)", metadata: [
                "storagePath": .string(self.volumeStoragePath)
            ])
        }
    }

    // MARK: - Volume Creation

    /// Creates a new empty volume
    /// Returns the path to the created volume
    func createVolume(volumeId: String, size: Int64, format: String = "qcow2") async throws -> String {
        let volumeDir = "\(volumeStoragePath)/\(volumeId)"
        let volumePath = "\(volumeDir)/volume.\(format)"

        logger.info("Creating volume", metadata: [
            "volumeId": .string(volumeId),
            "size": .stringConvertible(size),
            "format": .string(format)
        ])

        // Create directory
        try FileManager.default.createDirectory(
            atPath: volumeDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Run qemu-img create
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImgPath)
        process.arguments = ["create", "-f", format, volumePath, "\(size)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logger.error("qemu-img create failed", metadata: [
                "volumeId": .string(volumeId),
                "output": .string(output)
            ])
            throw VolumeServiceError.createFailed("qemu-img create failed: \(output)")
        }

        logger.info("Volume created successfully", metadata: [
            "volumeId": .string(volumeId),
            "path": .string(volumePath)
        ])

        return volumePath
    }

    /// Creates a volume from a source image
    /// Returns the path to the created volume
    func createVolumeFromImage(volumeId: String, imageInfo: ImageInfo) async throws -> String {
        guard let cacheService = imageCacheService else {
            throw VolumeServiceError.createFailed("Image cache service not available")
        }

        let volumeDir = "\(volumeStoragePath)/\(volumeId)"
        let volumePath = "\(volumeDir)/volume.qcow2"

        logger.info("Creating volume from image", metadata: [
            "volumeId": .string(volumeId),
            "imageId": .string(imageInfo.imageId.uuidString)
        ])

        // Get the cached image path (downloads if necessary)
        let cachedImagePath = try await cacheService.getImagePath(imageInfo: imageInfo)

        // Create directory
        try FileManager.default.createDirectory(
            atPath: volumeDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Copy the image to the volume location
        try FileManager.default.copyItem(atPath: cachedImagePath, toPath: volumePath)

        logger.info("Volume created from image", metadata: [
            "volumeId": .string(volumeId),
            "path": .string(volumePath),
            "sourceImage": .string(cachedImagePath)
        ])

        return volumePath
    }

    // MARK: - Volume Deletion

    /// Deletes a volume and its directory
    func deleteVolume(volumeId: String) async throws {
        let volumeDir = "\(volumeStoragePath)/\(volumeId)"

        logger.info("Deleting volume", metadata: ["volumeId": .string(volumeId)])

        if FileManager.default.fileExists(atPath: volumeDir) {
            try FileManager.default.removeItem(atPath: volumeDir)
            logger.info("Volume deleted", metadata: ["volumeId": .string(volumeId)])
        } else {
            logger.warning("Volume directory not found", metadata: [
                "volumeId": .string(volumeId),
                "path": .string(volumeDir)
            ])
        }
    }

    // MARK: - Volume Resize

    /// Resizes a volume (must be detached from any VM)
    func resizeVolume(volumePath: String, newSize: Int64) async throws {
        logger.info("Resizing volume", metadata: [
            "path": .string(volumePath),
            "newSize": .stringConvertible(newSize)
        ])

        // Run qemu-img resize
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImgPath)
        process.arguments = ["resize", volumePath, "\(newSize)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logger.error("qemu-img resize failed", metadata: [
                "path": .string(volumePath),
                "output": .string(output)
            ])
            throw VolumeServiceError.resizeFailed("qemu-img resize failed: \(output)")
        }

        logger.info("Volume resized successfully", metadata: [
            "path": .string(volumePath),
            "newSize": .stringConvertible(newSize)
        ])
    }

    // MARK: - Snapshots

    /// Creates an external snapshot of a volume using qcow2 backing files
    /// Returns the path to the snapshot
    func createSnapshot(volumeId: String, snapshotId: String, volumePath: String) async throws -> String {
        let snapshotDir = "\(volumeStoragePath)/\(volumeId)/snapshots"
        let snapshotPath = "\(snapshotDir)/\(snapshotId).qcow2"

        logger.info("Creating snapshot", metadata: [
            "volumeId": .string(volumeId),
            "snapshotId": .string(snapshotId),
            "volumePath": .string(volumePath)
        ])

        // Create snapshot directory
        try FileManager.default.createDirectory(
            atPath: snapshotDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Create snapshot as a new qcow2 with the volume as backing file
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImgPath)
        process.arguments = [
            "create",
            "-f", "qcow2",
            "-b", volumePath,
            "-F", "qcow2",
            snapshotPath
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logger.error("qemu-img snapshot create failed", metadata: [
                "volumeId": .string(volumeId),
                "output": .string(output)
            ])
            throw VolumeServiceError.snapshotFailed("qemu-img create snapshot failed: \(output)")
        }

        logger.info("Snapshot created successfully", metadata: [
            "volumeId": .string(volumeId),
            "snapshotId": .string(snapshotId),
            "path": .string(snapshotPath)
        ])

        return snapshotPath
    }

    /// Deletes a snapshot
    func deleteSnapshot(snapshotPath: String) async throws {
        logger.info("Deleting snapshot", metadata: ["path": .string(snapshotPath)])

        if FileManager.default.fileExists(atPath: snapshotPath) {
            try FileManager.default.removeItem(atPath: snapshotPath)
            logger.info("Snapshot deleted", metadata: ["path": .string(snapshotPath)])
        } else {
            logger.warning("Snapshot not found", metadata: ["path": .string(snapshotPath)])
        }
    }

    // MARK: - Volume Clone

    /// Clones a volume to a new location
    /// Returns the path to the cloned volume
    func cloneVolume(sourceVolumeId: String, sourcePath: String, targetVolumeId: String) async throws -> String {
        let targetDir = "\(volumeStoragePath)/\(targetVolumeId)"
        let targetPath = "\(targetDir)/volume.qcow2"

        logger.info("Cloning volume", metadata: [
            "sourceVolumeId": .string(sourceVolumeId),
            "targetVolumeId": .string(targetVolumeId),
            "sourcePath": .string(sourcePath)
        ])

        // Create target directory
        try FileManager.default.createDirectory(
            atPath: targetDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Use qemu-img convert to create a full copy (breaks backing file chain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImgPath)
        process.arguments = [
            "convert",
            "-f", "qcow2",
            "-O", "qcow2",
            sourcePath,
            targetPath
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logger.error("qemu-img clone failed", metadata: [
                "sourceVolumeId": .string(sourceVolumeId),
                "output": .string(output)
            ])
            throw VolumeServiceError.cloneFailed("qemu-img convert failed: \(output)")
        }

        logger.info("Volume cloned successfully", metadata: [
            "sourceVolumeId": .string(sourceVolumeId),
            "targetVolumeId": .string(targetVolumeId),
            "targetPath": .string(targetPath)
        ])

        return targetPath
    }

    // MARK: - Volume Info

    /// Gets information about a volume using qemu-img info
    func getVolumeInfo(volumePath: String) async throws -> VolumeInfoResult {
        logger.debug("Getting volume info", metadata: ["path": .string(volumePath)])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: qemuImgPath)
        process.arguments = ["info", "--output=json", volumePath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw VolumeServiceError.infoFailed("qemu-img info failed")
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let info = try JSONDecoder().decode(QemuImgInfo.self, from: outputData)

        return VolumeInfoResult(
            actualSize: info.actualSize,
            virtualSize: info.virtualSize,
            format: info.format,
            dirty: info.dirty ?? false,
            encrypted: info.encrypted ?? false
        )
    }

    /// Builds the path for a volume given its ID
    func buildVolumePath(volumeId: String, format: String = "qcow2") -> String {
        return "\(volumeStoragePath)/\(volumeId)/volume.\(format)"
    }

    /// Checks if a volume exists
    func volumeExists(volumeId: String) -> Bool {
        let volumeDir = "\(volumeStoragePath)/\(volumeId)"
        return FileManager.default.fileExists(atPath: volumeDir)
    }
}

// MARK: - Supporting Types

/// Result of qemu-img info query
struct VolumeInfoResult: Codable, Sendable {
    let actualSize: Int64
    let virtualSize: Int64
    let format: String
    let dirty: Bool
    let encrypted: Bool
}

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

// MARK: - Errors

enum VolumeServiceError: Error, LocalizedError, Sendable {
    case createFailed(String)
    case deleteFailed(String)
    case resizeFailed(String)
    case snapshotFailed(String)
    case cloneFailed(String)
    case infoFailed(String)
    case volumeNotFound(String)

    var errorDescription: String? {
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
        }
    }
}
