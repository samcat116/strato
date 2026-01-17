import Foundation
import Logging
import StratoShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
import CommonCrypto
#endif

/// Service for managing local image cache on the agent
actor ImageCacheService {
    private let logger: Logger
    private let cachePath: String
    private let controlPlaneURL: String

    /// Default cache path for images (platform-specific)
    static var defaultCachePath: String {
        #if os(macOS)
        // On macOS, use user's cache directory (writable without root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Caches/strato/images"
        #else
        // On Linux, use system cache directory
        return "/var/cache/strato/images"
        #endif
    }

    init(logger: Logger, cachePath: String? = nil, controlPlaneURL: String) {
        self.logger = logger
        self.cachePath = cachePath ?? Self.defaultCachePath
        self.controlPlaneURL = controlPlaneURL

        // Ensure cache directory exists
        do {
            try FileManager.default.createDirectory(
                atPath: self.cachePath,
                withIntermediateDirectories: true,
                attributes: nil
            )
            logger.info("Image cache service initialized", metadata: ["cachePath": .string(self.cachePath)])
        } catch {
            logger.error("Failed to create cache directory: \(error)", metadata: ["cachePath": .string(self.cachePath)])
        }
    }

    // MARK: - Cache Operations

    /// Gets the local path for a cached image, downloading if necessary
    /// Returns the path to the image file ready for use by QEMU
    func getImagePath(imageInfo: ImageInfo) async throws -> String {
        let cachedPath = buildCachePath(imageInfo: imageInfo)

        // Check if image is already cached and valid
        if try await isCached(imageInfo: imageInfo) {
            logger.info("Image found in cache", metadata: [
                "imageId": .string(imageInfo.imageId.uuidString),
                "path": .string(cachedPath)
            ])
            return cachedPath
        }

        // Download the image
        logger.info("Image not in cache, downloading", metadata: [
            "imageId": .string(imageInfo.imageId.uuidString),
            "url": .string(imageInfo.downloadURL)
        ])

        try await downloadImage(imageInfo: imageInfo, to: cachedPath)

        return cachedPath
    }

    /// Checks if an image is cached and has valid checksum
    func isCached(imageInfo: ImageInfo) async throws -> Bool {
        let cachedPath = buildCachePath(imageInfo: imageInfo)

        // Check if file exists
        guard FileManager.default.fileExists(atPath: cachedPath) else {
            return false
        }

        // Verify checksum
        let actualChecksum = try computeChecksum(filePath: cachedPath)
        let isValid = actualChecksum.lowercased() == imageInfo.checksum.lowercased()

        if !isValid {
            logger.warning("Cached image checksum mismatch, will re-download", metadata: [
                "imageId": .string(imageInfo.imageId.uuidString),
                "expected": .string(imageInfo.checksum),
                "actual": .string(actualChecksum)
            ])
            // Delete the invalid cached file
            try? FileManager.default.removeItem(atPath: cachedPath)
        }

        return isValid
    }

    /// Builds the local cache path for an image
    /// Structure: {cachePath}/{projectId}/{imageId}/{filename}
    func buildCachePath(imageInfo: ImageInfo) -> String {
        return "\(cachePath)/\(imageInfo.projectId)/\(imageInfo.imageId)/\(imageInfo.filename)"
    }

    /// Downloads an image from the control plane
    private func downloadImage(imageInfo: ImageInfo, to localPath: String) async throws {
        // Create directory structure
        let directoryPath = (localPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directoryPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Build the download URL
        guard let url = URL(string: imageInfo.downloadURL) else {
            throw ImageCacheError.invalidURL(imageInfo.downloadURL)
        }

        logger.info("Downloading image", metadata: [
            "imageId": .string(imageInfo.imageId.uuidString),
            "url": .string(imageInfo.downloadURL),
            "size": .stringConvertible(imageInfo.size)
        ])

        // Perform the download
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ImageCacheError.downloadFailed("HTTP \(statusCode)")
        }

        // Move downloaded file to cache location
        // First remove existing file if any
        if FileManager.default.fileExists(atPath: localPath) {
            try FileManager.default.removeItem(atPath: localPath)
        }

        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: localPath))

        // Verify checksum
        let actualChecksum = try computeChecksum(filePath: localPath)
        guard actualChecksum.lowercased() == imageInfo.checksum.lowercased() else {
            // Delete the corrupted file
            try? FileManager.default.removeItem(atPath: localPath)
            throw ImageCacheError.checksumMismatch(expected: imageInfo.checksum, actual: actualChecksum)
        }

        logger.info("Image downloaded and verified", metadata: [
            "imageId": .string(imageInfo.imageId.uuidString),
            "path": .string(localPath),
            "checksum": .string(actualChecksum)
        ])
    }

    /// Computes SHA256 checksum of a file
    private func computeChecksum(filePath: String) throws -> String {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            throw ImageCacheError.fileNotFound(filePath)
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256Hasher()
        let bufferSize = 1024 * 1024 // 1MB chunks

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        return hasher.finalize()
    }

    /// Deletes a cached image
    func deleteImage(imageId: UUID, projectId: UUID) throws {
        let directoryPath = "\(cachePath)/\(projectId)/\(imageId)"

        if FileManager.default.fileExists(atPath: directoryPath) {
            try FileManager.default.removeItem(atPath: directoryPath)
            logger.info("Cached image deleted", metadata: ["imageId": .string(imageId.uuidString)])
        }
    }

    /// Cleans up old cached images (can be called periodically)
    func cleanupCache(maxAgeSeconds: TimeInterval = 7 * 24 * 60 * 60) throws {
        let fileManager = FileManager.default
        let cutoffDate = Date().addingTimeInterval(-maxAgeSeconds)

        guard let enumerator = fileManager.enumerator(atPath: cachePath) else {
            return
        }

        var deletedCount = 0

        while let file = enumerator.nextObject() as? String {
            let fullPath = "\(cachePath)/\(file)"

            guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                  let modificationDate = attributes[.modificationDate] as? Date,
                  modificationDate < cutoffDate else {
                continue
            }

            // Only delete files, not directories
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) && !isDirectory.boolValue {
                try? fileManager.removeItem(atPath: fullPath)
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            logger.info("Cache cleanup completed", metadata: ["deletedFiles": .stringConvertible(deletedCount)])
        }
    }

    /// Gets the total size of the cache in bytes
    func getCacheSize() throws -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0

        guard let enumerator = fileManager.enumerator(atPath: cachePath) else {
            return 0
        }

        while let file = enumerator.nextObject() as? String {
            let fullPath = "\(cachePath)/\(file)"
            if let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
               let size = attributes[.size] as? Int64 {
                totalSize += size
            }
        }

        return totalSize
    }
}

// MARK: - SHA256 Hasher (Platform-agnostic)

/// A simple SHA256 hasher that works on both macOS and Linux
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
private struct SHA256Hasher {
    private var context: CC_SHA256_CTX

    init() {
        context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
    }

    mutating func update(data: Data) {
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256_Update(&context, bytes.baseAddress, CC_LONG(data.count))
        }
    }

    mutating func finalize() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
#else
private struct SHA256Hasher {
    // Fallback implementation for Linux using command-line sha256sum
    private var data = Data()

    init() {}

    mutating func update(data: Data) {
        self.data.append(data)
    }

    mutating func finalize() -> String {
        // Use command-line sha256sum for Linux
        let tempFile = "/tmp/strato-sha256-\(UUID().uuidString)"
        try? data.write(to: URL(fileURLWithPath: tempFile))
        defer { try? FileManager.default.removeItem(atPath: tempFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.arguments = [tempFile]

        let pipe = Pipe()
        process.standardOutput = pipe

        try? process.run()
        process.waitUntilExit()

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: outputData, encoding: .utf8) {
            return String(output.prefix(64))
        }
        return ""
    }
}
#endif

// MARK: - Errors

enum ImageCacheError: Error, LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case fileNotFound(String)
    case storageFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid download URL: \(url)"
        case .downloadFailed(let reason):
            return "Image download failed: \(reason)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch. Expected: \(expected), Actual: \(actual)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .storageFailed(let reason):
            return "Storage operation failed: \(reason)"
        }
    }
}
