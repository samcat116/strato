import Foundation
import StratoShared
import Testing

@testable import App

@Suite("Agent dependency health gates")
struct AgentDependencyHealthTests {
    @Test("Duplicate dependency IDs retain only the freshest observation")
    func duplicateDependencyIDs() throws {
        let older = observation(
            .libvirt, capability: .qemuPlacement, state: .unhealthy,
            checkedAt: Date(timeIntervalSince1970: 100))
        let networking = observation(
            .ovnOvs, capability: .overlayNetworking, state: .healthy,
            checkedAt: Date(timeIntervalSince1970: 150))
        let newer = observation(
            .libvirt, capability: .qemuPlacement, state: .healthy,
            checkedAt: Date(timeIntervalSince1970: 200))

        let normalized = AgentService.normalizedDependencyObservations([older, networking, newer])

        #expect(normalized.map(\.id) == [.libvirt, .ovnOvs])
        #expect(try #require(normalized.first).checkedAt == newer.checkedAt)
        #expect(try #require(normalized.first).functionalState == .healthy)
    }

    @Test("Fresh health gates only the capability it affects")
    func featureScopedGating() {
        let now = Date()
        let agent = makeAgent(observations: [
            observation(.libvirt, capability: .qemuPlacement, state: .unhealthy, checkedAt: now),
            observation(.ovnOvs, capability: .overlayNetworking, state: .healthy, checkedAt: now),
        ])

        #expect(!agent.supportedHypervisors.contains(.qemu))
        #expect(agent.supportedHypervisors.contains(.firecracker))
        #expect(agent.supportsInterVMNetworking)
    }

    @Test("Stale observations refuse new placement without changing agent liveness")
    func staleObservation() {
        let stale = Date().addingTimeInterval(-61)
        let agent = makeAgent(observations: [
            observation(.libvirt, capability: .qemuPlacement, state: .healthy, checkedAt: stale),
            observation(.ovnOvs, capability: .overlayNetworking, state: .healthy, checkedAt: stale),
        ])

        #expect(agent.status == .online)
        #expect(!agent.supportedHypervisors.contains(.qemu))
        #expect(!agent.supportsInterVMNetworking)
    }

    @Test("A first degraded sample remains eligible for hysteresis")
    func degradedHysteresis() {
        let agent = makeAgent(observations: [
            observation(.libvirt, capability: .qemuPlacement, state: .degraded, checkedAt: Date())
        ])
        #expect(agent.supportedHypervisors.contains(.qemu))
    }

    private func makeAgent(observations: [NodeDependencyObservation]) -> Agent {
        Agent(
            name: "node-1", hostname: "node-1", version: "test", status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000, availableMemory: 16_000,
                totalDisk: 100_000, availableDisk: 100_000),
            hypervisors: [
                HypervisorSupport(
                    type: .qemu, available: true, accelerated: true,
                    capabilities: .capabilities(for: .qemu)),
                HypervisorSupport(
                    type: .firecracker, available: true, accelerated: true,
                    capabilities: .capabilities(for: .firecracker)),
            ],
            networkCapability: .overlay,
            sandboxCapable: true,
            sandboxNetworkingCapable: true,
            resolverCapable: true,
            dependencyObservations: observations)
    }

    private func observation(
        _ id: NodeDependencyID,
        capability: NodeCapability,
        state: NodeDependencyFunctionalState,
        checkedAt: Date
    ) -> NodeDependencyObservation {
        NodeDependencyObservation(
            id: id,
            role: id == .libvirt ? .compute : .networking,
            desiredState: .required,
            ownership: .observeOnly,
            supervisorState: .active,
            compatibility: .compatible,
            functionalState: state,
            checkedAt: checkedAt,
            lastHealthyAt: state == .unhealthy ? nil : checkedAt,
            reason: state == .unhealthy
                ? .init(code: .functionalProbeFailed, message: "test failure") : nil,
            consecutiveFailures: state == .unhealthy ? 2 : 0,
            affectedCapabilities: [capability])
    }
}
