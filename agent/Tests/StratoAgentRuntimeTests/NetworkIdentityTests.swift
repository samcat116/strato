import Foundation
import Logging
import Testing
import StratoAgentCore
import StratoShared
@testable import StratoAgentRuntime

@Suite("Network identity")
struct NetworkIdentityTests {
    @Test(arguments: [nil, "garbage", "ff:ff:ff:ff:ff:ff"] as [String?])
    func refusesMissingOrInvalidIdentity(mac: String?) async {
        let orchestrator = NetworkOrchestrator(
            networkService: NetworkServiceMacOS(logger: Logger(label: "test")), logger: Logger(label: "test"))
        await #expect(throws: NetworkError.self) {
            try await orchestrator.prepareAttachment(
                vmId: "vm",
                spec: NetworkSpec(
                    network: "test", networkId: UUID(), macAddress: mac), fallbackIndex: 0)
        }
    }

    @Test func preservesControlPlaneIdentityAcrossRecreation() async throws {
        let spec = NetworkSpec(network: "test", networkId: UUID(), macAddress: "52:54:00:AB:CD:EF")
        for _ in 0..<2 {
            let service = NetworkServiceMacOS(logger: Logger(label: "test"))
            let orchestrator = NetworkOrchestrator(networkService: service, logger: Logger(label: "test"))
            let attachment = try await orchestrator.prepareAttachment(vmId: "vm", spec: spec, fallbackIndex: 0)
            #expect(attachment.macAddress == "52:54:00:ab:cd:ef")
        }
    }
}
