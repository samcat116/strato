import Foundation
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Per-organization SPIRE trust domains, phase 2 (issue #613).
///
/// Everything here ships dark: with `SPIRE_ORG_TRUST_DOMAINS_ENABLED` off only
/// the platform trust domain exists and behavior is identical to before. These
/// tests lock in both halves — that the dormant path really is dormant, and
/// that the multi-trust-domain machinery is correct when it is switched on.
@Suite("Org Trust Domain Tests", .serialized)
final class OrgTrustDomainTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Trust domain derivation

    @Test("Trust domain derivation is deterministic and org-specific")
    func trustDomainDerivation() {
        let orgA = UUID(uuidString: "3F2A91C0-4B7D-4E5F-8A1B-2C3D4E5F6A7B")!
        let orgB = UUID(uuidString: "AB2A91C0-4B7D-4E5F-8A1B-2C3D4E5F6A7B")!

        let a = OrgTrustDomain.trustDomain(forOrganization: orgA, platformTrustDomain: "strato.local")
        // The domain is baked into every SVID the org's CA ever issues, so
        // re-deriving it must never produce a different answer.
        #expect(a == OrgTrustDomain.trustDomain(forOrganization: orgA, platformTrustDomain: "strato.local"))
        #expect(a == "org-3f2a91c04b7d4e5f.strato.local")
        #expect(a != OrgTrustDomain.trustDomain(forOrganization: orgB, platformTrustDomain: "strato.local"))

        // SPIFFE requires lowercase trust domain names, so an operator's
        // uppercase SPIRE_TRUST_DOMAIN must not leak through and produce a
        // domain that fails to match a normalized SAN.
        let upper = OrgTrustDomain.trustDomain(forOrganization: orgA, platformTrustDomain: "Strato.LOCAL")
        #expect(upper == upper.lowercased())
        #expect(upper == "org-3f2a91c04b7d4e5f.strato.local")
    }

    private func configuration(orgTrustDomainsEnabled: Bool) async throws
        -> ControlPlaneConfiguration
    {
        try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "SPIRE_ORG_TRUST_DOMAINS_ENABLED": orgTrustDomainsEnabled ? "true" : "false"
            ],
            for: .testing)
    }

    @Test("With the flag on, claim writes a pending row and teardown tombstones it")
    func provisioningLifecycleWithFlagOn() async throws {
        try await withApp { app in
            let orgID = UUID()
            let configuration = try await self.configuration(orgTrustDomainsEnabled: true)

            try await OrgTrustDomainProvisioning.claim(
                organizationID: orgID, configuration: configuration, on: app.testPostgres)

            let claimed = try #require(
                try await OrgTrustDomainStore.find(organizationID: orgID, on: app.testPostgres))
            #expect(claimed.phase == .pending)
            #expect(claimed.generation == 1)
            #expect(claimed.deletedAt == nil)
            #expect(
                claimed.trustDomain
                    == OrgTrustDomain.trustDomain(
                        forOrganization: orgID, platformTrustDomain: PlatformTrustDomain.current))

            // Idempotent: the domain is immutable once any SVID exists under it.
            try await OrgTrustDomainProvisioning.claim(
                organizationID: orgID, configuration: configuration, on: app.testPostgres)
            let count = try await OrgTrustDomainStore.count(
                organizationID: orgID, on: app.testPostgres)
            #expect(count == 1)

            // Teardown is deliberately NOT flag-gated: the flag may flip between
            // an org's creation and its deletion, and a missed tombstone would
            // orphan a row whose CA is resurrected when the flag comes back on.
            try await OrgTrustDomainProvisioning.markForTeardown(organizationID: orgID, on: app.testPostgres)

            let tombstoned = try #require(
                try await OrgTrustDomainStore.find(organizationID: orgID, on: app.testPostgres))
            #expect(tombstoned.phase == .deleting)
            #expect(tombstoned.generation == 2)
            #expect(tombstoned.deletedAt != nil)
        }
    }

    @Test("A colliding trust domain is reported as itself, not a constraint violation")
    func trustDomainCollisionIsExplicit() async throws {
        try await withApp { app in
            // Squat the domain a second organization would derive, then let
            // that organization try to claim it.
            let squatter = UUID()
            let configuration = try await self.configuration(orgTrustDomainsEnabled: true)
            let contendedDomain = OrgTrustDomain.trustDomain(
                forOrganization: squatter, platformTrustDomain: PlatformTrustDomain.current)
            try await OrgTrustDomainStore.insert(
                OrgTrustDomainWrite(
                    organizationID: UUID(), trustDomain: contendedDomain),
                on: app.testPostgres)

            // Must surface as itself rather than tripping the unique index
            // inside the org-create transaction, where it would become an
            // opaque 500 with no hint that a fresh org UUID is the remedy.
            await #expect(throws: OrgTrustDomainError.self) {
                try await OrgTrustDomainProvisioning.claim(
                    organizationID: squatter, configuration: configuration, on: app.testPostgres)
            }
        }
    }

    // MARK: - Model / migration round-trip

    @Test("An org trust domain row round-trips, tombstone included")
    func rowRoundTrips() async throws {
        try await withApp { app in
            let orgID = UUID()
            let row = try await OrgTrustDomainStore.insert(
                OrgTrustDomainWrite(
                organizationID: orgID,
                trustDomain: OrgTrustDomain.trustDomain(
                    forOrganization: orgID, platformTrustDomain: "strato.local"),
                phase: .active,
                serverAddress: "spire-org.example:8081",
                bundleEndpointURL: "https://spire-org.example/bundle",
                nodeAddress: "spire-org.example:8443",
                orgBundlePEM: "-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----"),
                on: app.testPostgres)

            let loaded = try #require(
                try await OrgTrustDomainStore.find(organizationID: orgID, on: app.testPostgres))
            #expect(loaded.phase == .active)
            #expect(loaded.generation == 1)
            #expect(loaded.observedGeneration == 0)
            #expect(loaded.acceptsIdentities)
            #expect(loaded.deletedAt == nil)

            // The tombstone must stay *findable*: it is the instruction to
            // destroy the CA, so a soft-delete that hid it from queries would
            // strand the teardown.
            _ = try await OrgTrustDomainStore.updateState(
                id: row.id,
                phase: .deleting,
                generation: loaded.generation,
                observedGeneration: loaded.observedGeneration,
                serverAddress: loaded.serverAddress,
                bundleEndpointURL: loaded.bundleEndpointURL,
                nodeAddress: loaded.nodeAddress,
                orgBundlePEM: loaded.orgBundlePEM,
                lastError: loaded.lastError,
                deletedAt: Date(),
                on: app.testPostgres)

            let tombstoned = try #require(
                try await OrgTrustDomainStore.find(organizationID: orgID, on: app.testPostgres))
            #expect(tombstoned.phase == .deleting)
            #expect(tombstoned.deletedAt != nil)
            #expect(!tombstoned.acceptsIdentities)
        }
    }

    @Test("A row with no cached bundle is not accepted for identity validation")
    func pendingRowRejectsIdentities() {
        let pending = orgTrustDomainRecord(phase: .pending, bundlePEM: nil)
        #expect(!pending.acceptsIdentities)
        let activeWithoutBundle = orgTrustDomainRecord(phase: .active, bundlePEM: nil)
        // Active but bundle-less: there are no roots to verify against, and
        // accepting on the strength of the row alone would be the union-of-roots
        // mistake per-org domains exist to prevent.
        #expect(!activeWithoutBundle.acceptsIdentities)
        let ready = orgTrustDomainRecord(
            phase: .active,
            bundlePEM: "-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----")
        #expect(ready.acceptsIdentities)
    }

    // MARK: - Provisioning hooks are dormant behind the flag

    @Test("Organization creation writes no trust domain while the flag is off")
    func creationIsDormant() async throws {
        try await withApp { app in
            let configuration = try await self.configuration(orgTrustDomainsEnabled: false)
            let orgID = UUID()
            try await OrgTrustDomainProvisioning.claim(
                organizationID: orgID, configuration: configuration, on: app.testPostgres)

            let count = try await OrgTrustDomainStore.count(
                organizationID: orgID, on: app.testPostgres)
            #expect(count == 0)
        }
    }

    private func orgTrustDomainRecord(
        phase: OrgTrustDomainPhase, bundlePEM: String?
    ) -> OrgTrustDomainRecord {
        OrgTrustDomainRecord(
            id: UUID(),
            organizationID: UUID(),
            trustDomain: "org-abc.strato.local",
            phase: phase,
            generation: 1,
            observedGeneration: 0,
            serverAddress: nil,
            bundleEndpointURL: nil,
            nodeAddress: nil,
            orgBundlePEM: bundlePEM,
            lastError: nil,
            createdAt: nil,
            updatedAt: nil,
            deletedAt: nil)
    }

    // MARK: - Per-trust-domain bundle selection

    /// A service holding the platform bundle plus one organization's, exactly
    /// as production assembles it: platform from the configured file, orgs from
    /// the registry.
    private func makeMultiDomainService(
        platformPEM: String,
        orgs: [OrgTrustDomainSnapshot]
    ) async throws -> SPIREService {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-td-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundlePath = dir.appendingPathComponent("bundle.pem").path
        try platformPEM.write(toFile: bundlePath, atomically: true, encoding: .utf8)

        let service = SPIREService(
            config: SPIREServiceConfig(
                enabled: true,
                trustDomain: "strato.local",
                trustBundlePath: bundlePath
            ),
            logger: Logger(label: "test.spire.orgtd"),
            httpClient: NoopClient(),
            orgTrustDomainSource: StaticOrgTrustDomainSource(snapshots: orgs)
        )
        try await service.start()
        return service
    }

    @Test("An org SVID validates against its own trust domain's roots and resolves its org")
    func orgSVIDValidatesAndResolvesOrganization() async throws {
        let platformPKI = try TestPKI()
        let orgPKI = try TestPKI()
        let orgID = UUID()
        let orgTD = "org-aaaaaaaaaaaa.strato.local"

        let service = try await makeMultiDomainService(
            platformPEM: platformPKI.caPEM,
            orgs: [
                OrgTrustDomainSnapshot(
                    organizationID: orgID, trustDomain: orgTD, bundlePEM: orgPKI.caPEM)
            ]
        )

        let leaf = try orgPKI.issueLeafPEM(spiffeURI: "spiffe://\(orgTD)/agent/agent-1")
        let validated = try await service.validateCertificate(leaf)
        #expect(validated.identity.agentID == "agent-1")
        #expect(validated.organizationID == orgID)

        // The platform domain still resolves to no organization.
        let platformLeaf = try platformPKI.issueLeafPEM(spiffeURI: "spiffe://strato.local/agent/cp-agent")
        let platformValidated = try await service.validateCertificate(platformLeaf)
        #expect(platformValidated.organizationID == nil)

        await service.stop()
    }

    @Test("Roots are never unioned across trust domains")
    func rootsAreNotUnioned() async throws {
        let platformPKI = try TestPKI()
        let orgAPKI = try TestPKI()
        let orgBPKI = try TestPKI()

        let service = try await makeMultiDomainService(
            platformPEM: platformPKI.caPEM,
            orgs: [
                OrgTrustDomainSnapshot(
                    organizationID: UUID(), trustDomain: "org-aaaaaaaaaaaa.strato.local",
                    bundlePEM: orgAPKI.caPEM),
                OrgTrustDomainSnapshot(
                    organizationID: UUID(), trustDomain: "org-bbbbbbbbbbbb.strato.local",
                    bundlePEM: orgBPKI.caPEM),
            ]
        )

        // This is the whole point of the feature: org B's CA holds a perfectly
        // valid key, and it still cannot mint an identity inside org A's domain.
        let forged = try orgBPKI.issueLeafPEM(spiffeURI: "spiffe://org-aaaaaaaaaaaa.strato.local/agent/agent-1")
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateCertificate(forged)
        }

        // Nor can the platform CA, which under a union of roots would be
        // trusted for everything.
        let platformForged = try platformPKI.issueLeafPEM(
            spiffeURI: "spiffe://org-aaaaaaaaaaaa.strato.local/agent/agent-1")
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateCertificate(platformForged)
        }

        await service.stop()
    }

    @Test("An unregistered trust domain is refused outright")
    func unregisteredTrustDomainRefused() async throws {
        let platformPKI = try TestPKI()
        let strangerPKI = try TestPKI()

        let service = try await makeMultiDomainService(platformPEM: platformPKI.caPEM, orgs: [])

        let leaf = try strangerPKI.issueLeafPEM(spiffeURI: "spiffe://org-zzzzzzzzzzzz.strato.local/agent/agent-1")
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateCertificate(leaf)
        }

        let identity = try #require(SPIFFEIdentity(uri: "spiffe://org-zzzzzzzzzzzz.strato.local/agent/agent-1"))
        await #expect(throws: SPIREServiceError.self) {
            _ = try await service.validateAgentIdentity(identity)
        }

        await service.stop()
    }

    @Test("An agent identity in a registered org trust domain is accepted")
    func orgAgentIdentityAccepted() async throws {
        let platformPKI = try TestPKI()
        let orgPKI = try TestPKI()
        let orgTD = "org-cccccccccccc.strato.local"

        let service = try await makeMultiDomainService(
            platformPEM: platformPKI.caPEM,
            orgs: [
                OrgTrustDomainSnapshot(organizationID: UUID(), trustDomain: orgTD, bundlePEM: orgPKI.caPEM)
            ]
        )

        let identity = try #require(SPIFFEIdentity(uri: "spiffe://\(orgTD)/agent/agent-1"))
        #expect(try await service.validateAgentIdentity(identity) == "agent-1")

        await service.stop()
    }

    // MARK: - Agent-name collisions across trust domains

    @Test("Two organizations can each enroll the same agent name")
    func enrollmentNamesAreScopedPerTrustDomain() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let orgA = try await builder.createOrganization(name: "TD Org A")
            let orgB = try await builder.createOrganization(name: "TD Org B")

            let domainA = "org-aaaaaaaaaaaa.strato.local"
            let domainB = "org-bbbbbbbbbbbb.strato.local"

            let enrollmentA = TestAgentEnrollment(
                agentName: "agent-1",
                spiffeID: "spiffe://\(domainA)/agent/agent-1",
                trustDomain: domainA,
                organizationScope: .organization(try orgA.requireID())
            )
            _ = try await saveTestAgentEnrollment(enrollmentA, on: app.testPostgres)

            // Globally unique names would reject this insert, which is the
            // blocking correctness bug: two tenants may legitimately both call
            // their first node `agent-1`.
            let enrollmentB = TestAgentEnrollment(
                agentName: "agent-1",
                spiffeID: "spiffe://\(domainB)/agent/agent-1",
                trustDomain: domainB,
                organizationScope: .organization(try orgB.requireID())
            )
            _ = try await saveTestAgentEnrollment(enrollmentB, on: app.testPostgres)

            let count = try await testAgentEnrollmentCount(
                agentName: "agent-1",
                on: app.testPostgres
            )
            #expect(count == 2)
        }
    }

    @Test("Same-named agents in different trust domains are distinct rows and distinct sockets")
    func agentNamesAreScopedPerTrustDomain() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let orgA = try await builder.createOrganization(name: "Agent TD Org A")
            let orgB = try await builder.createOrganization(name: "Agent TD Org B")
            let siteA = Site(
                name: "agent-td-a",
                organizationScope: .organization(try orgA.requireID()))
            try await siteA.save(on: app.testPostgres)
            let siteB = Site(
                name: "agent-td-b",
                organizationScope: .organization(try orgB.requireID()))
            try await siteB.save(on: app.testPostgres)

            let domainA = "org-aaaaaaaaaaaa.strato.local"
            let domainB = "org-bbbbbbbbbbbb.strato.local"

            let idA = try await app.agentService.registerAgent(
                Self.registration(name: "agent-1"),
                identity: AgentIdentity(trustDomain: domainA, name: "agent-1"),
                siteID: try siteA.requireID(),
                organizationScope: .organization(try orgA.requireID()))
            let idB = try await app.agentService.registerAgent(
                Self.registration(name: "agent-1"),
                identity: AgentIdentity(trustDomain: domainB, name: "agent-1"),
                siteID: try siteB.requireID(),
                organizationScope: .organization(try orgB.requireID()))

            // Two rows, not one row re-registered: a name-keyed lookup would
            // have found org A's agent and handed org B's registration to it.
            #expect(idA != idB)

            let rowA = try #require(try await Agent.find(idA, on: app.testPostgres))
            let rowB = try #require(try await Agent.find(idB, on: app.testPostgres))
            #expect(rowA.organizationID == orgA.id)
            #expect(rowB.organizationID == orgB.id)
            #expect(rowA.identity.key == "spiffe://\(domainA)/agent/agent-1")
            #expect(rowB.identity.key != rowA.identity.key)
        }
    }

    @Test("An SVID from one org cannot register into another org's scope")
    func identityOrganizationMustMatchEnrollmentScope() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let orgA = try await builder.createOrganization(name: "Mismatch Org A")
            let orgB = try await builder.createOrganization(name: "Mismatch Org B")

            // The node attested to org A's CA, but its enrollment hands it org
            // B's capacity. Refuse: the trust domain is a cryptographic
            // statement about whose node this is.
            await #expect(throws: AgentServiceError.self) {
                _ = try await app.agentService.registerAgent(
                    Self.registration(name: "mismatched"),
                    identity: AgentIdentity(
                        trustDomain: "org-aaaaaaaaaaaa.strato.local", name: "mismatched"),
                    identityOrganizationID: try orgA.requireID(),
                    organizationScope: .organization(try orgB.requireID()))
            }
        }
    }

    @Test("A scopeless enrollment inherits the organization its trust domain resolves to")
    func identityOrganizationSuppliesMissingScope() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "Inherit Org")
            let orgID = try org.requireID()
            let site = Site(name: "inherit-dc", organizationScope: .organization(orgID))
            try await site.save(on: app.testPostgres)

            let agentID = try await app.agentService.registerAgent(
                Self.registration(name: "inheriting"),
                identity: AgentIdentity(trustDomain: "org-dddddddddddd.strato.local", name: "inheriting"),
                identityOrganizationID: orgID,
                siteID: try site.requireID())

            let row = try #require(try await Agent.find(agentID, on: app.testPostgres))
            #expect(row.organizationID == orgID)
        }
    }

    // MARK: - Operator teardown actually tears down

    @Test("forceUnregisterAgent removes the agent's socket registration")
    func forceUnregisterRemovesSocketRegistration() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "Teardown Org")
            let site = Site(
                name: "teardown-dc",
                organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.testPostgres)

            let agentID = try await app.agentService.registerAgent(
                Self.registration(name: "teardown-agent"),
                identity: AgentIdentity(
                    trustDomain: PlatformTrustDomain.current, name: "teardown-agent"),
                siteID: try site.requireID(),
                organizationScope: .organization(try org.requireID()))

            let row = try #require(try await Agent.find(agentID, on: app.testPostgres))

            // Registration publishes the agent's presence under its identity
            // key; the operator teardown path must clear the same key, or the
            // stale-agent sweep keeps skipping a node the operator just tore
            // down. Passing the bare name here silently did nothing, because
            // nothing is keyed by name any more — which is exactly the
            // regression this guards. `forceUnregisterAgent` now takes an
            // `AgentIdentity`, so repeating the mistake is a compile error.
            #expect(await app.coordination.isAgentPresent(agentKey: row.identity.key) == true)

            await app.agentService.forceUnregisterAgent(row.identity)

            #expect(await app.coordination.isAgentPresent(agentKey: row.identity.key) == false)
        }
    }

    private static func registration(name: String) -> AgentRegisterMessage {
        AgentRegisterMessage(
            agentId: name,
            hostname: "test-host",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion
        )
    }
}

/// An `OrgTrustDomainSource` with a fixed answer, so trust-domain selection can
/// be tested without a database or the feature flag.
struct StaticOrgTrustDomainSource: OrgTrustDomainSource {
    let snapshots: [OrgTrustDomainSnapshot]

    func loadOrgTrustDomains() async throws -> [OrgTrustDomainSnapshot] {
        snapshots
    }
}
