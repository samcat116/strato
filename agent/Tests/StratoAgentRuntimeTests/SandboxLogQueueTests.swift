import Foundation
import Logging
import StratoShared
import Testing
@testable import StratoAgentRuntime

@Suite("Agent sandbox workload log pressure")
struct SandboxLogQueueTests {
    @Test("Runtime handler queue sheds logs while the outbound consumer stalls")
    func slowOutboundConsumer() async throws {
        let agent = Agent(
            agentID: "test", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(path: FileManager.default.temporaryDirectory.path),
            logger: Logger(label: "sandbox-log-queue-test"))
        // This is the same synchronous queue used by the runtime log handler.
        // Retain one active line as a pump blocked on sendMessage would do.
        let queue = agent.sandboxLogLines
        queue.append(("s", "stdout", "active"), byteCount: 13)
        let active = queue.drain(maxCount: 1)
        #expect(active.count == 1)
        let line = String(repeating: "x", count: 8192)
        for _ in 0..<20_000 { queue.append(("s", "stdout", line), byteCount: 8199) }
        #expect(queue.snapshot.bytes <= BoundedLogQueue<(String, String, String)>.defaultByteLimit)
        #expect(queue.snapshot.count <= 503)
        #expect(queue.snapshot.dropped > 19_000)
        // Log pressure does not close the queue or any interactive session.
        #expect(queue.append(("s", "stdout", "tail"), byteCount: 11))
        queue.finish()
        #expect(queue.snapshot.bytes == 0)
        try await agent.eventLoopGroup.shutdownGracefully()
    }
    @Test("Disconnected delivery increments the active-line loss counter without closing the log queue")
    func disconnectedDelivery() async throws {
        let agent = Agent(
            agentID: "test", webSocketURL: "ws://localhost/agent/ws",
            configuration: runtimeTestConfiguration(path: FileManager.default.temporaryDirectory.path),
            logger: Logger(label: "sandbox-log-disconnect-test"))
        await agent.sendSandboxLogLine(sandboxId: "s", stream: "stdout", line: "dropped")
        #expect(agent.sandboxLogLines.snapshot.dropped == 1)
        #expect(agent.sandboxLogLines.append(("s", "stdout", "next"), byteCount: 11))
        agent.sandboxLogLines.finish()
        try await agent.eventLoopGroup.shutdownGracefully()
    }

}
