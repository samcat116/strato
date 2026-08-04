import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("Agent Update Artifact Resolution")
struct AgentUpdateArtifactsTests {

    // MARK: - Release tags

    @Test("bare semver versions gain the v prefix tags carry")
    func bareVersionGainsPrefix() {
        #expect(AgentUpdateArtifacts.releaseTag(for: "1.2.3") == "v1.2.3")
    }

    @Test("already-tagged versions pass through")
    func taggedVersionPassesThrough() {
        #expect(AgentUpdateArtifacts.releaseTag(for: "v1.2.3") == "v1.2.3")
    }

    @Test("non-semver values pass through untouched")
    func nonSemverPassesThrough() {
        #expect(AgentUpdateArtifacts.releaseTag(for: "main") == "main")
    }

    // MARK: - Asset URLs

    @Test("asset URL follows the install.sh naming convention per OS/arch")
    func assetURLConvention() {
        let url = AgentUpdateArtifacts.assetURL(
            targetVersion: "1.2.3",
            operatingSystem: .linux,
            architecture: .x86_64,
            baseURL: "https://github.com/samcat116/strato/releases/download"
        )
        #expect(
            url == "https://github.com/samcat116/strato/releases/download/v1.2.3/strato-linux-x86_64.tar.gz")

        let arm = AgentUpdateArtifacts.assetURL(
            targetVersion: "v2.0.0",
            operatingSystem: .macos,
            architecture: .arm64,
            baseURL: "https://mirror.internal/strato/"
        )
        // Trailing slash on the base collapses; the tag is not re-prefixed.
        #expect(arm == "https://mirror.internal/strato/v2.0.0/strato-macos-arm64.tar.gz")
    }

    @Test("main-branch targets have no release assets and resolve to nil")
    func mainBuildsResolveToNil() {
        // Both the baked form ("main") and the published-tag form
        // ("main-<sha>") collapse to main and must refuse URL resolution.
        let baked = AgentUpdateArtifacts.assetURL(
            targetVersion: "main", operatingSystem: .linux, architecture: .x86_64)
        #expect(baked == nil)
        let tagged = AgentUpdateArtifacts.assetURL(
            targetVersion: "main-abc123def", operatingSystem: .linux, architecture: .x86_64)
        #expect(tagged == nil)
    }

    // MARK: - Manifest resolution (issue #431)

    @Test("manifest URL lives beside the release assets")
    func manifestURLConvention() {
        let url = AgentUpdateArtifacts.manifestURL(
            targetVersion: "1.2.3",
            baseURL: "https://github.com/samcat116/strato/releases/download"
        )
        #expect(
            url == "https://github.com/samcat116/strato/releases/download/v1.2.3/agent-manifest.json")
        #expect(AgentUpdateArtifacts.manifestURL(targetVersion: "main") == nil)
    }

    @Test("selectAsset picks the host platform's entry and its member path")
    func selectAssetMatchesPlatform() throws {
        let digest = String(repeating: "cd", count: 32)
        let manifest = AgentReleaseManifest(
            schemaVersion: 1,
            version: "v1.2.3",
            assets: [
                AgentReleaseManifest.Asset(
                    os: "linux", arch: "x86_64", asset: "strato-linux-x86_64.tar.gz",
                    url: "https://example.com/v1.2.3/strato-linux-x86_64.tar.gz",
                    sha256: String(repeating: "ab", count: 32), size: 1, agentBinaryPath: nil),
                AgentReleaseManifest.Asset(
                    os: "linux", arch: "arm64", asset: "strato-linux-arm64.tar.gz",
                    url: "https://example.com/v1.2.3/strato-linux-arm64.tar.gz",
                    sha256: digest.uppercased(), size: 2, agentBinaryPath: "bin/strato-agent"),
            ]
        )

        let arm = AgentUpdateArtifacts.selectAsset(
            from: manifest, operatingSystem: .linux, architecture: .arm64)
        let resolved = try #require(arm)
        #expect(resolved.url == "https://example.com/v1.2.3/strato-linux-arm64.tar.gz")
        // Manifest digests normalize to lowercase like sidecar ones.
        #expect(resolved.sha256 == digest)
        #expect(resolved.tarballMember == "bin/strato-agent")

        // No agentBinaryPath falls back to the conventional member name.
        let amd = AgentUpdateArtifacts.selectAsset(
            from: manifest, operatingSystem: .linux, architecture: .x86_64)
        #expect(amd?.tarballMember == "strato-agent")

        // A platform the release doesn't publish resolves to nothing.
        let missing = AgentUpdateArtifacts.selectAsset(
            from: manifest, operatingSystem: .macos, architecture: .arm64)
        #expect(missing == nil)
    }

    @Test("selectAsset refuses an entry whose digest is not a sha256")
    func selectAssetRejectsBadDigest() {
        let manifest = AgentReleaseManifest(
            schemaVersion: 1,
            version: "v1.2.3",
            assets: [
                AgentReleaseManifest.Asset(
                    os: "linux", arch: "x86_64", asset: "strato-linux-x86_64.tar.gz",
                    url: "https://example.com/a.tar.gz",
                    sha256: "not-a-digest", size: 1, agentBinaryPath: nil)
            ]
        )
        let resolved = AgentUpdateArtifacts.selectAsset(
            from: manifest, operatingSystem: .linux, architecture: .x86_64)
        #expect(resolved == nil)
    }

    @Test("the published manifest JSON shape decodes")
    func manifestDecodes() throws {
        let json = """
            {
              "schemaVersion": 1,
              "version": "v1.2.3",
              "gitSHA": "abc123",
              "assets": [
                {
                  "os": "linux",
                  "arch": "arm64",
                  "asset": "strato-linux-arm64.tar.gz",
                  "url": "https://github.com/samcat116/strato/releases/download/v1.2.3/strato-linux-arm64.tar.gz",
                  "sha256": "\(String(repeating: "ab", count: 32))",
                  "size": 123456789,
                  "agentBinaryPath": "strato-agent"
                }
              ]
            }
            """
        let manifest = try JSONDecoder().decode(AgentReleaseManifest.self, from: Data(json.utf8))
        #expect(manifest.version == "v1.2.3")
        #expect(manifest.assets.count == 1)
        #expect(manifest.assets[0].agentBinaryPath == "strato-agent")
    }

    // MARK: - Checksum sidecar parsing

    @Test("parses the sha256sum sidecar format")
    func parsesSidecarFormat() {
        let digest = String(repeating: "ab", count: 32)
        #expect(AgentUpdateArtifacts.parseChecksum("\(digest)  strato-linux-x86_64.tar.gz\n") == digest)
        // A bare digest with no filename is fine too.
        #expect(AgentUpdateArtifacts.parseChecksum("  \(digest)\n") == digest)
        // Uppercase digests normalize to lowercase for comparison.
        #expect(AgentUpdateArtifacts.parseChecksum(digest.uppercased()) == digest)
    }

    @Test("rejects bodies that don't lead with a sha256 digest")
    func rejectsNonDigests() {
        #expect(AgentUpdateArtifacts.parseChecksum("") == nil)
        #expect(AgentUpdateArtifacts.parseChecksum("<html>Not Found</html>") == nil)
        // Too short (a sha1), and non-hex characters.
        #expect(AgentUpdateArtifacts.parseChecksum(String(repeating: "ab", count: 20)) == nil)
        #expect(AgentUpdateArtifacts.parseChecksum(String(repeating: "zz", count: 32)) == nil)
    }

    // MARK: - The resolver seam

    /// A resolver that quietly fell back to fetching from the real release host
    /// turned a stub that never took into a live 404 from github.com, which the
    /// sweep swallowed as "artifact unresolvable, retry next sweep" — the
    /// `AgentAutoUpdateTests.staleTargetIsReset` CI flake. Unconfigured now
    /// means refused, so no test can reach the network by accident and a
    /// missing stub says what it is.
    @Test("an app with no installed resolver refuses rather than fetching from the release host")
    func unsetResolverRefuses() async throws {
        let app = try await Application.make(.testing)
        do {
            await #expect(throws: (any Error).self) {
                try await app.agentArtifactResolver.resolve(
                    version: "1.4.0", operatingSystem: .linux, architecture: .x86_64)
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // MARK: - Redirect following

    /// The shared HTTP client has redirect-following disabled so tenant-
    /// influenced fetches can't be steered at internal addresses by a 3xx.
    /// Release metadata lives behind a redirect by nature — GitHub answers every
    /// release download with a 302 to its asset CDN — so these fetches follow
    /// redirects explicitly. Without that, the manifest read sees a 302, silently
    /// degrades to the pre-manifest convention path, and the sidecar fetch then
    /// fails: agent updates stop resolving. These pin the follow.
    private func withEventLoop(_ body: (any EventLoop) async throws -> Void) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            try await body(group.next())
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        try await group.shutdownGracefully()
    }

    private func manifestJSON(assetURL: String, digest: String) -> String {
        """
        {"schemaVersion":1,"version":"v1.2.3","assets":[
          {"os":"linux","arch":"x86_64","asset":"strato-linux-x86_64.tar.gz",
           "url":"\(assetURL)","sha256":"\(digest)","size":1}
        ]}
        """
    }

    @Test("a redirected manifest is followed rather than degrading to the fallback path")
    func followsManifestRedirect() async throws {
        let digest = String(repeating: "ab", count: 32)
        let manifestURL = try #require(AgentUpdateArtifacts.manifestURL(targetVersion: "1.2.3"))
        let cdnURL = "https://objects.example-cdn.com/agent-manifest.json"

        try await withEventLoop { eventLoop in
            let client = RecordingClient(
                eventLoop: eventLoop,
                responses: [
                    manifestURL: .redirect(to: cdnURL),
                    cdnURL: .ok(
                        body: manifestJSON(
                            assetURL: "https://example.com/strato-linux-x86_64.tar.gz",
                            digest: digest)),
                ])

            let resolved = try await AgentUpdateArtifacts.resolveArtifact(
                targetVersion: "1.2.3",
                operatingSystem: .linux,
                architecture: .x86_64,
                client: client,
                logger: Logger(label: "test"))

            #expect(resolved.url == "https://example.com/strato-linux-x86_64.tar.gz")
            #expect(resolved.sha256 == digest)
            // The CDN hop was actually taken, not just the original URL.
            #expect(client.requestedURLs.contains(cdnURL))
        }
    }

    /// The pre-manifest fallback path fetches a `.sha256` sidecar from the same
    /// redirecting host, so it needs the same treatment.
    @Test("a redirected checksum sidecar is followed")
    func followsChecksumRedirect() async throws {
        let digest = String(repeating: "cd", count: 32)
        let assetURL = "https://github.example/v1.2.3/strato-linux-x86_64.tar.gz"
        let cdnURL = "https://objects.example-cdn.com/sidecar"

        try await withEventLoop { eventLoop in
            let client = RecordingClient(
                eventLoop: eventLoop,
                responses: [
                    assetURL + ".sha256": .redirect(to: cdnURL),
                    cdnURL: .ok(body: "\(digest)  strato-linux-x86_64.tar.gz\n"),
                ])

            let resolved = try await AgentUpdateArtifacts.fetchChecksum(
                forAssetAt: assetURL, client: client, logger: Logger(label: "test"))
            #expect(resolved == digest)
        }
    }

    /// A redirect loop must terminate rather than spin. Exercised against
    /// `getFollowingRedirects` directly: routed through `fetchChecksum` a
    /// non-following client would throw too, so the test would pass whether or
    /// not redirects are followed at all.
    @Test("a redirect loop is bounded")
    func boundsRedirectLoops() async throws {
        let looping = "https://github.example/loop"
        try await withEventLoop { eventLoop in
            let client = RecordingClient(
                eventLoop: eventLoop, responses: [looping: .redirect(to: looping)])
            await #expect(throws: (any Error).self) {
                try await AgentUpdateArtifacts.getFollowingRedirects(
                    looping, client: client, logger: Logger(label: "test"))
            }
            // Bounded: the hop cap, not an unbounded spin.
            #expect(client.requestedURLs.count <= 6)
        }
    }

    /// A redirect must not be able to pivot to another scheme — a `file://`
    /// or `gopher://` hop is a classic SSRF escape.
    @Test("a redirect to a non-http(s) scheme is refused")
    func refusesSchemePivot() async throws {
        let start = "https://github.example/asset"
        try await withEventLoop { eventLoop in
            let client = RecordingClient(
                eventLoop: eventLoop, responses: [start: .redirect(to: "file:///etc/passwd")])
            await #expect(throws: (any Error).self) {
                try await AgentUpdateArtifacts.getFollowingRedirects(
                    start, client: client, logger: Logger(label: "test"))
            }
            // Refused before the pivot was ever requested.
            #expect(client.requestedURLs == [start])
        }
    }
}

/// Serves canned responses per URL and records what was actually requested, so
/// a test can assert a redirect hop was taken rather than inferred.
private final class RecordingClient: Client, @unchecked Sendable {
    let eventLoop: any EventLoop
    private let responses: [String: ClientResponse]
    private let lock = NIOLock()
    private var requested: [String] = []

    init(eventLoop: any EventLoop, responses: [String: ClientResponse]) {
        self.eventLoop = eventLoop
        self.responses = responses
    }

    var requestedURLs: [String] {
        lock.withLock { requested }
    }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let url = request.url.string
        lock.withLock { requested.append(url) }
        return eventLoop.makeSucceededFuture(responses[url] ?? ClientResponse(status: .notFound))
    }
}

extension ClientResponse {
    fileprivate static func redirect(to location: String) -> ClientResponse {
        var headers = HTTPHeaders()
        headers.add(name: .location, value: location)
        return ClientResponse(status: .found, headers: headers)
    }

    fileprivate static func ok(body: String) -> ClientResponse {
        ClientResponse(status: .ok, body: ByteBuffer(string: body))
    }
}
