import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("OCI Auth Challenge Parsing")
struct OCIAuthChallengeTests {

    @Test("bearer challenge with quoted parameters")
    func bearerChallenge() {
        let parsed = OCIAuthChallenge.parse(
            "Bearer realm=\"https://auth.docker.io/token\",service=\"registry.docker.io\"")
        #expect(parsed == .bearer(realm: "https://auth.docker.io/token", service: "registry.docker.io", scope: nil))
    }

    @Test("bearer challenge with scope and unquoted values")
    func bearerChallengeWithScope() {
        let parsed = OCIAuthChallenge.parse(
            "Bearer realm=https://auth.example.com/token,scope=\"repository:a/b:pull\",service=reg")
        #expect(
            parsed == .bearer(realm: "https://auth.example.com/token", service: "reg", scope: "repository:a/b:pull"))
    }

    @Test("quoted commas do not split parameters")
    func quotedCommas() {
        let parsed = OCIAuthChallenge.parse(
            "Bearer realm=\"https://auth.example.com/token\",scope=\"repository:a:pull,push\"")
        guard case .bearer(let realm, _, let scope) = parsed else {
            Issue.record("expected a bearer challenge")
            return
        }
        #expect(realm == "https://auth.example.com/token")
        #expect(scope == "repository:a:pull,push")
    }

    @Test("basic challenge")
    func basicChallenge() {
        #expect(OCIAuthChallenge.parse("Basic realm=\"registry\"") == .basic)
    }

    @Test("unrecognized schemes and realm-less bearers parse to nil")
    func unrecognized() {
        #expect(OCIAuthChallenge.parse("Digest realm=\"x\"") == nil)
        #expect(OCIAuthChallenge.parse("Bearer service=\"x\"") == nil)
    }
}

@Suite("OCI Registry Client")
struct OCIRegistryClientTests {

    private let ref = OCIImageReference.parse("registry.example.com/acme/app:v1")!
    private let manifestURL = "https://registry.example.com/v2/acme/app/manifests/v1"
    private let tokenURL = "https://auth.example.com/token?scope=repository:acme/app:pull&service=reg"
    private let bearerChallenge = [
        "WWW-Authenticate": "Bearer realm=\"https://auth.example.com/token\",service=\"reg\""
    ]

    private func makeClient(_ transport: MockOCITransport) -> OCIRegistryClient {
        var configuration = OCIRegistryClient.Configuration()
        configuration.retryBaseDelay = .milliseconds(1)
        return OCIRegistryClient(
            transport: transport, logger: Logger(label: "test"), configuration: configuration)
    }

    /// A minimal manifest document plus its exact served bytes and digest.
    private func manifestFixture() throws -> (data: Data, digest: String) {
        let manifest = OCIManifest(
            config: OCIDescriptor(
                mediaType: OCIMediaType.ociConfig, digest: "sha256:" + String(repeating: "a", count: 64), size: 2),
            layers: [
                OCIDescriptor(
                    mediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
                    digest: "sha256:" + String(repeating: "b", count: 64), size: 10)
            ])
        let data = try JSONEncoder().encode(manifest)
        return (data, testSHA256Digest(of: data))
    }

    private func expectOCIError(_ operation: () async throws -> Void) async -> OCIError? {
        do {
            try await operation()
            Issue.record("expected an OCIError to be thrown")
            return nil
        } catch let error as OCIError {
            return error
        } catch {
            Issue.record("expected an OCIError, got \(error)")
            return nil
        }
    }

    @Test("anonymous pull runs the bearer challenge flow")
    func anonymousBearerFlow() async throws {
        let transport = MockOCITransport()
        let fixture = try manifestFixture()
        await transport.script(
            manifestURL,
            .init(status: 401, headers: bearerChallenge),
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: fixture.data))
        await transport.script(tokenURL, .init(status: 200, body: Data(#"{"token":"tok123"}"#.utf8)))

        let resolved = try await makeClient(transport).resolveManifest(for: ref, architecture: .arm64)
        #expect(resolved.manifestDigest == fixture.digest)
        #expect(resolved.manifest.layers.count == 1)

        // The token request is anonymous; the manifest retry carries it.
        let tokenRequests = await transport.requests(to: tokenURL)
        #expect(tokenRequests.count == 1)
        #expect(tokenRequests.first?.headers["Authorization"] == nil)
        let manifestRequests = await transport.requests(to: manifestURL)
        #expect(manifestRequests.count == 2)
        #expect(manifestRequests.last?.headers["Authorization"] == "Bearer tok123")
    }

    @Test("basic credentials authenticate the token endpoint")
    func basicCredentialMintsToken() async throws {
        let transport = MockOCITransport()
        let fixture = try manifestFixture()
        await transport.script(
            manifestURL,
            .init(status: 401, headers: bearerChallenge),
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: fixture.data))
        await transport.script(tokenURL, .init(status: 200, body: Data(#"{"access_token":"tok456"}"#.utf8)))

        let credential = RegistryCredential(
            registry: "registry.example.com", username: "alice", password: "s3cret")
        _ = try await makeClient(transport).resolveManifest(for: ref, credential: credential)

        let expectedBasic = "Basic " + Data("alice:s3cret".utf8).base64EncodedString()
        let tokenRequests = await transport.requests(to: tokenURL)
        #expect(tokenRequests.first?.headers["Authorization"] == expectedBasic)
        let manifestRequests = await transport.requests(to: manifestURL)
        #expect(manifestRequests.last?.headers["Authorization"] == "Bearer tok456")
    }

    @Test("control-plane-minted bearer tokens are presented directly")
    func directBearerCredential() async throws {
        let transport = MockOCITransport()
        let fixture = try manifestFixture()
        await transport.script(
            manifestURL,
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: fixture.data))

        let credential = RegistryCredential(
            registry: "registry.example.com", username: "", password: "minted-token", bearer: true)
        _ = try await makeClient(transport).resolveManifest(for: ref, credential: credential)

        let manifestRequests = await transport.requests(to: manifestURL)
        #expect(manifestRequests.count == 1)
        #expect(manifestRequests.first?.headers["Authorization"] == "Bearer minted-token")
    }

    @Test("a Basic challenge retries with the credential itself")
    func basicChallengeFlow() async throws {
        let transport = MockOCITransport()
        let fixture = try manifestFixture()
        await transport.script(
            manifestURL,
            .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"registry\""]),
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: fixture.data))

        let credential = RegistryCredential(
            registry: "registry.example.com", username: "bob", password: "pw")
        _ = try await makeClient(transport).resolveManifest(for: ref, credential: credential)

        let expectedBasic = "Basic " + Data("bob:pw".utf8).base64EncodedString()
        let manifestRequests = await transport.requests(to: manifestURL)
        #expect(manifestRequests.last?.headers["Authorization"] == expectedBasic)
    }

    @Test("an index is narrowed to this host's platform")
    func indexPlatformSelection() async throws {
        let transport = MockOCITransport()
        let fixture = try manifestFixture()

        let amd64Digest = "sha256:" + String(repeating: "c", count: 64)
        let index = OCIIndex(manifests: [
            OCIDescriptor(
                mediaType: OCIMediaType.ociManifest, digest: amd64Digest, size: 100,
                platform: OCIPlatform(architecture: "amd64", os: "linux")),
            OCIDescriptor(
                mediaType: OCIMediaType.ociManifest, digest: fixture.digest, size: Int64(fixture.data.count),
                platform: OCIPlatform(architecture: "arm64", os: "linux", variant: "v8")),
            OCIDescriptor(
                mediaType: OCIMediaType.ociManifest, digest: "sha256:" + String(repeating: "d", count: 64),
                size: 100, platform: OCIPlatform(architecture: "unknown", os: "unknown")),
        ])
        let indexData = try JSONEncoder().encode(index)

        await transport.script(
            manifestURL,
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociIndex], body: indexData))
        await transport.script(
            "https://registry.example.com/v2/acme/app/manifests/\(fixture.digest)",
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: fixture.data))

        let resolved = try await makeClient(transport).resolveManifest(for: ref, architecture: .arm64)
        #expect(resolved.manifestDigest == fixture.digest)
    }

    @Test("an index without this platform is a permanent error")
    func noMatchingPlatform() async throws {
        let transport = MockOCITransport()
        let index = OCIIndex(manifests: [
            OCIDescriptor(
                mediaType: OCIMediaType.ociManifest, digest: "sha256:" + String(repeating: "c", count: 64),
                size: 100, platform: OCIPlatform(architecture: "amd64", os: "linux"))
        ])
        let indexData = try JSONEncoder().encode(index)
        await transport.script(
            manifestURL,
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociIndex], body: indexData))

        let client = makeClient(transport)
        let error = await expectOCIError {
            _ = try await client.resolveManifest(for: ref, architecture: .arm64)
        }
        guard case .noMatchingPlatform = error else {
            Issue.record("expected noMatchingPlatform, got \(String(describing: error))")
            return
        }
        #expect(error?.failureClassification == .permanent)
    }

    @Test("a pinned digest that doesn't match the served bytes is rejected")
    func pinnedDigestMismatch() async throws {
        let transport = MockOCITransport()
        let fixture = try manifestFixture()
        let wrongPin = "sha256:" + String(repeating: "e", count: 64)
        let pinnedRef = OCIImageReference(
            registry: ref.registry, repository: ref.repository, tag: ref.tag, digest: wrongPin)

        await transport.script(
            "https://registry.example.com/v2/acme/app/manifests/\(wrongPin)",
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: fixture.data))

        let client = makeClient(transport)
        let error = await expectOCIError {
            _ = try await client.resolveManifest(for: pinnedRef)
        }
        guard case .digestMismatch = error else {
            Issue.record("expected digestMismatch, got \(String(describing: error))")
            return
        }
    }

    @Test("server errors are retried, terminal statuses are not")
    func retryBehavior() async throws {
        let transport = MockOCITransport()
        let fixture = try manifestFixture()
        await transport.script(
            manifestURL,
            .init(status: 500),
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: fixture.data))

        _ = try await makeClient(transport).resolveManifest(for: ref)
        let manifestRequestCount = await transport.requests(to: manifestURL).count
        #expect(manifestRequestCount == 2)

        // 404 is terminal: one request, classified for the reconciler.
        let missingTransport = MockOCITransport()
        await missingTransport.script(manifestURL, .init(status: 404))
        let client = makeClient(missingTransport)
        let error = await expectOCIError {
            _ = try await client.resolveManifest(for: ref)
        }
        guard case .manifestUnavailable = error else {
            Issue.record("expected manifestUnavailable, got \(String(describing: error))")
            return
        }
        let missingCount = await missingTransport.requests.count
        #expect(missingCount == 1)
    }

    @Test("an expired credential fails fast without touching the network")
    func expiredCredential() async throws {
        let transport = MockOCITransport()
        let credential = RegistryCredential(
            registry: "registry.example.com", username: "alice", password: "pw",
            expiresAt: Date(timeIntervalSinceNow: -60))
        let client = makeClient(transport)
        let error = await expectOCIError {
            _ = try await client.resolveManifest(for: ref, credential: credential)
        }
        guard case .credentialExpired = error else {
            Issue.record("expected credentialExpired, got \(String(describing: error))")
            return
        }
        let requestCount = await transport.requests.count
        #expect(requestCount == 0)
        #expect(error?.failureClassification == .transient)
    }

    @Test("credentials never travel to a plaintext non-loopback token realm")
    func insecureTokenRealm() async throws {
        let transport = MockOCITransport()
        await transport.script(
            manifestURL,
            .init(
                status: 401,
                headers: ["WWW-Authenticate": "Bearer realm=\"http://auth.example.com/token\",service=\"reg\""]))

        let credential = RegistryCredential(
            registry: "registry.example.com", username: "alice", password: "pw")
        let client = makeClient(transport)
        let error = await expectOCIError {
            _ = try await client.resolveManifest(for: ref, credential: credential)
        }
        guard case .insecureTokenRealm = error else {
            Issue.record("expected insecureTokenRealm, got \(String(describing: error))")
            return
        }
        // Only the original manifest request went out.
        let allRequests = await transport.requests
        #expect(allRequests.count == 1)
    }

    @Test("blob fetch verifies the digest and publishes atomically")
    func blobFetch() async throws {
        let transport = MockOCITransport()
        let content = Data("layer-bytes".utf8)
        let digest = testSHA256Digest(of: content)
        let blobURL = "https://registry.example.com/v2/acme/app/blobs/\(digest)"
        await transport.script(blobURL, .init(status: 200, body: content))

        let destination = NSTemporaryDirectory() + "oci-blob-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let descriptor = OCIDescriptor(
            mediaType: "application/vnd.oci.image.layer.v1.tar+gzip", digest: digest,
            size: Int64(content.count))
        try await makeClient(transport).fetchBlob(descriptor, from: ref, to: destination)

        let written = FileManager.default.contents(atPath: destination)
        #expect(written == content)
        #expect(!FileManager.default.fileExists(atPath: destination + ".partial"))
    }

    @Test("a blob that hashes wrong never reaches its destination")
    func blobDigestMismatch() async throws {
        let transport = MockOCITransport()
        let claimed = "sha256:" + String(repeating: "f", count: 64)
        let blobURL = "https://registry.example.com/v2/acme/app/blobs/\(claimed)"
        await transport.script(blobURL, .init(status: 200, body: Data("corrupt".utf8)))

        let destination = NSTemporaryDirectory() + "oci-blob-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let descriptor = OCIDescriptor(mediaType: "application/vnd.oci.image.layer.v1.tar", digest: claimed, size: 7)
        let client = makeClient(transport)
        let error = await expectOCIError {
            try await client.fetchBlob(descriptor, from: ref, to: destination)
        }
        guard case .digestMismatch = error else {
            Issue.record("expected digestMismatch, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destination))
        #expect(!FileManager.default.fileExists(atPath: destination + ".partial"))
    }

    @Test("blob redirects are followed without forwarding credentials")
    func blobRedirectDropsAuthorization() async throws {
        let transport = MockOCITransport()
        let content = Data("cdn-bytes".utf8)
        let digest = testSHA256Digest(of: content)
        let blobURL = "https://registry.example.com/v2/acme/app/blobs/\(digest)"
        let cdnURL = "https://cdn.example.com/signed/xyz"
        await transport.script(blobURL, .init(status: 307, headers: ["Location": cdnURL]))
        await transport.script(cdnURL, .init(status: 200, body: content))

        let destination = NSTemporaryDirectory() + "oci-blob-test-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let credential = RegistryCredential(
            registry: "registry.example.com", username: "", password: "minted", bearer: true)
        let descriptor = OCIDescriptor(
            mediaType: "application/vnd.oci.image.layer.v1.tar", digest: digest, size: Int64(content.count))
        try await makeClient(transport).fetchBlob(
            descriptor, from: ref, credential: credential, to: destination)

        let registryRequests = await transport.requests(to: blobURL)
        #expect(registryRequests.first?.headers["Authorization"] == "Bearer minted")
        let cdnRequests = await transport.requests(to: cdnURL)
        #expect(cdnRequests.count == 1)
        #expect(cdnRequests.first?.headers["Authorization"] == nil)
    }
}
