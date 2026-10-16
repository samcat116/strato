import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing
@testable import StratoAgentRuntime

@Suite("Guest configuration observation reporting and retirement")
struct GuestConfigObservationRuntimeTests {
    private func observation(_ status: GuestConfigObservation.Status, generation: Int64 = 7) throws
        -> GuestConfigObservation
    {
        try JSONDecoder().decode(
            GuestConfigObservation.self,
            from: Data(
                """
                {"generation":\(generation),"status":"\(status.rawValue)","error":\(status == .failed ? "\"observation failed\"" : "null"),"packages":[],"files":[],"services":[],"sysctls":[]}
                """.utf8))
    }

    private func withAgent(_ body: (Agent) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let agent = Agent(
            agentID: "test", webSocketURL: "wss://localhost/agent/ws",
            configuration: runtimeTestConfiguration(path: path, volumeStoragePath: path + "/volumes"),
            logger: Logger(label: "test.guest-observation"))
        do {
            try await body(agent)
            try await agent.eventLoopGroup.shutdownGracefully()
        } catch {
            try? await agent.eventLoopGroup.shutdownGracefully()
            throw error
        }
    }

    @Test("Drift and recovery observations agree with the captured reconciler verdict")
    func reportMatchesVerdictAcrossDriftAndRecovery() async throws {
        try await withAgent { agent in
            let id = UUID().uuidString
            let failed = try observation(.failed)
            await agent.cacheGuestObservation(failed, for: id)
            // The drift pass has published failure but the heartbeat captured
            // the previous success facts before that pass finished.
            #expect(
                await agent.guestConfigObservation(
                    for: id, status: .running, observedGeneration: 7, failedGeneration: nil) == nil)
            #expect(
                await agent.guestConfigObservation(
                    for: id, status: .running, observedGeneration: 7, failedGeneration: 7) == failed)
            #expect(
                await agent.guestConfigObservation(
                    for: id, status: .running, observedGeneration: 7, failedGeneration: 8) == nil)
            let converged = try observation(.converged)
            await agent.cacheGuestObservation(converged, for: id)
            // Recovery published its observation before clearing the failure.
            #expect(
                await agent.guestConfigObservation(
                    for: id, status: .running, observedGeneration: 7, failedGeneration: 7) == nil)
            #expect(
                await agent.guestConfigObservation(
                    for: id, status: .running, observedGeneration: 7, failedGeneration: nil) == converged)
            #expect(
                await agent.guestConfigObservation(
                    for: id, status: .running, observedGeneration: 8, failedGeneration: nil) == nil)
            #expect(
                await agent.guestConfigObservation(
                    for: id, status: .shutdown, observedGeneration: 7, failedGeneration: nil) == nil)
        }
    }

    @Test("Nil and empty guest intent retire observations while deferred nonempty intent retains them")
    func withdrawnIntentRetiresObservation() async throws {
        try await withAgent { agent in
            let id = UUID()
            let cached = try observation(.converged)
            for config: GuestConfig? in [nil, GuestConfig()] {
                await agent.cacheGuestObservation(cached, for: id.uuidString)
                let desired = DesiredVMState(
                    vmId: id, hypervisorType: .qemu,
                    spec: VMSpec(cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil)),
                    desiredStatus: .shutdown, generation: 8, guestConfig: config)
                let item = ReconcileWorkItem(
                    kind: .vm, id: id.uuidString, generation: 8, steps: [], target: .vm(desired))
                await agent.retireGuestConfigObservation(item)
                #expect(await agent.cachedGuestObservation(for: id.uuidString) == nil)
            }
            await agent.cacheGuestObservation(cached, for: id.uuidString)
            let managed = DesiredVMState(
                vmId: id, hypervisorType: .qemu,
                spec: VMSpec(cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil)),
                desiredStatus: .shutdown, generation: 8,
                guestConfig: GuestConfig(packages: [GuestPackage(name: "curl", state: .present)]))
            await agent.retireGuestConfigObservation(
                ReconcileWorkItem(kind: .vm, id: id.uuidString, generation: 8, steps: [], target: .vm(managed)))
            #expect(await agent.cachedGuestObservation(for: id.uuidString) == cached)
        }
    }

    @Test(
        "Managed, orphaned, and already absent VM teardown retires cached guest facts",
        arguments: ["managed", "orphaned", "absent"])
    func deletionRetiresObservation(presence: String) async throws {
        try await withAgent { agent in
            let id = UUID()
            await agent.cacheGuestObservation(try observation(.converged), for: id.uuidString)
            try await agent.prepareGuestObservationDeletion(id: id, presence: presence)
            let desired = DesiredVMState(
                vmId: id, hypervisorType: .qemu,
                spec: VMSpec(cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil)),
                desiredStatus: .absent, generation: 8)
            try await agent.reconcileDelete(
                ReconcileWorkItem(kind: .vm, id: id.uuidString, generation: 8, steps: [.delete], target: .vm(desired)))
            #expect(await agent.cachedGuestObservation(for: id.uuidString) == nil)
        }
    }
}

private extension Agent {
    func cacheGuestObservation(_ observation: GuestConfigObservation, for id: String) {
        guestConfigObservationCache[id] = observation
    }
    func cachedGuestObservation(for id: String) -> GuestConfigObservation? { guestConfigObservationCache[id] }
    func prepareGuestObservationDeletion(id: UUID, presence: String) async throws {
        guard presence != "absent" else { return }
        let spec = VMSpec(cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil))
        let backend = MockHypervisorService(logger: logger, bootDelay: .zero)
        try await backend.createVM(
            vmId: id.uuidString, spec: spec, imageInfo: nil, networkAttachments: [], metadata: nil, vsockCID: nil)
        hypervisorServices[.qemu] = backend
        let entry = VMManifestEntry(hypervisorType: .qemu, spec: spec)
        if presence == "orphaned" { orphanedVMs[id.uuidString] = entry } else { managedVMs[id.uuidString] = entry }
    }
}
