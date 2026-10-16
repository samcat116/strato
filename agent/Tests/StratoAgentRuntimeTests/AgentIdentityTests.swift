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
    @Test("Simulated Apple hosts advertise usable memory bounds")
    func simulatedAppleMemoryBounds() throws {
        let apple = try #require(
            Agent.simulatedHypervisorSupport().first(where: { $0.type == .appleVirtualization }))
        #expect(apple.available)
        #expect(apple.supportsMemorySize(1 << 30))
        #expect(!apple.supportsMemorySize(0))
        #expect(!apple.supportsMemorySize((1 << 30) + 1))
    }

}
