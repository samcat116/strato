import Foundation
import Logging
import StratoAgentCore
import Testing
@testable import StratoAgentRuntime

@Suite("Agent startup ownership")
struct AgentStateDirectoryOwnershipTests {
    @Test("A refused startup cannot migrate permissions or quarantine a manifest")
    func refusalPrecedesStateAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-start-lock-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let owner = try AgentStateDirectoryLock(at: root)
        // A corrupt manifest would be preserved/quarantined if startup read it.
        let manifest = root + "/vm-manifest.json"
        let bytes = Data("invalid manifest".utf8)
        try bytes.write(to: URL(fileURLWithPath: manifest))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest)
        let agent = Agent(
            agentID: "contender", webSocketURL: "ws://127.0.0.1:1/agent",
            configuration: runtimeTestConfiguration(path: root), logger: Logger(label: "agent-lock-test"))
        do {
            try await agent.start()
            Issue.record("Startup unexpectedly acquired another agent's directory")
        } catch is AgentStateDirectoryInUse {
            // Expected before any state access or subsystem startup.
        } catch {
            Issue.record("Unexpected startup error: \(error)")
        }
        await agent.stop()
        withExtendedLifetime(owner) {
            #expect(throws: AgentStateDirectoryInUse.self) { try AgentStateDirectoryLock(at: root) }
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: manifest)) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: manifest)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root)) == [".agent.lock", "vm-manifest.json"])
    }
}
