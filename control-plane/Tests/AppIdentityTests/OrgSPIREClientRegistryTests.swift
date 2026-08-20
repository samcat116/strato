import Fluent
import Foundation
import SPIREServerAPI
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Enrollment against the owning organization's SPIRE instance (issue #615).
///
/// The registry is what decides *which* trust domain a node is provisioned in,
/// so these lock down both directions: that the platform domain stays the
/// answer everywhere it used to be, and that a ready organization domain takes
/// over — carrying the federation and the explicit control-plane pin an
/// org-domain agent cannot derive for itself.
///
/// The feature flags are passed to the registry as values rather than set in
/// the process environment: `setenv` is process-global and swift-testing runs
/// suites concurrently, so mutating it here would race
/// `SPIRERegistrationFlowTests`, which asserts platform-domain behavior off the
/// same two variables.
@Suite("Org SPIRE Client Registry")
struct OrgSPIREClientRegistryTests {

    /// Deliberately *not* the `SPIRE_TRUST_DOMAIN` default (`strato.local`).
    /// Anything that derives the platform domain from the environment instead
    /// of from the installed service will disagree with this and fail.
    private static let platformTrustDomain = "platform.test"
    private static let orgTrustDomain = "org-0123456789abcdef.platform.test"

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// The platform registration service as `configureSPIRERegistration` would
    /// have installed it, but against a fake API so nothing dials a server.
    private func installPlatformSPIRE(on app: Application, workloadSocket: String? = "/tmp/agent.sock") {
        let config = SPIRERegistrationConfig(
            trustDomain: Self.platformTrustDomain,
            serverAPIAddress: .tcp(host: "127.0.0.1", port: 1),
            workloadAPISocketPath: workloadSocket,
            serverPublicAddress: "spire.example.com:8085",
            agentSelectors: [SPIRESelector(type: "unix", value: "uid:0")],
            svidTTLSeconds: 1800
        )
        app.spireRegistrationService = SPIRERegistrationService(
            api: FakeSPIREServerAPI(), config: config, logger: app.logger)
    }

    private func makeRegistry(
        on app: Application,
        orgTrustDomainsEnabled: Bool = true,
        legacyEnrollmentsAllowed: Bool = true
    ) throws -> OrgSPIREClientRegistry {
        let platform = try #require(app.spireRegistrationService)
        return OrgSPIREClientRegistry(
            platform: platform,
            platformConfig: platform.registrationConfig,
            logger: app.logger,
            orgTrustDomainsEnabled: orgTrustDomainsEnabled,
            legacyEnrollmentsAllowed: legacyEnrollmentsAllowed
        )
    }

    private func makeOrg(on db: Database) async throws -> UUID {
        let org = Organization(name: "TD Org", description: "org for trust domain tests")
        try await org.save(on: db)
        return try org.requireID()
    }

    /// An org trust domain row in the shape the phase-3 reconciler leaves a
    /// fully provisioned instance.
    @discardableResult
    private func makeReadyTrustDomain(
        on db: Database,
        organizationID: UUID,
        trustDomain: String = OrgSPIREClientRegistryTests.orgTrustDomain
    ) async throws -> OrgTrustDomainRecord {
        try await OrgTrustDomainStore.insert(
            OrgTrustDomainWrite(
                organizationID: organizationID,
                trustDomain: trustDomain,
                phase: .active,
                serverAddress: "spire-org.example.com:8085",
                nodeAddress: "spire-org.example.com:8081",
                orgBundlePEM: Self.samplePEM),
            on: db)
    }

    // MARK: - Platform fallback

    @Test("With the feature off, every scope resolves to the platform trust domain")
    func featureOffUsesPlatform() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            // Even with a fully provisioned row present, the flag is what gates
            // the behavior — that is what makes the phase-2 rows ship dark.
            try await makeReadyTrustDomain(on: app.db, organizationID: org)

            let registry = try makeRegistry(on: app, orgTrustDomainsEnabled: false)
            let selection = try await registry.resolve(scope: .organization(org), on: app.db)

            #expect(selection.service.trustDomain == Self.platformTrustDomain)
            #expect(selection.federatesWith.isEmpty)
            #expect(selection.platformFallback != nil)
        }
    }

    @Test("An organization with no claimed trust domain falls back to the platform one")
    func noClaimedDomainUsesPlatform() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)

            let registry = try makeRegistry(on: app)
            let selection = try await registry.resolve(scope: .organization(org), on: app.db)
            #expect(selection.service.trustDomain == Self.platformTrustDomain)
            #expect(selection.federatesWith.isEmpty)
            guard case .noTrustDomainClaimed = selection.platformFallback else {
                Issue.record("expected a no-trust-domain-claimed fallback")
                return
            }
        }
    }

    @Test("A claimed but unprovisioned domain falls back while legacy enrollments are allowed")
    func pendingDomainFallsBack() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            // Claimed by org creation, not yet converged by the reconciler.
            try await OrgTrustDomainStore.insert(
                OrgTrustDomainWrite(
                    organizationID: org, trustDomain: Self.orgTrustDomain),
                on: app.db)

            let registry = try makeRegistry(on: app, legacyEnrollmentsAllowed: true)
            let selection = try await registry.resolve(scope: .organization(org), on: app.db)
            #expect(selection.service.trustDomain == Self.platformTrustDomain)
            guard case .trustDomainNotReady = selection.platformFallback else {
                Issue.record("expected a trust-domain-not-ready fallback")
                return
            }
        }
    }

    @Test("A claimed but unprovisioned domain is refused once legacy enrollments are off")
    func pendingDomainRefusedWithoutLegacy() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            try await OrgTrustDomainStore.insert(
                OrgTrustDomainWrite(
                    organizationID: org, trustDomain: Self.orgTrustDomain),
                on: app.db)

            let registry = try makeRegistry(on: app, legacyEnrollmentsAllowed: false)
            await #expect(throws: (any Error).self) {
                _ = try await registry.resolve(scope: .organization(org), on: app.db)
            }
        }
    }

    @Test("An active domain missing its cached bundle is not treated as ready")
    func activeWithoutBundleIsNotReady() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            // Provisioning got as far as `active` but the bundle never landed.
            // Minting an identity here would produce an agent the control plane
            // holds no roots for and refuses on the WebSocket.
            try await OrgTrustDomainStore.insert(
                OrgTrustDomainWrite(
                    organizationID: org,
                    trustDomain: Self.orgTrustDomain,
                    phase: .active,
                    serverAddress: "spire-org.example.com:8085",
                    nodeAddress: "spire-org.example.com:8081"),
                on: app.db)

            let registry = try makeRegistry(on: app, legacyEnrollmentsAllowed: false)
            await #expect(throws: (any Error).self) {
                _ = try await registry.resolve(scope: .organization(org), on: app.db)
            }
        }
    }

    // MARK: - Organization instances

    @Test("A ready organization domain provisions against its own instance, federated with the platform")
    func readyDomainUsesOrgInstance() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            let row = try await makeReadyTrustDomain(on: app.db, organizationID: org)

            let registry = try makeRegistry(on: app)
            let selection = try await registry.resolve(scope: .organization(org), on: app.db)

            #expect(selection.platformFallback == nil)
            #expect(selection.service.trustDomain == row.trustDomain)
            // Without this the agent's Workload API hands it only its own
            // domain's roots and it can never verify the control plane.
            #expect(selection.federatesWith == [Self.platformTrustDomain])
            #expect(
                selection.service.agentSPIFFEID(agentName: "hv-01") == "spiffe://\(row.trustDomain)/agent/hv-01")
            // Both of these must come from the installed platform service, not
            // from SPIRE_TRUST_DOMAIN — which is why the fake's domain above is
            // deliberately not the environment default.
            #expect(selection.controlPlaneSPIFFEID == "spiffe://\(Self.platformTrustDomain)/control-plane")
        }
    }

    @Test("A folder-scoped enrollment resolves to its root organization's domain")
    func folderScopeResolvesToRootOrg() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            let row = try await makeReadyTrustDomain(on: app.db, organizationID: org)

            let folder = OrganizationalUnit(
                name: "capacity",
                description: "delegated capacity",
                organizationID: org,
                path: "/capacity",
                depth: 0
            )
            try await folder.save(on: app.db)
            let folderID = try folder.requireID()

            let registry = try makeRegistry(on: app)
            let selection = try await registry.resolve(scope: .organizationalUnit(folderID), on: app.db)
            // A folder has no CA of its own — capacity delegated to it is
            // still the organization's tenancy.
            #expect(selection.service.trustDomain == row.trustDomain)
            #expect(selection.platformFallback == nil)
        }
    }

    @Test("Reaching an organization instance requires the control plane's own SVID")
    func orgInstanceRequiresWorkloadSocket() async throws {
        try await withApp { app in
            // The compose/unix-socket platform shape: no Workload API socket,
            // so there is no identity to present to a *networked* org server.
            installPlatformSPIRE(on: app, workloadSocket: nil)
            let org = try await makeOrg(on: app.db)
            try await makeReadyTrustDomain(on: app.db, organizationID: org)

            let registry = try makeRegistry(on: app)
            await #expect(throws: (any Error).self) {
                _ = try await registry.resolve(scope: .organization(org), on: app.db)
            }
        }
    }

    @Test("Enrollment still requires the node-attestation address the bootstrap command carries")
    func enrollmentRequiresServerAddress() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            let row = try await makeReadyTrustDomain(on: app.db, organizationID: org)
            _ = try await OrgTrustDomainStore.updateState(
                id: row.id,
                phase: row.phase,
                generation: row.generation,
                observedGeneration: row.observedGeneration,
                serverAddress: nil,
                bundleEndpointURL: row.bundleEndpointURL,
                nodeAddress: row.nodeAddress,
                orgBundlePEM: row.orgBundlePEM,
                lastError: row.lastError,
                deletedAt: row.deletedAt,
                on: app.db)

            let registry = try makeRegistry(on: app)
            // Handing back a bootstrap command with no address for the node to
            // attest against would be worse than refusing.
            await #expect(throws: (any Error).self) {
                _ = try await registry.resolve(scope: .organization(org), on: app.db)
            }
        }
    }

    // MARK: - Deprovisioning

    @Test("Deprovisioning resolves by trust domain, not by current organization")
    func deprovisionResolvesByTrustDomain() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            let row = try await makeReadyTrustDomain(on: app.db, organizationID: org)

            // Note the flags: deprovisioning must not consult them at all —
            // entries issued while the feature was on stay revocable after it
            // is switched off.
            let registry = try makeRegistry(
                on: app, orgTrustDomainsEnabled: false, legacyEnrollmentsAllowed: false)

            let platform = try await registry.service(forTrustDomain: Self.platformTrustDomain, on: app.db)
            #expect(platform?.trustDomain == Self.platformTrustDomain)

            let orgService = try await registry.service(forTrustDomain: row.trustDomain, on: app.db)
            #expect(orgService?.trustDomain == row.trustDomain)
        }
    }

    @Test("An unknown trust domain reports no instance rather than throwing")
    func deprovisionUnknownDomainReportsNoInstance() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let registry = try makeRegistry(on: app)
            // Distinct from "the server is unreachable": there is nothing to
            // retry, so the caller has to decide whether to proceed rather than
            // being handed an error that implies waiting will help. Returning
            // nil is what lets `?skipSpireDeprovision=true` work at all — see
            // AgentControllerDeprovisionTests.
            let service = try await registry.service(
                forTrustDomain: "org-deadbeefdeadbeef.platform.test", on: app.db)
            #expect(service == nil)
        }
    }

    @Test("A domain being torn down is still reachable for revocation")
    func deletingDomainStillRevocable() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            let row = try await makeReadyTrustDomain(on: app.db, organizationID: org)
            _ = try await OrgTrustDomainStore.updateState(
                id: row.id,
                phase: .deleting,
                generation: row.generation,
                observedGeneration: row.observedGeneration,
                serverAddress: row.serverAddress,
                bundleEndpointURL: row.bundleEndpointURL,
                nodeAddress: row.nodeAddress,
                orgBundlePEM: row.orgBundlePEM,
                lastError: row.lastError,
                deletedAt: row.deletedAt,
                on: app.db)

            let registry = try makeRegistry(on: app)
            // Teardown is exactly when entries most need removing, so the
            // stricter `acceptsIdentities` gate must not apply here.
            let service = try await registry.service(forTrustDomain: row.trustDomain, on: app.db)
            #expect(service?.trustDomain == row.trustDomain)
        }
    }

    @Test("Revocation does not require the node-attestation address it never uses")
    func revocationIgnoresServerAddress() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            let row = try await makeReadyTrustDomain(on: app.db, organizationID: org)
            // A half-provisioned or mid-teardown row: the reconciler never set,
            // or has already cleared, the address agents dial. That address only
            // ever feeds bootstrap commands, so demanding it here would fail
            // revocation for exactly the rows that most need it.
            _ = try await OrgTrustDomainStore.updateState(
                id: row.id,
                phase: .deleting,
                generation: row.generation,
                observedGeneration: row.observedGeneration,
                serverAddress: nil,
                bundleEndpointURL: row.bundleEndpointURL,
                nodeAddress: row.nodeAddress,
                orgBundlePEM: row.orgBundlePEM,
                lastError: row.lastError,
                deletedAt: row.deletedAt,
                on: app.db)

            let registry = try makeRegistry(on: app)
            let service = try await registry.service(forTrustDomain: row.trustDomain, on: app.db)
            #expect(service?.trustDomain == row.trustDomain)
        }
    }

    // MARK: - PEM splitting

    @Test("A concatenated PEM bundle splits into one string per certificate")
    func splitPEMSeparatesCertificates() {
        let two = Self.samplePEM + Self.samplePEM
        let split = OrgSPIREClientRegistry.splitPEM(two)
        #expect(split.count == 2)
        #expect(split.allSatisfy { $0.contains("-----BEGIN CERTIFICATE-----") })
        #expect(split.allSatisfy { $0.contains("-----END CERTIFICATE-----") })

        #expect(OrgSPIREClientRegistry.splitPEM("").isEmpty)
        #expect(OrgSPIREClientRegistry.splitPEM("not a certificate").isEmpty)
    }

    /// A syntactically valid PEM block. Nothing in these tests parses it as
    /// X.509 — no connection is ever made — so the payload is inert filler.
    private static let samplePEM = """
        -----BEGIN CERTIFICATE-----
        MIIBhTCCASugAwIBAgIQIRi6zePL6mKjOipn+dNuaTAKBggqhkjOPQQDAjASMRAw
        -----END CERTIFICATE-----

        """
}
