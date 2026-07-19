import Crypto
import Foundation
import Logging
import StratoShared
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Service for managing local image cache on the agent
public actor ImageCacheService {
    private let logger: Logger
    private let cachePath: String
    private let controlPlaneURL: String
    /// Byte budget for the whole cache; nil means unbounded (the historical
    /// behavior). Enforced by LRU eviction of whole image directories before
    /// each download.
    private let maxCacheSizeBytes: Int64?
    /// Collapses concurrent requests for the same cache entry into one download.
    ///
    /// The check-then-download path suspends on the network, and actors are reentrant across
    /// suspension points, so without this two creates placed on this agent against the same
    /// cold image would both miss the cache and both download to the same destination. Keyed
    /// by the destination path, which is unique per image (and per typed artifact).
    private let downloads = SingleFlight<String>()
    /// Fetches one URL to a local temporary file, whose ownership passes to the caller.
    /// Injectable so tests can exercise the cache and its concurrency without a network.
    private let fetch: Fetcher

    /// Fetches `url` to a temporary file and returns its location. Throws
    /// `TransientDownloadFailure` for failures worth retrying (network errors, 5xx, 408, 429)
    /// and any other error for failures that won't change within the operation.
    public typealias Fetcher = @Sendable (URL) async throws -> URL

    /// A download failure that another attempt might get past.
    public struct TransientDownloadFailure: Error {
        public let reason: String
        public init(reason: String) {
            self.reason = reason
        }
    }

    /// Default cache path for images (platform-specific)
    public static var defaultCachePath: String {
        #if os(macOS)
        // On macOS, use user's cache directory (writable without root)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Caches/strato/images"
        #else
        // On Linux, use system cache directory
        return "/var/cache/strato/images"
        #endif
    }

    public init(
        logger: Logger,
        cachePath: String? = nil,
        controlPlaneURL: String,
        maxCacheSizeBytes: Int64? = nil,
        fetch: @escaping Fetcher = ImageCacheService.defaultFetch
    ) {
        self.logger = logger
        self.cachePath = cachePath ?? Self.defaultCachePath
        self.controlPlaneURL = controlPlaneURL
        self.maxCacheSizeBytes = maxCacheSizeBytes
        self.fetch = fetch

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
    public func getImagePath(imageInfo: ImageInfo) async throws -> String {
        let cachedPath = buildCachePath(imageInfo: imageInfo)
        return try await downloads.run(key: cachedPath) {
            try await self.resolveImagePath(imageInfo: imageInfo, cachedPath: cachedPath)
        }
    }

    private func resolveImagePath(imageInfo: ImageInfo, cachedPath: String) async throws -> String {
        // Check if image is already cached and valid
        if try await isCached(imageInfo: imageInfo) {
            DiskCacheLRU.touch(entryDirectory: imageDirectory(imageInfo: imageInfo))
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

        makeRoom(forIncomingBytes: imageInfo.size, into: imageDirectory(imageInfo: imageInfo))
        try await downloadImage(imageInfo: imageInfo, to: cachedPath)

        return cachedPath
    }

    /// Checks if an image is cached and has valid checksum
    public func isCached(imageInfo: ImageInfo) async throws -> Bool {
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
    public func buildCachePath(imageInfo: ImageInfo) -> String {
        return "\(cachePath)/\(imageInfo.projectId)/\(imageInfo.imageId)/\(imageInfo.filename)"
    }

    /// The eviction unit: everything cached for one image lives under
    /// {cachePath}/{projectId}/{imageId}, and its mtime is the image's
    /// last-use marker.
    private func imageDirectory(imageInfo: ImageInfo) -> String {
        return "\(cachePath)/\(imageInfo.projectId)/\(imageInfo.imageId)"
    }

    /// All cached image directories (the second level of the
    /// {projectId}/{imageId} layout).
    private func cacheEntryDirectories() -> [String] {
        let fileManager = FileManager.default
        var entries: [String] = []
        for project in (try? fileManager.contentsOfDirectory(atPath: cachePath)) ?? [] {
            let projectPath = cachePath + "/" + project
            for image in (try? fileManager.contentsOfDirectory(atPath: projectPath)) ?? [] {
                entries.append(projectPath + "/" + image)
            }
        }
        return entries
    }

    /// Evicts least-recently-used images until the cache (plus the download
    /// about to land in `entryDirectory`) fits the configured budget. No-op
    /// when no budget is configured. The target image's own directory is
    /// touched first so partial multi-artifact entries are never evicted out
    /// from under the download that is adding to them.
    private func makeRoom(forIncomingBytes incomingBytes: Int64, into entryDirectory: String) {
        guard let maxCacheSizeBytes else { return }
        if FileManager.default.fileExists(atPath: entryDirectory) {
            DiskCacheLRU.touch(entryDirectory: entryDirectory)
        }
        DiskCacheLRU.sweep(
            entryDirectories: cacheEntryDirectories(),
            budgetBytes: maxCacheSizeBytes,
            incomingBytes: max(0, incomingBytes),
            logger: logger
        )
        pruneEmptyProjectDirectories()
    }

    /// Removes project-level directories left empty by eviction so the cache
    /// root doesn't accumulate husks.
    private func pruneEmptyProjectDirectories() {
        let fileManager = FileManager.default
        for project in (try? fileManager.contentsOfDirectory(atPath: cachePath)) ?? [] {
            let projectPath = cachePath + "/" + project
            if let contents = try? fileManager.contentsOfDirectory(atPath: projectPath), contents.isEmpty {
                try? fileManager.removeItem(atPath: projectPath)
            }
        }
    }

    /// Builds the local cache path for a specific typed artifact. Artifacts are
    /// namespaced by kind so a kernel and a rootfs with colliding filenames
    /// never overwrite each other.
    /// Structure: {cachePath}/{projectId}/{imageId}/{kind}/{filename}
    public func buildArtifactCachePath(imageInfo: ImageInfo, artifact: ArtifactInfo) -> String {
        return "\(cachePath)/\(imageInfo.projectId)/\(imageInfo.imageId)/\(artifact.kind.rawValue)/\(artifact.filename)"
    }

    // MARK: - Artifact Operations

    /// Returns the local path to a specific typed artifact, downloading and
    /// verifying it if it isn't cached. Falls back to the primary-disk path when
    /// the requested kind is `.diskImage` and the image carries no typed artifact
    /// set (legacy single-file images).
    public func getArtifactPath(imageInfo: ImageInfo, kind: ArtifactKind) async throws -> String {
        guard let artifact = imageInfo.artifact(ofKind: kind) else {
            if kind == .diskImage {
                return try await getImagePath(imageInfo: imageInfo)
            }
            throw ImageCacheError.artifactNotFound(kind.rawValue)
        }

        let cachedPath = buildArtifactCachePath(imageInfo: imageInfo, artifact: artifact)
        return try await downloads.run(key: cachedPath) {
            try await self.resolveArtifactPath(
                imageInfo: imageInfo, artifact: artifact, kind: kind, cachedPath: cachedPath)
        }
    }

    private func resolveArtifactPath(
        imageInfo: ImageInfo, artifact: ArtifactInfo, kind: ArtifactKind, cachedPath: String
    ) async throws -> String {
        if try await isArtifactCached(cachedPath: cachedPath, checksum: artifact.checksum) {
            DiskCacheLRU.touch(entryDirectory: imageDirectory(imageInfo: imageInfo))
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

        makeRoom(forIncomingBytes: artifact.size, into: imageDirectory(imageInfo: imageInfo))
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
        // The staging name is unique per download so a concurrent writer of the
        // same image (another agent process, or a stale `.partial` left by a
        // crash) can't have its bytes clobbered mid-copy.
        let stagingPath = localPath + ".partial." + UUID().uuidString
        do {
            try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: stagingPath))

            // Verify before publishing, so the cache path never holds
            // corrupted bytes even transiently.
            let actualChecksum = try computeChecksum(filePath: stagingPath)
            guard actualChecksum.lowercased() == checksum.lowercased() else {
                throw ImageCacheError.checksumMismatch(expected: checksum, actual: actualChecksum)
            }

            try publish(stagingPath: stagingPath, to: localPath)
        } catch {
            try? FileManager.default.removeItem(atPath: stagingPath)
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// Publishes verified staged bytes at their final cache path.
    ///
    /// Uses POSIX rename(2) rather than FileManager: rename(2) atomically replaces an existing
    /// destination on the same filesystem whether or not it is already there, so a destination
    /// that appeared concurrently (another writer publishing the same image) is a no-op rather
    /// than an error. FileManager's moveItem throws when the destination exists, which made the
    /// old check-then-move a race that failed healthy creates.
    private func publish(stagingPath: String, to localPath: String) throws {
        guard rename(stagingPath, localPath) == 0 else {
            let code = errno
            throw ImageCacheError.storageFailed(
                "publishing \(stagingPath) to \(localPath) failed: \(String(cString: strerror(code)))")
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
                return try await fetch(url)
            } catch let error as TransientDownloadFailure {
                lastError = ImageCacheError.downloadFailed(error.reason)
                continue
            }
        }

        throw lastError
    }

    /// The production fetcher: one URLSession download, with server-side and throttling
    /// failures reported as transient. Other statuses (403 expired signature, 404) are not
    /// going to change within this operation, so they surface as-is and end the retry loop.
    public static let defaultFetch: Fetcher = { url in
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await URLSession.shared.download(from: url)
        } catch let error as URLError {
            // Network-level errors are transient by nature.
            throw TransientDownloadFailure(reason: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImageCacheError.downloadFailed("non-HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            if isRetryableStatus(httpResponse.statusCode) {
                throw TransientDownloadFailure(reason: "HTTP \(httpResponse.statusCode)")
            }
            throw ImageCacheError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }
        return tempURL
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
    public func localImagePath(for imageInfo: ImageInfo) async throws -> String {
        try await getImagePath(imageInfo: imageInfo)
    }

    public func localImagePath(for imageInfo: ImageInfo, kind: ArtifactKind) async throws -> String {
        try await getArtifactPath(imageInfo: imageInfo, kind: kind)
    }
}

// MARK: - Errors

public enum ImageCacheError: Error, LocalizedError {
    case invalidURL(String)
    case downloadFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case fileNotFound(String)
    case artifactNotFound(String)
    case storageFailed(String)
    case insufficientDiskSpace(String)

    public var errorDescription: String? {
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
    public var failureClassification: FailureClassification {
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
