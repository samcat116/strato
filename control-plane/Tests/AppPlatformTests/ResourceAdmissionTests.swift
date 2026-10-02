import AppTestSupport
import Fluent
import Foundation
import SQLKit
import StratoShared
import Testing
import Vapor
@testable import App

@Suite("Durable resource admission", .serialized, .postgresFixture)
struct ResourceAdmissionTests {
    struct Fixture {
        let agent: Agent
        let vm: VM
        let previous: WorkloadAdmittedReservation
        let current: WorkloadAdmittedReservation
        let snapshot: WorkloadResourceClassSnapshot
        let key: String
    }

    func fixture(_ app: Application) async throws -> Fixture {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "Durable class org")
        let project = try await builder.createProject(
            name: "Durable class project", description: "Durable admission fixture", organization: org)
        let site = Site(name: "Durable class site", organizationScope: .organization(try org.requireID()))
        try await site.save(on: app.db)
        let agent = try await builder.createAgent(named: "durable-host", siteID: try site.requireID())
        agent.resourceClassEnforcement = [
            .init(
                backend: .qemuVM, controllersDelegated: true, stableOwnership: true,
                preExecutionEnforcement: true, effectiveReadback: true)
        ]
        try await agent.save(on: app.db)
        let vm = try await builder.createVM(name: "durable-workload", project: project)
        let snapshot = try site.resourceClasses()[1]
        let previous = WorkloadAdmittedReservation(
            cpus: 1, memory: .init(guestBytes: 16384, backendOverheadBytes: 4096), policy: snapshot.policy)
        let current = previous.growing(
            cpus: 2, memory: .init(guestBytes: 32768, backendOverheadBytes: 4096), policy: snapshot.policy)
        var key = ""
        key = try await app.db.transaction { tx in
            let (key, _) = try await ResourceAdmissionService.stageGrowth(
                agentID: try agent.requireID(), workloadID: try vm.requireID(), generation: 1, mutationID: UUID(),
                admission: .init(snapshot: snapshot, reservation: current), previous: previous,
                backend: .qemuVM, on: tx)
            return key
        }
        vm.cpu = 2
        vm.memory = 32768
        vm.generation = 1
        vm.hypervisorId = try agent.requireID().uuidString
        vm.resourceClass = snapshot
        vm.admittedReservation = current
        try await vm.save(on: app.db)
        return .init(agent: agent, vm: vm, previous: previous, current: current, snapshot: snapshot, key: key)
    }

    func ack(_ f: Fixture, flaw: String = "") throws -> WorkloadEnforcementAcknowledgement {
        let desired = try f.snapshot.policy.runtimeLimits(guestBytes: 32768, backendOverheadBytes: 4096)
        let other = try WorkloadResourceClassSnapshot(
            classID: f.snapshot.classID, siteID: flaw == "site" ? UUID() : f.snapshot.siteID,
            revision: f.snapshot.revision + 1,
            policy: f.snapshot.policy)
        return .init(
            kind: flaw == "kind" ? .volume : .vm,
            workloadId: flaw == "id" ? UUID() : try f.vm.requireID(),
            appliedGeneration: flaw == "generation" ? 2 : 1,
            resourceClass: ["class", "site"].contains(flaw) ? other : f.snapshot,
            backend: flaw == "backend" ? .jailedFirecrackerSandbox : .qemuVM,
            accountedReservation: flaw == "ledger" ? f.previous : f.current,
            runtimeGuestBytes: flaw == "guest" ? 16384 : 32768,
            pageSizeBytes: flaw == "page" ? 3 : 4096,
            desiredLimits: flaw == "desired"
                ? try f.snapshot.policy.runtimeLimits(guestBytes: 16384, backendOverheadBytes: 4096) : desired,
            appliedLimits: flaw == "applied" ? desired : try desired.aligned(pageSizeBytes: 4096),
            cpuQuotaUnlimited: flaw != "quota", ownershipVerified: flaw != "ownership")
    }

    func report(
        _ f: Fixture, boot: UUID, sequence: Int64, acknowledgements: [WorkloadEnforcementAcknowledgement],
        complete: Bool = true, missingObserved: Bool = false, failedObserved: Bool = false, accountingFlaw: String = ""
    ) throws -> ObservedStateReport {
        let memory = HostMemoryAccounting(
            physicalBytes: f.agent.totalMemory, hostReservedBytes: 0,
            workloadEffectiveBytes: accountingFlaw == "accounting" ? 0 : f.current.effectiveMemoryBytes)
        let total = WorkloadResourceClassPolicy.guaranteed.cpuMicroUnits(cpus: f.agent.totalCPU)
        let cpu: Int64 = accountingFlaw == "cpuBudget" ? total : total - f.current.cpuMicroUnits
        let resources = AgentResources(
            totalCPU: f.agent.totalCPU, availableCPU: Int(cpu / 1_000_000),
            totalMemory: f.agent.totalMemory, availableMemory: memory.remainingAllocatableBytes,
            totalDisk: f.agent.totalDisk, availableDisk: f.agent.availableDisk,
            memoryAccounting: memory, availableCPUMicroUnits: accountingFlaw == "precision" ? nil : cpu)
        return .init(
            agentId: try f.agent.requireID().uuidString,
            vms: missingObserved
                ? []
                : [
                    .init(
                        vmId: try f.vm.requireID(), status: .running, observedGeneration: 1,
                        lastError: failedObserved ? "failed" : nil, failedGeneration: failedObserved ? 1 : nil)
                ],
            resources: resources,
            resourceEnforcement: .init(
                agentBootID: boot, sequence: sequence, sampledAt: Date(), inventoryComplete: complete,
                acknowledgements: acknowledgements))
    }

    @Test func pendingSurvivesCoordinationRestartAndBlocksCapacity() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let state = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db)).state
            let store = InMemoryCoordinationStore()
            #expect(try await store.reservedTotal(agentKey: "empty-after-restart") == .zero)
            let capacity = ResourceAdmissionService.capacity(agent: f.agent, state: state)
            #expect(capacity.cpuMicroUnits == 15_750_000)
            #expect(capacity.memory == f.agent.availableMemory - 16384)
            // The production placement view uses the same durable deduction.
            await app.agentService.refreshAgentPresenceIfNeeded(agentKey: f.agent.identity.key, force: true)
            let candidates = await app.workloadPlacement.schedulableAgentsFromDatabase()
            let candidate = try #require(candidates.first { $0.id == f.agent.id?.uuidString })
            #expect(candidate.availableCPUMicroUnits == capacity.cpuMicroUnits)
            #expect(candidate.availableMemory == capacity.memory)
        }
    }

    @Test(arguments: [
        "kind", "id", "generation", "class", "backend", "ledger", "guest", "page", "desired", "applied", "quota",
        "ownership", "duplicate", "incomplete", "manifest", "readiness", "missingObserved", "failedObserved",
        "accounting", "precision", "cpuBudget", "owner", "site", "duplicateReadiness",
    ])
    func invalidEvidenceRetainsPending(_ flaw: String) async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            if flaw == "readiness" {
                f.agent.resourceClassEnforcement = nil
                try await f.agent.save(on: app.db)
            }
            if flaw == "owner" {
                f.vm.hypervisorId = UUID().uuidString
                try await f.vm.save(on: app.db)
            }
            if flaw == "duplicateReadiness" {
                f.agent.resourceClassEnforcement = f.agent.resourceClassEnforcement.map { $0 + $0 }
                try await f.agent.save(on: app.db)
            }
            let item = try ack(f, flaw: flaw)
            let message = try report(
                f, boot: UUID(), sequence: 0,
                acknowledgements: flaw == "duplicate" ? [item, item] : [item], complete: flaw != "incomplete",
                missingObserved: flaw == "missingObserved", failedObserved: flaw == "failedObserved",
                accountingFlaw: flaw)
            let outcome = try await ResourceAdmissionService.accept(
                message, agentID: try f.agent.requireID(), sessionID: UUID(), inventoryComplete: flaw != "manifest",
                on: app.db)
            guard case .accepted(let released) = outcome else {
                Issue.record("Expected accepted resource report"); return
            }
            #expect(released.isEmpty)
            let state = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db)).state
            #expect(state.pending.map(\.reservationID) == [f.key])
            if ["incomplete", "manifest", "accounting", "precision", "cpuBudget"].contains(flaw) {
                #expect(ResourceAdmissionService.capacity(agent: f.agent, state: state) == .zero)
            }
        }
    }

    @Test func reportReplayAndBootChangeCannotReleaseNewerCommitment() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let boot = UUID(), session = UUID()
            let message = try report(f, boot: boot, sequence: 10, acknowledgements: [try ack(f)])
            let accepted = try await ResourceAdmissionService.accept(
                message, agentID: try f.agent.requireID(), sessionID: session, inventoryComplete: true, on: app.db)
            guard case .accepted(let released) = accepted else { Issue.record("Expected acknowledgement"); return }
            #expect(released == [f.key])
            let next = f.current.growing(
                cpus: 3, memory: .init(guestBytes: 49152, backendOverheadBytes: 4096), policy: f.snapshot.policy)
            let nextKey = try await app.db.transaction { tx in
                try await ResourceAdmissionService.stageGrowth(
                    agentID: try f.agent.requireID(), workloadID: try f.vm.requireID(), generation: 2,
                    mutationID: UUID(),
                    admission: .init(snapshot: f.snapshot, reservation: next), previous: f.current, backend: .qemuVM,
                    on: tx
                ).0
            }
            let repeatedRequest = ObservedStateReport(
                requestId: message.requestId,
                agentId: message.agentId, vms: message.vms, resources: message.resources,
                resourceEnforcement: .init(
                    agentBootID: boot, sequence: 11, sampledAt: Date(),
                    inventoryComplete: true, acknowledgements: [try ack(f)]))
            for old in [
                message, repeatedRequest, try report(f, boot: boot, sequence: -1, acknowledgements: [try ack(f)]),
                try report(f, boot: boot, sequence: 9, acknowledgements: [try ack(f)]),
                try report(f, boot: UUID(), sequence: 11, acknowledgements: [try ack(f)]),
            ] {
                let outcome = try await ResourceAdmissionService.accept(
                    old, agentID: try f.agent.requireID(), sessionID: session, inventoryComplete: true, on: app.db)
                guard case .refused = outcome else { Issue.record("Replay accepted"); continue }
            }
            let row = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(row.state.pending.map(\.reservationID) == [nextKey])
            #expect(row.state.sequence == 10)
            f.vm.generation = 2
            f.vm.cpu = 3
            f.vm.memory = 49152
            f.vm.admittedReservation = next
            try await f.vm.save(on: app.db)
            let freshOld = try report(f, boot: boot, sequence: 12, acknowledgements: [try ack(f)])
            let staleGeneration = try await ResourceAdmissionService.accept(
                freshOld, agentID: try f.agent.requireID(), sessionID: session, inventoryComplete: true, on: app.db)
            guard case .accepted(let staleReleased) = staleGeneration else {
                Issue.record("Expected ordered report"); return
            }
            #expect(staleReleased.isEmpty)
            let newBoot = UUID(), newSession = UUID()
            _ = try await ResourceAdmissionService.accept(
                try report(f, boot: newBoot, sequence: 0, acknowledgements: []),
                agentID: try f.agent.requireID(), sessionID: newSession, inventoryComplete: true, on: app.db)
            let retiredBoot = try await ResourceAdmissionService.accept(
                try report(f, boot: boot, sequence: 99, acknowledgements: [try ack(f)]),
                agentID: try f.agent.requireID(), sessionID: newSession, inventoryComplete: true, on: app.db)
            guard case .refused = retiredBoot else { Issue.record("Retired boot accepted"); return }
            let retained = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(retained.state.pending.map(\.reservationID) == [nextKey])
        }
    }

    @Test func abortedTransactionCannotLeaveDurableClaim() async throws {
        enum Rollback: Error { case requested }
        try await withTestApp { app in
            let f = try await fixture(app)
            do {
                try await app.db.transaction { tx in
                    _ = try await ResourceAdmissionService.stageGrowth(
                        agentID: try f.agent.requireID(), workloadID: try f.vm.requireID(), generation: 2,
                        mutationID: UUID(),
                        admission: .init(
                            snapshot: f.snapshot,
                            reservation: f.current.growing(
                                cpus: 3, memory: .init(guestBytes: 49152, backendOverheadBytes: 4096),
                                policy: f.snapshot.policy)),
                        previous: f.current, backend: .qemuVM, on: tx)
                    throw Rollback.requested
                }
            } catch Rollback.requested {}
            let row = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(row.state.pending.map(\.reservationID) == [f.key])
        }
    }
    @Test func concurrentGrowthDoesNotOversubscribeDurableCapacity() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            f.agent.availableCPU = 0
            f.agent.availableCPUMicroUnits = 500_000
            try await f.agent.save(on: app.db)
            let next = f.current.growing(
                cpus: 3, memory: .init(guestBytes: 49152, backendOverheadBytes: 4096), policy: f.snapshot.policy)
            let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        do {
                            _ = try await app.db.transaction { tx in
                                try await ResourceAdmissionService.stageGrowth(
                                    agentID: try f.agent.requireID(), workloadID: try f.vm.requireID(),
                                    generation: 2, mutationID: UUID(),
                                    admission: .init(snapshot: f.snapshot, reservation: next),
                                    previous: f.current, backend: .qemuVM, on: tx)
                            }
                            return true
                        } catch let error as Abort where error.status == .conflict { return false }
                    }
                }
                var count = 0
                for try await accepted in group { if accepted { count += 1 } }
                return count
            }
            #expect(winners == 1)
            let row = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(row.state.pending.count == 2)
            #expect(ResourceAdmissionService.capacity(agent: f.agent, state: row.state).cpuMicroUnits == 0)
        }
    }

    @Test func provenLedgerChainCoversEarlierGrowthButNeverNewerClaims() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let row = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            let first = try #require(row.state.pending.first)
            let secondLedger = f.current.growing(
                cpus: 3, memory: .init(guestBytes: 49152, backendOverheadBytes: 4096), policy: f.snapshot.policy)
            let second = PendingResourceCommitment(
                reservationID: "second", kind: .vm,
                workloadID: try f.vm.requireID(), generation: 2, resourceClass: f.snapshot,
                previousReservation: f.current, reservation: secondLedger, backend: .qemuVM,
                cpuMicroUnits: 1_000_000, memoryBytes: 16384)
            let third = PendingResourceCommitment(
                reservationID: "third", kind: .vm,
                workloadID: try f.vm.requireID(), generation: 3, resourceClass: f.snapshot,
                previousReservation: secondLedger,
                reservation: secondLedger.growing(
                    cpus: 4,
                    memory: .init(guestBytes: 65536, backendOverheadBytes: 4096), policy: f.snapshot.policy),
                backend: .qemuVM, cpuMicroUnits: 1_000_000, memoryBytes: 16384)
            let desired = try f.snapshot.policy.runtimeLimits(guestBytes: 49152, backendOverheadBytes: 4096)
            let acknowledgement = WorkloadEnforcementAcknowledgement(
                kind: .vm, workloadId: try f.vm.requireID(),
                appliedGeneration: 2, resourceClass: f.snapshot, backend: .qemuVM, accountedReservation: secondLedger,
                runtimeGuestBytes: 49152, pageSizeBytes: 4096, desiredLimits: desired,
                appliedLimits: try desired.aligned(pageSizeBytes: 4096), cpuQuotaUnlimited: true,
                ownershipVerified: true)
            #expect(
                ResourceAdmissionService.coveredClaims(acknowledgement, pending: [third, second, first]) == [
                    f.key, "second",
                ])
            let metadataAcknowledgement = WorkloadEnforcementAcknowledgement(
                kind: .vm, workloadId: try f.vm.requireID(), appliedGeneration: 4,
                resourceClass: f.snapshot, backend: .qemuVM, accountedReservation: secondLedger,
                runtimeGuestBytes: 49152, pageSizeBytes: 4096, desiredLimits: desired,
                appliedLimits: try desired.aligned(pageSizeBytes: 4096), cpuQuotaUnlimited: true,
                ownershipVerified: true)
            #expect(
                ResourceAdmissionService.coveredClaims(metadataAcknowledgement, pending: [first, second]) == [
                    f.key, "second",
                ])
            // A later generation is not sufficient when its ledger cannot
            // cover another commitment recorded in that generation range.
            #expect(
                ResourceAdmissionService.coveredClaims(metadataAcknowledgement, pending: [first, second, third]).isEmpty
            )
            let broken = PendingResourceCommitment(
                reservationID: "broken", kind: .vm,
                workloadID: try f.vm.requireID(), generation: 2, resourceClass: f.snapshot,
                previousReservation: f.previous, reservation: secondLedger, backend: .qemuVM,
                cpuMicroUnits: 1_000_000, memoryBytes: 16384)
            #expect(ResourceAdmissionService.coveredClaims(acknowledgement, pending: [first, broken, third]).isEmpty)
        }
    }

    @Test func heartbeatCannotOverwriteAcceptedNetResourceSnapshot() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            try await app.agentService.beginObservedInventorySession(for: f.agent.identity.key)
            let message = try report(f, boot: UUID(), sequence: 1, acknowledgements: [try ack(f)])
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: message), fromAgentKey: f.agent.identity.key)
            try await app.agentService.updateAgentHeartbeat(
                .init(
                    agentId: try f.agent.requireID().uuidString,
                    resources: f.agent.resources), fromAgentKey: f.agent.identity.key)
            let persisted = try #require(try await Agent.find(try f.agent.requireID(), on: app.db))
            #expect(persisted.availableCPUMicroUnits == 15_500_000)
            let row = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(row.state.pending.isEmpty)
        }
    }

    @Test func concurrentlyArrivingReportsCannotRegressDurableSequence() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let boot = UUID(), session = UUID()
            let messages = try [1, 2, 3, 4].map { try report(f, boot: boot, sequence: Int64($0), acknowledgements: []) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for message in messages {
                    group.addTask {
                        _ = try await ResourceAdmissionService.accept(
                            message, agentID: try f.agent.requireID(),
                            sessionID: session, inventoryComplete: true, on: app.db)
                    }
                }
                try await group.waitForAll()
            }
            let row = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(row.state.sequence == 4)
            #expect(row.state.requestID == messages.last?.requestId)
            #expect(row.state.pending.map(\.reservationID) == [f.key])
        }
    }

    @Test func reconnectAndRevocationInvalidateCapacityWithoutLosingPendingCharges() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let boot = UUID()
            _ = try await ResourceAdmissionService.accept(
                try report(f, boot: boot, sequence: 1, acknowledgements: []),
                agentID: try f.agent.requireID(), sessionID: UUID(), inventoryComplete: true, on: app.db)
            let initial = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(ResourceAdmissionService.capacity(agent: f.agent, state: initial.state).cpuMicroUnits > 0)
            try await app.agentService.beginObservedInventorySession(for: f.agent.identity.key)
            let rotated = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(ResourceAdmissionService.capacity(agent: f.agent, state: rotated.state) == .zero)
            #expect(rotated.state.pending.map(\.reservationID) == [f.key])
            let fresh = try report(f, boot: boot, sequence: 2, acknowledgements: [])
            await app.agentService.applyObservedStateReport(
                try MessageEnvelope(message: fresh), fromAgentKey: f.agent.identity.key)
            let restored = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(ResourceAdmissionService.capacity(agent: f.agent, state: restored.state).cpuMicroUnits > 0)
            #expect(restored.state.pending.map(\.reservationID) == [f.key])
            await app.agentService.endObservedInventorySession(for: f.agent.identity.key)
            let revoked = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(ResourceAdmissionService.capacity(agent: f.agent, state: revoked.state) == .zero)
            #expect(revoked.state.pending.map(\.reservationID) == [f.key])
        }
    }

    @Test func failedNetResourceCommitCannotReleaseDurableOrCoordinationClaims() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let id = try f.agent.requireID()
            let reserved = await app.coordination.reserveCapacity(
                agentId: id.uuidString, vmId: f.key,
                amounts: .init(memory: 16384, disk: 0, cpuMicroUnits: 250_000),
                capacity: .init(memory: f.agent.availableMemory, disk: 0, cpuMicroUnits: 16_000_000))
            #expect(reserved)
            app.databases.middleware.use(RejectAcknowledgedResourceSave())
            do {
                _ = try await ResourceAdmissionService.accept(
                    try report(f, boot: UUID(), sequence: 1, acknowledgements: [try ack(f)]),
                    agentID: id, sessionID: UUID(), inventoryComplete: true, on: app.db)
                Issue.record("Injected report commit failure did not abort")
            } catch InjectedResourceSaveFailure.expected {}
            let row = try #require(try await AgentResourceAdmission.find(id, on: app.db))
            #expect(row.state.pending.map(\.reservationID) == [f.key])
            #expect(row.state.resources == nil)
            #expect(row.state.bootID == nil)
            let active = await app.coordination.activeReservations(agentIds: [id.uuidString])
            #expect(active[id.uuidString]?.cpuMicroUnits == 250_000)
            let reloaded = try #require(try await Agent.find(id, on: app.db))
            #expect(ResourceAdmissionService.capacity(agent: reloaded, state: row.state).cpuMicroUnits == 15_750_000)
        }
    }

    @Test func delayedPredecessorReportCannotSpendSuccessorSession() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let key = f.agent.identity.key
            let s1 = UUID(), s2 = UUID(), b1 = UUID(), b2 = UUID()
            try await app.agentService.beginObservedInventorySession(for: key, sessionID: s1)
            let baseline = try report(f, boot: b1, sequence: 100, acknowledgements: [])
            await app.agentService.enqueueObservedStateReport(
                try MessageEnvelope(message: baseline), fromAgentKey: key, inventorySession: s1
            ).value
            // Capture the predecessor frame and its socket token before S2,
            // then deterministically enqueue it only after S2 owns the row.
            let delayed = try MessageEnvelope(
                message: report(f, boot: b1, sequence: 101, acknowledgements: [try ack(f)]))
            try await app.agentService.beginObservedInventorySession(for: key, sessionID: s2)
            await app.agentService.enqueueObservedStateReport(delayed, fromAgentKey: key, inventorySession: s1).value
            let refused = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(refused.state.sequence == 100)
            #expect(refused.state.bootID == b1)
            #expect(refused.state.pending.map(\.reservationID) == [f.key])
            #expect(ResourceAdmissionService.capacity(agent: f.agent, state: refused.state) == .zero)
            // The new boot initially has no adoption/readback acknowledgements.
            let restarted = try report(f, boot: b2, sequence: 0, acknowledgements: [])
            await app.agentService.enqueueObservedStateReport(
                try MessageEnvelope(message: restarted), fromAgentKey: key, inventorySession: s2
            ).value
            let adopted = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(adopted.state.bootID == b2 && adopted.state.sequence == 0)
            #expect(adopted.state.pending.map(\.reservationID) == [f.key])
            // A late heartbeat from S1 cannot overwrite S2's resources either.
            try await app.agentService.updateAgentHeartbeat(
                .init(
                    agentId: try f.agent.requireID().uuidString,
                    resources: f.agent.resources), fromAgentKey: key, inventorySession: s1)
            let agent = try #require(try await Agent.find(try f.agent.requireID(), on: app.db))
            #expect(agent.availableCPUMicroUnits == 15_500_000)
            let freshEvidence = try report(f, boot: b2, sequence: 1, acknowledgements: [try ack(f)])
            await app.agentService.enqueueObservedStateReport(
                try MessageEnvelope(message: freshEvidence), fromAgentKey: key, inventorySession: s2
            ).value
            let confirmed = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(confirmed.state.pending.isEmpty)
        }
    }

    @Test func sameBootReconnectPreservesCursorUntilFreshHigherSequence() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let key = f.agent.identity.key, boot = UUID(), first = UUID(), second = UUID()
            try await app.agentService.beginObservedInventorySession(for: key, sessionID: first)
            await app.agentService.enqueueObservedStateReport(
                try MessageEnvelope(message: report(f, boot: boot, sequence: 100, acknowledgements: [])),
                fromAgentKey: key, inventorySession: first
            ).value
            try await app.agentService.beginObservedInventorySession(for: key, sessionID: second)
            await app.agentService.enqueueObservedStateReport(
                try MessageEnvelope(message: report(f, boot: boot, sequence: 99, acknowledgements: [try ack(f)])),
                fromAgentKey: key, inventorySession: second
            ).value
            let old = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(old.state.sequence == 100 && old.state.inventoryComplete == false)
            #expect(old.state.pending.map(\.reservationID) == [f.key])
            await app.agentService.enqueueObservedStateReport(
                try MessageEnvelope(message: report(f, boot: boot, sequence: 101, acknowledgements: [try ack(f)])),
                fromAgentKey: key, inventorySession: second
            ).value
            let fresh = try #require(try await AgentResourceAdmission.find(try f.agent.requireID(), on: app.db))
            #expect(fresh.state.bootID == boot && fresh.state.sequence == 101)
            #expect(fresh.state.inventoryComplete == true && fresh.state.pending.isEmpty)
        }
    }

    @Test func successorRegistrationWaitsForPredecessorFrameDrain() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let key = f.agent.identity.key, predecessor = UUID(), successor = UUID()
            let entered = SocketRegistrationLatch(), release = SocketRegistrationLatch(),
                finished = SocketRegistrationLatch()
            let processor = AgentWebSocketFrameProcessor { _ in
                await entered.signal()
                await release.wait()
                do { try await app.agentService.beginObservedInventorySession(for: key, sessionID: predecessor) } catch
                { Issue.record("Predecessor registration failed: \(error)") }
            }
            #expect(processor.enqueue("register") == .accepted)
            await entered.wait()
            let next = Task {
                await processor.finishAndDrain()
                try await app.agentService.beginObservedInventorySession(for: key, sessionID: successor)
                await finished.signal()
            }
            #expect(await app.agentService.observedInventorySessions[key] == nil)
            #expect(!(await finished.signaled))
            await release.signal()
            try await next.value
            #expect(await app.agentService.observedInventorySessions[key] == successor)
            let sqlSession = try await InventorySessionFence.current(agentID: try f.agent.requireID(), on: app.db)
            #expect(sqlSession == successor)
            #expect(processor.enqueue("late register") == .closed)
        }
    }

    @Test(arguments: [true, false])
    func realLateRegistrationCannotOverwriteSuccessorMetadataOrSite(usesExplicitSession: Bool) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Registration race")
            let scope = OrganizationScope.organization(try org.requireID())
            let firstSite = Site(name: "Old registration site", organizationScope: scope)
            let nextSite = Site(name: "Successor site", organizationScope: scope)
            try await firstSite.save(on: app.db)
            try await nextSite.save(on: app.db)
            let firstSiteID = try firstSite.requireID(), nextSiteID = try nextSite.requireID()
            let agent = try await builder.createAgent(named: "real-registration-race", siteID: firstSiteID)
            let peer = try await builder.createAgent(
                named: "eligible-site-peer", networkCapability: .overlay,
                lastHeartbeat: Date(), siteID: nextSiteID)
            let agentID = try agent.requireID(), key = agent.identity.key
            let prior = UUID(), lateSession = UUID(), successor = UUID()
            try await app.agentService.beginObservedInventorySession(for: key, sessionID: prior)
            let lateReplica = AgentService(app: app)
            let entered = SocketRegistrationLatch(), release = SocketRegistrationLatch()
            let late = Task {
                do {
                    _ = try await lateReplica.registerAgent(
                        AgentRegisterMessage(
                            agentId: agent.name, hostname: "stale-host", version: "stale-version",
                            resources: agent.resources, architecture: .x86_64, networkCapability: .userMode),
                        identity: agent.identity, siteID: firstSiteID,
                        inventorySessionID: usesExplicitSession ? lateSession : nil,
                        afterCapturingInventorySession: {
                            await entered.signal()
                            await release.wait()
                        })
                    Issue.record("Delayed real registration overwrote the successor")
                } catch let error as Abort { #expect(error.status == .conflict) }
            }
            await entered.wait()
            let profile = NodeDependencyObservation(
                id: .hostMemoryProfile, role: .compute, desiredState: .required,
                ownership: .observeOnly, supervisorState: .active,
                compatibility: .compatible, functionalState: .healthy,
                checkedAt: Date(), affectedCapabilities: [])
            let overlay = NodeDependencyObservation(
                id: .ovnOvs, role: .networking, desiredState: .required,
                ownership: .observeOnly, supervisorState: .active,
                compatibility: .compatible, functionalState: .healthy,
                checkedAt: Date(), lastHealthyAt: Date(), affectedCapabilities: [.overlayNetworking])
            peer.dependencyObservations = [overlay]
            peer.dependencyObservationsReceivedAt = Date()
            try await peer.save(on: app.db)
            let resources = AgentResources(
                totalCPU: 16, availableCPU: 12, totalMemory: 32 << 30, availableMemory: 20 << 30,
                totalDisk: 1 << 40, availableDisk: 1 << 40,
                memoryAccounting: .init(
                    physicalBytes: 32 << 30, hostReservedBytes: 4 << 30, workloadEffectiveBytes: 8 << 30,
                    qemuOverheadBytes: 1 << 30))
            let message = AgentRegisterMessage(
                agentId: agent.name, hostname: "successor-host", version: "successor-version",
                resources: resources, architecture: .arm64,
                hypervisors: [.init(type: .qemu, available: true, accelerated: true)],
                networkCapability: .overlay, sandboxCapable: true, resolverCapable: true,
                dependencyObservations: [profile, overlay])
            _ = try await app.agentService.registerAgent(
                message, identity: agent.identity, siteID: nextSiteID, inventorySessionID: successor)
            #expect(try await Site.find(nextSiteID, on: app.db)?.$networkControllerAgent.id == agentID)
            #expect(SiteNetworkAuthority.canAuthorTopology(peer, at: try await ClusterClock.read(on: app.db)))
            await release.signal()
            try await late.value
            let stored = try #require(try await Agent.find(agentID, on: app.db))
            #expect(stored.hostname == message.hostname && stored.version == message.version)
            #expect(stored.cpuArchitecture == .arm64)
            #expect(stored.hypervisors == message.hypervisors)
            #expect(
                stored.networkCapability == NetworkCapability.overlay.rawValue && stored.sandboxCapable
                    && stored.resolverCapable)
            #expect(stored.dependencyObservations == [profile, overlay])
            #expect(stored.memoryAccounting?.qemuOverheadBytes == (Int64(1) << 30))
            #expect(stored.$site.id == nextSiteID)
            #expect(try await Site.find(nextSiteID, on: app.db)?.$networkControllerAgent.id == agentID)
            #expect(try await Site.find(firstSiteID, on: app.db)?.$networkControllerAgent.id == nil)
            #expect(try await InventorySessionFence.current(agentID: agentID, on: app.db) == successor)
            await lateReplica.shutdown()
        }
    }

    @Test func lateRegistrationCannotReplaceSuccessorAcrossReplicas() async throws {
        try await withTestApp { app in
            let f = try await fixture(app)
            let key = f.agent.identity.key, prior = UUID(), late = UUID(), successor = UUID()
            try await app.agentService.beginObservedInventorySession(for: key, sessionID: prior)
            let otherReplica = AgentService(app: app)
            try await otherReplica.beginObservedInventorySession(
                for: key, sessionID: successor, expectation: .matches(prior))
            do {
                try await app.agentService.beginObservedInventorySession(
                    for: key, sessionID: late, expectation: .matches(prior))
                Issue.record("Late predecessor registration replaced successor")
            } catch let error as Abort { #expect(error.status == .conflict) }
            // The old socket is also forbidden to re-register after observing
            // the successor, rather than treating that successor as its predecessor.
            do {
                _ = try await app.agentService.registerAgent(
                    AgentRegisterMessage(
                        agentId: f.agent.name, hostname: f.agent.hostname,
                        version: f.agent.version, resources: f.agent.resources),
                    identity: f.agent.identity, inventorySessionID: prior)
                Issue.record("Superseded socket re-registered over the successor")
            } catch let error as Abort { #expect(error.status == .conflict) }
            let current = try await InventorySessionFence.current(agentID: try f.agent.requireID(), on: app.db)
            #expect(current == successor)
            #expect(await app.agentService.observedInventorySessions[key] == prior)
            #expect(await otherReplica.observedInventorySessions[key] == successor)
            await otherReplica.shutdown()
        }
    }

}

private enum InjectedResourceSaveFailure: Error { case expected }
private struct RejectAcknowledgedResourceSave: AsyncModelMiddleware {
    func update(model: Agent, on db: any Database, next: any AnyAsyncModelResponder) async throws {
        if model.availableCPUMicroUnits == 15_500_000 { throw InjectedResourceSaveFailure.expected }
        try await next.update(model, on: db)
    }
}

private actor SocketRegistrationLatch {
    private(set) var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        signaled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
