import Foundation
import PostgresNIO
import Testing

@testable import ControlPlanePostgres

@Suite("Native workload persistence", .serialized)
struct WorkloadsPersistenceTests {
    @Test("registration lifecycle preserves filters, uniqueness, and scoped deletion")
    func registrationLifecycle() async throws {
        try await withWorkloadDatabase { _, workloads in
            let organizationID = UUID()
            let serviceAccountID = UUID()
            let vmID = UUID()
            let creatorID = UUID()
            let vmRegistration = WorkloadRegistrationWrite(
                spiffeID: "spiffe://strato.test/vm/\(vmID)",
                kind: "workload",
                organizationID: organizationID,
                createdBy: creatorID,
                vmID: vmID)
            let serviceAccountRegistration = WorkloadRegistrationWrite(
                spiffeID: "spiffe://strato.test/service-account/\(serviceAccountID)",
                kind: "service_account",
                serviceAccountID: serviceAccountID,
                displayName: "build worker")

            let createdVM = try await workloads.createRegistration(vmRegistration)
            let createdAccount = try await workloads.createRegistration(serviceAccountRegistration)
            #expect(createdVM.id == vmRegistration.id)
            #expect(createdVM.organizationID == organizationID)
            #expect(createdVM.createdBy == creatorID)
            #expect(createdVM.vmID == vmID)
            #expect(createdVM.createdAt != nil)
            #expect(createdAccount.displayName == "build worker")

            #expect(try await workloads.registration(id: createdVM.id) == createdVM)
            #expect(
                try await workloads.registration(spiffeID: createdAccount.spiffeID)
                    == createdAccount)
            #expect(
                try await workloads.registrations(kind: "workload", vmOwned: true)
                    == [createdVM])
            #expect(
                try await workloads.registrations(serviceAccountID: serviceAccountID)
                    == [createdAccount])
            #expect(try await workloads.registrations(vmIDs: [vmID]) == [createdVM])

            await #expect(
                throws: WorkloadsPersistenceError.duplicateSPIFFEID(vmRegistration.spiffeID)
            ) {
                try await workloads.createRegistration(
                    WorkloadRegistrationWrite(
                        spiffeID: vmRegistration.spiffeID,
                        kind: "workload"))
            }

            #expect(
                try await workloads.deleteRegistration(
                    id: createdAccount.id, serviceAccountID: UUID()) == false)
            #expect(
                try await workloads.deleteRegistration(
                    id: createdAccount.id, serviceAccountID: serviceAccountID))
            #expect(try await workloads.registration(id: createdAccount.id) == nil)
        }
    }

    @Test("claim batches preserve lifecycle and filtering semantics")
    func claimLifecycle() async throws {
        try await withWorkloadDatabase { database, workloads in
            let first = WorkloadClaimWrite(
                agentID: "agent-a",
                resourceKind: "virtual_machine",
                resourceID: UUID(),
                disposition: .tombstoned,
                tombstoneGeneration: 8,
                observedGeneration: 7,
                observedStatus: "running")
            let second = WorkloadClaimWrite(
                agentID: "agent-a",
                resourceKind: "sandbox",
                resourceID: UUID(),
                disposition: .held,
                reason: "row_present_here",
                observedGeneration: 3)

            try await workloads.insertClaims([first, second])
            #expect(try await workloads.countClaims(agentID: "agent-a") == 2)
            #expect(try await workloads.claims(agentID: "agent-a", disposition: .held).count == 1)

            try await workloads.updateClaim(
                id: second.id,
                disposition: .held,
                tombstoneGeneration: nil,
                reason: "row_on_agent:source",
                observedGeneration: 4,
                observedStatus: "paused")
            let updated = try #require(
                try await workloads.claims(agentID: "agent-a").first { $0.id == second.id })
            #expect(updated.placedOnAgentID == "source")
            #expect(updated.observedGeneration == 4)
            #expect(updated.lastSeenAt != nil)

            #expect(try await workloads.deleteClaims(ids: [first.id]) == [first.id])
            #expect(try await workloads.countClaims(agentID: "agent-a") == 1)

            _ = database
        }
    }

    @Test("adoption commits placements, replica deduplication, and claim consumption together")
    func adoption() async throws {
        try await withWorkloadDatabase { database, workloads in
            let source = UUID().uuidString
            let target = UUID().uuidString
            let claimedVM = UUID()
            let skippedVM = UUID()
            let claimedSandbox = UUID()
            let skippedSandbox = UUID()
            let detachedVolume = UUID()
            let attachedVolume = UUID()
            let heldVolume = UUID()
            let replicatedVolume = UUID()

            _ = try await database.withSession(operation: "test.workloads.seed") { session in
                try await session.command(
                    """
                    INSERT INTO vms (id, hypervisor_id) VALUES
                        ('\(claimedVM)', '\(source)'), ('\(skippedVM)', '\(source)');
                    INSERT INTO sandboxes (id, hypervisor_id) VALUES
                        ('\(claimedSandbox)', '\(source)'), ('\(skippedSandbox)', '\(source)');
                    INSERT INTO volumes (id, vm_id, attached_agent_id) VALUES
                        ('\(detachedVolume)', NULL, NULL),
                        ('\(attachedVolume)', '\(claimedVM)', '\(source)'),
                        ('\(heldVolume)', '\(skippedVM)', '\(source)'),
                        ('\(replicatedVolume)', NULL, NULL);
                    INSERT INTO volume_replicas (id, volume_id, agent_id) VALUES
                        ('\(UUID())', '\(detachedVolume)', '\(source)'),
                        ('\(UUID())', '\(attachedVolume)', '\(source)'),
                        ('\(UUID())', '\(heldVolume)', '\(source)'),
                        ('\(UUID())', '\(replicatedVolume)', '\(source)'),
                        ('\(UUID())', '\(replicatedVolume)', '\(target)')
                    """,
                    operation: "test.workloads.seed.rows")
            }

            let evidence = [
                WorkloadClaimWrite(
                    agentID: target,
                    resourceKind: "virtual_machine",
                    resourceID: claimedVM,
                    disposition: .held,
                    reason: "row_on_agent:\(source)",
                    observedGeneration: 1),
                WorkloadClaimWrite(
                    agentID: target,
                    resourceKind: "sandbox",
                    resourceID: claimedSandbox,
                    disposition: .held,
                    reason: "row_on_agent:\(source)",
                    observedGeneration: 1),
                WorkloadClaimWrite(
                    agentID: target,
                    resourceKind: "volume",
                    resourceID: detachedVolume,
                    disposition: .held,
                    reason: "row_on_agent:\(source)",
                    observedGeneration: 1),
            ]
            try await workloads.insertClaims(evidence)

            let result = try await workloads.adoptWorkloads(
                targetAgentID: target, sourceAgentID: source)
            #expect(result == WorkloadAdoptionResult(
                adoptedVMs: 1,
                adoptedSandboxes: 1,
                adoptedVolumes: 3,
                skippedUnclaimed: 2))
            #expect(try await workloads.claims(agentID: target).isEmpty)

            let facts = try await database.withSession(operation: "test.workloads.facts") { session in
                try #require(
                    try await session.execute(
                        AdoptionFacts(
                            claimedVM: claimedVM,
                            skippedVM: skippedVM,
                            claimedSandbox: claimedSandbox,
                            skippedSandbox: skippedSandbox,
                            attachedVolume: attachedVolume,
                            heldVolume: heldVolume,
                            replicatedVolume: replicatedVolume,
                            source: source,
                            target: target),
                        operation: "test.workloads.facts.query").first)
            }
            #expect(facts.claimedVM == target)
            #expect(facts.skippedVM == source)
            #expect(facts.claimedSandbox == target)
            #expect(facts.skippedSandbox == source)
            #expect(facts.attachedVolume == target)
            #expect(facts.heldVolume == source)
            #expect(facts.replicatedSourceCount == 0)
            #expect(facts.replicatedTargetCount == 1)
        }
    }

    @Test("adoption without matching evidence changes nothing")
    func noEvidence() async throws {
        try await withWorkloadDatabase { _, workloads in
            await #expect(throws: WorkloadsPersistenceError.noMatchingClaims) {
                try await workloads.adoptWorkloads(
                    targetAgentID: UUID().uuidString,
                    sourceAgentID: UUID().uuidString)
            }
        }
    }

    @Test("guest-observed interface addresses replace and delete atomically")
    func observedInterfaceAddresses() async throws {
        try await withWorkloadDatabase { database, workloads in
            let interfaceID = UUID()
            _ = try await database.withSession(operation: "test.workloads.observed.seed") { session in
                try await session.command(
                    "INSERT INTO vm_network_interfaces (id) VALUES ('\(interfaceID)')",
                    operation: "test.workloads.observed.seed.query")
            }

            try await workloads.replaceObservedInterfaceAddresses(
                interfaceID: interfaceID,
                addresses: [
                    .init(family: "ipv4", address: "192.0.2.10", prefixLength: 24),
                    .init(family: "ipv6", address: "2001:db8::10", prefixLength: 64),
                ])
            var rows = try await workloads.observedInterfaceAddresses(interfaceIDs: [interfaceID])
            #expect(rows.map(\.address) == ["192.0.2.10", "2001:db8::10"])
            #expect(rows.allSatisfy { $0.createdAt != nil && $0.updatedAt != nil })

            try await workloads.replaceObservedInterfaceAddresses(
                interfaceID: interfaceID,
                addresses: [.init(family: "ipv4", address: "192.0.2.11", prefixLength: 25)])
            rows = try await workloads.observedInterfaceAddresses(interfaceIDs: [interfaceID])
            #expect(rows.map(\.address) == ["192.0.2.11"])
            #expect(try await workloads.deleteObservedInterfaceAddresses(
                interfaceIDs: [interfaceID]).count == 1)
            #expect(try await workloads.observedInterfaceAddresses(
                interfaceIDs: [interfaceID]).isEmpty)
        }
    }

    private func withWorkloadDatabase(
        _ test: (ControlPlanePostgres.PostgresDatabase, WorkloadsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            _ = try await database.withSession(operation: "test.workloads.schema") { session in
                try await session.command(
                    """
                    CREATE TYPE workload_registration_kind AS ENUM (
                        'agent', 'service_account', 'workload'
                    );
                    CREATE TABLE workload_registrations (
                        id UUID PRIMARY KEY,
                        spiffe_id TEXT NOT NULL,
                        kind workload_registration_kind NOT NULL,
                        agent_name TEXT,
                        service_account_id UUID,
                        organization_id UUID,
                        display_name TEXT,
                        created_by UUID,
                        created_at TIMESTAMPTZ,
                        vm_id UUID,
                        CONSTRAINT "uq:workload_registrations.spiffe_id" UNIQUE (spiffe_id)
                    );
                    CREATE TABLE agent_workload_claims (
                        id UUID PRIMARY KEY,
                        agent_id TEXT NOT NULL,
                        resource_kind TEXT NOT NULL,
                        resource_id UUID NOT NULL,
                        disposition TEXT NOT NULL CHECK (disposition IN ('tombstoned', 'held')),
                        tombstone_generation BIGINT,
                        reason TEXT,
                        observed_generation BIGINT NOT NULL DEFAULT 0,
                        observed_status TEXT,
                        first_seen_at TIMESTAMPTZ,
                        last_seen_at TIMESTAMPTZ,
                        UNIQUE (agent_id, resource_kind, resource_id)
                    );
                    CREATE TABLE vms (
                        id UUID PRIMARY KEY, hypervisor_id TEXT, updated_at TIMESTAMPTZ
                    );
                    CREATE TABLE sandboxes (
                        id UUID PRIMARY KEY, hypervisor_id TEXT, updated_at TIMESTAMPTZ
                    );
                    CREATE TABLE volumes (
                        id UUID PRIMARY KEY, vm_id UUID, attached_agent_id TEXT, updated_at TIMESTAMPTZ
                    );
                    CREATE TABLE volume_replicas (
                        id UUID PRIMARY KEY,
                        volume_id UUID NOT NULL,
                        agent_id TEXT NOT NULL,
                        updated_at TIMESTAMPTZ,
                        UNIQUE (volume_id, agent_id)
                    );
                    CREATE TABLE vm_network_interfaces (
                        id UUID PRIMARY KEY
                    );
                    CREATE TABLE vm_interface_observed_addresses (
                        id UUID PRIMARY KEY,
                        interface_id UUID NOT NULL REFERENCES vm_network_interfaces(id) ON DELETE CASCADE,
                        family TEXT NOT NULL,
                        address TEXT NOT NULL,
                        prefix_length INTEGER,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ,
                        UNIQUE (interface_id, family, address)
                    )
                    """,
                    operation: "test.workloads.schema.create")
            }
            try await test(database, ControlPlanePersistence(database: database).workloads)
        }
    }
}

private struct AdoptionFactSnapshot: Sendable {
    let claimedVM: String?
    let skippedVM: String?
    let claimedSandbox: String?
    let skippedSandbox: String?
    let attachedVolume: String?
    let heldVolume: String?
    let replicatedSourceCount: Int
    let replicatedTargetCount: Int
}

private struct AdoptionFacts: PostgresPreparedStatement {
    static let sql = """
        SELECT
            (SELECT hypervisor_id FROM vms WHERE id = $1),
            (SELECT hypervisor_id FROM vms WHERE id = $2),
            (SELECT hypervisor_id FROM sandboxes WHERE id = $3),
            (SELECT hypervisor_id FROM sandboxes WHERE id = $4),
            (SELECT attached_agent_id FROM volumes WHERE id = $5),
            (SELECT attached_agent_id FROM volumes WHERE id = $6),
            (SELECT count(*)::bigint FROM volume_replicas WHERE volume_id = $7 AND agent_id = $8),
            (SELECT count(*)::bigint FROM volume_replicas WHERE volume_id = $7 AND agent_id = $9)
        """
    typealias Row = AdoptionFactSnapshot
    let claimedVM: UUID
    let skippedVM: UUID
    let claimedSandbox: UUID
    let skippedSandbox: UUID
    let attachedVolume: UUID
    let heldVolume: UUID
    let replicatedVolume: UUID
    let source: String
    let target: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 9)
        bindings.append(claimedVM); bindings.append(skippedVM)
        bindings.append(claimedSandbox); bindings.append(skippedSandbox)
        bindings.append(attachedVolume); bindings.append(heldVolume)
        bindings.append(replicatedVolume); bindings.append(source); bindings.append(target)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> AdoptionFactSnapshot {
        let value = try row.decode((String?, String?, String?, String?, String?, String?, Int, Int).self)
        return AdoptionFactSnapshot(
            claimedVM: value.0,
            skippedVM: value.1,
            claimedSandbox: value.2,
            skippedSandbox: value.3,
            attachedVolume: value.4,
            heldVolume: value.5,
            replicatedSourceCount: value.6,
            replicatedTargetCount: value.7)
    }
}
