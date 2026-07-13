import Crypto
import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for registry pull secrets and tag→digest resolution (issue #414):
/// the project-scoped CRUD API with the secret encrypted at rest and never
/// echoed, the distribution auth flow (challenge → token → manifest) in
/// `DistributionRegistryClient`, and sync assembly pinning digests and
/// minting the short-lived credential carried in `DesiredSandboxState`.
@Suite("Registry Pull Secret Tests", .serialized)
final class RegistryPullSecretTests {

    // MARK: - Harness

    /// Same shape as `SandboxTests`: full middleware stack, mock SpiceDB,
    /// API-key auth, one org/project and one pre-created sandbox.
    private func withPullSecretTestApp(
        _ test: (Application, User, Project, Sandbox, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "pullsecretuser",
                email: "pullsecret@example.com",
                displayName: "Pull Secret User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Pull Secret Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Pull Secret Project",
                description: "Project for registry credential tests",
                organization: org
            )
            let sandbox = try await builder.createSandbox(
                name: "private-sandbox", project: project, image: "ghcr.io/acme/worker:v3")
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, sandbox, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an in-memory Firecracker-capable agent and places the
    /// sandbox on it, so `assembleDesiredState` carries it.
    private func registerAgent(app: Application, sandbox: Sandbox) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: "pull-secret-agent",
            hostname: "test-host",
            version: "1.0.0",
            capabilities: ["firecracker"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: "pull-secret-agent",
            organizationScope: orgID.map { .organization($0) })
        sandbox.hypervisorId = agentUUID.uuidString
        try await sandbox.save(on: app.db)
        return agentUUID.uuidString
    }

    private func credentialsPath(_ project: Project) -> String {
        "/api/projects/\(project.id!.uuidString)/registry-credentials"
    }

    private let sampleDigest = "sha256:6c3c624b58dbbcd3c0dd82b4c53f04194d1247c6eebdaab7c610cf7d66709b3b"

    // MARK: - CRUD

    @Test("Pull secret CRUD lifecycle: create, list, rotate, delete")
    func crudLifecycle() async throws {
        try await withPullSecretTestApp { app, _, project, _, token in
            var created: RegistryPullSecretResponse?
            try await app.test(.POST, credentialsPath(project)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "registry": "ghcr.io",
                    "username": "acme-bot",
                    "secret": "ghp_supersecret",
                ])
            } afterResponse: { res in
                #expect(res.status == .created)
                #expect(!res.body.string.contains("ghp_supersecret"))
                created = try res.content.decode(RegistryPullSecretResponse.self)
            }
            let response = try #require(created)
            #expect(response.registry == "ghcr.io")
            #expect(response.username == "acme-bot")

            try await app.test(.GET, credentialsPath(project)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let listed = try res.content.decode([RegistryPullSecretResponse].self)
                #expect(listed.count == 1)
                #expect(listed.first?.registry == "ghcr.io")
                #expect(!res.body.string.contains("ghp_supersecret"))
            }

            let secretID = try #require(response.id)
            try await app.test(.PUT, "\(credentialsPath(project))/\(secretID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["username": "acme-bot-2", "secret": "ghp_rotated"])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(RegistryPullSecretResponse.self)
                #expect(updated.username == "acme-bot-2")
            }

            let stored = try #require(await RegistryPullSecret.find(secretID, on: app.db))
            // Works in pass-through and encrypted modes alike.
            let recoverable = try app.secretsEncryption.decrypt(stored.secret)
            #expect(recoverable == "ghp_rotated")

            try await app.test(.DELETE, "\(credentialsPath(project))/\(secretID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            let remaining = try await RegistryPullSecret.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Secrets are encrypted at rest when an encryption key is configured")
    func secretEncryptedAtRest() async throws {
        try await withPullSecretTestApp { app, _, project, _, token in
            let encryption = SecretsEncryptionService(key: SymmetricKey(size: .bits256))
            app.secretsEncryption = encryption

            var created: RegistryPullSecretResponse?
            try await app.test(.POST, credentialsPath(project)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "registry": "ghcr.io",
                    "username": "acme-bot",
                    "secret": "ghp_supersecret",
                ])
            } afterResponse: { res in
                #expect(res.status == .created)
                created = try res.content.decode(RegistryPullSecretResponse.self)
            }

            let response = try #require(created)
            let secretID = try #require(response.id)
            let stored = try #require(await RegistryPullSecret.find(secretID, on: app.db))
            #expect(stored.secret.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let decrypted = try encryption.decrypt(stored.secret)
            #expect(decrypted == "ghp_supersecret")
        }
    }

    @Test("Startup sweep encrypts plaintext pull secrets once a key exists")
    func startupSweepEncrypts() async throws {
        try await withPullSecretTestApp { app, _, project, _, _ in
            let row = RegistryPullSecret(
                projectID: project.id!, registry: "ghcr.io", username: "bot", secret: "plaintext")
            try await row.save(on: app.db)

            let encryption = SecretsEncryptionService(key: SymmetricKey(size: .bits256))
            try await encryption.encryptStoredSecrets(on: app.db, logger: app.logger)

            let stored = try #require(await RegistryPullSecret.find(row.id, on: app.db))
            #expect(stored.secret.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            let decrypted = try encryption.decrypt(stored.secret)
            #expect(decrypted == "plaintext")
        }
    }

    @Test("Duplicate registry in a project conflicts")
    func duplicateRegistryConflicts() async throws {
        try await withPullSecretTestApp { app, _, project, _, token in
            for expectedStatus in [HTTPStatus.created, .conflict] {
                try await app.test(.POST, credentialsPath(project)) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode([
                        "registry": "ghcr.io",
                        "username": "acme-bot",
                        "secret": "ghp_supersecret",
                    ])
                } afterResponse: { res in
                    #expect(res.status == expectedStatus)
                }
            }
        }
    }

    @Test("Registry input is normalized like image references")
    func registryNormalization() async throws {
        try await withPullSecretTestApp { app, _, project, _, token in
            try await app.test(.POST, credentialsPath(project)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "registry": "https://INDEX.Docker.io/v2/",
                    "username": "hub-user",
                    "secret": "hub-pass",
                ])
            } afterResponse: { res in
                #expect(res.status == .created)
                let created = try res.content.decode(RegistryPullSecretResponse.self)
                #expect(created.registry == "docker.io")
            }
        }
    }

    @Test("Mutations require manage_project; denial is a 403")
    func mutationsRequirePermission() async throws {
        try await withPullSecretTestApp { app, _, project, _, token in
            app.spicedbMockAllows = false
            try await app.test(.POST, credentialsPath(project)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "registry": "ghcr.io", "username": "bot", "secret": "s",
                ])
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            let count = try await RegistryPullSecret.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    // MARK: - Challenge parsing

    @Test("WWW-Authenticate challenges parse across quoting and order variants")
    func challengeParsing() {
        let hub = RegistryAuthChallenge.parse(
            #"Bearer realm="https://auth.docker.io/token",service="registry.docker.io""#)
        #expect(hub == .bearer(realm: "https://auth.docker.io/token", service: "registry.docker.io"))

        let reordered = RegistryAuthChallenge.parse(
            #"bearer service="ghcr.io",realm="https://ghcr.io/token",scope="repository:a/b:pull""#)
        #expect(reordered == .bearer(realm: "https://ghcr.io/token", service: "ghcr.io"))

        let basic = RegistryAuthChallenge.parse(#"Basic realm="registry""#)
        #expect(basic == .basic)

        #expect(RegistryAuthChallenge.parse("Negotiate") == nil)
        #expect(RegistryAuthChallenge.parse(#"Bearer service="x""#) == nil)  // no realm
    }

    // MARK: - DistributionRegistryClient

    /// Boots a bare app with a scripted HTTP client installed, and the real
    /// `DistributionRegistryClient` under test on top of it.
    private func withRegistryClient(
        _ test: (DistributionRegistryClient, FakeRegistryHTTPClient) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            let fake = FakeRegistryHTTPClient(on: app.eventLoopGroup.next())
            app.clients.use { _ in fake }
            let client = DistributionRegistryClient(app: app)
            try await test(client, fake)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Bearer flow: challenge, token mint with Basic + scope, manifest with Bearer")
    func bearerFlowResolvesDigest() async throws {
        try await withRegistryClient { client, fake in
            fake.stub(
                urlContaining: "ghcr.io/v2/",
                status: .unauthorized,
                headers: ["WWW-Authenticate": #"Bearer realm="https://ghcr.io/token",service="ghcr.io""#],
                body: "")
            fake.stub(
                urlContaining: "ghcr.io/token",
                status: .ok,
                body: #"{"token":"short-lived-jwt","expires_in":300}"#)
            fake.stub(
                urlContaining: "/v2/acme/worker/manifests/v3",
                status: .ok,
                headers: ["Docker-Content-Digest": sampleDigest],
                body: "{}")

            let ref = try #require(OCIImageReference.parse("ghcr.io/acme/worker:v3"))
            let credential = RegistryBasicCredential(username: "acme-bot", password: "ghp_supersecret")
            let digest = try await client.resolveDigest(for: ref, credential: credential)
            #expect(digest == sampleDigest)

            // The token request carried the constructed pull scope, the
            // service, and the stored credential as Basic auth.
            let tokenRequests = fake.requests(urlContaining: "ghcr.io/token")
            #expect(tokenRequests.count == 1)
            let tokenURL = try #require(tokenRequests.first?.url.string)
            #expect(tokenURL.contains("scope=repository:acme%2Fworker:pull"))
            #expect(tokenURL.contains("service=ghcr.io"))
            #expect(tokenRequests.first?.headers.basicAuthorization?.username == "acme-bot")

            // The manifest request presented the minted token, not Basic auth.
            let manifestRequests = fake.requests(urlContaining: "/manifests/v3")
            #expect(manifestRequests.first?.headers.bearerAuthorization?.token == "short-lived-jwt")
            #expect(manifestRequests.first?.headers.basicAuthorization == nil)
        }
    }

    @Test("Minted tokens are cached until near expiry")
    func tokenCaching() async throws {
        try await withRegistryClient { client, fake in
            fake.stub(
                urlContaining: "ghcr.io/v2/",
                status: .unauthorized,
                headers: ["WWW-Authenticate": #"Bearer realm="https://ghcr.io/token",service="ghcr.io""#],
                body: "")
            fake.stub(
                urlContaining: "ghcr.io/token",
                status: .ok,
                body: #"{"token":"short-lived-jwt","expires_in":300}"#)

            let ref = try #require(OCIImageReference.parse("ghcr.io/acme/worker:v3"))
            let first = try await client.mintPullToken(for: ref, credential: nil)
            let second = try await client.mintPullToken(for: ref, credential: nil)
            #expect(first?.token == "short-lived-jwt")
            #expect(second?.token == "short-lived-jwt")
            #expect(fake.requests(urlContaining: "ghcr.io/token").count == 1)
        }
    }

    @Test("Basic-challenge registries mint no token and resolve with Basic auth")
    func basicOnlyRegistry() async throws {
        try await withRegistryClient { client, fake in
            fake.stub(
                urlContaining: "registry.example.com/v2/",
                status: .unauthorized,
                headers: ["WWW-Authenticate": #"Basic realm="registry""#],
                body: "")
            fake.stub(
                urlContaining: "/v2/team/app/manifests/latest",
                status: .ok,
                headers: ["Docker-Content-Digest": sampleDigest],
                body: "{}")

            let ref = try #require(OCIImageReference.parse("registry.example.com/team/app"))
            let credential = RegistryBasicCredential(username: "u", password: "p")

            let token = try await client.mintPullToken(for: ref, credential: credential)
            #expect(token == nil)

            let digest = try await client.resolveDigest(for: ref, credential: credential)
            #expect(digest == sampleDigest)
            let manifestRequests = fake.requests(urlContaining: "/manifests/latest")
            #expect(manifestRequests.first?.headers.basicAuthorization?.username == "u")
        }
    }

    @Test("Missing Docker-Content-Digest falls back to hashing the manifest bytes")
    func digestFromBody() async throws {
        try await withRegistryClient { client, fake in
            let manifestBody = #"{"schemaVersion":2}"#
            fake.stub(urlContaining: "registry.example.com/v2/", status: .ok, body: "{}")
            fake.stub(
                urlContaining: "/v2/team/app/manifests/latest",
                status: .ok,
                body: manifestBody)

            let ref = try #require(OCIImageReference.parse("registry.example.com/team/app"))
            let digest = try await client.resolveDigest(for: ref, credential: nil)

            let expectedHash = SHA256.hash(data: Data(manifestBody.utf8))
            let expected = "sha256:" + expectedHash.map { String(format: "%02x", $0) }.joined()
            #expect(digest == expected)
        }
    }

    @Test("Plaintext token realms never receive the stored credential")
    func plaintextRealmRefused() async throws {
        try await withRegistryClient { client, fake in
            fake.stub(
                urlContaining: "registry.example.com/v2/",
                status: .unauthorized,
                headers: [
                    "WWW-Authenticate":
                        #"Bearer realm="http://auth.example.com/token",service="registry.example.com""#
                ],
                body: "")
            fake.stub(urlContaining: "auth.example.com/token", status: .ok, body: #"{"token":"t"}"#)

            let ref = try #require(OCIImageReference.parse("registry.example.com/team/app"))
            let credential = RegistryBasicCredential(username: "u", password: "p")
            await #expect(throws: (any Error).self) {
                _ = try await client.mintPullToken(for: ref, credential: credential)
            }
            // The plaintext endpoint was never contacted while holding the secret.
            #expect(fake.requests(urlContaining: "auth.example.com").isEmpty)

            // Anonymous minting over the same realm is fine — nothing at risk.
            let anonymous = try await client.mintPullToken(for: ref, credential: nil)
            #expect(anonymous?.token == "t")
        }
    }

    @Test("Digest-pinned references resolve without any registry traffic")
    func pinnedReferenceSkipsNetwork() async throws {
        try await withRegistryClient { client, fake in
            let ref = try #require(OCIImageReference.parse("ghcr.io/acme/worker@\(sampleDigest)"))
            let digest = try await client.resolveDigest(for: ref, credential: nil)
            #expect(digest == sampleDigest)
            #expect(fake.allRequests.isEmpty)
        }
    }

    // MARK: - Sync assembly

    @Test("Assembly pins the digest, persists it, and mints a bearer credential")
    func assemblyPinsDigestAndMintsToken() async throws {
        try await withPullSecretTestApp { app, _, project, sandbox, _ in
            let row = RegistryPullSecret(
                projectID: project.id!, registry: "ghcr.io", username: "acme-bot",
                secret: "ghp_supersecret")
            try await row.save(on: app.db)

            let scripted = ScriptedRegistryClient(
                digest: sampleDigest,
                token: RegistryPullToken(token: "short-lived-jwt", expiresAt: Date().addingTimeInterval(300)))
            app.registryClient = scripted

            let agentId = try await registerAgent(app: app, sandbox: sandbox)
            let message = try await app.agentService.assembleDesiredState(agentId: agentId)

            let entry = try #require(message.sandboxes.first)
            #expect(entry.spec.imageDigest == sampleDigest)

            let credential = try #require(entry.registryCredential)
            #expect(credential.registry == "ghcr.io")
            #expect(credential.username == "acme-bot")
            #expect(credential.password == "short-lived-jwt")
            #expect(credential.bearer == true)
            #expect(credential.expiresAt != nil)

            // The resolver saw the decrypted credential material.
            #expect(scripted.resolveCredentials == ["ghp_supersecret"])

            // The pin is persisted, so the next assembly never re-resolves.
            let stored = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(stored.imageDigest == sampleDigest)
            _ = try await app.agentService.assembleDesiredState(agentId: agentId)
            #expect(scripted.resolveCallCount == 1)
        }
    }

    @Test("Assembly falls back to the stored Basic credential when no token mints")
    func assemblyBasicFallback() async throws {
        try await withPullSecretTestApp { app, _, project, sandbox, _ in
            let row = RegistryPullSecret(
                projectID: project.id!, registry: "ghcr.io", username: "acme-bot",
                secret: "ghp_supersecret")
            try await row.save(on: app.db)

            // Token minting yields nothing (Basic-only registry).
            app.registryClient = ScriptedRegistryClient(digest: sampleDigest, token: nil)

            let agentId = try await registerAgent(app: app, sandbox: sandbox)
            let message = try await app.agentService.assembleDesiredState(agentId: agentId)

            let credential = try #require(message.sandboxes.first?.registryCredential)
            #expect(credential.password == "ghp_supersecret")
            #expect(credential.bearer == false)
            #expect(credential.expiresAt == nil)
        }
    }

    @Test("Public images sync with no credential and survive a failing registry")
    func assemblyPublicImage() async throws {
        try await withPullSecretTestApp { app, _, _, sandbox, _ in
            // No pull secret rows at all; the resolver also fails, which must
            // not block the sync.
            app.registryClient = ScriptedRegistryClient(digest: nil, token: nil, throwOnResolve: true)

            let agentId = try await registerAgent(app: app, sandbox: sandbox)
            let message = try await app.agentService.assembleDesiredState(agentId: agentId)

            let entry = try #require(message.sandboxes.first)
            #expect(entry.registryCredential == nil)
            #expect(entry.spec.imageDigest == nil)
        }
    }

    @Test("Sandboxes on their way out get neither resolution nor credentials")
    func assemblySkipsAbsentSandboxes() async throws {
        try await withPullSecretTestApp { app, _, project, sandbox, _ in
            // Even with a matching pull secret, an absent-desired sandbox
            // must not receive credential material.
            let row = RegistryPullSecret(
                projectID: project.id!, registry: "ghcr.io", username: "acme-bot",
                secret: "ghp_supersecret")
            try await row.save(on: app.db)

            let scripted = ScriptedRegistryClient(
                digest: sampleDigest,
                token: RegistryPullToken(token: "jwt", expiresAt: Date().addingTimeInterval(300)))
            app.registryClient = scripted

            sandbox.setDesiredStatus(.absent)
            try await sandbox.save(on: app.db)

            let agentId = try await registerAgent(app: app, sandbox: sandbox)
            let message = try await app.agentService.assembleDesiredState(agentId: agentId)

            let entry = try #require(message.sandboxes.first)
            #expect(entry.spec.imageDigest == nil)
            #expect(entry.registryCredential == nil)
            #expect(scripted.resolveCallCount == 0)
            #expect(scripted.mintCallCount == 0)
        }
    }

    @Test("A policy refusal from token minting sends no credential at all")
    func assemblyPolicyRefusalSendsNothing() async throws {
        try await withPullSecretTestApp { app, _, project, sandbox, _ in
            let row = RegistryPullSecret(
                projectID: project.id!, registry: "ghcr.io", username: "acme-bot",
                secret: "ghp_supersecret")
            try await row.save(on: app.db)

            // An insecure-realm refusal must NOT degrade into the Basic
            // fallback — that would hand the agent the stored secret to
            // present to the very endpoint the client refused.
            app.registryClient = ScriptedRegistryClient(
                digest: sampleDigest, token: nil,
                mintError: RegistryClientError.insecureTokenRealm(
                    registry: "ghcr.io", realm: "http://auth.example.com/token"))

            let agentId = try await registerAgent(app: app, sandbox: sandbox)
            let message = try await app.agentService.assembleDesiredState(agentId: agentId)

            let entry = try #require(message.sandboxes.first)
            #expect(entry.registryCredential == nil)
            // The digest pin itself is unaffected.
            #expect(entry.spec.imageDigest == sampleDigest)
        }
    }
}

// MARK: - Scripted registry client

/// `RegistryClientProtocol` double for assembly tests: returns fixed material
/// and records what it was asked, including the decrypted credential secrets
/// it received.
private final class ScriptedRegistryClient: RegistryClientProtocol, @unchecked Sendable {
    private let digest: String?
    private let token: RegistryPullToken?
    private let throwOnResolve: Bool
    private let mintError: Error?
    private let lock = NIOLock()
    private var _resolveCredentials: [String?] = []
    private var _mintCallCount = 0

    init(
        digest: String?, token: RegistryPullToken?, throwOnResolve: Bool = false,
        mintError: Error? = nil
    ) {
        self.digest = digest
        self.token = token
        self.throwOnResolve = throwOnResolve
        self.mintError = mintError
    }

    var resolveCallCount: Int {
        lock.withLock { _resolveCredentials.count }
    }

    var mintCallCount: Int {
        lock.withLock { _mintCallCount }
    }

    /// The secret (password) of each credential passed to `resolveDigest`.
    var resolveCredentials: [String?] {
        lock.withLock { _resolveCredentials }
    }

    func resolveDigest(
        for ref: OCIImageReference, credential: RegistryBasicCredential?
    ) async throws -> String? {
        lock.withLock { _resolveCredentials.append(credential?.password) }
        if throwOnResolve {
            throw Abort(.badGateway, reason: "scripted resolution failure")
        }
        return digest
    }

    func mintPullToken(
        for ref: OCIImageReference, credential: RegistryBasicCredential?
    ) async throws -> RegistryPullToken? {
        lock.withLock { _mintCallCount += 1 }
        if let mintError {
            throw mintError
        }
        return token
    }
}

// MARK: - Scripted HTTP client

/// Vapor `Client` double for `DistributionRegistryClient` tests, in the mold
/// of `FakeIdPClient`: URL-substring stubs (with response headers, which the
/// registry flow needs for challenges and digests) plus request recording.
private final class FakeRegistryHTTPClient: Client, @unchecked Sendable {
    struct Stub {
        var status: HTTPStatus
        var headers: HTTPHeaders
        var body: String
    }

    let eventLoop: EventLoop
    private let lock = NIOLock()
    private var stubs: [(match: String, stub: Stub)] = []
    private var recorded: [ClientRequest] = []

    init(on eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func stub(urlContaining match: String, status: HTTPStatus, headers: HTTPHeaders = [:], body: String) {
        lock.withLock { stubs.append((match, Stub(status: status, headers: headers, body: body))) }
    }

    var allRequests: [ClientRequest] {
        lock.withLock { recorded }
    }

    func requests(urlContaining match: String) -> [ClientRequest] {
        lock.withLock { recorded.filter { $0.url.string.contains(match) } }
    }

    func delegating(to eventLoop: EventLoop) -> Client {
        self
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let stub = lock.withLock { () -> Stub? in
            recorded.append(request)
            return stubs.last { request.url.string.contains($0.match) }?.stub
        }
        guard let stub else {
            return eventLoop.makeFailedFuture(
                Abort(.badGateway, reason: "FakeRegistryHTTPClient has no stub for \(request.url.string)"))
        }
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: stub.status, headers: stub.headers, body: ByteBuffer(string: stub.body)))
    }
}
