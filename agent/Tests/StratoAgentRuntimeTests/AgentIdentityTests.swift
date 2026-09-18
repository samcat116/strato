import StratoShared
import Testing

@testable import StratoAgentRuntime

@Suite("Agent identity")
struct AgentIdentityTests {
    @Test("Simulation does not advertise volume I/O limits without a live domain")
    func simulationOmitsVolumeIOLimitCapability() throws {
        let qemu = try #require(
            Agent.simulatedHypervisorSupport().first(where: { $0.type == .qemu }))

        #expect(qemu.available)
        #expect(qemu.supportsVolumeIOLimits == nil)
    }
}
