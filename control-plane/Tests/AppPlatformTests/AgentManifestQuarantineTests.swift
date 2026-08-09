import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport

@testable import App

/// STR-138: what the control plane does with a report from an agent that
/// cannot read its own workload manifest.
///
/// The manifest is the agent's only memory of what it is running, so an agent
/// that cannot read it has no inventory to send. The lists on such a report are
/// empty because the host's contents are unknown — not because it is idle — and
/// every absence-driven path here would otherwise act on that emptiness as
/// fact: a VM whose desired state is `.absent` would have its deletion
/// "confirmed" while the guest is still running, and a live VM would be
/// escalated to `.error`.
@Suite("Agent Manifest Quarantine Tests", .serialized)
final class AgentManifestQuarantineTests {

    private func withQuarantineApp(
        _ test: (Application, TestDataBuilder, Organization, Project) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "manifestadmin",
                email: "manifest@example.com",
                displayName: "Manifest Admin",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Manifest Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)
            let project = try await builder.createProject(
                name: "Manifest Project", description: "STR-138", organization: org)

            try await test(app, builder, org, project)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func makeAgent(app: Application, org: Organization, name: String) async throws -> Agent {
        let agent = Agent(
            name: name,
            hostname: "\(name).example",
            version: "1.0.0",
            capabilities: ["qemu"],
            status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000_000_000, availableMemory: 16_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 100_000_000_000
            ),
            architecture: .x86_64,
            lastHeartbeat: Date()
        )
        agent.wireProtocolVersion = WireProtocol.currentVersion
        agent.organizationScope = .organization(try org.requireID())
        try await agent.save(on: app.db)
        return agent
    }

    /// A report from a blind agent: no workloads, and a manifest status that
    /// says the lists are not an inventory. This is exactly what the agent
    /// sends while quarantined — the condition and the (zeroed) resources are
    /// its entire useful content.
    private func blindReport(agentId: String) -> ObservedStateReport {
        ObservedStateReport(
            agentId: agentId,
            vms: [],
            resources: AgentResources(
                totalCPU: 8, availableCPU: 0,
                totalMemory: 16_000_000_000, availableMemory: 0,
                totalDisk: 100_000_000_000, availableDisk: 0
            ),
            manifestStatus: ObservedManifestStatus(
                inventoryComplete: false,
                quarantinedEntries: 0,
                reason: "Workload manifest at /var/lib/strato/vm-manifest.json is not a readable manifest object."
            )
        )
    }

    private func healthyReport(
        agentId: String,
        vms: [ObservedVMState] = [],
        manifestStatus: ObservedManifestStatus? = nil
    ) -> ObservedStateReport {
        ObservedStateReport(
            agentId: agentId,
            vms: vms,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 6,
                totalMemory: 16_000_000_000, availableMemory: 8_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 50_000_000_000
            ),
            manifestStatus: manifestStatus
        )
    }

    // MARK: - A blind report confirms nothing

    @Test("A blind report does not confirm a deletion the agent never performed")
    func blindReportDoesNotReapATerminatingVM() async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "mq-agent")
            let agentId = try agent.requireID().uuidString

            let vm = try await builder.createVM(name: "deleting-vm", project: project)
            let vmID = try vm.requireID()
            vm.hypervisorId = agentId
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)

            _ = try await app.observedStateApplier.apply(self.blindReport(agentId: agentId))

            // The guest may well still be running: the agent never got far
            // enough to tear anything down. Reaping the row here loses the
            // only record that it exists.
            let survivor = try #require(try await VM.find(vmID, on: app.db))
            #expect(survivor.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
        }
    }

    @Test("A blind report does not escalate a running VM to error")
    func blindReportDoesNotEscalateALiveVM() async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "mq-agent")
            let agentId = try agent.requireID().uuidString

            let vm = try await builder.createVM(name: "live-vm", project: project)
            let vmID = try vm.requireID()
            vm.hypervisorId = agentId
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            _ = try await app.observedStateApplier.apply(self.blindReport(agentId: agentId))

            let unchanged = try #require(try await VM.find(vmID, on: app.db))
            #expect(unchanged.status == .running)
        }
    }

    @Test("A blind report decides nothing about workloads the agent holds")
    func blindReportRecordsNoClaims() async throws {
        try await withQuarantineApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "mq-agent")
            let agentId = try agent.requireID().uuidString

            let outcome = try await app.observedStateApplier.apply(self.blindReport(agentId: agentId))
            #expect(!outcome.authorizedTeardown)

            // No claims either way: a host that cannot see itself cannot tell
            // the control plane that anything is a stray.
            let claims = try await AgentWorkloadClaim.query(on: app.db)
                .filter(\.$agentId == agentId)
                .all()
            #expect(claims.isEmpty)
        }
    }

    // MARK: - The condition on the row

    @Test("An unreadable manifest lands on the agent row and clears when it recovers")
    func manifestStatusRoundTrip() async throws {
        try await withQuarantineApp { app, _, org, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "mq-agent")
            let agentId = try agent.requireID().uuidString

            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: self.blindReport(agentId: agentId)),
                fromAgentKey: agent.identity.key)

            var row = try #require(await Agent.find(agent.id, on: app.db))
            #expect(row.manifestInventoryComplete == false)
            #expect(row.manifestStatusReason?.contains("not a readable manifest object") == true)
            #expect(row.manifestStatusAt != nil)
            // The quarantined host advertises nothing, so the scheduler stops
            // choosing it — that half rides on the resource snapshot, which a
            // blind report still carries.
            #expect(row.availableCPU == 0)
            #expect(row.availableMemory == 0)

            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: self.healthyReport(agentId: agentId)),
                fromAgentKey: agent.identity.key)

            row = try #require(await Agent.find(agent.id, on: app.db))
            #expect(row.manifestStatusReason == nil)
            #expect(row.manifestStatusAt == nil)
            #expect(row.manifestInventoryComplete == nil)
        }
    }

    @Test("Unroutable entries are surfaced without suspending the inventory")
    func partialQuarantineStillAppliesTheInventory() async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "mq-agent")
            let agentId = try agent.requireID().uuidString

            let vm = try await builder.createVM(name: "gone-vm", project: project)
            let vmID = try vm.requireID()
            vm.hypervisorId = agentId
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            // The partial case: the manifest read fine, but one entry names a
            // backend this agent build has never heard of. The rest of the host
            // still reconciles normally, so absence still means absence.
            let status = ObservedManifestStatus(
                inventoryComplete: true,
                quarantinedEntries: 1,
                reason: "1 workload(s) in this host's manifest cannot be routed by this agent build "
                    + "(unrecognized hypervisor type \"libvirt\")."
            )
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(
                    message: self.healthyReport(agentId: agentId, manifestStatus: status)),
                fromAgentKey: agent.identity.key)

            let row = try #require(await Agent.find(agent.id, on: app.db))
            #expect(row.manifestInventoryComplete == true)
            #expect(row.manifestStatusReason?.contains("libvirt") == true)

            let escalated = try #require(try await VM.find(vmID, on: app.db))
            #expect(escalated.status == .error)
        }
    }
}
