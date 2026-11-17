import Foundation
import Logging
import StratoShared
import Synchronization
import Testing

@testable import StratoAgentCore
@testable import StratoAgentRuntime

private final class OutboundFailureLog: Sendable {
    let messages = Mutex<[String]>([])
}

private struct OutboundFailureLogHandler: LogHandler {
    let capture: OutboundFailureLog
    var logLevel: Logger.Level = .trace
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
        source: String, file: String, function: String, line: UInt
    ) {
        capture.messages.withLock { $0.append(message.description) }
    }
}

@Suite("Agent outbound delivery")
struct AgentOutboundDeliveryTests {
    @Test("Unregistered console, log, and exec sends report the transport rejection")
    func unregisteredSendsAreObservable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = OutboundFailureLog()
        let logger = Logger(label: "outbound-test") { _ in OutboundFailureLogHandler(capture: capture) }
        let agent = Agent(
            agentID: "outbound-test", webSocketURL: "ws://127.0.0.1:1/agent/ws",
            configuration: runtimeTestConfiguration(path: directory.path, simulation: SimulationConfig(enabled: true)),
            logger: logger)
        await agent.installDisconnectedOutboundTestClient()
        #expect(await agent.protocolAgreement == nil)
        let id = UUID().uuidString
        await agent.sendVMLog(vmId: id, level: .info, eventType: .statusChange, message: "created")
        await agent.sendConsoleData(vmId: id, sessionId: id, data: Data([0, 255]))
        await agent.sendConsoleDisconnected(vmId: id, sessionId: id, reason: "closed")
        await agent.sendGuestExecClosed(sessionId: id, reason: "closed")
        let messages = capture.messages.withLock { $0 }
        #expect(messages.contains { $0.contains("Failed to send VM log") })
        #expect(messages.contains { $0.contains("Failed to send console data") })
        #expect(messages.contains { $0.contains("Failed to send console disconnected message") })
        #expect(messages.contains { $0.contains("Failed to send guest exec closed message") })
        await agent.stop()
    }
}

extension Agent {
    fileprivate func installDisconnectedOutboundTestClient() {
        websocketClient = StratoAgentRuntime.WebSocketClient(
            url: "ws://127.0.0.1:1/agent/ws", agent: self, logger: logger,
            inboundContinuation: inboundContinuation)
    }
}
