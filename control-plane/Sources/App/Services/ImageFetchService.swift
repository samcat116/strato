import Foundation
import Vapor
import Fluent
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOPosix
import Crypto

/// Protocol for image fetch services (enables testing with mocks)
protocol ImageFetchServiceProtocol: Sendable {
    func startFetch(imageId: UUID) async throws
    func cancelFetch(imageId: UUID) async
    func isFetchActive(imageId: UUID) async -> Bool
    /// Fetches a single typed artifact from its `sourceURL` in the background.
    func startArtifactFetch(artifactId: UUID) async throws
}

/// Actor service for managing background image fetches from URLs
actor ImageFetchService: ImageFetchServiceProtocol {
    private let app: Application
    private var activeFetches: [UUID: Task<Void, Error>] = [:]
    private var activeArtifactFetches: [UUID: Task<Void, Error>] = [:]
    private let httpClient: HTTPClient

    /// Progress update interval in bytes (update every 1MB)
    private let progressUpdateInterval: Int64 = 1024 * 1024

    init(app: Application) {
        self.app = app
        self.httpClient = HTTPClient(eventLoopGroupProvider: .shared(app.eventLoopGroup))
    }

    deinit {
        try? httpClient.syncShutdown()
    }

    /// Starts fetching an image from its source URL
    func startFetch(imageId: UUID) async throws {
        // Cancel any existing fetch for this image
        if let existingTask = activeFetches[imageId] {
            existingTask.cancel()
            activeFetches.removeValue(forKey: imageId)
        }

        // Start new fetch task
        let task = Task {
            try await performFetch(imageId: imageId)
        }

        activeFetches[imageId] = task
    }

    /// Cancels an active fetch
    func cancelFetch(imageId: UUID) {
        if let task = activeFetches[imageId] {
            task.cancel()
            activeFetches.removeValue(forKey: imageId)
        }
    }

    /// Checks if a fetch is active
    func isFetchActive(imageId: UUID) -> Bool {
        return activeFetches[imageId] != nil
    }

    /// Performs the actual fetch operation
    private func performFetch(imageId: UUID) async throws {
        let db = app.db
        let logger = app.logger

        // Get the image record
        guard let image = try await Image.find(imageId, on: db) else {
            throw ImageError.imageNotFound(imageId)
        }

        guard let sourceURL = image.sourceURL, let url = URL(string: sourceURL) else {
            try await updateImageError(imageId: imageId, error: "Invalid source URL", db: db)
            throw ImageError.downloadFailed("Invalid source URL")
        }

        logger.info(
            "Starting image fetch",
            metadata: [
                "image_id": .string(imageId.uuidString),
                "source_url": .string(sourceURL),
            ])

        // Update status to downloading
        image.status = .downloading
        image.downloadProgress = 0
        try await image.save(on: db)

        let storagePath = ImageStorageService.storagePath(from: app)
        let projectId = image.$project.id

        do {
            // Create directory structure
            try ImageStorageService.createDirectoryStructure(
                storagePath: storagePath,
                projectId: projectId,
                imageId: imageId
            )

            let filePath = ImageStorageService.buildFilePath(
                storagePath: storagePath,
                projectId: projectId,
                imageId: imageId,
                filename: image.filename
            )

            // Perform the download
            let (size, checksum, format) = try await downloadFile(
                from: url,
                to: filePath
            ) { [weak self] progress in
                try await self?.updateProgress(imageId: imageId, progress: progress, db: db)
            }

            let relativePath = "\(projectId)/\(imageId)/\(image.filename)"

            // Verify against the caller's expected digest before publishing. The
            // download already hashed every byte in-stream, so this costs nothing
            // beyond the comparison. A mismatch means the bytes aren't what was
            // asked for: bin them rather than leave an unreferenced file behind,
            // and fail the image instead of serving it to an agent.
            if let expected = image.expectedChecksum, expected != checksum {
                image.status = .validating
                try await image.save(on: db)

                try? ImageStorageService.deleteFileAt(
                    storagePath: storagePath, relativePath: relativePath)

                app.logger.warning(
                    "Image checksum mismatch",
                    metadata: [
                        "image_id": .string(imageId.uuidString),
                        "expected": .string(expected),
                        "actual": .string(checksum),
                    ])
                throw ImageError.downloadFailed(
                    "Checksum verification failed: expected \(expected), got \(checksum)")
            }

            // Update image with results
            image.size = size
            image.checksum = checksum
            image.format = format
            image.storagePath = relativePath
            image.status = .ready
            image.downloadProgress = 100
            image.errorMessage = nil

            try await image.save(on: db)

            // Register the fetched file as the image's disk-image artifact so the
            // typed artifact set matches uploaded images. Replace any prior
            // disk-image artifact from an earlier fetch attempt.
            try await image.$artifacts.query(on: db)
                .filter(\.$kind == .diskImage)
                .delete()
            let diskArtifact = ImageArtifact(
                imageID: imageId,
                kind: .diskImage,
                format: format,
                architecture: image.architecture,
                filename: image.filename,
                size: size,
                checksum: checksum,
                storagePath: relativePath
            )
            try await diskArtifact.save(on: db)

            logger.info(
                "Image fetch completed",
                metadata: [
                    "image_id": .string(imageId.uuidString),
                    "size": .stringConvertible(size),
                    "checksum": .string(checksum),
                ])

        } catch is CancellationError {
            logger.info("Image fetch cancelled", metadata: ["image_id": .string(imageId.uuidString)])
            try await updateImageError(imageId: imageId, error: "Download cancelled", db: db)
            throw CancellationError()

        } catch {
            logger.error("Image fetch failed: \(error)", metadata: ["image_id": .string(imageId.uuidString)])
            try await updateImageError(imageId: imageId, error: error.localizedDescription, db: db)
            throw error
        }

        // Remove from active fetches
        activeFetches.removeValue(forKey: imageId)
    }

    // MARK: - Artifact Fetch

    /// Starts fetching a single artifact from its source URL.
    func startArtifactFetch(artifactId: UUID) async throws {
        if let existing = activeArtifactFetches[artifactId] {
            existing.cancel()
            activeArtifactFetches.removeValue(forKey: artifactId)
        }
        activeArtifactFetches[artifactId] = Task {
            try await performArtifactFetch(artifactId: artifactId)
        }
    }

    /// Downloads one artifact's bytes, filling in size/checksum/format and
    /// flipping it to `.ready`, then recomputes the parent image's status.
    private func performArtifactFetch(artifactId: UUID) async throws {
        let db = app.db
        let logger = app.logger

        guard let artifact = try await ImageArtifact.find(artifactId, on: db) else {
            return  // artifact deleted before the fetch started
        }
        let imageId = artifact.$image.id

        guard let sourceURL = artifact.sourceURL, let url = URL(string: sourceURL) else {
            try await updateArtifactError(artifactId: artifactId, error: "Invalid source URL", db: db)
            try await recomputeImageStatus(imageId: imageId, db: db)
            throw ImageError.downloadFailed("Invalid artifact source URL")
        }

        logger.info(
            "Starting artifact fetch",
            metadata: [
                "artifact_id": .string(artifactId.uuidString),
                "kind": .string(artifact.kind.rawValue),
                "source_url": .string(sourceURL),
            ])

        artifact.status = .downloading
        artifact.downloadProgress = 0
        try await artifact.save(on: db)

        let storagePath = ImageStorageService.storagePath(from: app)
        let fullPath = ImageStorageService.getFilePath(
            storagePath: storagePath, relativePath: artifact.storagePath)

        do {
            // The artifact's relative path is {project}/{image}/{kind}/{filename};
            // make sure its directory exists before writing.
            try FileManager.default.createDirectory(
                atPath: (fullPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)

            let (size, checksum, format) = try await downloadFile(from: url, to: fullPath) {
                [weak self] progress in
                try await self?.updateArtifactProgress(artifactId: artifactId, progress: progress, db: db)
            }

            artifact.size = size
            artifact.checksum = checksum
            // Kernel/initramfs are opaque; only disk-like artifacts carry a format.
            if artifact.kind == .diskImage || artifact.kind == .rootfs {
                artifact.format = format
            }
            artifact.status = .ready
            artifact.downloadProgress = 100
            artifact.errorMessage = nil
            try await artifact.save(on: db)

            // Keep the image's legacy single-file columns pointed at the disk-image.
            if artifact.kind == .diskImage, let image = try await Image.find(imageId, on: db) {
                image.filename = artifact.filename
                image.size = size
                image.format = format
                image.checksum = checksum
                image.storagePath = artifact.storagePath
                try await image.save(on: db)
            }

            try await recomputeImageStatus(imageId: imageId, db: db)

            logger.info(
                "Artifact fetch completed",
                metadata: [
                    "artifact_id": .string(artifactId.uuidString),
                    "size": .stringConvertible(size),
                ])
        } catch is CancellationError {
            try await updateArtifactError(artifactId: artifactId, error: "Download cancelled", db: db)
            throw CancellationError()
        } catch {
            logger.error(
                "Artifact fetch failed: \(error)",
                metadata: ["artifact_id": .string(artifactId.uuidString)])
            try await updateArtifactError(
                artifactId: artifactId, error: error.localizedDescription, db: db)
            throw error
        }

        activeArtifactFetches.removeValue(forKey: artifactId)
    }

    /// Recomputes the parent image's status from its (freshly loaded) artifact
    /// set: `.ready` when some hypervisor can boot it, otherwise `.pending`.
    /// Leaves error/in-progress image states alone.
    private func recomputeImageStatus(imageId: UUID, db: Database) async throws {
        guard let image = try await Image.find(imageId, on: db) else { return }
        try await image.$artifacts.load(on: db)
        guard image.status == .ready || image.status == .pending else { return }
        let newStatus: ImageStatus = image.compatibleHypervisors().isEmpty ? .pending : .ready
        if image.status != newStatus {
            image.status = newStatus
            try await image.save(on: db)
        }
    }

    private func updateArtifactProgress(artifactId: UUID, progress: Int, db: Database) async throws {
        guard let artifact = try await ImageArtifact.find(artifactId, on: db) else { return }
        artifact.downloadProgress = progress
        try await artifact.save(on: db)
    }

    private func updateArtifactError(artifactId: UUID, error: String, db: Database) async throws {
        guard let artifact = try await ImageArtifact.find(artifactId, on: db) else { return }
        artifact.status = .error
        artifact.errorMessage = error
        try await artifact.save(on: db)
    }

    /// Downloads a file from URL to local path, invoking `onProgress` with a
    /// 0–99 percentage as bytes arrive.
    private func downloadFile(
        from url: URL,
        to filePath: String,
        onProgress: @escaping (Int) async throws -> Void
    ) async throws -> (size: Int64, checksum: String, format: ImageFormat) {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET

        // Add common headers
        request.headers.add(name: "User-Agent", value: "Strato/1.0")
        request.headers.add(name: "Accept", value: "*/*")

        let response = try await httpClient.execute(request, timeout: .minutes(30))

        guard response.status == .ok else {
            throw ImageError.downloadFailed("HTTP \(response.status.code): \(response.status.reasonPhrase)")
        }

        // Get expected content length if available
        let expectedLength = response.headers.first(name: "content-length").flatMap(Int64.init)

        // Create output file
        FileManager.default.createFile(atPath: filePath, contents: nil)
        guard let fileHandle = FileHandle(forWritingAtPath: filePath) else {
            throw ImageError.storageFailed("Failed to create output file")
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256Hasher()
        var totalBytesWritten: Int64 = 0
        var lastProgressUpdate: Int64 = 0
        var formatDetected: ImageFormat?

        // Stream the response body to file
        for try await buffer in response.body {
            try Task.checkCancellation()

            var mutableBuffer = buffer
            guard let bytes = mutableBuffer.readBytes(length: buffer.readableBytes) else {
                continue
            }

            // Detect format from first chunk
            if formatDetected == nil && !bytes.isEmpty {
                formatDetected = ImageValidationService.detectFormat(from: buffer)
            }

            // Write to file
            let data = Data(bytes)
            try fileHandle.write(contentsOf: data)

            // Update hasher
            hasher.update(data: data)

            totalBytesWritten += Int64(bytes.count)

            // Update progress periodically
            if totalBytesWritten - lastProgressUpdate >= progressUpdateInterval {
                lastProgressUpdate = totalBytesWritten

                let progress: Int
                if let expected = expectedLength, expected > 0 {
                    progress = min(99, Int((Double(totalBytesWritten) / Double(expected)) * 100))
                } else {
                    // Unknown size, show bytes downloaded
                    progress = min(99, Int(Double(totalBytesWritten) / Double(1024 * 1024 * 1024) * 100))
                }

                try await onProgress(progress)
            }
        }

        let checksum = hasher.finalize()
        let format = formatDetected ?? .raw

        return (totalBytesWritten, checksum, format)
    }

    /// Updates the download progress in the database
    private func updateProgress(imageId: UUID, progress: Int, db: Database) async throws {
        guard let image = try await Image.find(imageId, on: db) else {
            return
        }
        image.downloadProgress = progress
        try await image.save(on: db)
    }

    /// Updates the image with an error status
    private func updateImageError(imageId: UUID, error: String, db: Database) async throws {
        guard let image = try await Image.find(imageId, on: db) else {
            return
        }
        image.status = .error
        image.errorMessage = error
        try await image.save(on: db)
    }

    /// Processes all pending images that need fetching
    func processPendingFetches() async {
        let db = app.db
        let logger = app.logger

        do {
            // Find all images with pending status and a source URL
            let pendingImages = try await Image.query(on: db)
                .filter(\.$status == .pending)
                .filter(\.$sourceURL != nil)
                .all()

            for image in pendingImages {
                guard let imageId = image.id else { continue }

                // Skip if already being fetched
                if isFetchActive(imageId: imageId) {
                    continue
                }

                logger.info(
                    "Queueing pending image for fetch",
                    metadata: [
                        "image_id": .string(imageId.uuidString)
                    ])

                try await startFetch(imageId: imageId)
            }

            // Resume interrupted per-artifact URL fetches (e.g. after a restart).
            // Both pending and downloading are re-enqueued; a downloading row was
            // cut off mid-stream and simply restarts.
            let pendingArtifacts = try await ImageArtifact.query(on: db)
                .filter(\.$sourceURL != nil)
                .group(.or) { group in
                    group.filter(\.$status == .pending).filter(\.$status == .downloading)
                }
                .all()

            for artifact in pendingArtifacts {
                guard let artifactId = artifact.id else { continue }
                if activeArtifactFetches[artifactId] != nil { continue }
                logger.info(
                    "Resuming pending artifact fetch",
                    metadata: ["artifact_id": .string(artifactId.uuidString)])
                try await startArtifactFetch(artifactId: artifactId)
            }
        } catch {
            logger.error("Failed to process pending fetches: \(error)")
        }
    }
}

// MARK: - SHA256 Hasher Helper

/// A simple wrapper for streaming SHA256 computation using swift-crypto
private struct SHA256Hasher {
    private var hasher: Crypto.SHA256

    init() {
        hasher = Crypto.SHA256()
    }

    mutating func update(data: Data) {
        hasher.update(data: data)
    }

    mutating func finalize() -> String {
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Application Extension

extension Application {
    private struct ImageFetchServiceKey: StorageKey, LockKey {
        typealias Value = ImageFetchServiceProtocol
    }

    var imageFetchService: ImageFetchServiceProtocol {
        get {
            lazyService(ImageFetchServiceKey.self) { ImageFetchService(app: self) }
        }
        set {
            storage[ImageFetchServiceKey.self] = newValue
        }
    }
}

// MARK: - Request Extension

extension Request {
    var imageFetchService: ImageFetchServiceProtocol {
        application.imageFetchService
    }
}
