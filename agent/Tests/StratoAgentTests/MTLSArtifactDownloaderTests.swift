import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import StratoAgentCore

/// Coverage for the SVID-mTLS artifact downloader (issue #493): body streaming
/// to disk, the transient/permanent failure classification the retry loops in
/// `ImageCacheService` depend on, and the origin test that routes agent-update
/// artifacts to the mTLS path.
///
/// These run against a real loopback HTTP origin rather than a stub. The
/// classification is a property of what AsyncHTTPClient actually does with a
/// response — a hand-rolled fake would only assert that the test agrees with
/// itself. TLS is not exercised (a plain-HTTP origin ignores the client
/// configuration entirely); what matters here is everything downstream of the
/// handshake.
@Suite("MTLS artifact downloader", .serialized)
struct MTLSArtifactDownloaderTests {

    // MARK: - Fixed-response loopback origin

    /// Answers every request with one canned status and body, then closes.
    private final class FixedResponseHandler: ChannelInboundHandler, Sendable {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let status: HTTPResponseStatus
        private let body: ByteBuffer

        init(status: HTTPResponseStatus, body: ByteBuffer) {
            self.status = status
            self.body = body
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .end = unwrapInboundIn(data) else { return }

            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: String(body.readableBytes))
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)

            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    /// Binds a loopback origin on an ephemeral port, runs `test` against it,
    /// and tears it down. Returns whatever `test` returns.
    private func withOrigin<Result>(
        status: HTTPResponseStatus = .ok,
        body: String = "",
        _ test: (_ port: Int) async throws -> Result
    ) async throws -> Result {
        let payload = ByteBuffer(string: body)
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixedResponseHandler(status: status, body: payload))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        do {
            let port = try #require(channel.localAddress?.port)
            let result = try await test(port)
            try? await channel.close()
            return result
        } catch {
            try? await channel.close()
            throw error
        }
    }

    /// Production budgets except for the connect ceiling, which is cut to keep
    /// the refused-connection test quick — everything it exercises happens
    /// well inside the first attempt.
    private static let testTimeouts = MTLSArtifactDownloader.Timeouts(
        connect: .milliseconds(500), read: .seconds(10), request: .seconds(30))

    private func makeDownloader(
        tlsConfiguration: @escaping MTLSArtifactDownloader.TLSConfigurationProvider = {
            TLSConfiguration.makeClientConfiguration()
        }
    ) -> MTLSArtifactDownloader {
        MTLSArtifactDownloader(
            tlsConfigurationProvider: tlsConfiguration,
            logger: Logger(label: "test"),
            timeouts: Self.testTimeouts
        )
    }

    /// Names of the downloader's temp files currently on disk, so a test can
    /// assert a failed fetch left nothing behind.
    private func artifactTempFiles() -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(contents.filter { $0.hasPrefix("strato-artifact-") })
    }

    // MARK: - Streaming

    @Test("A 200 response streams its body to a temporary file")
    func streamsBodyToTemporaryFile() async throws {
        let payload = "some image bytes, streamed to disk"
        let downloaded = try await withOrigin(body: payload) { port in
            try await makeDownloader().fetchToTemporaryFile(
                url: URL(string: "http://127.0.0.1:\(port)/image")!)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }

        #expect(try String(contentsOf: downloaded, encoding: .utf8) == payload)
    }

    @Test("A body larger than the writer's buffer round-trips intact")
    func streamsLargeBody() async throws {
        // Comfortably past the 512 KiB buffered-writer capacity, so the write
        // path actually flushes mid-stream rather than landing in one chunk.
        let payload = String(repeating: "strato", count: 200_000)
        let downloaded = try await withOrigin(body: payload) { port in
            try await makeDownloader().fetchToTemporaryFile(
                url: URL(string: "http://127.0.0.1:\(port)/image")!)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }

        let written = try String(contentsOf: downloaded, encoding: .utf8)
        #expect(written.count == payload.count)
        #expect(written == payload)
    }

    @Test("The update-artifact adapter writes to the destination it is given")
    func downloadArtifactWritesToDestination() async throws {
        let payload = "agent tarball bytes"
        let destination = NSTemporaryDirectory() + "strato-update-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: destination) }

        try await withOrigin(body: payload) { port in
            try await makeDownloader().downloadArtifact(
                url: URL(string: "http://127.0.0.1:\(port)/strato-agent.tar.gz")!,
                to: destination)
        }

        #expect(try String(contentsOfFile: destination, encoding: .utf8) == payload)
    }

    // MARK: - Failure classification

    @Test(
        "Server-side and throttling statuses are transient",
        arguments: [HTTPResponseStatus.internalServerError, .serviceUnavailable, .requestTimeout, .tooManyRequests]
    )
    func serverFailuresAreTransient(status: HTTPResponseStatus) async throws {
        let before = artifactTempFiles()

        await #expect(throws: ImageCacheService.TransientDownloadFailure.self) {
            try await withOrigin(status: status) { port in
                try await makeDownloader().fetchToTemporaryFile(
                    url: URL(string: "http://127.0.0.1:\(port)/image")!)
            }
        }

        #expect(artifactTempFiles().subtracting(before).isEmpty, "a failed fetch must not leak its temp file")
    }

    @Test(
        "Client-error statuses are permanent",
        arguments: [HTTPResponseStatus.notFound, .forbidden, .unauthorized]
    )
    func clientFailuresArePermanent(status: HTTPResponseStatus) async throws {
        let before = artifactTempFiles()

        await #expect(throws: ImageCacheError.self) {
            try await withOrigin(status: status) { port in
                try await makeDownloader().fetchToTemporaryFile(
                    url: URL(string: "http://127.0.0.1:\(port)/image")!)
            }
        }

        #expect(artifactTempFiles().subtracting(before).isEmpty, "a failed fetch must not leak its temp file")
    }

    @Test("A refused connection is transient")
    func refusedConnectionIsTransient() async throws {
        // Bind and immediately close, so the port is almost certainly free but
        // was recently valid — the closest reproducible stand-in for an Envoy
        // that is restarting.
        let deadPort = try await withOrigin { port in port }

        await #expect(throws: ImageCacheService.TransientDownloadFailure.self) {
            try await makeDownloader().fetchToTemporaryFile(
                url: URL(string: "http://127.0.0.1:\(deadPort)/image")!)
        }
    }

    @Test("No available SVID is permanent, not transient")
    func missingSVIDIsPermanent() async throws {
        struct NoSVID: Error {}

        // A retry cannot mint a credential mid-operation, so this must end the
        // retry loop rather than spin it.
        await #expect(throws: ImageCacheError.self) {
            try await makeDownloader(tlsConfiguration: { throw NoSVID() })
                .fetchToTemporaryFile(url: URL(string: "https://cp.example/image")!)
        }
    }

    // MARK: - Origin matching (routes agent-update artifacts to mTLS)

    @Test("An implied default port matches an explicit one")
    func targetsOriginAcrossImpliedPorts() {
        // The bug this guards: URL.port is nil for an implied port, so a raw
        // comparison reads these as different origins and the artifact would
        // be fetched with no client certificate.
        #expect(
            MTLSArtifactDownloader.targetsOrigin(
                URL(string: "https://cp.example:443/a.tar.gz")!, of: "https://cp.example"))
        #expect(
            MTLSArtifactDownloader.targetsOrigin(
                URL(string: "https://cp.example/a.tar.gz")!, of: "https://cp.example:443"))
        #expect(
            MTLSArtifactDownloader.targetsOrigin(URL(string: "http://cp.example:80/a.tar.gz")!, of: "http://cp.example")
        )
    }

    @Test("An explicit non-default port must match exactly")
    func targetsOriginWithExplicitPort() {
        #expect(
            MTLSArtifactDownloader.targetsOrigin(
                URL(string: "https://cp.example:8443/a.tar.gz")!, of: "https://cp.example:8443"))
        #expect(
            !MTLSArtifactDownloader.targetsOrigin(
                URL(string: "https://cp.example:8443/a.tar.gz")!, of: "https://cp.example"))
        #expect(
            !MTLSArtifactDownloader.targetsOrigin(
                URL(string: "https://cp.example/a.tar.gz")!, of: "https://cp.example:8443"))
    }

    @Test("A different scheme, host, or no host at all is not the same origin")
    func targetsOriginRejectsOtherOrigins() {
        let base = "https://cp.example:8443"
        // GitHub releases — the common case — must keep the stock downloader.
        #expect(
            !MTLSArtifactDownloader.targetsOrigin(
                URL(string: "https://github.com/o/r/releases/download/v1/a.tar.gz")!, of: base))
        #expect(!MTLSArtifactDownloader.targetsOrigin(URL(string: "http://cp.example:8443/a.tar.gz")!, of: base))
        // A file:// override on an air-gapped host has no origin to match.
        #expect(!MTLSArtifactDownloader.targetsOrigin(URL(string: "file:///opt/strato/a.tar.gz")!, of: base))
        #expect(
            !MTLSArtifactDownloader.targetsOrigin(URL(string: "https://cp.example:8443/a.tar.gz")!, of: "not a url"))
    }
}
