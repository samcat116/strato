import Crypto
import Foundation
import Logging
import StratoAgentCore
import StratoShared
#if canImport(FoundationNetworking)
import FoundationNetworking
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
            logger.info(
                "Image found in cache",
                metadata: [
                    "imageId": .string(imageInfo.imageId.uuidString),
                    "path": .string(cachedPath),
                ])
            return cachedPath
        }

        // Download the image
        logger.info(
            "Image not in cache, downloading",
            metadata: [
                "imageId": .string(imageInfo.imageId.uuidString),
                "url": .string(imageInfo.downloadURL),
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
            logger.warning(
                "Cached image checksum mismatch, will re-download",
                metadata: [
                    "imageId": .string(imageInfo.imageId.uuidString),
                    "expected": .string(imageInfo.checksum),
                    "actual": .string(actualChecksum),
                ])
            // Delete the invalid cached file
            try? FileManager.default.removeItem(atPath: cachedPath)
        }

        return isValid
    }

    /// Builds the local cache path for an image's primary disk
    /// Structure: {cachePath}/{projectId}/{imageId}/{filename}
    func buildCachePath(imageInfo: ImageInfo) -> String {
        return "\(cachePath)/\(imageInfo.projectId)/\(imageInfo.imageId)/\(imageInfo.filename)"
    }

    /// Builds the local cache path for a specific typed artifact. Artifacts are
    /// namespaced by kind so a kernel and a rootfs with colliding filenames
    /// never overwrite each other.
    /// Structure: {cachePath}/{projectId}/{imageId}/{kind}/{filename}
    func buildArtifactCachePath(imageInfo: ImageInfo, artifact: ArtifactInfo) -> String {
        return "\(cachePath)/\(imageInfo.projectId)/\(imageInfo.imageId)/\(artifact.kind.rawValue)/\(artifact.filename)"
    }

    // MARK: - Artifact Operations

    /// Returns the local path to a specific typed artifact, downloading and
    /// verifying it if it isn't cached. Falls back to the primary-disk path when
    /// the requested kind is `.diskImage` and the image carries no typed artifact
    /// set (legacy single-file images).
    func getArtifactPath(imageInfo: ImageInfo, kind: ArtifactKind) async throws -> String {
        guard let artifact = imageInfo.artifact(ofKind: kind) else {
            if kind == .diskImage {
                return try await getImagePath(imageInfo: imageInfo)
            }
            throw ImageCacheError.artifactNotFound(kind.rawValue)
        }

        let cachedPath = buildArtifactCachePath(imageInfo: imageInfo, artifact: artifact)

        if try await isArtifactCached(cachedPath: cachedPath, checksum: artifact.checksum) {
            logger.info(
                "Artifact found in cache",
                metadata: [
                    "imageId": .string(imageInfo.imageId.uuidString),
                    "kind": .string(kind.rawValue),
                    "path": .string(cachedPath),
                ])
            return cachedPath
        }

        logger.info(
            "Artifact not in cache, downloading",
            metadata: [
                "imageId": .string(imageInfo.imageId.uuidString),
                "kind": .string(kind.rawValue),
                "url": .string(artifact.downloadURL),
            ])

        try await downloadArtifact(
            from: artifact.downloadURL,
            checksum: artifact.checksum,
            sizeBytes: artifact.size,
            imageId: imageInfo.imageId,
            kind: kind,
            to: cachedPath
        )
        return cachedPath
    }

    /// Checks whether a cached artifact file exists with a matching checksum,
    /// deleting it if the checksum no longer matches.
    private func isArtifactCached(cachedPath: String, checksum: String) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: cachedPath) else {
            return false
        }
        let actualChecksum = try computeChecksum(filePath: cachedPath)
        let isValid = actualChecksum.lowercased() == checksum.lowercased()
        if !isValid {
            try? FileManager.default.removeItem(atPath: cachedPath)
        }
        return isValid
    }

    /// Downloads a single artifact to `localPath` and verifies its checksum.
    private func downloadArtifact(
        from downloadURL: String,
        checksum: String,
        sizeBytes: Int64,
        imageId: UUID,
        kind: ArtifactKind,
        to localPath: String
    ) async throws {
        try await fetchVerifiedFile(
            from: downloadURL, checksum: checksum, sizeBytes: sizeBytes, to: localPath)

        logger.info(
            "Artifact downloaded and verified",
            metadata: [
                "imageId": .string(imageId.uuidString),
                "kind": .string(kind.rawValue),
                "path": .string(localPath),
            ])
    }

    /// Downloads an image from the control plane
    private func downloadImage(imageInfo: ImageInfo, to localPath: String) async throws {
        logger.info(
            "Downloading image",
            metadata: [
                "imageId": .string(imageInfo.imageId.uuidString),
                "url": .string(imageInfo.downloadURL),
                "size": .stringConvertible(imageInfo.size),
            ])

        try await fetchVerifiedFile(
            from: imageInfo.downloadURL, checksum: imageInfo.checksum, sizeBytes: imageInfo.size, to: localPath)

        logger.info(
            "Image downloaded and verified",
            metadata: [
                "imageId": .string(imageInfo.imageId.uuidString),
                "path": .string(localPath),
            ])
    }

    // MARK: - Download plumbing

    /// Attempts per download before giving up. Transient network failures
    /// (timeouts, connection resets, 5xx) abort an entire VM create if a
    /// single attempt is all they get.
    private static let maxDownloadAttempts = 3

    /// The full download path: free-space precheck, download with retries,
    /// checksum verification on a staging file, then atomic publish. The
    /// final path only ever holds verified, complete bytes.
    private func fetchVerifiedFile(
        from downloadURL: String, checksum: String, sizeBytes: Int64, to localPath: String
    ) async throws {
        let directoryPath = (localPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directoryPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Fail fast with a clear message rather than dying mid-download with
        // an opaque I/O error. The advertised size is known up front.
        if sizeBytes > 0, let free = HostPreflight.freeDiskSpace(atPath: directoryPath), free < sizeBytes {
            throw ImageCacheError.insufficientDiskSpace(
                "need \(sizeBytes) bytes for the download but only \(free) bytes are free on the filesystem "
                    + "backing \(directoryPath). Free up space or point the image cache at a larger filesystem.")
        }

        guard let url = URL(string: downloadURL) else {
            throw ImageCacheError.invalidURL(downloadURL)
        }

        let tempURL = try await downloadWithRetry(from: url)

        // Stage next to the destination: the system temp directory may be a
        // different filesystem, in which case moveItem degrades to a copy —
        // doing that into a `.partial` sibling keeps the final rename atomic
        // and means an interrupted copy never masquerades as a cached image.
        let stagingPath = localPath + ".partial"
        try? FileManager.default.removeItem(atPath: stagingPath)
        do {
            try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: stagingPath))

            // Verify before publishing, so the cache path never holds
            // corrupted bytes even transiently.
            let actualChecksum = try computeChecksum(filePath: stagingPath)
            guard actualChecksum.lowercased() == checksum.lowercased() else {
                throw ImageCacheError.checksumMismatch(expected: checksum, actual: actualChecksum)
            }

            if FileManager.default.fileExists(atPath: localPath) {
                try FileManager.default.removeItem(atPath: localPath)
            }
            try FileManager.default.moveItem(atPath: stagingPath, toPath: localPath)
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Downloads `url` to a temporary file, retrying transient failures with
    /// backoff. Returns the temporary file URL of a completed HTTP 200 body.
    private func downloadWithRetry(from url: URL) async throws -> URL {
        var lastError: any Error = ImageCacheError.downloadFailed("no download attempt made")

        for attempt in 1...Self.maxDownloadAttempts {
            if attempt > 1 {
                let backoffSeconds = Double(1 << (attempt - 1))  // 2s, 4s
                logger.warning(
                    "Retrying download after transient failure",
                    metadata: [
                        "url": .string(url.absoluteString),
                        "attempt": .stringConvertible(attempt),
                        "error": .string(String(describing: lastError)),
                    ])
                try? await Task.sleep(for: .seconds(backoffSeconds))
            }

            do {
                let (tempURL, response) = try await URLSession.shared.download(from: url)
                guard let httpResponse = response as? HTTPURLResponse else {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw ImageCacheError.downloadFailed("non-HTTP response")
                }
                guard httpResponse.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: tempURL)
                    let error = ImageCacheError.downloadFailed("HTTP \(httpResponse.statusCode)")
                    // Server-side and throttling failures are worth retrying;
                    // other statuses (403 expired signature, 404) are not
                    // going to change within this operation.
                    if Self.isRetryableStatus(httpResponse.statusCode) {
                        lastError = error
                        continue
                    }
                    throw error
                }
                return tempURL
            } catch let error as URLError {
                lastError = ImageCacheError.downloadFailed(error.localizedDescription)
                continue  // network-level errors are transient by nature
            }
        }

        throw lastError
    }

    private static func isRetryableStatus(_ status: Int) -> Bool {
        status >= 500 || status == 408 || status == 429
    }

    /// Computes SHA256 checksum of a file
    private func computeChecksum(filePath: String) throws -> String {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
            throw ImageCacheError.fileNotFound(filePath)
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024  // 1MB chunks

        while true {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

}

// MARK: - ImageSource Conformance

/// The storage layer pulls image bytes through this hook when materializing disks.
extension ImageCacheService: ImageSource {
    func localImagePath(for imageInfo: ImageInfo) async throws -> String {
        try await getImagePath(imageInfo: imageInfo)
    }

    func localImagePath(for imageInfo: ImageInfo, kind: ArtifactKind) async throws -> String {
        try await getArtifactPath(imageInfo: imageInfo, kind: kind)
    }
}

// MARK: - Errors

enum ImageCacheError: Error, LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case fileNotFound(String)
    case artifactNotFound(String)
    case storageFailed(String)
    case insufficientDiskSpace(String)

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
        case .artifactNotFound(let kind):
            return "Image has no \(kind) artifact"
        case .storageFailed(let reason):
            return "Storage operation failed: \(reason)"
        case .insufficientDiskSpace(let reason):
            return "Insufficient disk space: \(reason)"
        }
    }
}

extension ImageCacheError: ClassifiableError {
    var failureClassification: FailureClassification {
        switch self {
        case .invalidURL, .artifactNotFound, .insufficientDiskSpace:
            // Nothing on this host will change these; retrying the same
            // operation only delays the report.
            return .permanent
        case .downloadFailed, .checksumMismatch, .fileNotFound, .storageFailed:
            return .transient
        }
    }
}
