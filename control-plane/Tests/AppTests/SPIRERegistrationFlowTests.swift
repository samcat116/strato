import Fluent
import Foundation
import SPIREServerAPI
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Tests for the agent enrollment flow, which *is* SPIRE provisioning: creating
/// an enrollment provisions the node in SPIRE (join token + workload entry) and
/// is refused outright when SPIRE is unconfigured, while revoking one
/// deprovisions the grant it still owns and fails closed when the SPIRE server
/// is unreachable.
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

    private struct CreateEnrollmentBody: Content {
        let agentName: String
        var expirationHours: Int? = nil
        var organizationId: UUID? = nil
        var siteId: UUID? = nil
    }

    /// Enrollments must carry an owning organization; mint one per test app.
    private func makeOrg(on db: Database) async throws -> UUID {
        let org = Organization(name: "SPIRE Org", description: "org for SPIRE tests")
        try await org.save(on: db)
        return try org.requireID()
    }

    /// A site for the org to enroll agents into. Enrollment now requires one,
    /// so tests that drive `createEnrollment` to success need a real site whose
    /// scope contains the enrollment's org.
    private func makeSite(on db: Database, org: UUID, name: String = "spire-dc") async throws -> UUID {
        let site = Site(name: name, organizationScope: .organization(org))
        try await site.save(on: db)
        return try site.requireID()
    }

    /// An enrollment row as `createEnrollment` would have left it, without
    /// driving the endpoint (which would also call the fake SPIRE API and
    /// pollute the call recordings these tests assert on).
    private func makeEnrollment(agentName: String = "node-a") -> AgentEnrollment {
        AgentEnrollment(
            agentName: agentName,
            spiffeID: "spiffe://strato.local/agent/\(agentName)",
            expirationHours: 1)
    }

    // MARK: - Enrollment creation

    @Test("Creating an enrollment provisions SPIRE and returns the join token once")
    func createEnrollmentProvisionsSPIRE() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            let siteId = try await makeSite(on: app.db, org: orgId)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    CreateEnrollmentBody(
                        agentName: "node-a", expirationHours: 2, organizationId: orgId, siteId: siteId))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(AgentEnrollmentResponse.self)

                #expect(response.agentName == "node-a")
                #expect(response.spiffeId == "spiffe://strato.local/agent/node-a")

                // `spire` is no longer optional: enrollment *is* SPIRE
                // provisioning, so a response without it cannot exist.
                let spire = response.spire
                #expect(spire.joinToken == "fake-join-token")
                #expect(spire.spiffeId == "spiffe://strato.local/agent/node-a")
                #expect(spire.nodeId == "spiffe://strato.local/node/node-a")
                #expect(spire.trustDomain == "strato.local")
                #expect(spire.serverAddress == "spire.example.com:8085")

                let command = response.bootstrapCommand
                // The curl-able installer (deploy/agent/install.sh) is the one
                // node-onboarding entry point; the command must fetch it and
                // pass through the control plane and SPIRE parameters.
                #expect(command.hasPrefix("curl -fsSL"))
                #expect(command.contains("deploy/agent/install.sh"))
                #expect(command.contains("| sudo bash -s --"))
                // Agents dial the Envoy mTLS listener, which is always TLS — the
                // URL must be wss:// even though this request arrived over
                // plain HTTP.
                #expect(command.contains("--control-plane-url 'wss://"))
                #expect(command.contains("/agent/ws'"))
                #expect(command.contains("--agent-name 'node-a'"))
                #expect(command.contains("fake-join-token"))
                #expect(command.contains("spire.example.com:8085"))
                #expect(command.contains("--trust-domain 'strato.local'"))
            }

            // The join token lifetime matches the enrollment's expirationHours
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

            // The persisted row carries the scope a registering agent inherits.
            let row = try #require(
                try await AgentEnrollment.query(on: app.db).filter(\.$agentName == "node-a").first())
            #expect(row.organizationID == orgId)
            #expect(row.siteID == siteId)
            #expect(row.isUsed == false)
        }
    }

    @Test("An existing identical SPIRE entry is reused, not an error")
    func createEnrollmentReusesExistingEntry() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            let siteId = try await makeSite(on: app.db, org: orgId)
            let fake = FakeSPIREServerAPI()
            await fake.setEntryResult(.alreadyExists(entryID: "existing-entry"))
            installFakeSPIRE(on: app, fake: fake)

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    CreateEnrollmentBody(agentName: "node-a", organizationId: orgId, siteId: siteId))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(AgentEnrollmentResponse.self)
                #expect(response.spire.joinToken == "fake-join-token")
            }
        }
    }

    @Test("SPIRE provisioning failure returns 502 and persists nothing")
    func createEnrollmentFailsClosedWhenSPIREUnreachable() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            let siteId = try await makeSite(on: app.db, org: orgId)
            let fake = FakeSPIREServerAPI()
            await fake.setFailJoinToken(true)
            installFakeSPIRE(on: app, fake: fake)

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    CreateEnrollmentBody(agentName: "node-a", organizationId: orgId, siteId: siteId))
            } afterResponse: { res in
                #expect(res.status == .badGateway)
            }

            let enrollmentCount = try await AgentEnrollment.query(on: app.db).count()
            #expect(enrollmentCount == 0)
        }
    }

    @Test("Agent names unusable as SPIFFE path segments are rejected with 400")
    func createEnrollmentRejectsInvalidSPIFFEName() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(CreateEnrollmentBody(agentName: "node/../evil", organizationId: orgId))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let enrollmentCount = try await AgentEnrollment.query(on: app.db).count()
            #expect(enrollmentCount == 0)
        }
    }

    @Test("Without SPIRE configured, enrolling an agent is refused naming the missing settings")
    func createEnrollmentRequiresSPIRE() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)

            // No `spireRegistrationService`: mTLS is the only agent auth path,
            // so without SPIRE there is no way to enroll a node at all. A
            // siteId is supplied so the request clears validation and reaches
            // the SPIRE-missing check; the site is never resolved on this path.
            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    CreateEnrollmentBody(agentName: "node-a", organizationId: orgId, siteId: UUID()))
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
                let body = res.body.string
                #expect(body.contains("SPIRE_ENABLED"))
                #expect(body.contains("SPIRE_SERVER_API_ADDRESS"))
            }

            let enrollmentCount = try await AgentEnrollment.query(on: app.db).count()
            #expect(enrollmentCount == 0)
        }
    }

    @Test("A second enrollment for a name that already has one is a 409")
    func createEnrollmentRejectsDuplicateName() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            let siteId = try await makeSite(on: app.db, org: orgId)
            installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    CreateEnrollmentBody(agentName: "node-a", organizationId: orgId, siteId: siteId))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Re-enrolling means revoking the old enrollment first, so its SPIRE
            // grant is withdrawn rather than orphaned beside a second grant for
            // the same identity.
            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(
                    CreateEnrollmentBody(agentName: "node-a", organizationId: orgId, siteId: siteId))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            let enrollmentCount = try await AgentEnrollment.query(on: app.db).count()
            #expect(enrollmentCount == 1)
        }
    }

    @Test("Enrolling an agent without a site is rejected with 400 and persists nothing")
    func createEnrollmentRequiresSite() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let orgId = try await makeOrg(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            try await app.test(.POST, "/api/agent-enrollments") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                try req.content.encode(CreateEnrollmentBody(agentName: "node-a", organizationId: orgId))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("site"))
            }

            // Rejected before any SPIRE provisioning, so nothing is persisted.
            let enrollmentCount = try await AgentEnrollment.query(on: app.db).count()
            #expect(enrollmentCount == 0)
            let joinTokenRequests = await fake.joinTokenRequests
            #expect(joinTokenRequests.isEmpty)
        }
    }

    // MARK: - Enrollment revocation

    @Test("Revoking an enrollment for an unregistered node deletes the SPIRE entry")
    func revokeEnrollmentDeprovisions() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            let enrollment = makeEnrollment()
            try await enrollment.save(on: app.db)

            try await app.test(.DELETE, "/api/agent-enrollments/\(enrollment.id!)") { req in
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

            let remaining = try await AgentEnrollment.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Revoking an expired enrollment still deprovisions")
    func revokeExpiredEnrollmentDeprovisions() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            // Expiry alone does not make the grant inert: the join token may
            // have been redeemed before it expired (spire-agent attests before
            // strato-agent registers), so the grant can still be live.
            let enrollment = makeEnrollment()
            enrollment.expiresAt = Date().addingTimeInterval(-3600)
            try await enrollment.save(on: app.db)

            try await app.test(.DELETE, "/api/agent-enrollments/\(enrollment.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted == ["spiffe://strato.local/agent/node-a", "spiffe://strato.local/node/node-a"])
            let evicted = await fake.evictedAgentIDs
            #expect(evicted == ["spiffe://strato.local/node/node-a"])

            let remaining = try await AgentEnrollment.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("Revoking an enrollment whose agent has registered leaves the live agent's entries alone")
    func revokeEnrollmentForRegisteredAgentSkipsSPIRE() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            // Once an Agent row exists the node has attested and registered, so
            // the entries belong to the live agent: they are withdrawn by
            // deregistering it, not by revoking the enrollment it came from.
            let enrollment = makeEnrollment()
            enrollment.markAsUsed()
            try await enrollment.save(on: app.db)
            let agent = makeAgent(named: "node-a")
            try await agent.save(on: app.db)

            try await app.test(.DELETE, "/api/agent-enrollments/\(enrollment.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted.isEmpty)
            let evicted = await fake.evictedAgentIDs
            #expect(evicted.isEmpty)

            let remaining = try await AgentEnrollment.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }

    @Test("A used enrollment with no agent row still owns — and revokes — its grant")
    func revokeUsedEnrollmentWithoutAgentDeprovisions() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = installFakeSPIRE(on: app, fake: FakeSPIREServerAPI())

            // `isUsed` is informational; grant ownership is decided by whether
            // an Agent row exists. A node that attested and was later
            // deregistered must not keep a live grant behind a "used" flag.
            let enrollment = makeEnrollment()
            enrollment.markAsUsed()
            try await enrollment.save(on: app.db)

            try await app.test(.DELETE, "/api/agent-enrollments/\(enrollment.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted == ["spiffe://strato.local/agent/node-a", "spiffe://strato.local/node/node-a"])
        }
    }

    @Test("Revocation fails closed when SPIRE is unreachable")
    func revokeFailsClosedWhenSPIREUnreachable() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            await fake.setFailDelete(true)
            installFakeSPIRE(on: app, fake: fake)

            let enrollment = makeEnrollment()
            try await enrollment.save(on: app.db)

            try await app.test(.DELETE, "/api/agent-enrollments/\(enrollment.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .badGateway)
            }

            // The enrollment must remain revocable after SPIRE recovers
            let remaining = try await AgentEnrollment.query(on: app.db).count()
            #expect(remaining == 1)
        }
    }

    @Test("Revoking an enrollment whose node never attested tolerates SPIRE invalidArgument on evict")
    func revokeToleratesNeverAttestedEvict() async throws {
        try await withApp { app in
            let adminToken = try await makeAdmin(on: app.db)
            let fake = FakeSPIREServerAPI()
            // A never-redeemed join token means DeleteAgent hits "not an agent"
            // (invalidArgument). Cancelling the grant must still succeed — there
            // is nothing to evict — rather than 502 and strand the enrollment.
            await fake.setEvictInvalidArgument(true)
            installFakeSPIRE(on: app, fake: fake)

            let enrollment = makeEnrollment()
            try await enrollment.save(on: app.db)

            try await app.test(.DELETE, "/api/agent-enrollments/\(enrollment.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // The entries were still deleted; only the (nonexistent) eviction
            // was a no-op.
            let deleted = await fake.deletedSPIFFEIDs
            #expect(deleted == ["spiffe://strato.local/agent/node-a", "spiffe://strato.local/node/node-a"])
            let remaining = try await AgentEnrollment.query(on: app.db).count()
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

            let enrollment = makeEnrollment()
            try await enrollment.save(on: app.db)

            try await app.test(.DELETE, "/api/agent-enrollments/\(enrollment.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
            }

            let remaining = try await AgentEnrollment.query(on: app.db).count()
            #expect(remaining == 1)

            // Expiry doesn't unblock it — the join token may have been
            // redeemed before expiry. Only the explicit override does.
            enrollment.expiresAt = Date().addingTimeInterval(-3600)
            try await enrollment.save(on: app.db)

            try await app.test(.DELETE, "/api/agent-enrollments/\(enrollment.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .serviceUnavailable)
            }

            try await app.test(
                .DELETE, "/api/agent-enrollments/\(enrollment.id!)?skipSpireDeprovision=true"
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
        let federatesWith: [String]
        let admin: Bool
    }

    private(set) var joinTokenRequests: [JoinTokenRequest] = []
    private(set) var createdEntries: [CreateEntryRequest] = []
    private(set) var entryUpdates: [SPIREEntryUpdate] = []
    private(set) var deletedSPIFFEIDs: [String] = []
    private(set) var evictedAgentIDs: [String] = []
    private(set) var createdFederationRelationships: [SPIREFederationRelationshipInput] = []
    private(set) var updatedFederationRelationships: [SPIREFederationRelationshipInput] = []
    private(set) var deletedFederationTrustDomains: [String] = []

    private var failJoinToken = false
    private var failCreateEntry = false
    private var failDelete = false
    private var deleteInvalidArgument = false
    private var evictInvalidArgument = false
    private var entryResult: SPIREEntryCreationResult = .created(entryID: "entry-1")
    private var entries: [SPIREEntry] = []
    private var agents: [SPIREAgent] = []
    private var federationRelationships: [SPIREFederationRelationship] = []
    private var failFederation = false
    private var bundle = SPIREBundle(trustDomain: "strato.local", x509Authorities: [])

    func setFailJoinToken(_ fail: Bool) { failJoinToken = fail }
    func setFailCreateEntry(_ fail: Bool) { failCreateEntry = fail }
    func setFailDelete(_ fail: Bool) { failDelete = fail }
    func setEntries(_ entries: [SPIREEntry]) { self.entries = entries }
    func setAgents(_ agents: [SPIREAgent]) { self.agents = agents }
    func setFederationRelationships(_ relationships: [SPIREFederationRelationship]) {
        self.federationRelationships = relationships
    }
    func setBundle(_ bundle: SPIREBundle) { self.bundle = bundle }
    /// listFederationRelationships throws, as SPIRE does when the trustdomain
    /// API is unreachable.
    func setFailFederation(_ fail: Bool) { failFederation = fail }
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
        x509SVIDTTLSeconds: Int32,
        federatesWith: [String],
        admin: Bool
    ) async throws -> SPIREEntryCreationResult {
        if failCreateEntry {
            throw SPIREServerAPIError.unreachable("fake: SPIRE server down")
        }
        createdEntries.append(
            CreateEntryRequest(
                spiffeID: spiffeID,
                parentID: parentID,
                selectors: selectors,
                x509SVIDTTLSeconds: x509SVIDTTLSeconds,
                federatesWith: federatesWith,
                admin: admin
            ))
        return entryResult
    }

    func updateEntries(_ updates: [SPIREEntryUpdate]) async throws -> [SPIREEntry] {
        entryUpdates.append(contentsOf: updates)
        return []
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

    func listEntries() async throws -> [SPIREEntry] { entries }

    func listAgents() async throws -> [SPIREAgent] { agents }

    func listFederationRelationships() async throws -> [SPIREFederationRelationship] {
        if failFederation {
            throw SPIREServerAPIError.unreachable("fake: SPIRE trustdomain API down")
        }
        return federationRelationships
    }

    func getBundle() async throws -> SPIREBundle {
        if failFederation {
            throw SPIREServerAPIError.unreachable("fake: SPIRE bundle API down")
        }
        return bundle
    }

    func createFederationRelationships(
        _ relationships: [SPIREFederationRelationshipInput]
    ) async throws -> [SPIREFederationRelationshipCreationResult] {
        if failFederation {
            throw SPIREServerAPIError.unreachable("fake: SPIRE trustdomain API down")
        }
        createdFederationRelationships.append(contentsOf: relationships)
        return relationships.map { .created(trustDomain: $0.trustDomain) }
    }

    func updateFederationRelationships(
        _ relationships: [SPIREFederationRelationshipInput]
    ) async throws -> [SPIREFederationRelationship] {
        if failFederation {
            throw SPIREServerAPIError.unreachable("fake: SPIRE trustdomain API down")
        }
        updatedFederationRelationships.append(contentsOf: relationships)
        return federationRelationships
    }

    func deleteFederationRelationships(trustDomains: [String]) async throws -> [String] {
        if failFederation {
            throw SPIREServerAPIError.unreachable("fake: SPIRE trustdomain API down")
        }
        deletedFederationTrustDomains.append(contentsOf: trustDomains)
        return trustDomains
    }
}
