import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing
@testable import StratoAgentRuntime

@Suite("runtime enforcement capture")
struct ResourceEnforcementCaptureTests {
    @Test("actual report capture accounts the full ledger but mock readback cannot acknowledge enforcement")
    func unknownBackendDoesNotAcknowledge() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let logger = Logger(label: "enforcement-capture-test")
        let agent = Agent(
            agentID: "host", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: path, volumeStoragePath: path + "/volumes",
                simulation: SimulationConfig(enabled: true, cpuCores: 8, memoryMB: 4096)), logger: logger)
        let id = UUID()
        let policy = WorkloadResourceClassPolicy.burstable
        let snapshot = try WorkloadResourceClassSnapshot(
            classID: WorkloadResourceClassSnapshot.burstableID,
            siteID: UUID(), revision: 3, policy: policy)
        let memory = WorkloadMemoryReservation(
            guestBytes: 512 * 1024 * 1024,
            backendOverheadBytes: WorkloadMemoryReservation.defaultQEMUOverheadBytes)
        let reservation = WorkloadAdmittedReservation(cpus: 2, memory: memory, policy: policy)
        let spec = VMSpec(
            cpus: 2, memoryBytes: memory.guestBytes, boot: .disk(firmware: nil),
            resourceClass: snapshot, admittedReservation: reservation)
        let backend = MockHypervisorService(logger: logger, bootDelay: .zero)
        try await backend.createVM(
            vmId: id.uuidString, spec: spec, imageInfo: nil, networkAttachments: [], metadata: nil, vsockCID: nil)
        await agent.prepareEnforcementCapture(id: id, spec: spec, backend: backend)
        let item = ReconcileWorkItem(
            kind: .vm, id: id.uuidString, generation: 7, steps: [],
            target: .vm(.init(vmId: id, hypervisorType: .qemu, spec: spec, desiredStatus: .running, generation: 7)))
        await agent.resourceEnforcementWillConverge(item)
        await agent.resourceEnforcementDidConverge(item)
        #expect(await agent.enforcementApplicationCount() == 1)
        let observed = ObservedVMState(vmId: id, status: .running, observedGeneration: 7)
        let captured = await agent.captureResourceEnforcement(observedVMs: [observed], observedSandboxes: [])
        let enforcement = try #require(captured.enforcement)
        #expect(enforcement.inventoryComplete && enforcement.acknowledgements.isEmpty)
        #expect(captured.resources.availableCPUMicroUnits == 8_000_000 - reservation.cpuMicroUnits)
        #expect(captured.resources.memoryAccounting?.workloadEffectiveBytes == reservation.effectiveMemoryBytes)
        // A failed/in-progress retry withdraws the previous binding.
        await agent.resourceEnforcementWillConverge(item)
        #expect(await agent.enforcementApplicationCount() == 0)
        let failed = await agent.captureResourceEnforcement(observedVMs: [observed], observedSandboxes: [])
        #expect(failed.enforcement?.acknowledgements.isEmpty == true)
        #expect(failed.enforcement?.sequence == enforcement.sequence + 1)
        await agent.failEnforcementManifestPersistence()
        let incomplete = await agent.captureResourceEnforcement(observedVMs: [observed], observedSandboxes: [])
        #expect(incomplete.enforcement?.inventoryComplete == false)
        #expect(incomplete.enforcement?.acknowledgements.isEmpty == true)
        #expect(incomplete.resources.availableCPU == 0 && incomplete.resources.availableMemory == 0)
        let restarted = Agent(
            agentID: "host", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: path, volumeStoragePath: path + "/volumes",
                simulation: SimulationConfig(enabled: true, cpuCores: 8, memoryMB: 4096)), logger: logger)
        await restarted.prepareEnforcementCapture(id: id, spec: spec, backend: backend)
        let baseline = await restarted.captureResourceEnforcement(observedVMs: [observed], observedSandboxes: [])
        #expect(baseline.enforcement?.agentBootID != enforcement.agentBootID)
        #expect(baseline.enforcement?.sequence == 0 && baseline.enforcement?.acknowledgements.isEmpty == true)
        #expect(baseline.resources.memoryAccounting?.workloadEffectiveBytes == reservation.effectiveMemoryBytes)
        try await restarted.eventLoopGroup.shutdownGracefully()
        try await agent.eventLoopGroup.shutdownGracefully()
    }
}

private extension Agent {
    func prepareEnforcementCapture(id: UUID, spec: VMSpec, backend: MockHypervisorService) {
        managedVMs[id.uuidString] = VMManifestEntry(hypervisorType: .qemu, spec: spec)
        hypervisorServices[.qemu] = backend
        let local = MockStorageBackend(logger: logger, volumeStoragePath: configuration.volumeStoragePath)
        storageBackend = local
        storageBackends = StorageBackendRegistry(local: local, makeCeph: { _ in fatalError("No Ceph fixture") })
        snapshotInventoryUnreadable = false
    }
    func failEnforcementManifestPersistence() { manifestPersistFailed = true }
    func enforcementApplicationCount() -> Int { resourceEnforcementProducer.applications.count }
}
