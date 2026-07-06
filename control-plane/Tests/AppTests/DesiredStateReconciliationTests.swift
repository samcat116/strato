import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
@testable import App

/// Tests for the desired/observed state split and reconciliation phase 2
/// (issue #260): mutations write desired state and bump the generation,
/// desired-state syncs are assembled from the database, observed-state reports
/// update status/generation and complete operations, deletions are confirmed
/// by absence, and dual-mode dispatch keys on the agent's protocol version.
@Suite("Desired State Reconciliation Tests", .serialized)
final class DesiredStateReconciliationTests {

    /// Same harness as `VMOperationTests`: full middleware stack, mock SpiceDB,
    /// API-key auth, one VM.
    private func withVMTestApp(
        _ test: (Application, User, VM, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "reconuser",
                email: "recon@example.com",
                displayName: "Recon User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Recon Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Recon Project",
                description: "Project for reconciliation tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "recon-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, vm, token)

            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            app.cleanupTestDatabase()
            throw error
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
    }

    /// Registers an in-memory agent with the given protocol version and maps
    /// the VM to it. Returns the agent's UUID string.
    private func registerAgent(
        app: Application,
        vm: VM,
        named agentName: String = "recon-agent",
        protocolVersion: Int?
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: agentName,
            hostname: "test-host",
            version: "1.0.0",
            capabilities: ["qemu"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: protocolVersion
        )
        let agentUUID = try await app.agentService.registerAgent(message, agentName: agentName)
        vm.hypervisorId = agentUUID.uuidString
        try await vm.save(on: app.db)
        return agentUUID.uuidString
    }

    private func report(
        agentId: String,
        vms: [ObservedVMState]
    ) throws -> MessageEnvelope {
        let report = ObservedStateReport(
            agentId: agentId,
            vms: vms,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 12,
                totalMemory: 1 << 34, availableMemory: 1 << 33,
                totalDisk: 1 << 40, availableDisk: 1 << 39
            )
        )
        return try MessageEnvelope(message: report)
    }

    // MARK: - Model defaults and generation bumps

    @Test("New VMs rest at desired shutdown with generation zero")
    func modelDefaults() async throws {
        try await withVMTestApp { _, _, vm, _ in
            #expect(vm.desiredStatus == .shutdown)
            #expect(vm.generation == 0)
            #expect(vm.observedGeneration == 0)

            vm.setDesiredStatus(.running)
            #expect(vm.desiredStatus == .running)
            #expect(vm.generation == 1)
        }
    }

    // MARK: - Mutations write desired state

    @Test("POST start writes desired running and bumps the generation")
    func startWritesDesiredState() async throws {
        try await withVMTestApp { app, _, vm, token in
            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.desiredStatus == .running)
            #expect(refreshed?.generation == 1)
        }
    }

    @Test("State-sync agents skip the transitional status; imperative agents keep it")
    func dualModeTransitionalStatus() async throws {
        try await withVMTestApp { app, _, vm, token in
            _ = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            try await app.test(.POST, "/api/vms/\(vm.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // No `.starting` marker on the sync path: in-flight state is
            // derived from desired != observed plus the pending operation.
            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
            #expect(refreshed?.desiredStatus == .running)
            #expect(refreshed?.generation == 1)

            // The operation stays pending until an observed report confirms.
            let pending = try await VMOperation.query(on: app.db)
                .filter(\.$vmID == vm.id!)
                .filter(\.$status == .pending)
                .count()
            #expect(pending == 1)
        }
    }

    @Test("agentSupportsStateSync keys on the registered protocol version")
    func protocolVersionGate() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let v1Agent = try await self.registerAgent(
                app: app, vm: vm, named: "old-agent", protocolVersion: 1)
            let supportsV1 = await app.agentService.agentSupportsStateSync(v1Agent)
            #expect(!supportsV1)

            let v2Agent = try await self.registerAgent(
                app: app, vm: vm, named: "new-agent", protocolVersion: 2)
            let supportsV2 = await app.agentService.agentSupportsStateSync(v2Agent)
            #expect(supportsV2)

            let legacyAgent = try await self.registerAgent(
                app: app, vm: vm, named: "legacy-agent", protocolVersion: nil)
            let supportsLegacy = await app.agentService.agentSupportsStateSync(legacyAgent)
            #expect(!supportsLegacy)
        }
    }

    // MARK: - Sync assembly

    @Test("Sync assembly lists the agent's VMs with desired status and generation")
    func syncAssemblyFromDatabase() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)

            let message = try await app.agentService.assembleDesiredState(agentId: agentId)
            #expect(message.vms.count == 1)
            let entry = try #require(message.vms.first)
            #expect(entry.vmId == vm.id)
            #expect(entry.desiredStatus == .running)
            #expect(entry.generation == 1)
            #expect(entry.hypervisorType == .qemu)
            #expect(entry.spec.cpus == vm.cpu)

            // VMs on other agents are not included.
            let other = try await app.agentService.assembleDesiredState(agentId: UUID().uuidString)
            #expect(other.vms.isEmpty)
        }
    }

    // MARK: - Observed-state report application

    @Test("A converged report updates status, generation, and completes the operation")
    func reportCompletesOperation() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let operation = VMOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1)]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .running)
            #expect(refreshed?.observedGeneration == 1)

            let completed = try await VMOperation.find(operation.id, on: app.db)
            #expect(completed?.status == .succeeded)
        }
    }

    @Test("A convergence failure fails the pending operation with the agent's error")
    func reportFailsOperationWithError() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let operation = VMOperation(vmID: vm.id!, userID: user.id!, kind: .boot)
            try await operation.save(on: app.db)

            // Generation 1 was never reached; the agent reports the failure.
            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .shutdown, observedGeneration: 0,
                        lastError: "boot failed: no bootable device")
                ]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let failed = try await VMOperation.find(operation.id, on: app.db)
            #expect(failed?.status == .failed)
            #expect(failed?.error == "boot failed: no bootable device")
        }
    }

    @Test("Progress-only entries neither settle status nor complete operations")
    func convergingEntriesAreProgressOnly() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)
            let operation = VMOperation(vmID: vm.id!, userID: user.id!, kind: .create)
            try await operation.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [
                    ObservedVMState(
                        vmId: vm.id!, status: .unknown, observedGeneration: 0,
                        convergencePhase: "downloading image")
                ]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)  // untouched

            let stillPending = try await VMOperation.find(operation.id, on: app.db)
            #expect(stillPending?.status == .pending)
        }
    }

    @Test("Absence with desired absent confirms deletion: row removed, operation succeeded")
    func absenceConfirmsDeletion() async throws {
        try await withVMTestApp { app, user, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.absent)
            try await vm.save(on: app.db)
            let operation = VMOperation(vmID: vm.id!, userID: user.id!, kind: .delete)
            try await operation.save(on: app.db)

            // Full-list semantics: the VM is missing from the agent's report.
            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let gone = try await VM.find(vm.id, on: app.db)
            #expect(gone == nil)

            let completed = try await VMOperation.find(operation.id, on: app.db)
            #expect(completed?.status == .succeeded)
        }
    }

    @Test("Absence of an established VM that should exist marks it as error")
    func absenceOfEstablishedVMIsDrift() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            vm.setStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .error)
        }
    }

    @Test("A never-established VM absent from the report is left alone")
    func absenceOfFreshVMIsIgnored() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            // `.created` may be mid-create on an agent that hasn't received
            // the sync yet — absence must not escalate it.
            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(agentId: agentId, vms: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
        }
    }

    @Test("Out-of-band drift is applied and detected without a pending operation")
    func driftDetectedWithoutOperation() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            vm.setStatus(.running)
            vm.observedGeneration = 1
            try await vm.save(on: app.db)

            // The guest paused itself out of band; no operation asked for it.
            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .paused, observedGeneration: 1)]
            )
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "recon-agent")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .paused)
        }
    }

    @Test("A report claiming another agent's identity is ignored")
    func reportOwnershipValidated() async throws {
        try await withVMTestApp { app, _, vm, _ in
            let agentId = try await self.registerAgent(app: app, vm: vm, protocolVersion: 2)

            vm.setDesiredStatus(.running)
            try await vm.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                vms: [ObservedVMState(vmId: vm.id!, status: .running, observedGeneration: 1)]
            )
            // Delivered over a connection authenticated as a different agent.
            await app.agentService.applyObservedStateReport(envelope, fromAgentNamed: "impostor")

            let refreshed = try await VM.find(vm.id, on: app.db)
            #expect(refreshed?.status == .created)
            #expect(refreshed?.observedGeneration == 0)
        }
    }
}
