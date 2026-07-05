import Testing
import Foundation
import StratoShared
@testable import App

@Suite("AgentService schedulable transform Tests")
struct AgentSchedulableTransformTests {

    private func makeAgent(id: String, name: String, availableCPU: Int = 4) -> AgentInfo {
        AgentInfo(
            id: id,
            name: name,
            hostname: "host-\(id)",
            version: "1.0",
            capabilities: [],
            architecture: nil,
            hypervisors: [],
            networkCapability: nil,
            resources: AgentResources(
                totalCPU: 8,
                availableCPU: availableCPU,
                totalMemory: 16,
                availableMemory: 8,
                totalDisk: 100,
                availableDisk: 50
            ),
            lastHeartbeat: Date(),
            status: .online
        )
    }

    @Test("maps agent fields and derives running VM counts from the mapping")
    func testSchedulableAgents() throws {
        let agents = [
            makeAgent(id: "agent-1", name: "One", availableCPU: 6),
            makeAgent(id: "agent-2", name: "Two", availableCPU: 2),
        ]
        let mapping = [
            "vm1": "agent-1",
            "vm2": "agent-1",
            "vm3": "agent-2",
        ]

        let result = AgentService.schedulableAgents(from: agents, vmToAgentMapping: mapping)

        let one = try #require(result.first { $0.id == "agent-1" })
        let two = try #require(result.first { $0.id == "agent-2" })

        #expect(one.name == "One")
        #expect(one.availableCPU == 6)
        #expect(one.runningVMCount == 2)

        #expect(two.availableCPU == 2)
        #expect(two.runningVMCount == 1)
    }

    @Test("agents with no mapped VMs report a zero running count")
    func testNoRunningVMs() {
        let agents = [makeAgent(id: "agent-9", name: "Idle")]
        let result = AgentService.schedulableAgents(from: agents, vmToAgentMapping: [:])

        #expect(result.count == 1)
        #expect(result[0].runningVMCount == 0)
        #expect(result[0].supportedHypervisors.isEmpty)
        #expect(result[0].supportsInterVMNetworking == false)
    }
}
