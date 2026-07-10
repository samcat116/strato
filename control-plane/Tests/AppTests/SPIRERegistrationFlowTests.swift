import Fluent
import Foundation
import SPIREServerAPI
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for SPIRE join-token provisioning folded into the agent registration
/// flow: creating a registration token also provisions the node in SPIRE
/// (join token + workload entry), revocation deprovisions it and fails closed
/// when the SPIRE server is unreachable.
@Suite("SPIRE Registration Flow Tests")
final class SPIRERegistrationFlowTests: BaseTestCase {

    // MARK: - Helpers

    private func makeAdmin(on db: Database) async throws -> String {
        let admin = User(
            username: "spire-admin",
            email: "spire-admin@example.com",
            displayName: "SPIRE Admin",
            isSystemAdmin: true
        )
        try await admin.save(on: db)
        return try await admin.generateAPIKey(on: db)
    }

    private func makeConfig() -> SPIRERegistrationConfig {
        SPIRERegistrationConfig(
            trustDomain: "strato.local",
            serverAPIAddress: .tcp(host: "127.0.0.1", port: 1),
            serverPublicAddress: "spire.example.com:8085",
            agentSelectors: [SPIRESelector(type: "unix", value: "uid:0")],
            svidTTLSeconds: 1800
        )
    }

    @discardableResult
    private func installFakeSPIRE(on app: Application, fake: FakeSPIREServerAPI) -> FakeSPIREServerAPI {
        app.spireRegistrationService = SPIRERegistrationService(
            api: fake, config: makeConfig(), logger: app.logger)
        return fake
    }

    private struct CreateTokenBody: Content {
        let agentName: String
        var expirationHours: Int? = nil
        var organizationId: UUID? = nil
    }

    /// Tokens must carry an owning organization; mint one per test app.
    private func makeOrg(on db: Database) async throws -> UUID {
        let org = Organization(name: "SPIRE Org", description: "org for SPIRE tests")
        try await org.save(on: db)
        return try org.requireID()
    }

    // MARK: - Token creation

    @Test("Creating a registration token provisions SPIRE and returns the join token once")
    func createTokenProvisionsSPIRE() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(CreateTokenBody(agentName: "node-a", expirationHours: 2, organizationId: orgId))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(AgentRegistrationTokenResponse.self)

                let spire = try #require(response.spire)
                #expect(spire.joinToken == "fake-join-token")
                #expect(spire.spiffeID == "spiffe://strato.local/agent/node-a")
                #expect(spire.nodeID == "spiffe://strato.local/node/node-a")
                #expect(spire.trustDomain == "strato.local")
                #expect(spire.serverAddress == "spire.example.com:8085")

                // With SPIRE provisioning active, agents dial the Envoy mTLS
                // listener, which is always TLS — the URL must be wss:// even
                // though this test request arrived over plain HTTP.
                #expect(response.registrationURL.hasPrefix("wss://"))

                let command = try #require(response.bootstrapCommand)
                // The curl-able installer (deploy/agent/install.sh) is the one
                // node-onboarding entry point; the command must fetch it and
                // pass through the registration and SPIRE parameters.
                #expect(command.hasPrefix("curl -fsSL"))
                #expect(command.contains("deploy/agent/install.sh"))
                #expect(command.contains("| sudo bash -s --"))
                #expect(command.contains(response.registrationURL))
                #expect(command.contains("fake-join-token"))
                #expect(command.contains("spire.example.com:8085"))
                #expect(command.contains("--trust-domain 'strato.local'"))
            }

            // The join token lifetime matches the WS token's expirationHours
            let joinTokenRequests = await fake.joinTokenRequests
            #expect(joinTokenRequests.count == 1)
            #expect(joinTokenRequests.first?.ttlSeconds == 7200)
            #expect(joinTokenRequests.first?.agentID == "spiffe://strato.local/node/node-a")

            // The workload entry matches what the mTLS WebSocket path expects
            let entries = await fake.createdEntries
            #expect(entries.count == 1)
            #expect(entries.first?.spiffeID == "spiffe://strato.local/agent/node-a")
            #expect(entries.first?.parentID == "spiffe://strato.local/node/node-a")
            #expect(entries.first?.selectors == [SPIRESelector(type: "unix", value: "uid:0")])
            #expect(entries.first?.x509SVIDTTLSeconds == 1800)
        }
    }

    @Test("An existing identical SPIRE entry is reused, not an error")
    func createTokenReusesExistingEntry() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            let fake = FakeSPIREServerAPI()
            await fake.setEntryResult(.alreadyExists(entryID: "existing-entry"))
            installFakeSPIRE(on: app, fake: fake)

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(CreateTokenBody(agentName: "node-a", organizationId: orgId))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(AgentRegistrationTokenResponse.self)
                #expect(response.spire != nil)
            }
        }
    }

    @Test("SPIRE provisioning failure returns 502 and persists nothing")
    func createTokenFailsClosedWhenSPIREUnreachable() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            let fake = FakeSPIREServerAPI()
            await fake.setFailJoinToken(true)
            installFakeSPIRE(on: app, fake: fake)

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(CreateTokenBody(agentName: "node-a", organizationId: orgId))
            } afterResponse: { res in
                #expect(res.status == .badGateway)
            }

            let tokenCount = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(tokenCount == 0)
        }
    }

    @Test("Agent names unusable as SPIFFE path segments are rejected with 400")
    func createTokenRejectsInvalidSPIFFEName() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(CreateTokenBody(agentName: "node/../evil", organizationId: orgId))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let tokenCount = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(tokenCount == 0)
        }
    }

    @Test("Without SPIRE registration configured the response is unchanged")
    func createTokenWithoutSPIRE() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)

            try await app.test(.POST, "/api/agents/registration-tokens") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(CreateTokenBody(agentName: "node-a", organizationId: orgId))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(AgentRegistrationTokenResponse.self)
                #expect(response.spire == nil)
                #expect(response.bootstrapCommand == nil)
            }
        }
    }

    // MARK: - Token revocation

    @Test("Revoking an unused token deletes the SPIRE entry")
    func revokeUnusedTokenDeprovisions() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            let token = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            try await token.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(token.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // Both the workload entry and the join-token node alias go: the
            // alias is what an unredeemed join token would attest through.
            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted == ["spiffe://strato.local/agent/node-a", "spiffe://strato.local/node/node-a"])

            // And an already-attested node is evicted, so it cannot regain
            // issuance when a replacement grant recreates the entries.
            let evicted = await fake.evictedAgentIDs
            #expect(evicted == ["spiffe://strato.local/node/node-a"])

            let remaining = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Revoking an expired token without a successor still deprovisions")
    func revokeExpiredTokenWithoutSuccessorDeprovisions() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            // Expired but never superseded: the join token may have been
            // redeemed before expiry (spire-agent attests before strato-agent
            // registers), so the grant can still be live and must be revoked.
            let token = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            token.expiresAt = Date().addingTimeInterval(-3600)
            try await token.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(token.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted == ["spiffe://strato.local/agent/node-a", "spiffe://strato.local/node/node-a"])
            let evicted = await fake.evictedAgentIDs
            #expect(evicted == ["spiffe://strato.local/node/node-a"])

            let remaining = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Revoking a superseded expired token leaves the successor's grant alone")
    func revokeSupersededTokenSkipsSPIRE() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            let stale = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            stale.expiresAt = Date().addingTimeInterval(-3600)
            try await stale.save(on: app.db)

            // A valid replacement now owns the SPIRE grant (and the node may
            // already have attested with it against the same stable node ID).
            let successor = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            try await successor.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(stale.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted.isEmpty)
            let evicted = await fake.evictedAgentIDs
            #expect(evicted.isEmpty)

            let remaining = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(remaining == 1)
        }
    }

    @Test("Revoking an unused token for an mTLS-registered agent leaves its entries alone")
    func revokeTokenForRegisteredAgentSkipsSPIRE() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            // The mTLS path never redeems the WebSocket token, so the token
            // stays "unused" even though the agent is registered and live.
            let token = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            try await token.save(on: app.db)
            let agent = makeAgent(named: "node-a")
            try await agent.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(token.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted.isEmpty)
        }
    }

    @Test("Revocation fails closed when SPIRE is unreachable")
    func revokeFailsClosedWhenSPIREUnreachable() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            await fake.setFailDelete(true)
            installFakeSPIRE(on: app, fake: fake)

            let token = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            try await token.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(token.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .badGateway)
            }

            // The token must remain revocable after SPIRE recovers
            let remaining = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(remaining == 1)
        }
    }

    @Test("Revoking a token whose node never attested tolerates SPIRE invalidArgument on evict")
    func revokeToleratesNeverAttestedEvict() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            // A never-redeemed join token means DeleteAgent hits "not an agent"
            // (invalidArgument). Cancelling the grant must still succeed — there
            // is nothing to evict — rather than 502 and strand the token.
            await fake.setEvictInvalidArgument(true)
            installFakeSPIRE(on: app, fake: fake)

            let token = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            try await token.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(token.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // The entries were still deleted; only the (nonexistent) eviction
            // was a no-op.
            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted == ["spiffe://strato.local/agent/node-a", "spiffe://strato.local/node/node-a"])
            let remaining = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Deregistering a legacy agent tolerates SPIRE invalidArgument on entry deletion")
    func deregisterToleratesMalformedIDDelete() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            // Legacy agent names with illegal SPIFFE characters (e.g. spaces)
            // make ListEntries reject the filter with invalidArgument. Deleting
            // such an agent must still succeed — no such entry can exist.
            await fake.setDeleteInvalidArgument(true)
            installFakeSPIRE(on: app, fake: fake)

            let agent = makeAgent(named: "node-a")
            try await agent.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let remaining = try await Agent.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Revoking a used token leaves the registered agent's entry alone")
    func revokeUsedTokenKeepsEntry() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            let token = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            token.markAsUsed()
            try await token.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(token.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted.isEmpty)
        }
    }

    @Test("A successor minted without a SPIRE grant does not take ownership")
    func unprovisionedSuccessorDoesNotOwnGrant() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            // The original grant, expired but possibly redeemed.
            let stale = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            stale.expiresAt = Date().addingTimeInterval(-3600)
            try await stale.save(on: app.db)

            // Replacement issued while the registration API was unconfigured:
            // it carries no SPIRE grant, so it cannot absorb the old one.
            let successor = AgentRegistrationToken(agentName: "node-a", spireProvisioned: false)
            try await successor.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(stale.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted == ["spiffe://strato.local/agent/node-a", "spiffe://strato.local/node/node-a"])
            let evicted = await fake.evictedAgentIDs
            #expect(evicted == ["spiffe://strato.local/node/node-a"])
        }
    }

    // MARK: - SPIRE enabled without the registration API (misconfiguration)

    /// SPIRE mTLS auth on, but no SPIRE_SERVER_API_ADDRESS: the control plane
    /// cannot deprovision, so revocation paths must fail closed instead of
    /// deleting our records while the node keeps renewing SVIDs.
    private func installSPIREAuthWithoutRegistrationAPI(on app: Application) {
        app.spireService = SPIREService(
            config: SPIREServiceConfig(enabled: true),
            logger: app.logger,
            httpClient: NoopClient()
        )
    }

    @Test("Deregistration fails closed when SPIRE is enabled without the registration API")
    func deregisterFailsClosedWithoutRegistrationAPI() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            installSPIREAuthWithoutRegistrationAPI(on: app)

            let agent = makeAgent(named: "node-a")
            try await agent.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
            }

            let remaining = try await Agent.query(on: app.db).count()
            #expect(remaining == 1)

            // Explicit operator override for out-of-band-managed entries
            try await app.test(.DELETE, "/api/agents/\(agent.id!)?skipSpireDeprovision=true") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let afterOverride = try await Agent.query(on: app.db).count()
            #expect(afterOverride == 0)
        }
    }

    @Test("Revoking a live grant fails closed when SPIRE is enabled without the registration API")
    func revokeFailsClosedWithoutRegistrationAPI() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            installSPIREAuthWithoutRegistrationAPI(on: app)

            let token = AgentRegistrationToken(agentName: "node-a", spireProvisioned: true)
            try await token.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(token.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
            }

            let remaining = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(remaining == 1)

            // Expiry doesn't unblock it — the join token may have been
            // redeemed before expiry. Only the explicit override does.
            token.expiresAt = Date().addingTimeInterval(-3600)
            try await token.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/registration-tokens/\(token.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
            }

            try await app.test(
                .DELETE, "/api/agents/registration-tokens/\(token.id!)?skipSpireDeprovision=true"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
        }
    }

    // MARK: - Agent deregistration

    @Test("Deregistering an agent deletes its SPIRE entry")
    func deregisterAgentDeprovisions() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            let agent = makeAgent(named: "node-a")
            try await agent.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted == ["spiffe://strato.local/agent/node-a", "spiffe://strato.local/node/node-a"])

            let evicted = await fake.evictedAgentIDs
            #expect(evicted == ["spiffe://strato.local/node/node-a"])

            let remaining = try await Agent.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Deregistration fails closed when SPIRE is unreachable")
    func deregisterFailsClosedWhenSPIREUnreachable() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            await fake.setFailDelete(true)
            installFakeSPIRE(on: app, fake: fake)

            let agent = makeAgent(named: "node-a")
            try await agent.save(on: app.db)

            try await app.test(.DELETE, "/api/agents/\(agent.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .badGateway)
            }

            // The agent (and thus the operator's revocation lever) must survive
            let remaining = try await Agent.query(on: app.db).count()
            #expect(remaining == 1)
        }
    }

    private func makeAgent(named name: String) -> Agent {
        Agent(
            name: name,
            hostname: "\(name).example.com",
            version: "1.0.0",
            capabilities: [],
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000_000_000, availableMemory: 16_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 100_000_000_000
            )
        )
    }
}

// MARK: - Unit tests

@Suite("SPIRE Registration Service Unit Tests")
struct SPIRERegistrationServiceUnitTests {

    @Test("Agent names are restricted to SPIFFE path segment characters")
    func agentNameValidation() {
        #expect(SPIRERegistrationService.isValidAgentName("node-a"))
        #expect(SPIRERegistrationService.isValidAgentName("Node_1.internal"))
        #expect(!SPIRERegistrationService.isValidAgentName(""))
        #expect(!SPIRERegistrationService.isValidAgentName("."))
        #expect(!SPIRERegistrationService.isValidAgentName(".."))
        #expect(!SPIRERegistrationService.isValidAgentName("node/a"))
        #expect(!SPIRERegistrationService.isValidAgentName("node a"))
        #expect(!SPIRERegistrationService.isValidAgentName("node:a"))
        #expect(!SPIRERegistrationService.isValidAgentName("nöde"))
    }

    @Test("Selector strings parse as type:value")
    func selectorParsing() {
        let simple = SPIRESelector(string: "unix:uid:0")
        #expect(simple?.type == "unix")
        #expect(simple?.value == "uid:0")

        let path = SPIRESelector(string: "unix:path:/usr/local/bin/strato-agent")
        #expect(path?.type == "unix")
        #expect(path?.value == "path:/usr/local/bin/strato-agent")

        #expect(SPIRESelector(string: "no-separator") == nil)
        #expect(SPIRESelector(string: ":empty-type") == nil)
        #expect(SPIRESelector(string: "empty-value:") == nil)
    }
}

// MARK: - Fake SPIRE server API

/// In-memory `SPIREServerAPI` with switchable failure modes, recording every
/// call so tests can assert exactly what was provisioned.
actor FakeSPIREServerAPI: SPIREServerAPI {
    struct JoinTokenRequest: Sendable {
        let ttlSeconds: Int32
        let agentID: String?
    }

    struct CreateEntryRequest: Sendable {
        let spiffeID: String
        let parentID: String
        let selectors: [SPIRESelector]
        let x509SVIDTTLSeconds: Int32
    }

    private(set) var joinTokenRequests: [JoinTokenRequest] = []
    private(set) var createdEntries: [CreateEntryRequest] = []
    private(set) var deletedSPIFFEIDs: [String] = []
    private(set) var evictedAgentIDs: [String] = []

    private var failJoinToken = false
    private var failCreateEntry = false
    private var failDelete = false
    private var deleteInvalidArgument = false
    private var evictInvalidArgument = false
    private var entryResult: SPIREEntryCreationResult = .created(entryID: "entry-1")

    func setFailJoinToken(_ fail: Bool) { failJoinToken = fail }
    func setFailCreateEntry(_ fail: Bool) { failCreateEntry = fail }
    func setFailDelete(_ fail: Bool) { failDelete = fail }
    /// deleteEntries throws invalidArgument, as SPIRE does for a malformed
    /// SPIFFE ID filter (legacy agent names with illegal characters).
    func setDeleteInvalidArgument(_ fail: Bool) { deleteInvalidArgument = fail }
    /// evictAgent throws invalidArgument, as SPIRE does when the id is not an
    /// attested agent (a node that never redeemed its join token).
    func setEvictInvalidArgument(_ fail: Bool) { evictInvalidArgument = fail }
    func setEntryResult(_ result: SPIREEntryCreationResult) { entryResult = result }

    func createJoinToken(ttlSeconds: Int32, agentID: String?) async throws -> SPIREJoinToken {
        if failJoinToken {
            throw SPIREServerAPIError.unreachable("fake: SPIRE server down")
        }
        joinTokenRequests.append(JoinTokenRequest(ttlSeconds: ttlSeconds, agentID: agentID))
        return SPIREJoinToken(
            value: "fake-join-token",
            expiresAt: Date().addingTimeInterval(TimeInterval(ttlSeconds))
        )
    }

    func createEntry(
        spiffeID: String,
        parentID: String,
        selectors: [SPIRESelector],
        x509SVIDTTLSeconds: Int32
    ) async throws -> SPIREEntryCreationResult {
        if failCreateEntry {
            throw SPIREServerAPIError.unreachable("fake: SPIRE server down")
        }
        createdEntries.append(
            CreateEntryRequest(
                spiffeID: spiffeID,
                parentID: parentID,
                selectors: selectors,
                x509SVIDTTLSeconds: x509SVIDTTLSeconds
            ))
        return entryResult
    }

    func deleteEntries(spiffeID: String) async throws -> Int {
        if failDelete {
            throw SPIREServerAPIError.unreachable("fake: SPIRE server down")
        }
        if deleteInvalidArgument {
            throw SPIREServerAPIError.invalidArgument("fake: malformed SPIFFE ID filter")
        }
        deletedSPIFFEIDs.append(spiffeID)
        return 1
    }

    func evictAgent(spiffeID: String) async throws -> Bool {
        if failDelete {
            throw SPIREServerAPIError.unreachable("fake: SPIRE server down")
        }
        if evictInvalidArgument {
            throw SPIREServerAPIError.invalidArgument("fake: id is not an attested agent")
        }
        evictedAgentIDs.append(spiffeID)
        return true
    }
}
