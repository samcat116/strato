import Testing
import Foundation
import StratoShared
@testable import App

@Suite("AgentService schedulable transform Tests")
struct AgentSchedulableTransformTests {

    private func makeAgent(id: UUID, name: String, availableCPU: Int = 4) -> Agent {
        Agent(
            id: id,
            name: name,
            hostname: "host-\(name)",
            version: "1.0",
            capabilities: [],
            status: .online,
            resources: AgentResources(
                totalCPU: 8,
                availableCPU: availableCPU,
                totalMemory: 16,
                availableMemory: 8,
                totalDisk: 100,
                availableDisk: 50
            ),
            lastHeartbeat: Date()
        )
    }

    @Test("maps agent fields and derives running VM counts from the counts table")
    func testSchedulableAgents() throws {
        let idOne = UUID()
        let idTwo = UUID()
        let agents = [
            makeAgent(id: idOne, name: "One", availableCPU: 6),
            makeAgent(id: idTwo, name: "Two", availableCPU: 2),
        ]
        let counts = [
            idOne.uuidString: 2,
            idTwo.uuidString: 1,
        ]

        let result = AgentService.schedulableAgents(from: agents, runningVMCounts: counts)

        let one = try #require(result.first { $0.id == idOne.uuidString })
        let two = try #require(result.first { $0.id == idTwo.uuidString })

        #expect(one.name == "One")
        #expect(one.availableCPU == 6)
        #expect(one.runningVMCount == 2)

        #expect(two.availableCPU == 2)
        #expect(two.runningVMCount == 1)
    }

    @Test("agents with no mapped VMs report a zero running count")
    func testNoRunningVMs() {
        let agents = [makeAgent(id: UUID(), name: "Idle")]
        let result = AgentService.schedulableAgents(from: agents, runningVMCounts: [:])

        #expect(result.count == 1)
        #expect(result[0].runningVMCount == 0)
        #expect(result[0].supportedHypervisors.isEmpty)
        #expect(result[0].supportsInterVMNetworking == false)
    }

    @Test("agents without a persisted id are dropped rather than mis-keyed")
    func testMissingIdDropped() {
        let agent = makeAgent(id: UUID(), name: "NoId")
        agent.id = nil
        let result = AgentService.schedulableAgents(from: [agent], runningVMCounts: [:])
        #expect(result.isEmpty)
    }

    @Test("sandbox workload support keys on the advertised runtime")
    func testSandboxWorkloadSupport() throws {
        // A build may understand the wire fields without shipping the sandbox
        // runtime, so eligibility keys on the explicit capability alone.
        let incapable = makeAgent(id: UUID(), name: "incapable")
        incapable.sandboxCapable = false
        incapable.wireProtocolVersion = WireProtocol.currentVersion

        let capable = makeAgent(id: UUID(), name: "capable")
        capable.sandboxCapable = true
        capable.wireProtocolVersion = WireProtocol.currentVersion

        let result = AgentService.schedulableAgents(
            from: [incapable, capable],
            runningVMCounts: [:]
        )
        let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })

        #expect(byName["incapable"]?.supportsSandboxWorkloads == false)
        #expect(byName["capable"]?.supportsSandboxWorkloads == true)
    }

    /// Sandbox *networking* (STR-103) is a second capability on top of the
    /// runtime: OVN, the jailer barrier, and a guest image that configures the
    /// interface are installed independently of the agent binary.
    @Test("sandbox networking requires its own advertised capability")
    func testSandboxNetworkingSupport() throws {
        // Runs sandboxes, cannot network them: unjailed, user-mode, or an old
        // guest image. Schedulable for sandboxes, not for networked ones.
        let runtimeOnly = makeAgent(id: UUID(), name: "runtime-only")
        runtimeOnly.sandboxCapable = true
        runtimeOnly.sandboxNetworkingCapable = false
        runtimeOnly.wireProtocolVersion = WireProtocol.currentVersion

        let capable = makeAgent(id: UUID(), name: "net-capable")
        capable.sandboxCapable = true
        capable.sandboxNetworkingCapable = true
        capable.wireProtocolVersion = WireProtocol.currentVersion

        let result = AgentService.schedulableAgents(
            from: [runtimeOnly, capable], runningVMCounts: [:])
        let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })

        #expect(byName["runtime-only"]?.supportsSandboxNetworking == false)
        #expect(byName["runtime-only"]?.supportsSandboxWorkloads == true)
        #expect(byName["net-capable"]?.supportsSandboxNetworking == true)
    }

    /// vTPM keys on the advertised swtpm (issue #565): without it a Windows
    /// guest boots without the TPM it was promised.
    @Test("vTPM support requires the advertised swtpm")
    func testVTPMSupport() throws {
        let incapable = makeAgent(id: UUID(), name: "incapable")
        incapable.tpmCapable = false
        incapable.wireProtocolVersion = WireProtocol.currentVersion

        let capable = makeAgent(id: UUID(), name: "capable")
        capable.tpmCapable = true
        capable.wireProtocolVersion = WireProtocol.currentVersion

        let result = AgentService.schedulableAgents(
            from: [incapable, capable],
            runningVMCounts: [:]
        )
        let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })

        #expect(byName["incapable"]?.supportsVTPM == false)
        #expect(byName["capable"]?.supportsVTPM == true)
    }
}
