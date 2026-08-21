import Foundation
import SPIREServerAPI
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

/// Federation on the provisioned workload entry (issue #615).
///
/// `federatesWith` is what makes the node's Workload API hand the agent the
/// platform roots alongside its own — without it an org-domain agent holds
/// nothing that can verify the control plane, and fails every handshake.
@Suite("SPIRE Federation Reconciliation")
struct SPIREFederationReconcileTests {

    private func makeService(api: FakeSPIREServerAPI, trustDomain: String = "org-abc.strato.local")
        -> SPIRERegistrationService
    {
        SPIRERegistrationService(
            api: api,
            config: SPIRERegistrationConfig(
                trustDomain: trustDomain,
                serverAPIAddress: .tcp(host: "127.0.0.1", port: 1),
                serverPublicAddress: "spire-org.example.com:8085",
                agentSelectors: [SPIRESelector(type: "unix", value: "uid:0")],
                svidTTLSeconds: 1800
            ),
            logger: Logger(label: "test.spire-federation")
        )
    }

    @Test("A newly created entry carries the requested federation")
    func newEntryCarriesFederation() async throws {
        let api = FakeSPIREServerAPI()
        let service = makeService(api: api)

        let provisioning = try await service.provisionAgent(
            named: "hv-01", joinTokenTTLSeconds: 3600, federatesWith: ["strato.local"])

        let created = await api.createdEntries
        #expect(created.count == 1)
        #expect(created.first?.federatesWith == ["strato.local"])
        #expect(provisioning.federatesWith == ["strato.local"])

        // Nothing to reconcile: the create already carried it.
        let updates = await api.entryUpdates
        #expect(updates.isEmpty)
    }

    @Test("A reused entry has its federation reconciled rather than silently kept")
    func reusedEntryReconcilesFederation() async throws {
        let api = FakeSPIREServerAPI()
        // SPIRE identifies an entry by (spiffeID, parentID, selectors);
        // `federatesWith` is not part of that identity, so an entry predating
        // federation comes back as alreadyExists with its old — empty — set.
        await api.setEntryResult(.alreadyExists(entryID: "entry-existing"))
        let service = makeService(api: api)

        _ = try await service.provisionAgent(
            named: "hv-01", joinTokenTTLSeconds: 3600, federatesWith: ["strato.local"])

        let updates = await api.entryUpdates
        #expect(updates.count == 1)
        #expect(updates.first?.id == "entry-existing")
        #expect(updates.first?.federatesWith == ["strato.local"])
        // Only federation is touched; the rest of the entry is left alone.
        #expect(updates.first?.selectors == nil)
        #expect(updates.first?.spiffeID == nil)
    }

    @Test("A reused entry needs no reconciliation when nothing federates")
    func reusedEntryWithoutFederationIsUntouched() async throws {
        let api = FakeSPIREServerAPI()
        await api.setEntryResult(.alreadyExists(entryID: "entry-existing"))
        let service = makeService(api: api, trustDomain: "strato.local")

        // The single-trust-domain case: agent and control plane share a domain,
        // so there is nothing to federate and no update to make.
        _ = try await service.provisionAgent(named: "hv-01", joinTokenTTLSeconds: 3600)

        let updates = await api.entryUpdates
        #expect(updates.isEmpty)
    }

    @Test("Provisioning fails when federation cannot be reconciled")
    func failedReconciliationFailsProvisioning() async throws {
        let api = FakeSPIREServerAPI()
        await api.setEntryResult(.alreadyExists(entryID: "entry-existing"))
        await api.setFailEntryUpdates(true)
        let service = makeService(api: api)

        // Handing back a bootstrap command for an identity that cannot verify
        // the control plane would surface far from here, as an agent that
        // enrolls cleanly and then fails every handshake.
        await #expect(throws: (any Error).self) {
            _ = try await service.provisionAgent(
                named: "hv-01", joinTokenTTLSeconds: 3600, federatesWith: ["strato.local"])
        }
    }
}
