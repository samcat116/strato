import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing
@testable import StratoAgentRuntime

@Suite("Requested hypervisor selection")
struct HypervisorSelectionTests {
    @Test(arguments: [HypervisorType.qemu, .firecracker])
    func usesRequestedDriverAndRejectsMissingDriver(defaultBackend: HypervisorType) async throws {
        let logger = Logger(label: "backend-selection-test")
        let agent = Agent(
            agentID: "test", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(
                path: FileManager.default.temporaryDirectory.path, hypervisorType: defaultBackend),
            logger: logger)
        let qemu = MockHypervisorService(logger: logger, hypervisorType: .qemu)
        let firecracker = MockHypervisorService(logger: logger, hypervisorType: .firecracker)
        await agent.installSelectionTestDrivers([.qemu: qemu, .firecracker: firecracker])
        #expect(await agent.getHypervisorService(for: .qemu) === qemu)
        #expect(await agent.getHypervisorService(for: .firecracker) === firecracker)
        await agent.installSelectionTestDrivers([defaultBackend: defaultBackend == .qemu ? qemu : firecracker])
        let unavailable: HypervisorType = defaultBackend == .qemu ? .firecracker : .qemu
        #expect(await agent.getHypervisorService(for: unavailable) == nil)
        try await agent.eventLoopGroup.shutdownGracefully()
    }
}

private extension Agent {
    func installSelectionTestDrivers(_ drivers: [HypervisorType: any HypervisorService]) {
        hypervisorServices = drivers
    }
}
