import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing
@testable import StratoAgentRuntime

@Suite("runtime host memory accounting")
struct HostMemoryAccountingRuntimeTests {
    private let mib: Int64 = 1024 * 1024

    @Test func inventoryAndRestartKeepSameEffectiveCommitment() async throws {
        let logger = Logger(label: "memory-accounting-test")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let spec = VMSpec(cpus: 1, memoryBytes: 512 * mib, maxMemoryBytes: 1024 * mib, boot: .disk(firmware: nil))
        let vm = VMManifestEntry(hypervisorType: .qemu, spec: spec, realizedMemoryReservationBytes: 1024 * mib)
        let sandbox = VMManifestEntry(sandboxSpec: SandboxSpec(image: "alpine:3", cpus: 1, memoryBytes: 256 * mib))
        let backend = MockHypervisorService(logger: logger, bootDelay: .zero)
        try await backend.createVM(
            vmId: "vm", spec: spec, imageInfo: nil, networkAttachments: [], metadata: nil, vsockCID: nil)
        try await backend.bootVM(vmId: "vm")
        let original = Agent(
            agentID: "host", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: path, simulation: SimulationConfig(enabled: true, memoryMB: 4096)), logger: logger)
        await original.seedMemoryAccounting(vm: vm, sandbox: sandbox, backend: backend)
        let resources = await original.getAgentResources()
        let accounting = try #require(resources.memoryAccounting)
        #expect(accounting.workloadEffectiveBytes == (1536 + 384) * mib)
        #expect(accounting.hostReservedBytes == 1024 * mib)
        #expect(resources.availableMemory == (4096 - 1024 - 1920) * mib)

        // Restored manifests are orphans until adoption. With no backend
        // inventory they reserve the same amount as the live domain sweep.
        let restoredVM = try JSONDecoder().decode(VMManifestEntry.self, from: JSONEncoder().encode(vm))
        let restarted = Agent(
            agentID: "host", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: path, simulation: SimulationConfig(enabled: true, memoryMB: 4096)), logger: logger)
        await restarted.seedMemoryAccounting(vm: restoredVM, sandbox: sandbox, backend: nil)
        #expect(await restarted.getAgentResources().memoryAccounting == accounting)
        await restarted.seedMemoryAccounting(vm: restoredVM, sandbox: sandbox, backend: backend)
        #expect(await restarted.getAgentResources().memoryAccounting == accounting)

        // A new reserve policy reports zero remaining capacity without
        // mutating the workload or issuing any lifecycle operation.
        let reserved = Agent(
            agentID: "host", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: path, simulation: SimulationConfig(enabled: true, memoryMB: 4096),
                hostMemoryReserveBytes: 4096 * mib), logger: logger)
        await reserved.seedMemoryAccounting(vm: restoredVM, sandbox: sandbox, backend: backend)
        #expect(await reserved.getAgentResources().availableMemory == 0)
        #expect(try await backend.getVMStatus(vmId: "vm") == .running)
        try await original.eventLoopGroup.shutdownGracefully()
        try await restarted.eventLoopGroup.shutdownGracefully()
        try await reserved.eventLoopGroup.shutdownGracefully()
    }
}

private extension Agent {
    func seedMemoryAccounting(vm: VMManifestEntry, sandbox: VMManifestEntry, backend: MockHypervisorService?) {
        managedVMs = [:]
        orphanedVMs = ["vm": vm]
        managedSandboxes = [:]
        orphanedSandboxes = ["sandbox": sandbox]
        hypervisorServices = backend.map { [.qemu: $0 as any HypervisorService] } ?? [:]
    }
}
