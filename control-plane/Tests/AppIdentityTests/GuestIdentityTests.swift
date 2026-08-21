import ControlPlanePostgres
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// A VM's SPIFFE instance identity (STR-55): how the URI is composed, which
/// trust domain it lands in, and that the row it writes really resolves to a
/// principal the authorizer understands.
@Suite("Guest Identity Tests", .serialized)
final class GuestIdentityTests {

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

    private func configuration(orgTrustDomainsEnabled: Bool) async throws
        -> ControlPlaneConfiguration
    {
        try await ControlPlaneConfiguration.load(
            environmentVariables: [
                "SPIRE_ORG_TRUST_DOMAINS_ENABLED": orgTrustDomainsEnabled ? "true" : "false"
            ],
            for: .testing)
    }

    @discardableResult
    private func claimTrustDomain(
        _ app: Application, organizationID: UUID, phase: OrgTrustDomainPhase, bundlePEM: String?
    ) async throws -> OrgTrustDomainRecord {
        try await OrgTrustDomainStore.insert(
            OrgTrustDomainWrite(
                organizationID: organizationID,
                trustDomain: OrgTrustDomain.trustDomain(
                    forOrganization: organizationID,
                    platformTrustDomain: PlatformTrustDomain.current),
                phase: phase,
                orgBundlePEM: bundlePEM),
            on: app.testPostgres)
    }

    // MARK: - Composition

    @Test("A VM's SPIFFE ID lowercases the id and keeps the trust domain verbatim")
    func compositionLowercasesTheID() {
        // Deliberately an uppercase literal: `UUID.uuidString` is uppercase, so
        // a test that fed in a lowercase id would pass whether or not the
        // lowercasing exists. The spelling is load-bearing — the URI is matched
        // by exact string when a JWT-SVID's `sub` comes back in.
        let vmID = UUID(uuidString: "3F2A91C0-4B7D-4E5F-8A1B-2C3D4E5F6A7B")!

        #expect(GuestIdentity.path(forVM: vmID) == "/vm/3f2a91c0-4b7d-4e5f-8a1b-2c3d4e5f6a7b")
        #expect(
            GuestIdentity.spiffeID(forVM: vmID, trustDomain: "strato.local")
                == "spiffe://strato.local/vm/3f2a91c0-4b7d-4e5f-8a1b-2c3d4e5f6a7b")
    }

    @Test("A composed identity round-trips through SPIFFEIdentity and is not an agent")
    func compositionRoundTrips() throws {
        let vmID = UUID()
        let uri = GuestIdentity.spiffeID(forVM: vmID, trustDomain: "org-abc.strato.local")

        let parsed = try #require(SPIFFEIdentity(uri: uri))
        #expect(parsed.trustDomain == "org-abc.strato.local")
        #expect(parsed.path == "/vm/\(vmID.uuidString.lowercased())")
        // The reserved namespace a VM must never land in.
        #expect(!parsed.isAgent)
    }

    // MARK: - Trust domain resolution

    @Test("With the feature flag off, an active org domain is still not used")
    func flagOffFallsBackToPlatform() async throws {
        try await withApp { app in
            let orgID = UUID()
            let row = try await claimTrustDomain(
                app, organizationID: orgID, phase: .active, bundlePEM: "-----BEGIN CERTIFICATE-----")

            let configuration = try await self.configuration(orgTrustDomainsEnabled: false)
            // The row exists and would qualify — the flag alone keeps the
            // multi-domain path dormant, which is the whole point of phase 2.
            let resolved = try await GuestIdentity.trustDomain(
                forOrganization: orgID, configuration: configuration, on: app.testPostgres)
            #expect(resolved == PlatformTrustDomain.current)
            #expect(resolved != row.trustDomain)
        }
    }

    @Test("With the flag on, an active org domain holding a bundle is used")
    func flagOnUsesActiveOrgDomain() async throws {
        try await withApp { app in
            let configuration = try await self.configuration(orgTrustDomainsEnabled: true)
            let orgID = UUID()
            let row = try await claimTrustDomain(
                app, organizationID: orgID, phase: .active,
                bundlePEM: "-----BEGIN CERTIFICATE-----")

            let resolved = try await GuestIdentity.trustDomain(
                forOrganization: orgID, configuration: configuration, on: app.testPostgres)
            #expect(resolved == row.trustDomain)
        }
    }

    @Test("An active domain with no cached bundle falls back to the platform")
    func activeWithoutBundleFallsBack() async throws {
        try await withApp { app in
            let configuration = try await self.configuration(orgTrustDomainsEnabled: true)
            let orgID = UUID()
            // `acceptsIdentities` demands the bundle: the control plane
            // holds no roots for this domain, so it would refuse an SVID
            // minted into it. Minting one anyway is the mistake this guards.
            try await claimTrustDomain(
                app, organizationID: orgID, phase: .active, bundlePEM: nil)

            let resolved = try await GuestIdentity.trustDomain(
                forOrganization: orgID, configuration: configuration, on: app.testPostgres)
            #expect(resolved == PlatformTrustDomain.current)
        }
    }

    @Test("A domain that is not active falls back to the platform, whatever its phase")
    func nonActivePhasesFallBack() async throws {
        try await withApp { app in
            let configuration = try await self.configuration(orgTrustDomainsEnabled: true)
            for phase in [OrgTrustDomainPhase.pending, .provisioning, .failed, .deleting] {
                let orgID = UUID()
                try await claimTrustDomain(
                    app, organizationID: orgID, phase: phase,
                    bundlePEM: "-----BEGIN CERTIFICATE-----")

                let resolved = try await GuestIdentity.trustDomain(
                    forOrganization: orgID, configuration: configuration, on: app.testPostgres)
                #expect(resolved == PlatformTrustDomain.current, "phase \(phase.rawValue)")
            }
        }
    }

    @Test("A VM in no organization gets the platform trust domain")
    func noOrganizationUsesPlatform() async throws {
        try await withApp { app in
            let configuration = try await self.configuration(orgTrustDomainsEnabled: true)
            let resolved = try await GuestIdentity.trustDomain(
                forOrganization: nil, configuration: configuration, on: app.testPostgres)
            #expect(resolved == PlatformTrustDomain.current)
        }
    }

    // MARK: - Registration

    @Test("A registered VM resolves to a workload principal through the registry")
    func registrationResolvesToAWorkloadPrincipal() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "Guest Identity Org")
            let project = try await builder.createProject(
                name: "Guest Identity Project", description: "d", organization: org)
            let vm = try await builder.createVM(name: "identified-vm", project: project)
            let vmID = try vm.requireID()
            let orgID = try org.requireID()

            let registration = try await GuestIdentity.register(
                vmID: vmID, organizationID: orgID, createdBy: nil, on: app.testPostgres)
            let registrationID = registration.id

            #expect(registration.kind == .workload)
            #expect(registration.vmID == vmID)
            #expect(registration.organizationID == orgID)
            #expect(
                registration.spiffeID
                    == GuestIdentity.spiffeID(
                        forVM: vmID, trustDomain: PlatformTrustDomain.current))

            // The registry — not any parsing of the URI — is what turns the
            // identity into a principal.
            let resolved = try await WorkloadRegistry.resolve(
                spiffeID: registration.spiffeID, on: app.testPostgres)
            #expect(resolved == .workload(id: registrationID))
            #expect(resolved?.principal == IAMPrincipal.workload(registrationID))

            // The batched lookup the sync assembly and the VM list use.
            let batched = try await GuestIdentity.spiffeIDs(forVMs: [vmID], on: app.testPostgres)
            #expect(batched[vmID] == registration.spiffeID)
            #expect(try await GuestIdentity.spiffeID(forVM: vmID, on: app.testPostgres) == registration.spiffeID)
        }
    }

    @Test("An unregistered VM has no identity, and the empty batch asks nothing")
    func unregisteredVMHasNoIdentity() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "Unregistered Org")
            let project = try await builder.createProject(
                name: "Unregistered Project", description: "d", organization: org)
            let vm = try await builder.createVM(name: "anonymous-vm", project: project)

            #expect(try await GuestIdentity.spiffeID(forVM: vm.requireID(), on: app.testPostgres) == nil)
            #expect(try await GuestIdentity.spiffeIDs(forVMs: [], on: app.testPostgres).isEmpty)
        }
    }

    @Test("An org-less registration is external to every organization")
    func orgLessRegistrationIsExternal() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "Gate Org")
            let project = try await builder.createProject(
                name: "Gate Project", description: "d", organization: org)
            let vm = try await builder.createVM(name: "orgless-vm", project: project)

            // The defensive shape, not a reachable one: `Project.validate()`
            // refuses a project belonging to neither an organization nor a
            // folder, and both create routes are nested under an organization,
            // so `getRootOrganizationId` does not return nil in practice. It is
            // typed `UUID?` though, and STR-55 writes whatever it returns — so
            // pin what a NULL-org registration means before someone rediscovers
            // it as a bug.
            let registration = try await GuestIdentity.register(
                vmID: try vm.requireID(), organizationID: nil, createdBy: nil, on: app.testPostgres)
            #expect(registration.organizationID == nil)

            // External, so binding a role to it needs `iam:grantExternal` — the
            // safe default, and the same answer any org-less workload row has
            // always got: a principal that cannot be placed must not slip past
            // the gate.
            let external = try await CrossOrgBindingGate.isExternal(
                principalType: .workload, principalID: registration.id,
                organizationID: try org.requireID(), on: app.testPostgres)
            #expect(external)
        }
    }

    @Test("A VM cannot hold two identities")
    func oneRegistrationPerVM() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let org = try await builder.createOrganization(name: "Single Identity Org")
            let project = try await builder.createProject(
                name: "Single Identity Project", description: "d", organization: org)
            let vm = try await builder.createVM(name: "single-identity-vm", project: project)
            let vmID = try vm.requireID()
            let orgID = try org.requireID()

            try await GuestIdentity.register(
                vmID: vmID, organizationID: orgID, createdBy: nil, on: app.testPostgres)

            // A *distinct* SPIFFE ID on the same VM, so the `spiffe_id` index
            // cannot be what refuses it: two rows would give one VM two
            // principals and make the batched lookup non-deterministic about
            // which one the guest is told it is. The partial unique index on
            // `vm_id` is what forbids that, and this is the only assertion that
            // proves the index is really unique rather than merely present.
            await #expect(throws: (any Error).self) {
                _ = try await LegacyWorkloadRegistrationStore.insert(
                    WorkloadRegistrationWrite(
                        spiffeID:
                            "spiffe://\(PlatformTrustDomain.current)/vm/\(UUID().uuidString.lowercased())",
                        kind: WorkloadRegistrationKind.workload.rawValue,
                        organizationID: orgID,
                        vmID: vmID),
                    on: app.testPostgres)
            }
        }
    }
}
