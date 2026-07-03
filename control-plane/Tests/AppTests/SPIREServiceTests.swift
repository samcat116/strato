import Testing
import Vapor
@testable import App

/// Tests for the SPIFFE/SPIRE identity validation that underpins agent mTLS
/// authentication in `AgentWebSocketController`. These lock in the trust-domain
/// and agent-path checks a forged `X-Forwarded-Client-Cert` header must satisfy,
/// and the `requireClientCert` gate that prevents silent downgrade to token auth.
@Suite("SPIRE Service Tests")
struct SPIREServiceTests {

    private func makeService(
        trustDomain: String = "strato.local",
        requireClientCert: Bool = true
    ) -> SPIREService {
        let config = SPIREServiceConfig(
            enabled: true,
            trustDomain: trustDomain,
            requireClientCert: requireClientCert
        )
        return SPIREService(
            config: config,
            logger: Logger(label: "test.spire"),
            httpClient: NoopClient()
        )
    }

    // MARK: - SPIFFEIdentity parsing

    @Test("Parses a valid agent SPIFFE URI")
    func parsesValidAgentURI() throws {
        let id = try #require(SPIFFEIdentity(uri: "spiffe://strato.local/agent/agent-1"))
        #expect(id.trustDomain == "strato.local")
        #expect(id.path == "/agent/agent-1")
        #expect(id.isAgent)
        #expect(id.agentID == "agent-1")
    }

    @Test("Rejects non-spiffe scheme")
    func rejectsNonSpiffeScheme() {
        #expect(SPIFFEIdentity(uri: "https://strato.local/agent/agent-1") == nil)
    }

    // MARK: - validateAgentIdentity

    @Test("Accepts a well-formed agent identity in the configured trust domain")
    func acceptsValidAgentIdentity() async throws {
        let service = makeService()
        let id = try #require(SPIFFEIdentity(uri: "spiffe://strato.local/agent/agent-1"))
        let agentID = try await service.validateAgentIdentity(id)
        #expect(agentID == "agent-1")
    }

    @Test("Rejects a SPIFFE ID from a foreign trust domain")
    func rejectsForeignTrustDomain() async throws {
        let service = makeService(trustDomain: "strato.local")
        let id = try #require(SPIFFEIdentity(uri: "spiffe://evil.example/agent/agent-1"))
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateAgentIdentity(id)
        }
    }

    @Test("Rejects a non-agent identity even in the correct trust domain")
    func rejectsNonAgentIdentity() async throws {
        let service = makeService()
        let id = try #require(SPIFFEIdentity(uri: "spiffe://strato.local/workload/web"))
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateAgentIdentity(id)
        }
    }

    @Test("Rejects an agent identity with an empty agent name")
    func rejectsEmptyAgentName() async throws {
        let service = makeService()
        let id = try #require(SPIFFEIdentity(uri: "spiffe://strato.local/agent/"))
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateAgentIdentity(id)
        }
    }

    // MARK: - requireClientCert gate

    @Test("requireClientCert reflects configuration")
    func requireClientCertReflectsConfig() async {
        let strict = makeService(requireClientCert: true)
        #expect(await strict.requireClientCert)

        let lax = makeService(requireClientCert: false)
        #expect(await !lax.requireClientCert)
    }
}

/// Minimal `Client` stand-in: the SPIRE identity-validation paths under test never
/// perform outbound requests, so this never needs to succeed.
private struct NoopClient: Client {
    var eventLoop: any EventLoop { EmbeddedEventLoop() }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        eventLoop.makeFailedFuture(Abort(.notImplemented))
    }
}
