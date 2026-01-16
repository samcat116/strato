import Foundation
import Vapor
import Fluent
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOPosix
import Crypto

/// Actor service for managing background image fetches from URLs
actor ImageFetchService {
    private let app: Application
    private var activeFetches: [UUID: Task<Void, Error>] = [:]
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

        logger.info("Starting image fetch", metadata: [
            "image_id": .string(imageId.uuidString),
            "source_url": .string(sourceURL)
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
                to: filePath,
                imageId: imageId,
                db: db
            )

            // Update image with results
            image.size = size
            image.checksum = checksum
            image.format = format
            image.storagePath = "\(projectId)/\(imageId)/\(image.filename)"
            image.status = .ready
            image.downloadProgress = 100
            image.errorMessage = nil

            try await image.save(on: db)

            logger.info("Image fetch completed", metadata: [
                "image_id": .string(imageId.uuidString),
                "size": .stringConvertible(size),
                "checksum": .string(checksum)
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

    /// Downloads a file from URL to local path with progress updates
    private func downloadFile(
        from url: URL,
        to filePath: String,
        imageId: UUID,
        db: Database
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

                try await updateProgress(imageId: imageId, progress: progress, db: db)
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

                logger.info("Queueing pending image for fetch", metadata: [
                    "image_id": .string(imageId.uuidString)
                ])

                try await startFetch(imageId: imageId)
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
    private struct ImageFetchServiceKey: StorageKey {
        typealias Value = ImageFetchService
    }

    var imageFetchService: ImageFetchService {
        get {
            if let existing = storage[ImageFetchServiceKey.self] {
                return existing
            }
            let service = ImageFetchService(app: self)
            storage[ImageFetchServiceKey.self] = service
            return service
        }
        set {
            storage[ImageFetchServiceKey.self] = newValue
        }
    }
}

// MARK: - Request Extension

extension Request {
    var imageFetchService: ImageFetchService {
        application.imageFetchService
    }
}
