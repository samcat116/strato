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
    ) -> Agent {
        Agent(
            id: UUID(),
            name: id,
            hostname: "host-\(id)",
            version: "1.0",
            capabilities: [],
            status: status,
            resources: AgentResources(
                totalCPU: 8,
                availableCPU: 4,
                totalMemory: 16,
                availableMemory: 8,
                totalDisk: 100,
                availableDisk: 50
            ),
            hypervisors: hypervisors,
            lastHeartbeat: Date()
        )
    }

    @Test("skips a Firecracker-only agent in favor of a QEMU-capable one")
    func testMixedClusterSelectsQEMUAgent() throws {
        let agents = [
            makeAgent(id: "fc-only", hypervisors: [hypervisor(.firecracker)]),
            makeAgent(id: "qemu-capable", hypervisors: [hypervisor(.qemu)]),
        ]

        let selected = try #require(VolumeService.selectVolumeAgent(from: agents))
        #expect(selected.name == "qemu-capable")
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

        #expect(VolumeService.selectVolumeAgent(from: agents)?.name == "qemu-good")
    }

    @Test("accepts an agent that supports both Firecracker and QEMU")
    func testDualHypervisorAgent() {
        let agents = [
            makeAgent(id: "dual", hypervisors: [hypervisor(.firecracker), hypervisor(.qemu)])
        ]

        #expect(VolumeService.selectVolumeAgent(from: agents)?.name == "dual")
    }

    @Test("restricts selection to pool member agents when a member list is set")
    func testPoolMemberRestriction() throws {
        let member = makeAgent(id: "member", hypervisors: [hypervisor(.qemu)])
        let outsider = makeAgent(id: "outsider", hypervisors: [hypervisor(.qemu)])
        let memberId = try #require(member.id?.uuidString)

        let selected = VolumeService.selectVolumeAgent(
            from: [outsider, member], memberAgentIds: [memberId])
        #expect(selected?.name == "member")

        // No eligible agent is in the member list.
        let outsiderOnly = VolumeService.selectVolumeAgent(
            from: [outsider], memberAgentIds: [memberId])
        #expect(outsiderOnly == nil)
    }

    @Test("an empty member list leaves every QEMU-capable agent eligible")
    func testEmptyMemberListIsUnrestricted() {
        let agents = [makeAgent(id: "any", hypervisors: [hypervisor(.qemu)])]

        #expect(VolumeService.selectVolumeAgent(from: agents, memberAgentIds: [])?.name == "any")
    }
}
