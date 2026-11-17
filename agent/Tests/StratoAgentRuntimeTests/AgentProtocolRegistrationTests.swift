import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore
@testable import StratoAgentRuntime

@Suite("Protocol registration attempt ownership")
struct AgentProtocolRegistrationTests {
    @Test("A delayed response cannot consume a newer registration continuation")
    func supersededResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = Agent(
            agentID: "protocol-test", webSocketURL: "ws://127.0.0.1:1/agent/ws",
            configuration: runtimeTestConfiguration(path: directory.path, simulation: SimulationConfig(enabled: true)),
            logger: Logger(label: "protocol-registration-test"))
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let pending = Task { try await agent.waitForProtocolTestRegistration(signal: signal) }
        var iterator = ready.makeAsyncIterator()
        _ = await iterator.next()
        let generation = await agent.registrationGeneration
        let agreement = try AgentProtocolCompatibility.negotiate(
            local: AgentProtocolCompatibility.localOffer, remote: AgentProtocolCompatibility.localOffer,
            inventorySessionID: UUID())
        await agent.handleRegistrationResponse(
            AgentRegisterResponseMessage(
                requestId: UUID().uuidString, agentId: UUID().uuidString, name: "protocol-test", agreement: agreement),
            registrationGeneration: generation - 1)
        #expect(await agent.hasProtocolTestRegistrationWait)
        #expect(await agent.protocolAgreement == nil)
        await agent.failRegistrationOnTimeout(generation: generation)
        await #expect(throws: AgentError.self) { try await pending.value }
        signal.finish()
        await agent.stop()
    }
    @Test("A response delivered before send returns resolves the already armed wait")
    func immediateResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = Agent(
            agentID: "protocol-test", webSocketURL: "ws://127.0.0.1:1/agent/ws",
            configuration: runtimeTestConfiguration(path: directory.path, simulation: SimulationConfig(enabled: true)),
            logger: Logger(label: "protocol-registration-test"))
        let agentID = UUID().uuidString
        let agreement = try AgentProtocolCompatibility.negotiate(
            local: AgentProtocolCompatibility.localOffer, remote: AgentProtocolCompatibility.localOffer,
            inventorySessionID: UUID())
        let assigned = try await agent.waitForRegistrationResponse {
            #expect(await agent.hasProtocolTestRegistrationWait)
            await agent.handleRegistrationResponse(
                AgentRegisterResponseMessage(
                    requestId: UUID().uuidString, agentId: agentID, name: "protocol-test", agreement: agreement))
        }
        #expect(assigned == agentID)
        #expect(await agent.protocolAgreement == agreement)
        #expect(await !agent.hasProtocolTestRegistrationWait)
        await agent.stop()
    }

    @Test("A failed registration send clears its pending wait immediately")
    func sendFailure() async throws {
        struct SendFailure: Error {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = Agent(
            agentID: "protocol-test", webSocketURL: "ws://127.0.0.1:1/agent/ws",
            configuration: runtimeTestConfiguration(path: directory.path, simulation: SimulationConfig(enabled: true)),
            logger: Logger(label: "protocol-registration-test"))
        await #expect(throws: SendFailure.self) {
            try await agent.waitForRegistrationResponse { throw SendFailure() }
        }
        #expect(await !agent.hasProtocolTestRegistrationWait)
        await agent.stop()
    }

}

extension Agent {
    fileprivate var hasProtocolTestRegistrationWait: Bool { registrationContinuation != nil }

    fileprivate func waitForProtocolTestRegistration(signal: AsyncStream<Void>.Continuation) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            armRegistrationWait(continuation)
            signal.yield(())
        }
    }
}
