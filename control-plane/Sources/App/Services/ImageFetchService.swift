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
    /// Fetches a single typed artifact from its `sourceURL` in the background.
    func startArtifactFetch(artifactId: UUID) async throws
}

/// Actor service for managing background image fetches from URLs
actor ImageFetchService: ImageFetchServiceProtocol {
    private let app: Application
    private var activeArtifactFetches: [UUID: Task<Void, Error>] = [:]

    /// Progress update interval in bytes (update every 1MB)
    private let progressUpdateInterval: Int64 = 1024 * 1024

    init(app: Application) {
        self.app = app
    }

    /// Starts fetching a single artifact from its source URL.
    func startArtifactFetch(artifactId: UUID) async throws {
        // Do not register a replacement until the task it supersedes has
        // finished its cancellation path. Besides preventing concurrent
        // writers for the same object, the loop handles concurrent callers:
        // after awaiting, another caller may have installed a newer task that
        // this invocation must also cancel before it can become authoritative.
        while let existing = activeArtifactFetches[artifactId] {
            existing.cancel()
            _ = await existing.result
        }
        activeArtifactFetches[artifactId] = Task {
            try await performArtifactFetch(artifactId: artifactId)
        }
    }

    /// Downloads one artifact's bytes, filling in size/checksum/format and
    /// flipping it to `.ready`, then recomputes the parent image's status.
    private func performArtifactFetch(artifactId: UUID) async throws {
        defer { activeArtifactFetches.removeValue(forKey: artifactId) }
        try Task.checkCancellation()
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
        try await recomputeImageStatus(imageId: imageId, db: db)

        let store = app.imageObjectStore

        do {
            let (size, checksum, format) = try await downloadFile(
                from: url, to: artifact.storagePath, in: store
            ) {
                [weak self] progress in
                try await self?.updateArtifactProgress(artifactId: artifactId, progress: progress, db: db)
            }

            if let expected = artifact.expectedChecksum, expected != checksum {
                try? await store.delete(key: artifact.storagePath)
                logger.warning(
                    "Artifact checksum mismatch",
                    metadata: [
                        "artifact_id": .string(artifactId.uuidString),
                        "expected": .string(expected),
                        "actual": .string(checksum),
                    ])
                throw ImageError.downloadFailed(
                    "Checksum verification failed: expected \(expected), got \(checksum)")
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

            try await recomputeImageStatus(imageId: imageId, db: db)

            logger.info(
                "Artifact fetch completed",
                metadata: [
                    "artifact_id": .string(artifactId.uuidString),
                    "size": .stringConvertible(size),
                ])
        } catch is CancellationError {
            try await updateArtifactError(artifactId: artifactId, error: "Download cancelled", db: db)
            try await recomputeImageStatus(imageId: imageId, db: db)
            throw CancellationError()
        } catch {
            logger.error(
                "Artifact fetch failed: \(error)",
                metadata: ["artifact_id": .string(artifactId.uuidString)])
            try await updateArtifactError(
                artifactId: artifactId, error: error.localizedDescription, db: db)
            try await recomputeImageStatus(imageId: imageId, db: db)
            throw error
        }
    }

    /// Recomputes the parent image's status from its (freshly loaded) artifact
    /// set, including download and error lifecycle when no bootable set exists.
    private func recomputeImageStatus(imageId: UUID, db: Database) async throws {
        guard let image = try await Image.find(imageId, on: db) else { return }
        try await image.recomputeStatus(on: db)
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

    /// How many redirects a fetch may follow. Matches AsyncHTTPClient's default
    /// `RedirectConfiguration()` limit; we resolve them by hand (see
    /// `downloadFile`) so every hop can be SSRF-checked before it's connected.
    private static let maxRedirects = 5

    /// Hard ceiling on a server-side URL/artifact download. The multipart
    /// upload path is already bounded by `ImageController.maxUploadBytes`; the
    /// URL-fetch path had no equivalent, so a `sourceURL` serving an arbitrarily
    /// large or endless stream could fill the control plane's image-storage
    /// volume. Kept in sync with `ImageController.maxUploadBytes` (4 GiB).
    private static let maxDownloadBytes: Int64 = 4 * 1024 * 1024 * 1024

    private typealias DownloadResult = (size: Int64, checksum: String, format: ImageFormat)

    /// What one hop of the redirect chain resolved to.
    private enum HopOutcome {
        case redirect(URL)
        case completed(DownloadResult)
    }

    /// Downloads a file from `url` into `key`, invoking `onProgress` with a
    /// 0–99 percentage as bytes arrive. Every request it makes — the initial one
    /// and every redirect hop — goes through the guarded client.
    private func downloadFile(
        from url: URL,
        to key: String,
        in store: any ImageObjectStore,
        onProgress: @escaping (Int) async throws -> Void
    ) async throws -> DownloadResult {
        let guarded = app.guardedHTTPClient

        var headers = HTTPHeaders()
        headers.add(name: "User-Agent", value: "Strato/1.0")
        headers.add(name: "Accept", value: "*/*")

        // Redirects are followed BY HAND rather than by AsyncHTTPClient so the
        // guard sees every hop's host: an attacker-controlled `sourceURL` may
        // pass validation and then 3xx to `169.254.169.254` or an internal
        // service, which auto-follow would fetch unchecked. Every distro in the
        // catalog that isn't a direct CDN link (Fedora, openSUSE, Rocky) is
        // reached through a mirror redirector, so following them (up to the same
        // limit as the default config) still matters — `ImageFetchRedirectTests`
        // pins that behaviour.
        //
        // Each hop is its own guarded request, so each is validated *and* pinned
        // to the address that validation approved: `dnsOverride` is fixed at
        // client construction, so a hop cannot ride on the previous hop's pin.
        var currentURL = url
        for _ in 0...Self.maxRedirects {
            let outcome = try await guarded.withStreamedResponse(
                url: currentURL, method: .GET, headers: headers, timeout: .minutes(30)
            ) { response -> HopOutcome in
                // 3xx with a Location: resolve against the current URL and loop,
                // so the next hop is validated and pinned before it is connected.
                //
                // The redirect's own body is deliberately left unread. The
                // streaming contract is consume-or-cancel, and this is the
                // cancel: returning without iterating drops the body sequence,
                // and the guarded client then shuts this hop's client down —
                // which closes the connection rather than leaving a half-read
                // response holding it. Reading a redirect body would mean
                // buffering an attacker-chosen payload for nothing.
                if (300...399).contains(response.status.code),
                    let location = response.headers.first(name: "location"),
                    let next = URL(string: location, relativeTo: currentURL)?.absoluteURL
                {
                    return .redirect(next)
                }
                guard response.status == .ok else {
                    throw ImageError.downloadFailed(
                        "HTTP \(response.status.code): \(response.status.reasonPhrase)")
                }
                return .completed(
                    try await self.streamBody(
                        of: response, to: key, in: store, onProgress: onProgress))
            }

            switch outcome {
            case .redirect(let next):
                currentURL = next
            case .completed(let result):
                return result
            }
        }

        throw ImageError.downloadFailed("Exceeded redirect limit of \(Self.maxRedirects)")
    }

    /// Streams a 200 response's body into `key`, hashing and size-capping it as
    /// it goes. Runs while the guarded connection is still open.
    private func streamBody(
        of response: HTTPClientResponse,
        to key: String,
        in store: any ImageObjectStore,
        onProgress: @escaping (Int) async throws -> Void
    ) async throws -> DownloadResult {
        // Get expected content length if available
        let expectedLength = response.headers.first(name: "content-length").flatMap(Int64.init)

        // Reject an over-large download up front when the server declares its
        // size, before writing a single byte.
        if let expectedLength, expectedLength > Self.maxDownloadBytes {
            throw ImageError.downloadFailed(
                "Download exceeds the maximum allowed size of \(Self.maxDownloadBytes) bytes")
        }

        let writer = try await store.openWriter(key: key)

        var hasher = SHA256Hasher()
        var totalBytesWritten: Int64 = 0
        var lastProgressUpdate: Int64 = 0
        var formatDetected: ImageFormat?

        do {
            // Stream the response body into the store
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

                try await writer.write(buffer)

                // Update hasher
                hasher.update(data: Data(bytes))

                totalBytesWritten += Int64(bytes.count)

                // Enforce the ceiling for servers that under-declare or omit
                // `content-length` (chunked/endless streams).
                if totalBytesWritten > Self.maxDownloadBytes {
                    throw ImageError.downloadFailed(
                        "Download exceeds the maximum allowed size of \(Self.maxDownloadBytes) bytes")
                }

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

            try await writer.finish()
        } catch {
            // A partial object must never become visible at the real key: an
            // agent fetching it would fail checksum verification at best.
            await writer.abort()
            throw error
        }

        let checksum = hasher.finalize()
        let format = formatDetected ?? .raw

        return (totalBytesWritten, checksum, format)
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
            setService(ImageFetchServiceKey.self, to: newValue)
        }
    }
}

// MARK: - Request Extension

extension Request {
    var imageFetchService: ImageFetchServiceProtocol {
        application.imageFetchService
    }
}
