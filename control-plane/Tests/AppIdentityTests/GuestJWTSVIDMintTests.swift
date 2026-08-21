import ControlPlanePostgres
import Foundation
import NIOCore
import SPIREServerAPI
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

/// The security property is exercised through a real loopback server: XFCC is
/// accepted only from the pod-local sidecar address, which Vapor's in-memory
/// test client cannot provide.
@Suite("Guest JWT-SVID minting", .serialized)
struct GuestJWTSVIDMintTests {
    private static let audience = "spiffe://strato.local/example-relying-party"

    private struct Fixture {
        let agent: Agent
        var vm: VM
        let registration: LegacyWorkloadRegistrationRecord
        let fake: FakeSPIREServerAPI
    }

    private func enableSPIRE(on app: Application) {
        app.spireService = SPIREService(
            config: SPIREServiceConfig(enabled: true, trustDomain: "strato.local"),
            logger: app.logger,
            httpClient: app.client)
    }

    private func installFakeSPIRE(on app: Application, fake: FakeSPIREServerAPI) {
        app.spireRegistrationService = SPIRERegistrationService(
            api: fake,
            config: SPIRERegistrationConfig(
                trustDomain: "strato.local",
                serverAPIAddress: .tcp(host: "127.0.0.1", port: 1),
                serverPublicAddress: "spire.test:8085",
                agentSelectors: [SPIRESelector(type: "unix", value: "uid:0")],
                svidTTLSeconds: 1800),
            logger: app.logger)
    }

    private func registerAgent(
        on app: Application,
        name: String = "mint-agent",
        trustDomain: String = "strato.local"
    ) async throws -> Agent {
        let agent = Agent(
            name: name,
            trustDomain: trustDomain,
            hostname: "\(name).test",
            version: "1.0.0",
            status: .online,
            resources: AgentResources(
                totalCPU: 8,
                availableCPU: 8,
                totalMemory: 1 << 33,
                availableMemory: 1 << 33,
                totalDisk: 1 << 40,
                availableDisk: 1 << 40))
        try await agent.save(on: app.testPostgres)
        return agent
    }

    private func fixture(on app: Application, installSPIRE: Bool = true) async throws -> Fixture {
        enableSPIRE(on: app)
        app.guestIdentityIssuanceConfig = GuestIdentityIssuanceConfig(
            allowedAudiences: [Self.audience],
            defaultTTLSeconds: 300,
            maximumTTLSeconds: 600)
        let fake = FakeSPIREServerAPI()
        if installSPIRE { installFakeSPIRE(on: app, fake: fake) }

        let agent = try await registerAgent(on: app)
        let builder = TestDataBuilder(db: app.testPostgres)
        let org = try await builder.createOrganization(name: "Mint Org")
        let project = try await builder.createProject(
            name: "Mint Project", description: "guest identity tests", organization: org)
        var vm = try await builder.createVM(name: "mint-vm", project: project)
        vm.hypervisorId = try agent.requireID().uuidString
        try await vm.save(on: app.testPostgres)
        let registration = try await GuestIdentity.register(
            vmID: try vm.requireID(),
            organizationID: try org.requireID(),
            createdBy: nil,
            on: app.testPostgres)
        return Fixture(agent: agent, vm: vm, registration: registration, fake: fake)
    }

    private func mint(
        app: Application,
        port: Int,
        vmID: String,
        identity: String = "spiffe://strato.local/agent/mint-agent",
        request: GuestJWTSVIDRequest = GuestJWTSVIDRequest(audiences: [Self.audience]),
        includeXFCC: Bool = true
    ) async throws -> ClientResponse {
        let body = try WireProtocol.makeEncoder().encode(request)
        return try await app.client.post(
            URI(string: "http://127.0.0.1:\(port)/agent/vms/\(vmID)/jwt-svid")
        ) { req in
            req.headers.contentType = .json
            if includeXFCC {
                req.headers.add(name: "X-Forwarded-Client-Cert", value: "URI=\(identity)")
            }
            req.body = ByteBuffer(data: body)
        }
    }

    private func bodyData(_ response: ClientResponse) -> Data {
        response.body.map { Data($0.readableBytesView) } ?? Data()
    }

    private func rateLimitConfig(apiLimit: Int) -> RateLimitConfig {
        RateLimitConfig(
            enabled: true,
            authLimit: 100,
            authWindow: 60,
            apiLimit: apiLimit,
            apiWindow: 60,
            failureThreshold: 5,
            failureBaseDelay: 2,
            failureMaxDelay: 300,
            failureWindow: 900,
            proxyTrust: ProxyTrustConfig(
                trustForwardedFor: false,
                trustedProxyHops: 1))
    }

    @Test("A hosting agent mints the registered VM identity")
    func placedVM() async throws {
        try await withRunningMintApp { app, port in
            let fixture = try await fixture(on: app)
            let response = try await mint(
                app: app,
                port: port,
                vmID: try fixture.vm.requireID().uuidString,
                request: GuestJWTSVIDRequest(audiences: [Self.audience], ttlSeconds: 450))

            #expect(response.status == .ok)
            #expect(response.headers.cacheControl?.noStore == true)
            let body = try #require(response.body)
            let decoded = try WireProtocol.makeDecoder().decode(
                GuestJWTSVIDResponse.self, from: Data(body.readableBytesView))
            #expect(decoded.token == "fake-jwt-svid")
            #expect(decoded.spiffeId == fixture.registration.spiffeID)
            #expect(decoded.audiences == [Self.audience])

            let calls = await fixture.fake.mintedJWTSVIDs
            #expect(calls.count == 1)
            #expect(calls.first?.spiffeID == fixture.registration.spiffeID)
            #expect(calls.first?.audience == [Self.audience])
            #expect(calls.first?.ttlSeconds == 450)
        }
    }

    @Test("Mint limits are isolated by the verified agent SPIFFE identity")
    func rateLimitIsolation() async throws {
        try await withRunningMintApp { app, port in
            let first = try await fixture(on: app)
            let secondAgent = try await registerAgent(on: app, name: "mint-agent-2")
            let builder = TestDataBuilder(db: app.testPostgres)
            let secondOrg = try await builder.createOrganization(name: "Second Mint Org")
            let secondProject = try await builder.createProject(
                name: "Second Mint Project",
                description: "guest identity rate-limit tests",
                organization: secondOrg)
            var secondVM = try await builder.createVM(name: "second-mint-vm", project: secondProject)
            secondVM.hypervisorId = try secondAgent.requireID().uuidString
            try await secondVM.save(on: app.testPostgres)
            _ = try await GuestIdentity.register(
                vmID: try secondVM.requireID(),
                organizationID: try secondOrg.requireID(),
                createdBy: nil,
                on: app.testPostgres)

            app.agentGuestIdentityRateLimiter = AgentGuestIdentityRateLimiter(
                config: rateLimitConfig(apiLimit: 1),
                fallbackStore: InMemoryRateLimitStore())

            let firstAllowed = try await mint(
                app: app,
                port: port,
                vmID: try first.vm.requireID().uuidString)
            #expect(firstAllowed.status == .ok)
            #expect(firstAllowed.headers.first(name: "X-RateLimit-Limit") == "1")

            let firstThrottled = try await mint(
                app: app,
                port: port,
                vmID: try first.vm.requireID().uuidString)
            #expect(firstThrottled.status == .tooManyRequests)
            #expect(firstThrottled.headers.first(name: "Retry-After") != nil)

            let refusalEvent = try #require(
                try await app.audit.events.events(
                    matching: AuditEventFilter(
                        eventType: AuditEventType.guestIdentityRefused.rawValue
                    ),
                    limit: 1
                ).events.first)
            #expect(refusalEvent.status == Int(HTTPResponseStatus.tooManyRequests.code))
            #expect(refusalEvent.username == "spiffe://strato.local/agent/mint-agent")
            #expect(refusalEvent.resourceID == first.vm.id?.uuidString)
            #expect(refusalEvent.metadata?["reason"] == GuestIdentityRefusal.rateLimited.rawValue)

            let secondAllowed = try await mint(
                app: app,
                port: port,
                vmID: try secondVM.requireID().uuidString,
                identity: "spiffe://strato.local/agent/mint-agent-2")
            #expect(secondAllowed.status == .ok)
            #expect(secondAllowed.headers.first(name: "X-RateLimit-Remaining") == "0")
            #expect(await first.fake.mintedJWTSVIDs.count == 2)
        }
    }

    @Test("Unknown, unplaced, nil-placement, and revoked identities collapse to one 404")
    func placementOracleIsCollapsed() async throws {
        try await withRunningMintApp { app, port in
            var fixture = try await fixture(on: app)
            let vmID = try fixture.vm.requireID()

            fixture.vm.hypervisorId = UUID().uuidString
            try await fixture.vm.save(on: app.testPostgres)
            let unplaced = try await mint(app: app, port: port, vmID: vmID.uuidString)

            let unknown = try await mint(app: app, port: port, vmID: UUID().uuidString)

            fixture.vm.hypervisorId = nil
            try await fixture.vm.save(on: app.testPostgres)
            let noPlacement = try await mint(app: app, port: port, vmID: vmID.uuidString)

            fixture.vm.hypervisorId = try fixture.agent.requireID().uuidString
            try await fixture.vm.save(on: app.testPostgres)
            try await LegacyWorkloadRegistrationStore.delete(
                id: fixture.registration.id, on: app.testPostgres)
            let revoked = try await mint(app: app, port: port, vmID: vmID.uuidString)

            for response in [unplaced, unknown, noPlacement, revoked] {
                #expect(response.status == .notFound)
            }
            let reasons = try [unplaced, unknown, noPlacement, revoked].map {
                try JSONDecoder().decode(AbortErrorResponse.self, from: bodyData($0)).reason
            }
            #expect(reasons.allSatisfy { $0 == "No guest identity is available for this VM" })
            #expect(await fixture.fake.mintedJWTSVIDs.isEmpty)
        }
    }

    @Test("Audience policy is evaluated only for a VM placed on the caller")
    func audiencePolicy() async throws {
        try await withRunningMintApp { app, port in
            var fixture = try await fixture(on: app)
            let denied = GuestJWTSVIDRequest(audiences: ["strato-api"])

            fixture.vm.hypervisorId = UUID().uuidString
            try await fixture.vm.save(on: app.testPostgres)
            let unplaced = try await mint(
                app: app, port: port, vmID: try fixture.vm.requireID().uuidString, request: denied)
            #expect(unplaced.status == .notFound)

            fixture.vm.hypervisorId = try fixture.agent.requireID().uuidString
            try await fixture.vm.save(on: app.testPostgres)
            let forbidden = try await mint(
                app: app, port: port, vmID: try fixture.vm.requireID().uuidString, request: denied)
            #expect(forbidden.status == .forbidden)
            #expect(await fixture.fake.mintedJWTSVIDs.isEmpty)

            app.guestIdentityIssuanceConfig = .disabled
            let disabled = try await mint(
                app: app, port: port, vmID: try fixture.vm.requireID().uuidString)
            #expect(disabled.status == .forbidden)
            #expect(await fixture.fake.mintedJWTSVIDs.isEmpty)
        }
    }

    @Test("Body and TTL validation fail before VM or SPIRE work")
    func validation() async throws {
        try await withRunningMintApp { app, port in
            let fixture = try await fixture(on: app)
            let vmID = try fixture.vm.requireID().uuidString
            let invalidRequests = [
                GuestJWTSVIDRequest(audiences: []),
                GuestJWTSVIDRequest(audiences: Array(repeating: Self.audience, count: 9)),
                GuestJWTSVIDRequest(audiences: [Self.audience], ttlSeconds: 0),
                GuestJWTSVIDRequest(audiences: [Self.audience], ttlSeconds: -1),
            ]
            for request in invalidRequests {
                #expect(try await mint(app: app, port: port, vmID: vmID, request: request).status == .badRequest)
            }
            #expect(
                try await mint(app: app, port: port, vmID: "not-a-uuid").status
                    == .badRequest)
            #expect(await fixture.fake.mintedJWTSVIDs.isEmpty)
        }
    }

    @Test("TTL defaults, clamps, and passes through")
    func ttlResolution() async throws {
        try await withRunningMintApp { app, port in
            let fixture = try await fixture(on: app)
            let vmID = try fixture.vm.requireID().uuidString
            for ttl in [nil, 3_600, 450] as [Int?] {
                let response = try await mint(
                    app: app,
                    port: port,
                    vmID: vmID,
                    request: GuestJWTSVIDRequest(audiences: [Self.audience], ttlSeconds: ttl))
                #expect(response.status == .ok)
            }
            #expect(await fixture.fake.mintedJWTSVIDs.map(\.ttlSeconds) == [300, 600, 450])
        }
    }

    @Test("Authentication and agent-row failures retain their distinct statuses")
    func authenticationFailures() async throws {
        try await withRunningMintApp { app, port in
            enableSPIRE(on: app)
            let noCertificate = try await mint(
                app: app,
                port: port,
                vmID: UUID().uuidString,
                includeXFCC: false)
            #expect(noCertificate.status == .unauthorized)

            let unknownAgent = try await mint(
                app: app,
                port: port,
                vmID: UUID().uuidString,
                identity: "spiffe://strato.local/agent/no-row")
            #expect(unknownAgent.status == .forbidden)
        }
    }

    @Test("An org-domain name collision cannot reach a platform agent's VM")
    func crossOrgNameCollision() async throws {
        try await withRunningMintApp { app, port in
            let fixture = try await fixture(on: app)
            let orgID = UUID()
            let orgDomain = "org-aaaaaaaaaaaa.strato.local"
            let pki = try TestPKI()
            app.spireService = SPIREService(
                config: SPIREServiceConfig(enabled: true, trustDomain: "strato.local"),
                logger: app.logger,
                httpClient: app.client,
                orgTrustDomainSource: StaticOrgTrustDomainSource(snapshots: [
                    OrgTrustDomainSnapshot(
                        organizationID: orgID,
                        trustDomain: orgDomain,
                        bundlePEM: pki.caPEM)
                ]))

            _ = try await registerAgent(on: app, name: "mint-agent", trustDomain: orgDomain)
            let response = try await mint(
                app: app,
                port: port,
                vmID: try fixture.vm.requireID().uuidString,
                identity: "spiffe://\(orgDomain)/agent/mint-agent")

            #expect(response.status == .notFound)
            #expect(await fixture.fake.mintedJWTSVIDs.isEmpty)
        }
    }

    @Test("Unconfigured and unreachable SPIRE have separate retry semantics")
    func spireFailures() async throws {
        try await withRunningMintApp { app, port in
            let fixture = try await fixture(on: app, installSPIRE: false)
            let vmID = try fixture.vm.requireID().uuidString
            #expect(try await mint(app: app, port: port, vmID: vmID).status == .serviceUnavailable)

            installFakeSPIRE(on: app, fake: fixture.fake)
            await fixture.fake.setFailMintJWTSVID(true)
            #expect(try await mint(app: app, port: port, vmID: vmID).status == .badGateway)

            await fixture.fake.setFailMintJWTSVID(false)
            await fixture.fake.setMintedSPIFFEIDOverride(
                "spiffe://strato.local/vm/00000000-0000-0000-0000-000000000000")
            #expect(try await mint(app: app, port: port, vmID: vmID).status == .badGateway)
        }
    }

    @Test("Minted and refused audit rows attribute the agent and never contain the token")
    func auditTrail() async throws {
        try await withRunningMintApp { app, port in
            let fixture = try await fixture(on: app)
            let vmID = try fixture.vm.requireID().uuidString

            _ = try await mint(
                app: app,
                port: port,
                vmID: vmID,
                request: GuestJWTSVIDRequest(audiences: ["denied"]))
            _ = try await mint(app: app, port: port, vmID: vmID)

            let events = try await app.audit.events.events(limit: 500).events.filter {
                [
                    AuditEventType.guestIdentityMinted.rawValue,
                    AuditEventType.guestIdentityRefused.rawValue,
                ].contains($0.eventType)
            }
            #expect(events.count == 2)
            #expect(
                Set(events.map(\.eventType)) == [
                    AuditEventType.guestIdentityMinted.rawValue,
                    AuditEventType.guestIdentityRefused.rawValue,
                ])
            #expect(events.allSatisfy { $0.resourceID == vmID })
            #expect(
                events.allSatisfy {
                    $0.username == "spiffe://strato.local/agent/mint-agent"
                })
            #expect(events.allSatisfy { $0.action == "mint_jwt_svid" })
            #expect(
                events.allSatisfy { event in
                    !(event.metadata?.values.contains { $0.contains("fake-jwt-svid") } ?? false)
                })
        }
    }
}

private struct AbortErrorResponse: Decodable {
    let reason: String
}

private func withRunningMintApp(
    _ test: (Application, Int) async throws -> Void
) async throws {
    try await withApp { app in
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        let outcome: Result<Void, any Error>
        do {
            let port = try #require(
                app.http.server.shared.localAddress?.port,
                "HTTP server did not report a bound port")
            try await test(app, port)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await app.server.shutdown()
        try outcome.get()
    }
}
