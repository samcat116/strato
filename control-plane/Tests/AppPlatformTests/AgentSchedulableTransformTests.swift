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

    @Test("sandbox workload support requires both the advertised runtime and a v5+ protocol")
    func testSandboxWorkloadSupport() throws {
        // Capability alone (pre-v5 protocol): desired sandbox entries could
        // never reach the agent, so it must not be sandbox-schedulable.
        let capableOldProtocol = makeAgent(id: UUID(), name: "capable-old")
        capableOldProtocol.sandboxCapable = true
        capableOldProtocol.wireProtocolVersion = WireProtocol.sandboxSyncMinimumVersion - 1

        // Version alone: a v5 build may predate the sandbox runtime.
        let versionOnly = makeAgent(id: UUID(), name: "version-only")
        versionOnly.sandboxCapable = false
        versionOnly.wireProtocolVersion = WireProtocol.currentVersion

        // Both signals present.
        let capable = makeAgent(id: UUID(), name: "capable")
        capable.sandboxCapable = true
        capable.wireProtocolVersion = WireProtocol.currentVersion

        // Rows predating protocol recording read as legacy version 0.
        let unknownVersion = makeAgent(id: UUID(), name: "unknown-version")
        unknownVersion.sandboxCapable = true
        unknownVersion.wireProtocolVersion = nil

        let result = AgentService.schedulableAgents(
            from: [capableOldProtocol, versionOnly, capable, unknownVersion],
            runningVMCounts: [:]
        )
        let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })

        #expect(byName["capable-old"]?.supportsSandboxWorkloads == false)
        #expect(byName["version-only"]?.supportsSandboxWorkloads == false)
        #expect(byName["capable"]?.supportsSandboxWorkloads == true)
        #expect(byName["unknown-version"]?.supportsSandboxWorkloads == false)
    }

    /// vTPM follows the same two-signal rule as the sandbox runtime (issue
    /// #565): swtpm on the host proves the feature can be realized, and a v17+
    /// protocol proves `VMSpec.machine` reaches the agent at all. Either alone
    /// leaves a Windows guest booting without the TPM it was promised.
    @Test("vTPM support requires both the advertised swtpm and a v17+ protocol")
    func testVTPMSupport() throws {
        let capableOldProtocol = makeAgent(id: UUID(), name: "capable-old")
        capableOldProtocol.tpmCapable = true
        capableOldProtocol.wireProtocolVersion = WireProtocol.machineProfileMinimumVersion - 1

        let versionOnly = makeAgent(id: UUID(), name: "version-only")
        versionOnly.tpmCapable = false
        versionOnly.wireProtocolVersion = WireProtocol.currentVersion

        let capable = makeAgent(id: UUID(), name: "capable")
        capable.tpmCapable = true
        capable.wireProtocolVersion = WireProtocol.currentVersion

        let unknownVersion = makeAgent(id: UUID(), name: "unknown-version")
        unknownVersion.tpmCapable = true
        unknownVersion.wireProtocolVersion = nil

        let result = AgentService.schedulableAgents(
            from: [capableOldProtocol, versionOnly, capable, unknownVersion],
            runningVMCounts: [:]
        )
        let byName = Dictionary(uniqueKeysWithValues: result.map { ($0.name, $0) })

        #expect(byName["capable-old"]?.supportsVTPM == false)
        #expect(byName["version-only"]?.supportsVTPM == false)
        #expect(byName["capable"]?.supportsVTPM == true)
        #expect(byName["unknown-version"]?.supportsVTPM == false)

        // Secure Boot needs only the protocol, so it tracks the version alone.
        #expect(byName["version-only"]?.supportsMachineProfile == true)
        #expect(byName["capable-old"]?.supportsMachineProfile == false)
    }
}
