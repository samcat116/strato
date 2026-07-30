import Fluent
import Foundation
import SPIREServerAPI
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Enrollment against the owning organization's SPIRE instance (issue #615).
///
/// The registry is what decides *which* trust domain a node is provisioned in,
/// so these lock down both directions: that the platform domain stays the
/// answer everywhere it used to be, and that a ready organization domain takes
/// over — carrying the federation and the explicit control-plane pin an
/// org-domain agent cannot derive for itself.
@Suite("Org SPIRE Client Registry", .serialized)
final class OrgSPIREClientRegistryTests {

    private static let platformTrustDomain = "strato.local"

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
        trustDomain: String = "org-0123456789abcdef.strato.local"
    ) async throws -> OrgTrustDomain {
        let row = OrgTrustDomain(organizationID: organizationID, trustDomain: trustDomain, phase: .active)
        row.nodeAddress = "spire-org.example.com:8081"
        row.serverAddress = "spire-org.example.com:8085"
        row.orgBundlePEM = Self.samplePEM
        try await row.save(on: db)
        return row
    }

    /// Runs `body` with the per-org trust domain feature flag on. The flag is
    /// read from the environment on each access and the suite is `.serialized`,
    /// so toggling in-process is safe.
    private func withFeatureFlagOn<T>(_ body: () async throws -> T) async rethrows -> T {
        let previous = ProcessInfo.processInfo.environment["SPIRE_ORG_TRUST_DOMAINS_ENABLED"]
        setenv("SPIRE_ORG_TRUST_DOMAINS_ENABLED", "true", 1)
        defer {
            if let previous {
                setenv("SPIRE_ORG_TRUST_DOMAINS_ENABLED", previous, 1)
            } else {
                unsetenv("SPIRE_ORG_TRUST_DOMAINS_ENABLED")
            }
        }
        return try await body()
    }

    private func withLegacyEnrollments<T>(_ allowed: Bool, _ body: () async throws -> T) async rethrows -> T {
        let previous = ProcessInfo.processInfo.environment["SPIRE_LEGACY_ENROLLMENTS"]
        setenv("SPIRE_LEGACY_ENROLLMENTS", allowed ? "true" : "false", 1)
        defer {
            if let previous {
                setenv("SPIRE_LEGACY_ENROLLMENTS", previous, 1)
            } else {
                unsetenv("SPIRE_LEGACY_ENROLLMENTS")
            }
        }
        return try await body()
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

            let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
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

            try await withFeatureFlagOn {
                let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
                let selection = try await registry.resolve(scope: .organization(org), on: app.db)
                #expect(selection.service.trustDomain == Self.platformTrustDomain)
                #expect(selection.federatesWith.isEmpty)
                guard case .noTrustDomainClaimed = selection.platformFallback else {
                    Issue.record("expected a no-trust-domain-claimed fallback")
                    return
                }
            }
        }
    }

    @Test("A claimed but unprovisioned domain falls back while legacy enrollments are allowed")
    func pendingDomainFallsBack() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            // Claimed by org creation, not yet converged by the reconciler.
            let row = OrgTrustDomain(
                organizationID: org, trustDomain: "org-0123456789abcdef.strato.local")
            try await row.save(on: app.db)

            try await withFeatureFlagOn {
                try await withLegacyEnrollments(true) {
                    let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
                    let selection = try await registry.resolve(scope: .organization(org), on: app.db)
                    #expect(selection.service.trustDomain == Self.platformTrustDomain)
                    guard case .trustDomainNotReady = selection.platformFallback else {
                        Issue.record("expected a trust-domain-not-ready fallback")
                        return
                    }
                }
            }
        }
    }

    @Test("A claimed but unprovisioned domain is refused once legacy enrollments are off")
    func pendingDomainRefusedWithoutLegacy() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            let row = OrgTrustDomain(
                organizationID: org, trustDomain: "org-0123456789abcdef.strato.local")
            try await row.save(on: app.db)

            try await withFeatureFlagOn {
                try await withLegacyEnrollments(false) {
                    let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
                    await #expect(throws: (any Error).self) {
                        _ = try await registry.resolve(scope: .organization(org), on: app.db)
                    }
                }
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
            let row = OrgTrustDomain(
                organizationID: org, trustDomain: "org-0123456789abcdef.strato.local", phase: .active)
            row.nodeAddress = "spire-org.example.com:8081"
            row.serverAddress = "spire-org.example.com:8085"
            try await row.save(on: app.db)

            try await withFeatureFlagOn {
                try await withLegacyEnrollments(false) {
                    let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
                    await #expect(throws: (any Error).self) {
                        _ = try await registry.resolve(scope: .organization(org), on: app.db)
                    }
                }
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

            try await withFeatureFlagOn {
                let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
                let selection = try await registry.resolve(scope: .organization(org), on: app.db)

                #expect(selection.platformFallback == nil)
                #expect(selection.service.trustDomain == row.trustDomain)
                // Without this the agent's Workload API hands it only its own
                // domain's roots and it can never verify the control plane.
                #expect(selection.federatesWith == [Self.platformTrustDomain])
                // Agents dial the org's node API, not the platform server's.
                #expect(
                    selection.service.agentSPIFFEID(agentName: "hv-01") == "spiffe://\(row.trustDomain)/agent/hv-01")
                // The control plane stays in the platform domain regardless.
                #expect(selection.controlPlaneSPIFFEID == "spiffe://\(Self.platformTrustDomain)/control-plane")
            }
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

            try await withFeatureFlagOn {
                let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
                let selection = try await registry.resolve(
                    scope: .organizationalUnit(folderID), on: app.db)
                // A folder has no CA of its own — capacity delegated to it is
                // still the organization's tenancy.
                #expect(selection.service.trustDomain == row.trustDomain)
                #expect(selection.platformFallback == nil)
            }
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

            try await withFeatureFlagOn {
                let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
                await #expect(throws: (any Error).self) {
                    _ = try await registry.resolve(scope: .organization(org), on: app.db)
                }
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

            let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))

            // The platform domain resolves to the platform service...
            let platform = try await registry.service(
                forTrustDomain: Self.platformTrustDomain, on: app.db)
            #expect(platform.trustDomain == Self.platformTrustDomain)

            // ...and an org domain to that org's instance, so a revocation
            // reaches the server that actually issued the identity. Note this
            // does not consult the feature flag: entries issued while it was on
            // must stay revocable after it is switched off.
            let orgService = try await registry.service(forTrustDomain: row.trustDomain, on: app.db)
            #expect(orgService.trustDomain == row.trustDomain)
        }
    }

    @Test("Deprovisioning an unknown trust domain fails closed")
    func deprovisionUnknownDomainFailsClosed() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
            // Reporting success here would tell an operator a node was revoked
            // when nothing was removed anywhere.
            await #expect(throws: (any Error).self) {
                _ = try await registry.service(
                    forTrustDomain: "org-deadbeefdeadbeef.strato.local", on: app.db)
            }
        }
    }

    @Test("A domain being torn down is still reachable for revocation")
    func deletingDomainStillRevocable() async throws {
        try await withApp { app in
            installPlatformSPIRE(on: app)
            let org = try await makeOrg(on: app.db)
            let row = try await makeReadyTrustDomain(on: app.db, organizationID: org)
            row.phase = .deleting
            try await row.save(on: app.db)

            let registry = try #require(OrgSPIREClientRegistry.fromApplication(app))
            // Teardown is exactly when entries most need removing, so the
            // stricter `acceptsIdentities` gate must not apply here.
            let service = try await registry.service(forTrustDomain: row.trustDomain, on: app.db)
            #expect(service.trustDomain == row.trustDomain)
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
