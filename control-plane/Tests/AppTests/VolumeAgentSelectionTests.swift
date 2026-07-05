import Testing
import Foundation
import StratoShared
@testable import App

@Suite("VolumeService agent selection Tests")
struct VolumeAgentSelectionTests {

    private func hypervisor(_ type: HypervisorType, available: Bool = true) -> HypervisorSupport {
        HypervisorSupport(
            type: type,
            available: available,
            accelerated: true,
            capabilities: .capabilities(for: type)
        )
    }

    private func makeAgent(
        id: String,
        hypervisors: [HypervisorSupport],
        status: AgentStatus = .online
    ) -> AgentInfo {
        AgentInfo(
            id: id,
            name: id,
            hostname: "host-\(id)",
            version: "1.0",
            capabilities: [],
            architecture: nil,
            hypervisors: hypervisors,
            networkCapability: nil,
            resources: AgentResources(
                totalCPU: 8,
                availableCPU: 4,
                totalMemory: 16,
                availableMemory: 8,
                totalDisk: 100,
                availableDisk: 50
            ),
            lastHeartbeat: Date(),
            status: status
        )
    }

    @Test("skips a Firecracker-only agent in favor of a QEMU-capable one")
    func testMixedClusterSelectsQEMUAgent() throws {
        let agents = [
            makeAgent(id: "fc-only", hypervisors: [hypervisor(.firecracker)]),
            makeAgent(id: "qemu-capable", hypervisors: [hypervisor(.qemu)]),
        ]

        let selected = try #require(VolumeService.selectVolumeAgent(from: agents))
        #expect(selected.id == "qemu-capable")
    }

    @Test("returns nil when only Firecracker-only agents are online")
    func testFirecrackerOnlyCluster() {
        let agents = [
            makeAgent(id: "fc-1", hypervisors: [hypervisor(.firecracker)]),
            makeAgent(id: "fc-2", hypervisors: [hypervisor(.firecracker)]),
        ]

        #expect(VolumeService.selectVolumeAgent(from: agents) == nil)
    }

    @Test("ignores QEMU agents that are not online")
    func testOfflineQEMUAgent() {
        let agents = [
            makeAgent(id: "qemu-offline", hypervisors: [hypervisor(.qemu)], status: .offline),
            makeAgent(id: "fc-online", hypervisors: [hypervisor(.firecracker)]),
        ]

        #expect(VolumeService.selectVolumeAgent(from: agents) == nil)
    }

    @Test("ignores agents whose QEMU probe reported unavailable")
    func testUnavailableQEMUProbe() {
        let agents = [
            makeAgent(id: "qemu-broken", hypervisors: [hypervisor(.qemu, available: false)]),
            makeAgent(id: "qemu-good", hypervisors: [hypervisor(.qemu)]),
        ]

        #expect(VolumeService.selectVolumeAgent(from: agents)?.id == "qemu-good")
    }

    @Test("accepts an agent that supports both Firecracker and QEMU")
    func testDualHypervisorAgent() {
        let agents = [
            makeAgent(id: "dual", hypervisors: [hypervisor(.firecracker), hypervisor(.qemu)])
        ]

        #expect(VolumeService.selectVolumeAgent(from: agents)?.id == "dual")
    }
}
