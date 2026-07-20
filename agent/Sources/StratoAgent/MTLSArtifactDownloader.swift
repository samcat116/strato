import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOSSL
import StratoAgentCore

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
struct MTLSArtifactDownloader: Sendable {
    /// Supplies the current SVID-backed client TLS configuration. Throws when
    /// no SVID is available yet.
    typealias TLSConfigurationProvider = @Sendable () async throws -> TLSConfiguration

    /// Downloads run unmetered otherwise; a whole-request ceiling keeps a
    /// wedged connection from pinning a reconcile lane forever while still
    /// clearing any realistic multi-GB image pull. A duration, not a deadline:
    /// the deadline is computed per request, or a long-lived agent would
    /// eventually hold one that is already in the past.
    private static let requestTimeout: TimeAmount = .hours(12)

    let tlsConfigurationProvider: TLSConfigurationProvider
    let logger: Logger

    /// One download attempt's failure, classified for the retry loops above:
    /// network-level and server-side (5xx/408/429) failures are transient;
    /// anything else won't change within the operation.
    struct DownloadFailure: Error, CustomStringConvertible {
        let reason: String
        let isTransient: Bool
        var description: String { reason }
    }

    /// `ImageCacheService.Fetcher` adapter: fetch `url` to a temporary file
    /// whose ownership passes to the caller, translating failures into the
    /// cache's transient/permanent vocabulary.
    @Sendable
    func fetchToTemporaryFile(url: URL) async throws -> URL {
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
    func downloadArtifact(url: URL, to destination: String) async throws {
        do {
            try await stream(url: url, to: destination)
        } catch let failure as DownloadFailure {
            throw AgentUpdateError.downloadFailed(failure.reason)
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
                request, deadline: .now() + Self.requestTimeout, logger: logger)
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

        guard FileManager.default.createFile(atPath: destinationPath, contents: nil),
            let handle = FileHandle(forWritingAtPath: destinationPath)
        else {
            throw DownloadFailure(
                reason: "could not open \(destinationPath) for writing", isTransient: false)
        }

        do {
            for try await buffer in response.body {
                try handle.write(contentsOf: Data(buffer.readableBytesView))
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw DownloadFailure(reason: "body stream failed: \(error)", isTransient: true)
        }
    }
}
