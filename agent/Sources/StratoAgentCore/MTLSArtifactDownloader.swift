import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOFileSystem
import NIOSSL

/// Downloads control-plane artifacts over mTLS, presenting the agent's SPIFFE
/// SVID as the client certificate (issue #493).
///
/// Image and artifact download URLs arrive as control-plane-relative paths and
/// resolve to the Envoy mTLS listener the agent already dials — the same
/// listener that carries the WebSocket. `URLSession` cannot present a NIOSSL
/// client certificate, so these fetches go through AsyncHTTPClient configured
/// with the SVID-backed TLS configuration.
///
/// The TLS configuration is looked up per download rather than captured at
/// construction: SVIDs rotate on the order of an hour, downloads are rare
/// (cold image fetches, agent updates), and a fresh short-lived client per
/// download is the simplest way to never present an expired certificate.
public struct MTLSArtifactDownloader: Sendable {
    /// Supplies the current SVID-backed client TLS configuration. Throws when
    /// no SVID is available yet.
    public typealias TLSConfigurationProvider = @Sendable () async throws -> TLSConfiguration

    /// The budgets one download attempt runs under. Injectable so tests can
    /// drive the failure paths without waiting out production values.
    public struct Timeouts: Sendable {
        /// Ceiling on establishing the connection. Must be set explicitly:
        /// AsyncHTTPClient leaves `timeout.connect` nil by default and the
        /// connection pool then falls back to 30s, so even a refused
        /// connection to a restarting Envoy takes half a minute to surface —
        /// long enough to stall a reconcile lane before our own retry loop
        /// gets a look at it.
        public var connect: TimeAmount
        /// Idle ceiling between body chunks. Without it the only bound on a
        /// connection that stays open but stops delivering bytes is `request`,
        /// which would park a reconcile lane for half a day and starve the
        /// retry loop that exists precisely to recover from this. Long enough
        /// that a control plane pulling a cold object out of S3 is never
        /// mistaken for a stall.
        public var read: TimeAmount
        /// Whole-request ceiling: keeps a wedged transfer from pinning a
        /// reconcile lane forever while still clearing any realistic multi-GB
        /// image pull. A duration, not a deadline — the deadline is computed
        /// per request, or a long-lived agent would eventually hold one that
        /// is already in the past.
        public var request: TimeAmount

        public init(connect: TimeAmount, read: TimeAmount, request: TimeAmount) {
            self.connect = connect
            self.read = read
            self.request = request
        }

        public static let production = Timeouts(
            connect: .seconds(10), read: .minutes(2), request: .hours(12))
    }

    let tlsConfigurationProvider: TLSConfigurationProvider
    let logger: Logger
    let timeouts: Timeouts

    public init(
        tlsConfigurationProvider: @escaping TLSConfigurationProvider,
        logger: Logger,
        timeouts: Timeouts = .production
    ) {
        self.tlsConfigurationProvider = tlsConfigurationProvider
        self.logger = logger
        self.timeouts = timeouts
    }

    /// One download attempt's failure, classified for the retry loops above:
    /// network-level and server-side (5xx/408/429) failures are transient;
    /// anything else won't change within the operation.
    public struct DownloadFailure: Error, CustomStringConvertible {
        public let reason: String
        public let isTransient: Bool
        public var description: String { reason }
    }

    /// Whether `url` and `base` name the same scheme/host/port origin — the
    /// test that decides whether an agent-update artifact is control-plane
    /// hosted (and so must present the SVID) or an external release URL.
    ///
    /// Ports are compared after filling in the scheme default, because
    /// `URL.port` is nil for an implied port. Comparing raw values would read
    /// `https://cp.example` and `https://cp.example:443/artifact` as different
    /// origins, and the artifact would then be fetched with no client
    /// certificate and rejected.
    public static func targetsOrigin(_ url: URL, of base: String) -> Bool {
        guard let baseURL = URL(string: base) else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == baseURL.scheme?.lowercased() else {
            return false
        }
        // Both hosts nil (a `file://` override) is deliberately not a match.
        guard let host = url.host?.lowercased(), host == baseURL.host?.lowercased() else {
            return false
        }
        return effectivePort(of: url, scheme: scheme) == effectivePort(of: baseURL, scheme: scheme)
    }

    private static func effectivePort(of url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    /// `ImageCacheService.Fetcher` adapter: fetch `url` to a temporary file
    /// whose ownership passes to the caller, translating failures into the
    /// cache's transient/permanent vocabulary.
    @Sendable
    public func fetchToTemporaryFile(url: URL) async throws -> URL {
        let temporaryPath = NSTemporaryDirectory() + "strato-artifact-" + UUID().uuidString
        do {
            try await stream(url: url, to: temporaryPath)
        } catch let failure as DownloadFailure {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            if failure.isTransient {
                throw ImageCacheService.TransientDownloadFailure(reason: failure.reason)
            }
            throw ImageCacheError.downloadFailed(failure.reason)
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            throw error
        }
        return URL(fileURLWithPath: temporaryPath)
    }

    /// `AgentUpdater.Downloader` adapter: download `url` into `destination`.
    /// The updater runs its own single attempt with checksum verification, so
    /// transient/permanent classification collapses into its failure reason.
    @Sendable
    public func downloadArtifact(url: URL, to destination: String) async throws {
        do {
            try await stream(url: url, to: destination)
        } catch let failure as DownloadFailure {
            throw AgentUpdateError.downloadFailed(failure.reason)
        }
    }

    /// `SnapshotArtifactTransfer.FileDownloader` adapter: stream `url` to
    /// `destinationPath`. The transfer layer stages, checksum-verifies, and
    /// publishes, so partial bytes on failure are its concern; failures
    /// surface as `DownloadFailure` with the transient flag intact.
    @Sendable
    public func downloadSnapshotArtifact(url: URL, to destinationPath: String) async throws {
        try await stream(url: url, to: destinationPath)
    }

    /// `SnapshotArtifactTransfer.FileUploader` adapter (issue #428): one mTLS
    /// PUT streaming the file at `sourcePath` as the request body in bounded
    /// memory — snapshot memory files are guest-RAM-sized and must never pass
    /// through agent memory whole. Same per-call client construction as
    /// downloads, for the same SVID-rotation reason.
    @Sendable
    public func uploadFile(url: URL, fromFile sourcePath: String) async throws {
        var configuration = HTTPClient.Configuration()
        do {
            configuration.tlsConfiguration = try await tlsConfigurationProvider()
        } catch {
            throw DownloadFailure(
                reason: "no SVID available for mTLS upload: \(error)", isTransient: false)
        }
        configuration.timeout.connect = timeouts.connect
        configuration.timeout.read = timeouts.read
        configuration.connectionPool.retryConnectionEstablishment = false

        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        do {
            try await uploadWithClient(client, url: url, sourcePath: sourcePath)
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    private func uploadWithClient(_ client: HTTPClient, url: URL, sourcePath: String) async throws {
        let size: Int64
        do {
            guard let info = try await FileSystem.shared.info(forFileAt: FilePath(sourcePath)) else {
                throw DownloadFailure(reason: "no file at \(sourcePath)", isTransient: false)
            }
            size = info.size
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure(reason: "could not stat \(sourcePath): \(error)", isTransient: false)
        }

        do {
            try await FileSystem.shared.withFileHandle(forReadingAt: FilePath(sourcePath)) { handle in
                var request = HTTPClientRequest(url: url.absoluteString)
                request.method = .PUT
                request.headers.add(name: "Content-Type", value: "application/octet-stream")
                request.body = .stream(handle.readChunks(), length: .known(size))

                let response: HTTPClientResponse
                do {
                    response = try await client.execute(
                        request, deadline: .now() + timeouts.request, logger: logger)
                } catch {
                    throw DownloadFailure(reason: "upload request failed: \(error)", isTransient: true)
                }
                guard (200..<300).contains(response.status.code) else {
                    let transient =
                        response.status.code >= 500 || response.status.code == 408
                        || response.status.code == 429
                    throw DownloadFailure(
                        reason: "upload rejected: HTTP \(response.status.code)", isTransient: transient)
                }
            }
        } catch let failure as DownloadFailure {
            throw failure
        } catch {
            throw DownloadFailure(reason: "upload stream failed: \(error)", isTransient: true)
        }
    }

    /// The core download: one mTLS GET streamed to `destinationPath` in
    /// bounded memory. The destination holds partial bytes on failure — every
    /// caller stages into a private path and verifies a checksum before
    /// publishing, so cleanup-on-error is their concern, not a correctness one.
    private func stream(url: URL, to destinationPath: String) async throws {
        var configuration = HTTPClient.Configuration()
        do {
            configuration.tlsConfiguration = try await tlsConfigurationProvider()
        } catch {
            // No SVID means no credential to present; retrying the same
            // operation won't mint one mid-flight.
            throw DownloadFailure(
                reason: "no SVID available for mTLS download: \(error)", isTransient: false)
        }
        configuration.timeout.connect = timeouts.connect
        configuration.timeout.read = timeouts.read
        // AsyncHTTPClient retries connection establishment internally by
        // default. Every caller here already sits inside a retry loop that
        // classifies connection errors as transient and backs off
        // (`ImageCacheService.downloadWithRetry`), so leaving it on nests one
        // backoff schedule inside another — a refused connection takes ~30s to
        // surface before our own first retry even begins. One layer owns
        // retrying, and it is the one that can also re-resolve the URL.
        configuration.connectionPool.retryConnectionEstablishment = false

        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        do {
            try await streamWithClient(client, url: url, to: destinationPath)
        } catch {
            try? await client.shutdown()
            throw error
        }
        try await client.shutdown()
    }

    private func streamWithClient(_ client: HTTPClient, url: URL, to destinationPath: String) async throws {
        let request = HTTPClientRequest(url: url.absoluteString)

        let response: HTTPClientResponse
        do {
            response = try await client.execute(
                request, deadline: .now() + timeouts.request, logger: logger)
        } catch {
            // Connection-level failures (refused, reset, TLS handshake against
            // a restarting Envoy) are transient by nature.
            throw DownloadFailure(reason: "request failed: \(error)", isTransient: true)
        }

        guard response.status == .ok else {
            let transient =
                response.status.code >= 500 || response.status.code == 408 || response.status.code == 429
            throw DownloadFailure(reason: "HTTP \(response.status.code)", isTransient: transient)
        }

        // Written through NIOFileSystem rather than FileHandle: a multi-GB body
        // is thousands of write(2) calls, and issuing them synchronously would
        // block a cooperative-pool thread for the whole transfer — with a few
        // cold image pulls in flight that is enough to starve the executor.
        // The buffered writer also takes a ByteBuffer directly, so there is no
        // per-chunk copy into Data.
        do {
            try await FileSystem.shared.withFileHandle(
                forWritingAt: FilePath(destinationPath),
                options: .newFile(replaceExisting: true)
            ) { handle in
                try await handle.withBufferedWriter { writer in
                    for try await buffer in response.body {
                        _ = try await writer.write(contentsOf: buffer)
                    }
                }
            }
        } catch {
            throw DownloadFailure(reason: "body stream failed: \(error)", isTransient: true)
        }
    }
}
