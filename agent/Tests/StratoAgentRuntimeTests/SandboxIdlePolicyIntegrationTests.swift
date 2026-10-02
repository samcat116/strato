import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Testing

@testable import StratoAgentRuntime

@Suite("idle policy Agent integration")
struct SandboxIdlePolicyIntegrationTests {
    @Test func dependenciesAndDefaultPolicyBlockBeforeRuntimeAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = Agent(
            agentID: "idle-policy-test", webSocketURL: "ws://127.0.0.1:8080/agent",
            configuration: runtimeTestConfiguration(path: root.path), logger: Logger(label: "idle-policy-test"))
        let desired = DesiredSandboxState(
            sandboxId: UUID(),
            spec: SandboxSpec(image: "test", cpus: 1, memoryBytes: 128 * 1024 * 1024),
            desiredStatus: .running, generation: 1)
        let item = ReconcileWorkItem(
            kind: .sandbox, id: desired.sandboxId.uuidString, generation: 1,
            steps: [], target: .sandbox(desired))
        #expect(try await agent.sandboxReconcileIdleSuspend(item) == .disabled)
        var policy = SandboxIdlePolicy()
        policy.enabled = true
        #expect(try await agent.sandboxReconcileIdleSuspend(item, policy: policy) == .disabled)
        // A nil runtime would throw if either disabled path attempted host
        // admission or invoked STR-312. No automatic producer is activated.
    }

    @Test func automaticPolicyCannotOverrideStoppedIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = Agent(
            agentID: "idle-intent-test", webSocketURL: "ws://127.0.0.1:8080/agent",
            configuration: runtimeTestConfiguration(path: root.path), logger: Logger(label: "idle-intent-test"))
        let desired = DesiredSandboxState(
            sandboxId: UUID(),
            spec: SandboxSpec(image: "test", cpus: 1, memoryBytes: 128 * 1024 * 1024),
            desiredStatus: .stopped, generation: 1)
        let item = ReconcileWorkItem(
            kind: .sandbox, id: desired.sandboxId.uuidString, generation: 1,
            steps: [], target: .sandbox(desired))
        var policy = SandboxIdlePolicy()
        policy.enabled = true
        #expect(
            try await agent.sandboxReconcileIdleSuspend(item, policy: policy, dependenciesReady: true)
                == .unknownActivity)
    }
}
