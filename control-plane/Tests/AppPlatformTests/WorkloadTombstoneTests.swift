import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tombstone-confirmed teardown (STR-98): the control-plane half of taking
/// omission out of the destructive path.
///
/// An agent no longer destroys what a sync forgot to mention — it holds the
/// workload and reports it. These tests cover what the control plane does with
/// that report: authorize teardown only when no record exists, refuse it
/// loudly when one does, retire claims when the host stops holding them, carry
/// the authorized ones on the next sync, and let an operator re-point
/// workloads that came back under a new agent record.
@Suite("Workload Tombstone Tests", .serialized)
final class WorkloadTombstoneTests {

    private func withTombstoneApp(
        _ test: (Application, TestDataBuilder, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "tombstoneadmin",
                email: "tombstone@example.com",
                displayName: "Tombstone Admin",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Tombstone Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)
            let project = try await builder.createProject(
                name: "Tombstone Project", description: "STR-98", organization: org)
            let token = try await admin.generateAPIKey(on: app.db)

            try await test(app, builder, org, project, token)
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

    private func report(
        agentId: String,
        vms: [ObservedVMState] = [],
        unrecognized: [UnrecognizedWorkload] = [],
        teardownRefusal: ObservedTeardownRefusal? = nil
    ) -> ObservedStateReport {
        ObservedStateReport(
            agentId: agentId,
            vms: vms,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 6,
                totalMemory: 16_000_000_000, availableMemory: 8_000_000_000,
                totalDisk: 100_000_000_000, availableDisk: 50_000_000_000
            ),
            unrecognized: unrecognized,
            teardownRefusal: teardownRefusal
        )
    }

    private func claims(for agentId: String, on app: Application) async throws -> [AgentWorkloadClaim] {
        try await AgentWorkloadClaim.query(on: app.db)
            .filter(\.$agentId == agentId)
            .all()
    }

    // MARK: - The three verdicts

    @Test("A held workload with no record earns a tombstone on the next sync")
    func noRecordAuthorizesTeardown() async throws {
        try await withTombstoneApp { app, _, org, _, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString
            let strayId = UUID()

            let authorized = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    unrecognized: [
                        UnrecognizedWorkload(
                            kind: .vm, workloadId: strayId, observedGeneration: 6, status: "Running")
                    ]))
            #expect(authorized.authorizedTeardown)

            let recorded = try await self.claims(for: agentId, on: app)
            #expect(recorded.count == 1)
            #expect(recorded[0].disposition == .tombstoned)
            #expect(recorded[0].resourceID == strayId)
            // The tombstone must outrank what the agent last applied, or its
            // staleness guard drops it and the stray is held forever.
            #expect(recorded[0].tombstoneGeneration == 7)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(sync.tombstones?.count == 1)
            #expect(sync.tombstones?[0].workloadId == strayId)
            #expect(sync.tombstones?[0].kind == .vm)
            #expect(sync.tombstones?[0].generation == 7)
        }
    }

    @Test("A held workload whose record maps to this agent is never tombstoned")
    func recordOnSameAgentWithholdsTeardown() async throws {
        try await withTombstoneApp { app, builder, org, project, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString
            let vm = try await builder.createVM(name: "held-vm", project: project)
            vm.hypervisorId = agentId
            try await vm.save(on: app.db)

            // Reported unrecognized even though the record says it belongs
            // here: the sync that omitted it is the thing that is wrong.
            let authorized = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    unrecognized: [
                        UnrecognizedWorkload(
                            kind: .vm, workloadId: try vm.requireID(), observedGeneration: 3,
                            status: "Running")
                    ]))
            #expect(!authorized.authorizedTeardown)

            let recorded = try await self.claims(for: agentId, on: app)
            #expect(recorded.count == 1)
            #expect(recorded[0].disposition == .held)
            #expect(recorded[0].reason == AgentWorkloadClaim.heldRowPresentReason)
            #expect(recorded[0].tombstoneGeneration == nil)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(sync.tombstones?.isEmpty == true)
            // And the VM itself is untouched — no teardown, no error status.
            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status != .error)
        }
    }

    @Test("A held workload placed on another agent record is flagged for re-pointing")
    func recordOnOtherAgentRecordsRepointCandidate() async throws {
        try await withTombstoneApp { app, builder, org, project, _ in
            let oldAgent = try await self.makeAgent(app: app, org: org, name: "ts-old")
            let newAgent = try await self.makeAgent(app: app, org: org, name: "ts-new")
            let oldId = try oldAgent.requireID().uuidString
            let newId = try newAgent.requireID().uuidString

            // The node re-enrolled under a new record; its VM stayed placed on
            // the old one. Before STR-98 the new record's first sync listed
            // nothing and the host destroyed every VM it had.
            let vm = try await builder.createVM(name: "migrated-vm", project: project)
            vm.hypervisorId = oldId
            try await vm.save(on: app.db)

            let authorized = try await app.observedStateApplier.apply(
                self.report(
                    agentId: newId,
                    unrecognized: [
                        UnrecognizedWorkload(
                            kind: .vm, workloadId: try vm.requireID(), observedGeneration: 2,
                            status: "Running")
                    ]))
            #expect(!authorized.authorizedTeardown)

            let recorded = try await self.claims(for: newId, on: app)
            #expect(recorded.count == 1)
            #expect(recorded[0].disposition == .held)
            #expect(recorded[0].placedOnAgentId == oldId)

            let sync = try await app.desiredStateAssembler.assemble(agentId: newId)
            #expect(sync.tombstones?.isEmpty == true)
        }
    }

    // MARK: - Claim lifecycle

    @Test("A claim retires once the host stops reporting the workload")
    func claimRetiresWhenTheWorkloadIsGone() async throws {
        try await withTombstoneApp { app, _, org, _, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString
            let strayId = UUID()

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    unrecognized: [
                        UnrecognizedWorkload(kind: .vm, workloadId: strayId, observedGeneration: 0)
                    ]))
            #expect(try await self.claims(for: agentId, on: app).count == 1)

            // The tombstone converged: the agent no longer reports the id at
            // all, in either list.
            _ = try await app.observedStateApplier.apply(self.report(agentId: agentId))
            #expect(try await self.claims(for: agentId, on: app).isEmpty)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(sync.tombstones?.isEmpty == true)
        }
    }

    @Test("A tombstone is withdrawn if the record comes back before the teardown converges")
    func tombstoneWithdrawnWhenTheRecordReturns() async throws {
        try await withTombstoneApp { app, builder, org, project, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString

            let vm = try await builder.createVM(name: "restored-vm", project: project)
            let vmID = try vm.requireID()
            // The record was missing when the agent last reported, so its
            // teardown was authorized.
            try await vm.delete(on: app.db)
            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    unrecognized: [
                        UnrecognizedWorkload(kind: .vm, workloadId: vmID, observedGeneration: 1)
                    ]))
            #expect(try await self.claims(for: agentId, on: app).count == 1)

            // The record comes back (a restore, an operator re-creating it)
            // and the sync now describes the VM, so the agent stops reporting
            // it as unrecognized. The authorization has to be withdrawn, or
            // every sync would carry "keep this" and "destroy this" together.
            let restored = VM(
                id: vmID,
                name: "restored-vm",
                description: "Test VM",
                image: "test-image",
                projectID: try project.requireID(),
                environment: "development",
                cpu: 2,
                memory: 2 * 1024 * 1024 * 1024,
                disk: 10 * 1024 * 1024 * 1024
            )
            restored.hypervisorId = agentId
            try await restored.create(on: app.db)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    vms: [ObservedVMState(vmId: vmID, status: .running, observedGeneration: 1)]))

            #expect(try await self.claims(for: agentId, on: app).isEmpty)
            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(sync.tombstones?.isEmpty == true)
            #expect(sync.vms.map(\.vmId) == [vmID])
        }
    }

    @Test("Re-reporting the same held workload doesn't re-authorize or churn the claim")
    func repeatedReportsAreIdempotent() async throws {
        try await withTombstoneApp { app, _, org, _, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString
            let entry = UnrecognizedWorkload(
                kind: .vm, workloadId: UUID(), observedGeneration: 1, status: "Running")

            let first = try await app.observedStateApplier.apply(
                self.report(agentId: agentId, unrecognized: [entry]))
            let second = try await app.observedStateApplier.apply(
                self.report(agentId: agentId, unrecognized: [entry]))
            #expect(first.authorizedTeardown)
            #expect(!second.authorizedTeardown)  // no new authorization, so no sync nudge

            let recorded = try await self.claims(for: agentId, on: app)
            #expect(recorded.count == 1)
            #expect(recorded[0].tombstoneGeneration == 2)
        }
    }

    @Test("A tombstone generation only ever moves forward")
    func tombstoneGenerationIsMonotonic() async throws {
        try await withTombstoneApp { app, _, org, _, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString
            let strayId = UUID()

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    unrecognized: [
                        UnrecognizedWorkload(kind: .vm, workloadId: strayId, observedGeneration: 9)
                    ]))
            // A later report claims an older applied generation (a restarted
            // agent has no memory of what it applied). The tombstone must not
            // regress below what an earlier one already authorized, or the
            // agent's staleness guard would start dropping it.
            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: agentId,
                    unrecognized: [
                        UnrecognizedWorkload(kind: .vm, workloadId: strayId, observedGeneration: 0)
                    ]))

            let recorded = try await self.claims(for: agentId, on: app)
            #expect(recorded.count == 1)
            #expect(recorded[0].tombstoneGeneration == 10)
        }
    }

    // MARK: - Teardown refusal (phase 2)

    @Test("A reported teardown refusal lands on the agent row and clears on the next clean report")
    func teardownRefusalRoundTrip() async throws {
        try await withTombstoneApp { app, _, org, _, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString

            let refusal = ObservedTeardownRefusal(
                syncId: UUID().uuidString,
                requestedTeardowns: 12,
                presentWorkloads: 12,
                reason: "refusing to tear down 12 of 12 workloads on this host in one sync"
            )
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(
                    message: self.report(agentId: agentId, teardownRefusal: refusal)),
                fromAgentKey: agent.identity.key)

            var row = try #require(await Agent.find(agent.id, on: app.db))
            #expect(row.teardownRefusalReason == refusal.reason)
            #expect(row.teardownRefusedAt != nil)

            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: self.report(agentId: agentId)),
                fromAgentKey: agent.identity.key)

            row = try #require(await Agent.find(agent.id, on: app.db))
            #expect(row.teardownRefusalReason == nil)
            #expect(row.teardownRefusedAt == nil)
        }
    }

    @Test("Held claims are counted on every report, so the condition stays visible")
    func heldClaimsAreReportedLevelTriggered() async throws {
        try await withTombstoneApp { app, builder, org, project, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString
            let vm = try await builder.createVM(name: "held-vm", project: project)
            vm.hypervisorId = agentId
            try await vm.save(on: app.db)
            let entry = UnrecognizedWorkload(
                kind: .vm, workloadId: try vm.requireID(), observedGeneration: 1, status: "Running")

            // The withheld-teardown *counter* only fires at the transition, so
            // the count has to come back on every report or an operator who
            // wasn't watching that minute has no way to ask "is this still
            // happening" — including after a control-plane restart.
            let first = try await app.observedStateApplier.apply(
                self.report(agentId: agentId, unrecognized: [entry]))
            #expect(first.heldByReason[AgentWorkloadClaim.heldRowPresentReason] == 1)
            let second = try await app.observedStateApplier.apply(
                self.report(agentId: agentId, unrecognized: [entry]))
            #expect(second.heldByReason[AgentWorkloadClaim.heldRowPresentReason] == 1)
            #expect(second.heldByReason[AgentWorkloadClaim.heldOtherAgentBucket] == 0)

            // And it falls back to zero rather than going stale once the
            // condition clears.
            let cleared = try await app.observedStateApplier.apply(self.report(agentId: agentId))
            #expect(cleared.heldByReason[AgentWorkloadClaim.heldRowPresentReason] == 0)
        }
    }

    @Test("A refusal repeated on heartbeats updates the row without re-logging")
    func teardownRefusalIsDedupedPerSync() async throws {
        try await withTombstoneApp { app, _, org, _, _ in
            let agent = try await self.makeAgent(app: app, org: org, name: "ts-agent")
            let agentId = try agent.requireID().uuidString

            // The same refusal rides on every report while the agent's guard
            // stands, so the row must track it without the log and counter
            // firing per heartbeat.
            let syncId = UUID().uuidString
            let refusal = ObservedTeardownRefusal(
                syncId: syncId, requestedTeardowns: 9, presentWorkloads: 9, reason: "guard tripped")
            for _ in 0..<3 {
                await app.agentService.applyObservedStateReport(
                    try MessageEnvelope(
                        message: self.report(agentId: agentId, teardownRefusal: refusal)),
                    fromAgentKey: agent.identity.key)
            }
            var row = try #require(await Agent.find(agent.id, on: app.db))
            #expect(row.teardownRefusalReason == "guard tripped")
            let firstRefusedAt = try #require(row.teardownRefusedAt)

            // A genuinely new refused sync is a new event and does move the
            // timestamp.
            let next = ObservedTeardownRefusal(
                syncId: UUID().uuidString, requestedTeardowns: 9, presentWorkloads: 9,
                reason: "guard tripped again")
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: self.report(agentId: agentId, teardownRefusal: next)),
                fromAgentKey: agent.identity.key)
            row = try #require(await Agent.find(agent.id, on: app.db))
            #expect(row.teardownRefusalReason == "guard tripped again")
            #expect(row.teardownRefusedAt ?? .distantPast >= firstRefusedAt)
        }
    }

    // MARK: - Adoption (phase 3)

    @Test("Adoption re-points exactly the workloads the agent proves it holds")
    func adoptionMovesClaimedWorkloadsOnly() async throws {
        try await withTombstoneApp { app, builder, org, project, token in
            let oldAgent = try await self.makeAgent(app: app, org: org, name: "ts-old")
            let newAgent = try await self.makeAgent(app: app, org: org, name: "ts-new")
            let oldId = try oldAgent.requireID().uuidString
            let newId = try newAgent.requireID().uuidString

            let held = try await builder.createVM(name: "held-vm", project: project)
            held.hypervisorId = oldId
            try await held.save(on: app.db)
            // A second VM on the old record that the node does *not* report
            // holding — it must stay put, whatever the operator clicks.
            let unheld = try await builder.createVM(name: "unheld-vm", project: project)
            unheld.hypervisorId = oldId
            try await unheld.save(on: app.db)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: newId,
                    unrecognized: [
                        UnrecognizedWorkload(
                            kind: .vm, workloadId: try held.requireID(), observedGeneration: 4,
                            status: "Running")
                    ]))

            try await app.test(
                .POST, "/api/agents/\(newId)/actions/adopt-workloads",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["fromAgentId": oldId])
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(AgentController.AdoptWorkloadsResponse.self)
                    #expect(body.adoptedVMs == 1)
                    #expect(body.skippedUnclaimed == 1)
                })

            #expect(try await VM.find(held.id, on: app.db)?.hypervisorId == newId)
            #expect(try await VM.find(unheld.id, on: app.db)?.hypervisorId == oldId)
            // The claim is consumed; the VM now appears in the new agent's own
            // sync rather than as something it holds unaccounted for.
            #expect(try await self.claims(for: newId, on: app).isEmpty)
            let sync = try await app.desiredStateAssembler.assemble(agentId: newId)
            #expect(sync.vms.map(\.vmId) == [try held.requireID()])
        }
    }

    @Test("Adoption moves authoritative volume placement")
    func adoptionRepointsVolumePlacement() async throws {
        try await withTombstoneApp { app, builder, org, project, token in
            let oldAgent = try await self.makeAgent(app: app, org: org, name: "ts-old")
            let newAgent = try await self.makeAgent(app: app, org: org, name: "ts-new")
            let oldId = try oldAgent.requireID().uuidString
            let newId = try newAgent.requireID().uuidString
            let user = try #require(
                await User.query(on: app.db).filter(\.$username == "tombstoneadmin").first())

            let vm = try await builder.createVM(name: "held-vm", project: project)
            vm.hypervisorId = oldId
            try await vm.save(on: app.db)

            // An attached volume, and a detached one — both live on the same
            // physical host as the VM, and both are dispatched through the
            // replica row rather than `hypervisorId`.
            let attached = Volume(
                name: "attached-vol", description: "", projectID: try project.requireID(), environment: "development",
                size: 1 << 30, createdByID: try user.requireID())
            attached.attachedAgentId = oldId
            attached.$vm.id = try vm.requireID()
            // An attached row names its device: `NormalizeVolumeAttachments`
            // makes that a check constraint (STR-129).
            attached.deviceName = "disk0"
            try await attached.save(on: app.db)
            try await VolumeReplica(
                volumeID: try attached.requireID(), agentId: oldId, datasetPath: nil, state: .healthy
            ).create(on: app.db)

            let detached = Volume(
                name: "detached-vol", description: "", projectID: try project.requireID(), environment: "development",
                size: 1 << 30, createdByID: try user.requireID())
            try await detached.save(on: app.db)
            try await VolumeReplica(
                volumeID: try detached.requireID(), agentId: oldId, datasetPath: nil, state: .healthy
            ).create(on: app.db)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: newId,
                    unrecognized: [
                        UnrecognizedWorkload(
                            kind: .vm, workloadId: try vm.requireID(), observedGeneration: 1,
                            status: "Running")
                    ]))

            try await app.test(
                .POST, "/api/agents/\(newId)/actions/adopt-workloads",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["fromAgentId": oldId])
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(AgentController.AdoptWorkloadsResponse.self)
                    #expect(body.adoptedVolumes == 2)
                })

            // Replica placement is the dispatch source, so this proves future
            // operations on both disks reach the adopting host.
            let replicaAgents = try await VolumeReplica.query(on: app.db)
                .all()
                .map(\.agentId)
            #expect(Set(replicaAgents) == [newId])

            let reloadedAttached = try #require(await Volume.find(attached.id, on: app.db))
            #expect(reloadedAttached.attachedAgentId == newId)
        }
    }

    @Test("A volume attached to a VM that stayed behind does not move")
    func adoptionLeavesUnclaimedVMsVolumes() async throws {
        try await withTombstoneApp { app, builder, org, project, token in
            let oldAgent = try await self.makeAgent(app: app, org: org, name: "ts-old")
            let newAgent = try await self.makeAgent(app: app, org: org, name: "ts-new")
            let oldId = try oldAgent.requireID().uuidString
            let newId = try newAgent.requireID().uuidString
            let user = try #require(
                await User.query(on: app.db).filter(\.$username == "tombstoneadmin").first())

            let held = try await builder.createVM(name: "held-vm", project: project)
            held.hypervisorId = oldId
            try await held.save(on: app.db)
            let stayed = try await builder.createVM(name: "stayed-vm", project: project)
            stayed.hypervisorId = oldId
            try await stayed.save(on: app.db)

            let stayedVolume = Volume(
                name: "stayed-vol", description: "", projectID: try project.requireID(), environment: "development",
                size: 1 << 30, createdByID: try user.requireID())
            stayedVolume.$vm.id = try stayed.requireID()
            // An attached row names its device: `NormalizeVolumeAttachments`
            // makes that a check constraint (STR-129).
            stayedVolume.deviceName = "disk0"
            try await stayedVolume.save(on: app.db)
            try await placeVolume(stayedVolume, on: oldId, using: app.db)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: newId,
                    unrecognized: [
                        UnrecognizedWorkload(
                            kind: .vm, workloadId: try held.requireID(), observedGeneration: 1)
                    ]))

            try await app.test(
                .POST, "/api/agents/\(newId)/actions/adopt-workloads",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["fromAgentId": oldId])
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(AgentController.AdoptWorkloadsResponse.self)
                    #expect(body.adoptedVolumes == 0)
                })

            #expect(try await VolumeService.agentHolding(stayedVolume, on: app.db) == oldId)
        }
    }

    @Test("Adoption refuses to cross an organization boundary")
    func adoptionRefusesCrossOrg() async throws {
        try await withTombstoneApp { app, builder, org, project, token in
            let otherOrg = try await builder.createOrganization(name: "Other Tombstone Org")
            let oldAgent = try await self.makeAgent(app: app, org: otherOrg, name: "ts-foreign")
            let newAgent = try await self.makeAgent(app: app, org: org, name: "ts-new")
            let oldId = try oldAgent.requireID().uuidString
            let newId = try newAgent.requireID().uuidString

            let vm = try await builder.createVM(name: "foreign-vm", project: project)
            vm.hypervisorId = oldId
            try await vm.save(on: app.db)
            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: newId,
                    unrecognized: [
                        UnrecognizedWorkload(
                            kind: .vm, workloadId: try vm.requireID(), observedGeneration: 1)
                    ]))

            // The claim evidence bounds *which* workloads may move; it says
            // nothing about across what boundary.
            try await app.test(
                .POST, "/api/agents/\(newId)/actions/adopt-workloads",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["fromAgentId": oldId])
                },
                afterResponse: { res async throws in
                    #expect(res.status == .conflict)
                })

            #expect(try await VM.find(vm.id, on: app.db)?.hypervisorId == oldId)
        }
    }

    @Test("Adoption 404s on an unknown source record")
    func adoptionRejectsUnknownSource() async throws {
        try await withTombstoneApp { app, _, org, _, token in
            let newAgent = try await self.makeAgent(app: app, org: org, name: "ts-new")
            let newId = try newAgent.requireID().uuidString

            try await app.test(
                .POST, "/api/agents/\(newId)/actions/adopt-workloads",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["fromAgentId": UUID().uuidString])
                },
                afterResponse: { res async throws in
                    #expect(res.status == .notFound)
                })
        }
    }

    @Test("Adoption refuses a source the agent holds nothing from")
    func adoptionRefusesUnprovenSource() async throws {
        try await withTombstoneApp { app, builder, org, project, token in
            let oldAgent = try await self.makeAgent(app: app, org: org, name: "ts-old")
            let newAgent = try await self.makeAgent(app: app, org: org, name: "ts-new")
            let oldId = try oldAgent.requireID().uuidString
            let newId = try newAgent.requireID().uuidString

            // A VM on the old record that nobody reports holding: the endpoint
            // must not be usable to move it.
            let vm = try await builder.createVM(name: "someone-elses-vm", project: project)
            vm.hypervisorId = oldId
            try await vm.save(on: app.db)

            try await app.test(
                .POST, "/api/agents/\(newId)/actions/adopt-workloads",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(["fromAgentId": oldId])
                },
                afterResponse: { res async throws in
                    #expect(res.status == .conflict)
                })

            #expect(try await VM.find(vm.id, on: app.db)?.hypervisorId == oldId)
        }
    }

    @Test("Held workloads surface on the agent detail resource")
    func heldWorkloadsOnTheAgentResource() async throws {
        try await withTombstoneApp { app, builder, org, project, token in
            let oldAgent = try await self.makeAgent(app: app, org: org, name: "ts-old")
            let newAgent = try await self.makeAgent(app: app, org: org, name: "ts-new")
            let oldId = try oldAgent.requireID().uuidString
            let newId = try newAgent.requireID().uuidString
            let vm = try await builder.createVM(name: "held-vm", project: project)
            vm.hypervisorId = oldId
            try await vm.save(on: app.db)

            _ = try await app.observedStateApplier.apply(
                self.report(
                    agentId: newId,
                    unrecognized: [
                        UnrecognizedWorkload(
                            kind: .vm, workloadId: try vm.requireID(), observedGeneration: 1,
                            status: "Running")
                    ]))

            try await app.test(
                .GET, "/api/agents/\(newId)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(AgentResponse.self)
                    #expect(body.heldWorkloads?.count == 1)
                    #expect(body.heldWorkloads?[0].placedOnAgentId == oldId)
                    #expect(body.heldWorkloads?[0].status == "Running")
                })
        }
    }
}
