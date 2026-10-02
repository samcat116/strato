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

    @Test(arguments: [DesiredSandboxStatus.running, .stopped, .suspended])
    func automaticPolicyRequiresAdmittedSuspendedIntent(status: DesiredSandboxStatus) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = Agent(
            agentID: "idle-intent-test", webSocketURL: "ws://127.0.0.1:8080/agent",
            configuration: runtimeTestConfiguration(path: root.path), logger: Logger(label: "idle-intent-test"))
        let desired = DesiredSandboxState(
            sandboxId: UUID(),
            spec: SandboxSpec(image: "test", cpus: 1, memoryBytes: 128 * 1024 * 1024),
            desiredStatus: status, generation: 1)
        let item = ReconcileWorkItem(
            kind: .sandbox, id: desired.sandboxId.uuidString, generation: 1,
            steps: [], target: .sandbox(desired))
        var policy = SandboxIdlePolicy()
        policy.enabled = true
        #expect(
            try await agent.sandboxReconcileIdleSuspend(item, policy: policy, dependenciesReady: true)
                == .unknownActivity)
    }

    @Test func admittedSuspendedIntentStillRequiresSupportedIdleRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = Agent(
            agentID: "idle-admitted-test", webSocketURL: "ws://127.0.0.1:8080/agent",
            configuration: runtimeTestConfiguration(path: root.path), logger: Logger(label: "idle-admitted-test"))
        await agent.installIdlePolicyTestRuntime()
        let desired = DesiredSandboxState(
            sandboxId: UUID(), spec: SandboxSpec(image: "test", cpus: 1, memoryBytes: 128 * 1024 * 1024),
            desiredStatus: .suspended, generation: 1, suspensionStorageBudgetBytes: 256 * 1024 * 1024,
            automaticSuspensionFence: SandboxAutomaticSuspensionFence(
                operationId: UUID(), generation: 1,
                activityRevision: 0, admissionToken: UUID(), guestProtocolVersion: 5))
        let item = ReconcileWorkItem(
            kind: .sandbox, id: desired.sandboxId.uuidString, generation: 1,
            steps: [.shutdown], target: .sandbox(desired))
        var policy = SandboxIdlePolicy()
        policy.enabled = true
        #expect(
            try await agent.sandboxReconcileIdleSuspend(item, policy: policy, dependenciesReady: true)
                == .unsupportedBackend)
    }

}

extension Agent {
    fileprivate func installIdlePolicyTestRuntime() {
        sandboxRuntime = MockSandboxRuntime(logger: Logger(label: "idle-policy-mock"))
    }
}
