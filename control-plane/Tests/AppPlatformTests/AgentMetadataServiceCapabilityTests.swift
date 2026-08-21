import ControlPlanePostgres
import AppTestSupport
import Foundation
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("Agent metadata-service capability", .serialized)
struct AgentMetadataServiceCapabilityTests {
    private let resources = AgentResources(
        totalCPU: 4, availableCPU: 4,
        totalMemory: 8 * 1024 * 1024 * 1024,
        availableMemory: 8 * 1024 * 1024 * 1024,
        totalDisk: 100 * 1024 * 1024 * 1024,
        availableDisk: 100 * 1024 * 1024 * 1024)

    @Test("Registration mapping is absent-means-false")
    func registrationMappingFailsClosed() {
        let implicit = Agent.from(
            registration: AgentRegisterMessage(
                agentId: "implicit", hostname: "implicit", version: "1", resources: resources),
            name: "implicit")
        #expect(!implicit.metadataServiceCapable)

        let capable = Agent.from(
            registration: AgentRegisterMessage(
                agentId: "capable", hostname: "capable", version: "1", resources: resources,
                metadataServiceCapable: true),
            name: "capable")
        #expect(capable.metadataServiceCapable)
    }

}
