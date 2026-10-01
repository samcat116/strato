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
        try await TestDataBuilder(db: app.db).createAgent(
            named: name,
            hostname: "\(name).example",
            version: "1.0.0",
            status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000_000_000, availableMemory: 16_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 100_000_000_000),
            architecture: .x86_64,
            lastHeartbeat: Date(),
            organizationScope: .organization(try org.requireID()))
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

    @Test(
        "A missing-manifest baseline preserves every placed guest, with or without an agent warning",
        arguments: [true, false])
    func missingManifestBaselinePreservesRows(agentDeclaresUnknown: Bool) async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "missing-manifest-agent")
            let agentId = try agent.requireID().uuidString
            var vmIDs: [UUID] = []
            var sandboxIDs: [UUID] = []
            for index in 0..<4 {
                let vm = try await builder.createVM(name: "surviving-vm-\(index)", project: project)
                vm.hypervisorId = agentId
                vm.setStatus(.running)
                if index % 2 == 0 {
                    vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
                    vm.setFixtureDesiredStatus(.absent)
                }
                try await vm.save(on: app.db)
                vmIDs.append(try vm.requireID())

                let sandbox = try await builder.createSandbox(name: "surviving-sandbox-\(index)", project: project)
                sandbox.hypervisorId = agentId
                sandbox.setStatus(.running, at: try await ClusterClock.read(on: app.db))
                sandbox.observedGeneration = 1
                if index % 2 == 0 {
                    sandbox.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
                    sandbox.setFixtureDesiredStatus(.absent)
                }
                try await sandbox.save(on: app.db)
                sandboxIDs.append(try sandbox.requireID())
            }
            let report = ObservedStateReport(
                agentId: agentId, vms: [],
                resources: AgentResources(
                    totalCPU: 8, availableCPU: 0, totalMemory: 16_000_000_000, availableMemory: 0,
                    totalDisk: 100_000_000_000, availableDisk: 0),
                manifestStatus: agentDeclaresUnknown
                    ? ObservedManifestStatus(
                        inventoryComplete: false, quarantinedEntries: 0,
                        reason: "Workload manifest is missing; host inventory is unproven") : nil,
                volumes: nil, snapshots: nil)

            // Exercise the first-report path, including the persisted condition,
            // rather than just the workload merge helper.
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: report), fromAgentKey: agent.identity.key)

            for (index, id) in vmIDs.enumerated() {
                let row = try #require(try await VM.find(id, on: app.db))
                #expect(row.status == .running)
                if index % 2 == 0 { #expect(row.finalizers == [ResourceFinalizer.agentAbsent.rawValue]) }
            }
            for (index, id) in sandboxIDs.enumerated() {
                let row = try #require(try await Sandbox.find(id, on: app.db))
                #expect(row.status == .running)
                if index % 2 == 0 { #expect(row.finalizers == [ResourceFinalizer.agentAbsent.rawValue]) }
            }
            let row = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(row.manifestInventoryComplete == false)
            #expect(
                row.manifestStatusReason?.contains(agentDeclaresUnknown ? "missing" : "Control-plane inventory guard")
                    == true)
            #expect(row.availableCPU == 0)
        }
    }

    @Test(
        "A refused first report stays refused on retry, heartbeat, and reconnect; an operator can authorize verified loss"
    )
    func firstReportRefusalPersists() async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "first-report-agent")
            let agentId = try agent.requireID().uuidString
            let vm = try await builder.createVM(name: "still-running", project: project)
            let vmID = try vm.requireID()
            vm.hypervisorId = agentId
            vm.setStatus(.running)
            vm.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)
            let owner = try await builder.createUser(
                username: "guardowner", email: "guardowner@example.com", displayName: "Guard Owner",
                isSystemAdmin: false)
            let dataVolume = try await builder.createVolume(
                name: "attached-data", project: project, vmID: vmID, deviceName: "vdb", attachedAgentID: agentId,
                createdBy: owner)
            let network = try await builder.createNetwork(project: project)
            let nic = try await builder.attachNIC(to: vm, network: network, macAddress: "02:00:00:00:01:28")
            let envelope = try MessageEnvelope(message: self.healthyReport(agentId: agentId))

            for _ in 0..<2 {
                await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agent.identity.key)
                let survivor = try #require(try await VM.find(vmID, on: app.db))
                #expect(survivor.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
            }
            let heldVolume = try #require(try await Volume.find(dataVolume.id, on: app.db))
            #expect(heldVolume.$vm.id == vmID)
            #expect(try await VMNetworkInterface.find(nic.id, on: app.db) != nil)
            var row = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(row.manifestInventoryComplete == false)
            _ = row.updateAvailableResources(self.healthyReport(agentId: agentId).resources)
            #expect(row.availableCPU == 0)
            #expect(row.availableMemory == 0)
            #expect(row.availableDisk == 0)

            try await app.agentService.beginObservedInventorySession(for: agent.identity.key)
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agent.identity.key)
            #expect(try await VM.find(vmID, on: app.db) != nil)

            app.controlPlaneConfiguration = try await ControlPlaneConfiguration.load(
                environmentVariables: ["OBSERVED_INVENTORY_ALLOW_BULK_LOSS": "true"], for: .testing)
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: self.blindReport(agentId: agentId)), fromAgentKey: agent.identity.key)
            #expect(try await VM.find(vmID, on: app.db) != nil)
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agent.identity.key)
            #expect(try await VM.find(vmID, on: app.db) == nil)
            row = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(row.manifestInventoryComplete == nil)
            #expect(row.availableCPU == 6)
        }
    }

    @Test("Established inventory refuses excessive loss and recovers when the guest list returns")
    func thresholdAfterBaseline() async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "threshold-agent")
            let agentId = try agent.requireID().uuidString
            var observations: [ObservedVMState] = []
            for index in 0..<4 {
                let vm = try await builder.createVM(name: "threshold-vm-\(index)", project: project)
                vm.hypervisorId = agentId
                vm.setStatus(.running)
                try await vm.save(on: app.db)
                observations.append(ObservedVMState(vmId: try vm.requireID(), status: .running, observedGeneration: 0))
            }
            // Pending placements must not dilute a complete loss of the
            // established host into a percentage below the configured limit.
            for index in 0..<16 {
                let pending = try await builder.createVM(name: "pending-vm-\(index)", project: project)
                pending.hypervisorId = agentId
                try await pending.save(on: app.db)
            }
            let complete = try MessageEnvelope(message: self.healthyReport(agentId: agentId, vms: observations))
            await app.agentService.applyObservedStateReport(complete, fromAgentKey: agent.identity.key)
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: self.healthyReport(agentId: agentId)), fromAgentKey: agent.identity.key)
            for observation in observations {
                #expect(try await VM.find(observation.vmId, on: app.db)?.status == .running)
            }
            var row = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(row.manifestStatusReason?.contains("more than 3 resources and 25%") == true)
            #expect(row.availableCPU == 0)

            await app.agentService.applyObservedStateReport(complete, fromAgentKey: agent.identity.key)
            row = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(row.manifestStatusReason == nil)
            #expect(row.availableCPU == 6)

            // A later one-VM disappearance is below the floor and still uses
            // the existing loss/reconciliation semantics.
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(
                    message: self.healthyReport(agentId: agentId, vms: Array(observations.dropFirst()))),
                fromAgentKey: agent.identity.key)
            #expect(try await VM.find(observations[0].vmId, on: app.db)?.status == .error)

            // Registration resets the baseline even after a healthy session.
            try await app.agentService.beginObservedInventorySession(for: agent.identity.key)
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(
                    message: self.healthyReport(agentId: agentId, vms: Array(observations.dropFirst(2)))),
                fromAgentKey: agent.identity.key)
            #expect(try await VM.find(observations[1].vmId, on: app.db)?.status == .running)
            row = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(row.manifestStatusReason?.contains("first authoritative inventory") == true)
        }
    }

    @Test(
        "Session replacement drains suspended reports and drops queued predecessor inventory", arguments: [false, true])
    func sessionReplacementDrainsReports(pauseInsideApplier: Bool) async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "session-race-agent")
            let agentId = try agent.requireID().uuidString
            let key = agent.identity.key
            let service = app.agentService
            try await service.beginObservedInventorySession(for: key)
            let originalSession = await service.observedInventorySessions[key]
            let owner = try await builder.createUser(
                username: "raceowner", email: "raceowner@example.com", displayName: "Race Owner", isSystemAdmin: false)
            let vm = try await builder.createVM(name: "race-vm", project: project)
            var snapshots: [VMSnapshot] = []
            var observations: [ObservedSnapshotState] = []
            for index in 0..<2 {
                let snapshot = VMSnapshot(
                    name: "race-checkpoint-\(index)", vmID: try vm.requireID(), projectID: try project.requireID(),
                    environment: vm.environment, agentId: agentId, createdByID: try owner.requireID())
                snapshot.desiredStatus = .absent
                snapshot.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
                try await snapshot.save(on: app.db)
                snapshots.append(snapshot)
                observations.append(
                    ObservedSnapshotState(
                        snapshotId: try snapshot.requireID(), kind: .vmCheckpoint, parentId: try vm.requireID(),
                        present: true, observedGeneration: 1))
            }
            let resources = self.healthyReport(agentId: agentId).resources
            let baseline = ObservedStateReport(agentId: agentId, vms: [], resources: resources, snapshots: observations)
            await service.applyObservedStateReport(try MessageEnvelope(message: baseline), fromAgentKey: key)

            let gate = InventoryReportGate()
            if pauseInsideApplier {
                app.databases.middleware.use(PauseSnapshotDeletion(gate: gate))
            } else {
                app.databases.middleware.use(PauseAgentInventorySave(gate: gate))
            }
            // Force an agent save after validation; omit only one snapshot,
            // which the established session is legitimately allowed to reap.
            let changedResources = AgentResources(
                totalCPU: 8, availableCPU: 5, totalMemory: 16_000_000_000, availableMemory: 7_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 40_000_000_000)
            let oldReport = ObservedStateReport(
                agentId: agentId, vms: [], resources: changedResources, snapshots: [observations[1]])
            let oldTask = await service.enqueueObservedStateReport(
                try MessageEnvelope(message: oldReport), fromAgentKey: key)
            await gate.waitUntilEntered()
            let previousTail = await service.nextReportTailId
            let successor = Task { try await service.beginObservedInventorySession(for: key) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await service.nextReportTailId == previousTail, ContinuousClock.now < deadline { await Task.yield() }
            #expect(await service.nextReportTailId > previousTail)
            // The old transaction is still suspended: no successor session may
            // become visible until all of its writes have finished.
            #expect(await service.observedInventorySessions[key] == originalSession)
            let queuedOldBaseline = await service.enqueueObservedStateReport(
                try MessageEnvelope(message: oldReport), fromAgentKey: key)
            await gate.release()
            await oldTask.value
            try await successor.value
            await queuedOldBaseline.value
            #expect(await service.observedInventorySessions[key] != originalSession)
            #expect(try await VMSnapshot.find(snapshots[0].id, on: app.db) == nil)
            // A stale queued report must not spend the successor's baseline.
            let loss = ObservedStateReport(agentId: agentId, vms: [], resources: resources, snapshots: [])
            await service.applyObservedStateReport(try MessageEnvelope(message: loss), fromAgentKey: key)
            let held = try #require(try await VMSnapshot.find(snapshots[1].id, on: app.db))
            #expect(held.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
            let row = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(row.manifestStatusReason?.contains("first authoritative") == true)
            #expect(row.availableCPU == 0)
        }
    }

    @Test("Successor replica fences old reports and delayed disconnects")
    func successorReplicaFencesInventory() async throws {
        try await withQuarantineApp { app, builder, org, project in
            let old = app.agentService
            let successor = AgentService(app: app)
            do {
                let agent = try await self.makeAgent(app: app, org: org, name: "replica-fence-agent")
                let agentID = try agent.requireID()
                let key = agent.identity.key
                let vm = try await builder.createVM(name: "replica-held-vm", project: project)
                vm.hypervisorId = agentID.uuidString
                vm.setStatus(.running)
                try await vm.save(on: app.db)
                try await old.beginObservedInventorySession(for: key)
                let owner = try await builder.createUser(
                    username: "replicaowner", email: "replicaowner@example.com", displayName: "Replica Owner",
                    isSystemAdmin: false)
                let checkpoint = VMSnapshot(
                    name: "replica-held-checkpoint", vmID: try vm.requireID(), projectID: try project.requireID(),
                    environment: vm.environment, agentId: agentID.uuidString, createdByID: try owner.requireID())
                checkpoint.desiredStatus = .absent
                checkpoint.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
                try await checkpoint.save(on: app.db)
                let baseline = ObservedStateReport(
                    agentId: agentID.uuidString,
                    vms: [ObservedVMState(vmId: try vm.requireID(), status: .running, observedGeneration: 0)],
                    resources: self.healthyReport(agentId: agentID.uuidString).resources,
                    snapshots: [
                        ObservedSnapshotState(
                            snapshotId: try checkpoint.requireID(), kind: .vmCheckpoint, parentId: try vm.requireID(),
                            present: true, observedGeneration: 1)
                    ])
                await old.applyObservedStateReport(try MessageEnvelope(message: baseline), fromAgentKey: key)
                let previous = try await InventorySessionFence.current(agentID: agentID, on: app.db)

                // Hold an accepted old report after admission, while the other
                // replica tries to replace its generation. No shared queue exists.
                let gate = InventoryReportGate()
                app.databases.middleware.use(PauseAgentInventorySave(gate: gate))
                let loss = ObservedStateReport(
                    agentId: agentID.uuidString, vms: [], resources: baseline.resources, snapshots: [])
                // A different resource sample forces the post-admission save.
                let changed = ObservedStateReport(
                    agentId: agentID.uuidString, vms: baseline.vms,
                    resources: AgentResources(
                        totalCPU: 8, availableCPU: 4,
                        totalMemory: 16_000_000_000, availableMemory: 7_000_000_000,
                        totalDisk: 100_000_000_000, availableDisk: 40_000_000_000))
                let active = await old.enqueueObservedStateReport(
                    try MessageEnvelope(message: changed), fromAgentKey: key)
                await gate.waitUntilEntered()
                let replacement = Task { try await successor.beginObservedInventorySession(for: key) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while await successor.nextReportTailId == 0, ContinuousClock.now < deadline { await Task.yield() }
                #expect(await successor.nextReportTailId > 0)
                #expect(try await InventorySessionFence.current(agentID: agentID, on: app.db) == previous)
                await gate.release()
                await active.value
                try await replacement.value
                let current = try await InventorySessionFence.current(agentID: agentID, on: app.db)
                #expect(current != previous)
                #expect(await old.observedInventorySessions[key] == previous)
                await successor.applyObservedStateReport(try MessageEnvelope(message: loss), fromAgentKey: key)
                // Both destructive and healthy old reports are fenced: the
                // latter must not clear the successor's refusal/capacity clamp.
                await old.applyObservedStateReport(try MessageEnvelope(message: loss), fromAgentKey: key)
                await old.applyObservedStateReport(try MessageEnvelope(message: baseline), fromAgentKey: key)
                let held = try #require(try await VM.find(vm.id, on: app.db))
                #expect(held.status == .running)
                let heldCheckpoint = try #require(try await VMSnapshot.find(checkpoint.id, on: app.db))
                #expect(heldCheckpoint.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
                let row = try #require(try await Agent.find(agentID, on: app.db))
                #expect(row.manifestStatusReason?.contains("first authoritative") == true)
                #expect(row.availableCPU == 0)
                #expect(row.availableMemory == 0)
                #expect(row.availableDisk == 0)
                await old.endObservedInventorySession(for: key)
                #expect(try await InventorySessionFence.current(agentID: agentID, on: app.db) == current)
                await successor.applyObservedStateReport(try MessageEnvelope(message: baseline), fromAgentKey: key)
                let recovered = try #require(try await Agent.find(agentID, on: app.db))
                #expect(recovered.manifestInventoryComplete != false)
            } catch {
                await successor.shutdown()
                throw error
            }
            await successor.shutdown()
        }
    }

    @Test("Healthy workloads cannot mask loss of every established snapshot")
    func mixedSectionLossPreservesSnapshots() async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "mixed-inventory-agent")
            let agentId = try agent.requireID().uuidString
            let owner = try await builder.createUser(
                username: "snapshotowner", email: "snapshotowner@example.com", displayName: "Snapshot Owner",
                isSystemAdmin: false)
            var workloads: [ObservedVMState] = []
            for index in 0..<100 {
                let vm = try await builder.createVM(name: "mixed-vm-\(index)", project: project)
                vm.hypervisorId = agentId
                vm.setStatus(.running)
                try await vm.save(on: app.db)
                workloads.append(ObservedVMState(vmId: try vm.requireID(), status: .running, observedGeneration: 0))
            }
            let parentID = try #require(workloads.first?.vmId)
            var snapshots: [VMSnapshot] = []
            var observations: [ObservedSnapshotState] = []
            for index in 0..<4 {
                let snapshot = VMSnapshot(
                    name: "mixed-checkpoint-\(index)", vmID: parentID, projectID: try project.requireID(),
                    environment: "development", agentId: agentId, createdByID: try owner.requireID())
                try await snapshot.save(on: app.db)
                snapshots.append(snapshot)
                observations.append(
                    ObservedSnapshotState(
                        snapshotId: try snapshot.requireID(), kind: .vmCheckpoint, parentId: parentID,
                        present: true, observedGeneration: 1))
            }
            let resources = self.healthyReport(agentId: agentId).resources
            let baseline = ObservedStateReport(
                agentId: agentId, vms: workloads, resources: resources, snapshots: observations)
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: baseline), fromAgentKey: agent.identity.key)
            let healthy = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(healthy.manifestInventoryComplete != false)
            for snapshot in snapshots {
                snapshot.desiredStatus = .absent
                snapshot.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
                try await snapshot.save(on: app.db)
            }
            let loss = ObservedStateReport(agentId: agentId, vms: workloads, resources: resources, snapshots: [])
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: loss), fromAgentKey: agent.identity.key)
            for snapshot in snapshots {
                let held = try #require(try await VMSnapshot.find(snapshot.id, on: app.db))
                #expect(held.finalizers == [ResourceFinalizer.agentAbsent.rawValue])
                #expect(held.desiredStatus == .absent)
            }
            let refused = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(refused.manifestInventoryComplete == false)
            #expect(refused.manifestStatusReason?.contains("snapshots") == true)
            #expect(refused.manifestStatusReason?.contains("first authoritative") == false)
            #expect(refused.availableCPU == 0)
            #expect(refused.availableMemory == 0)
            #expect(refused.availableDisk == 0)
        }
    }

    @Test("Nil storage lists do not authorize later loss of replicas or checkpoints")
    func storageSectionsRequireTheirOwnBaseline() async throws {
        try await withQuarantineApp { app, builder, org, project in
            let agent = try await self.makeAgent(app: app, org: org, name: "storage-guard-agent")
            let agentId = try agent.requireID().uuidString
            let owner = try await builder.createUser(
                username: "storageowner", email: "storageowner@example.com", displayName: "Storage Owner",
                isSystemAdmin: false)
            let vm = try await builder.createVM(name: "checkpoint-parent", project: project)
            vm.hypervisorId = agentId
            vm.setStatus(.running)
            try await vm.save(on: app.db)
            let volume = try await builder.createVolume(
                name: "held-volume", project: project, desiredStatus: .absent,
                generation: 2, observedGeneration: 1, attachedAgentID: agentId, createdBy: owner)
            volume.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            try await volume.save(on: app.db)
            let replica = VolumeReplica(volumeID: try volume.requireID(), agentId: agentId)
            try await replica.save(on: app.db)
            let checkpoint = VMSnapshot(
                name: "held-checkpoint", vmID: try vm.requireID(), projectID: try project.requireID(),
                environment: vm.environment, agentId: agentId, createdByID: try owner.requireID())
            checkpoint.desiredStatus = .absent
            checkpoint.finalizers = [ResourceFinalizer.agentAbsent.rawValue]
            try await checkpoint.save(on: app.db)

            let baseline = self.healthyReport(
                agentId: agentId,
                vms: [
                    ObservedVMState(vmId: try vm.requireID(), status: .running, observedGeneration: 0)
                ])
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: baseline), fromAgentKey: agent.identity.key)
            for section in [ObservedInventoryGuard.Section.volumes, .snapshots] {
                let report = ObservedStateReport(
                    agentId: agentId, vms: baseline.vms, resources: baseline.resources,
                    volumes: section == .volumes ? [] : nil, snapshots: section == .snapshots ? [] : nil)
                await app.agentService.applyObservedStateReport(
                    try MessageEnvelope(message: report), fromAgentKey: agent.identity.key)
                let row = try #require(try await Agent.find(agent.id, on: app.db))
                #expect(row.manifestStatusReason?.contains("first authoritative inventory") == true)
                #expect(row.manifestStatusReason?.contains(section.rawValue) == true)
                #expect(try await Volume.find(volume.id, on: app.db) != nil)
                #expect(try await VolumeReplica.find(replica.id, on: app.db) != nil)
                #expect(try await VMSnapshot.find(checkpoint.id, on: app.db) != nil)
            }
        }
    }

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

            // Establish a trustworthy baseline before testing ordinary,
            // below-threshold drift on a later partial-quarantine report.
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(
                    message: self.healthyReport(
                        agentId: agentId,
                        vms: [
                            ObservedVMState(vmId: vmID, status: .running, observedGeneration: 0)
                        ])), fromAgentKey: agent.identity.key)

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

/// One-shot suspension at a real database write, after inventory admission.
private actor InventoryReportGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard !entered else { return }
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private struct PauseAgentInventorySave: AsyncModelMiddleware {
    let gate: InventoryReportGate
    func update(model: Agent, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        await gate.pauseOnce()
        try await next.update(model, on: db)
    }
}

private struct PauseSnapshotDeletion: AsyncModelMiddleware {
    let gate: InventoryReportGate
    func delete(model: VMSnapshot, force: Bool, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        await gate.pauseOnce()
        try await next.delete(model, force: force, on: db)
    }
}
