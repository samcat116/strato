import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// Unit tests for `MockSandboxRuntime` (issue #470) — the simulation-mode
/// sandbox backend. The lifecycle half mirrors the mock hypervisor's contract
/// (status reflects the last transition, operations are idempotent); the exec
/// half is where the correctness risk lives: every session must emit
/// `.started`, then `.output`*, then exactly one terminal event, because a
/// session with zero or two terminal events wedges the control plane's
/// session teardown.
@Suite("Mock Sandbox Runtime")
struct MockSandboxRuntimeTests {

    private static let logger = Logger(label: "mock-sandbox-runtime-tests")

    /// A runtime with no artificial delays and no synthetic activity, for
    /// lifecycle/exec tests that need determinism.
    private func makeRuntime(
        workloadLifetime: Duration? = nil,
        logInterval: Duration? = nil
    ) -> MockSandboxRuntime {
        MockSandboxRuntime(
            logger: Self.logger,
            bootDelay: .zero,
            shutdownDelay: .zero,
            workloadLifetime: workloadLifetime,
            logInterval: logInterval
        )
    }

    private func makeSpec() -> SandboxSpec {
        SandboxSpec(image: "ghcr.io/acme/worker:v1", cpus: 2, memoryBytes: 512 * 1024 * 1024)
    }

    /// Thread-safe recorder for exec events / log lines delivered from
    /// `@Sendable` callbacks.
    private final class Recorder<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ item: T) {
            lock.lock()
            defer { lock.unlock() }
            items.append(item)
        }
        var all: [T] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// Poll until `condition` holds, failing after a generous deadline —
    /// timing-based assertions must not flake on slow CI.
    private func eventually(
        within deadline: Duration = .seconds(10),
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - Lifecycle

    @Test("Create, boot, shutdown, delete walk the expected statuses")
    func lifecycle() async throws {
        let runtime = makeRuntime()
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        let created = try await runtime.getSandboxStatus(sandboxId: "sb-1")
        #expect(created == .stopped)

        try await runtime.bootSandbox(sandboxId: "sb-1")
        let booted = try await runtime.getSandboxStatus(sandboxId: "sb-1")
        #expect(booted == .running)

        try await runtime.shutdownSandbox(sandboxId: "sb-1")
        let stopped = try await runtime.getSandboxStatus(sandboxId: "sb-1")
        #expect(stopped == .stopped)

        try await runtime.deleteSandbox(sandboxId: "sb-1")
        await #expect(throws: SandboxRuntimeError.self) {
            try await runtime.getSandboxStatus(sandboxId: "sb-1")
        }
    }

    @Test("Operations are idempotent at the already-satisfied level")
    func idempotency() async throws {
        let runtime = makeRuntime()
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        // A replayed create must not regress a running sandbox to stopped.
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        let afterReplayedCreate = try await runtime.getSandboxStatus(sandboxId: "sb-1")
        #expect(afterReplayedCreate == .running)

        try await runtime.bootSandbox(sandboxId: "sb-1")
        let afterReplayedBoot = try await runtime.getSandboxStatus(sandboxId: "sb-1")
        #expect(afterReplayedBoot == .running)

        try await runtime.shutdownSandbox(sandboxId: "sb-1")
        try await runtime.shutdownSandbox(sandboxId: "sb-1")
        let afterReplayedShutdown = try await runtime.getSandboxStatus(sandboxId: "sb-1")
        #expect(afterReplayedShutdown == .stopped)

        // Deletion is idempotent (the Agent guards on its manifest anyway).
        try await runtime.deleteSandbox(sandboxId: "sb-1")
        try await runtime.deleteSandbox(sandboxId: "sb-1")
    }

    @Test("Boot and shutdown of an unknown sandbox throw sandboxNotFound")
    func unknownSandbox() async throws {
        let runtime = makeRuntime()
        await #expect(throws: SandboxRuntimeError.self) {
            try await runtime.bootSandbox(sandboxId: "nope")
        }
        await #expect(throws: SandboxRuntimeError.self) {
            try await runtime.shutdownSandbox(sandboxId: "nope")
        }
    }

    @Test("Adoption resumes tracking and reports running")
    func adoption() async throws {
        let runtime = makeRuntime()
        let adopted = try await runtime.adoptSandbox(sandboxId: "sb-1", spec: makeSpec())
        #expect(adopted == .running)
        let observed = try await runtime.getSandboxStatus(sandboxId: "sb-1")
        #expect(observed == .running)
    }

    @Test("A networked spec is refused, mirroring the real runtime")
    func networkingUnsupported() async throws {
        let runtime = makeRuntime()
        let spec = SandboxSpec(
            image: "ghcr.io/acme/worker:v1", cpus: 1, memoryBytes: 256 * 1024 * 1024,
            network: NetworkSpec(network: "default"))
        await #expect(throws: SandboxRuntimeError.self) {
            try await runtime.createSandbox(
                sandboxId: "sb-net", spec: spec, registryCredential: nil, networkAttachments: [])
        }
    }

    // MARK: - One-shot workloads

    @Test("A configured lifetime transitions running workloads to exited with code 0")
    func oneShotWorkload() async throws {
        let runtime = makeRuntime(workloadLifetime: .milliseconds(50))
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        let exited = await eventually {
            (try? await runtime.getSandboxStatus(sandboxId: "sb-1")) == .exited
        }
        #expect(exited)
        let exitCode = await runtime.exitCode(sandboxId: "sb-1")
        #expect(exitCode == 0)
    }

    // MARK: - Exec sessions

    @Test("A non-tty exec session emits started, output, then exactly one exited")
    func oneShotExec() async throws {
        let runtime = makeRuntime()
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        let events = Recorder<SandboxExecEvent>()
        try await runtime.startExec(
            sandboxId: "sb-1", sessionId: "sess-1",
            request: SandboxExecRequest(command: ["echo", "hi"])
        ) { events.append($0) }

        let recorded = events.all
        #expect(recorded.first == .started)
        #expect(recorded.last == .exited(code: 0))
        let terminals = recorded.filter {
            if case .exited = $0 { return true }
            if case .closed = $0 { return true }
            return false
        }
        #expect(terminals.count == 1)
        let outputs = recorded.filter {
            if case .output = $0 { return true }
            return false
        }
        #expect(!outputs.isEmpty)

        // The session ended, so input for it reports execSessionNotFound.
        await #expect(throws: SandboxRuntimeError.self) {
            try await runtime.sendExecInput(sessionId: "sess-1", data: Data("x".utf8), eof: false)
        }

        // A replayed start for the completed session must not re-run it — that
        // would emit a second terminal event for the same control-plane session.
        try await runtime.startExec(
            sandboxId: "sb-1", sessionId: "sess-1",
            request: SandboxExecRequest(command: ["echo", "hi"])
        ) { events.append($0) }
        #expect(events.all == recorded)
    }

    @Test("A tty exec session echoes input and exits exactly once on EOF")
    func interactiveExec() async throws {
        let runtime = makeRuntime()
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        let events = Recorder<SandboxExecEvent>()
        try await runtime.startExec(
            sandboxId: "sb-1", sessionId: "sess-1",
            request: SandboxExecRequest(command: ["sh"], tty: true, rows: 24, cols: 80)
        ) { events.append($0) }
        #expect(events.all == [.started])

        try await runtime.resizeExec(sessionId: "sess-1", rows: 50, cols: 120)
        try await runtime.sendExecInput(sessionId: "sess-1", data: Data("ls\n".utf8), eof: false)
        #expect(events.all == [.started, .output(stream: "stdout", data: Data("ls\n".utf8))])

        try await runtime.sendExecInput(sessionId: "sess-1", data: nil, eof: true)
        #expect(events.all.last == .exited(code: 0))
        let terminals = events.all.filter {
            if case .exited = $0 { return true }
            if case .closed = $0 { return true }
            return false
        }
        #expect(terminals.count == 1)

        // A replayed start after EOF must not resurrect the ended session.
        let countAfterEOF = events.all.count
        try await runtime.startExec(
            sandboxId: "sb-1", sessionId: "sess-1",
            request: SandboxExecRequest(command: ["sh"], tty: true)
        ) { events.append($0) }
        #expect(events.all.count == countAfterEOF)
    }

    @Test("A duplicate startExec for the same session is a no-op replay")
    func duplicateExecStart() async throws {
        let runtime = makeRuntime()
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        let events = Recorder<SandboxExecEvent>()
        let request = SandboxExecRequest(command: ["sh"], tty: true)
        try await runtime.startExec(sandboxId: "sb-1", sessionId: "sess-1", request: request) {
            events.append($0)
        }
        try await runtime.startExec(sandboxId: "sb-1", sessionId: "sess-1", request: request) {
            events.append($0)
        }
        #expect(events.all == [.started])
    }

    @Test("startExec on an unknown or stopped sandbox throws")
    func execRequiresRunningSandbox() async throws {
        let runtime = makeRuntime()
        await #expect(throws: SandboxRuntimeError.self) {
            try await runtime.startExec(
                sandboxId: "nope", sessionId: "sess-1",
                request: SandboxExecRequest(command: ["sh"])
            ) { _ in }
        }
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        await #expect(throws: SandboxRuntimeError.self) {
            try await runtime.startExec(
                sandboxId: "sb-1", sessionId: "sess-1",
                request: SandboxExecRequest(command: ["sh"])
            ) { _ in }
        }
    }

    @Test("closeExec drops the session silently and is idempotent")
    func closeExec() async throws {
        let runtime = makeRuntime()
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        let events = Recorder<SandboxExecEvent>()
        try await runtime.startExec(
            sandboxId: "sb-1", sessionId: "sess-1",
            request: SandboxExecRequest(command: ["sh"], tty: true)
        ) { events.append($0) }

        await runtime.closeExec(sessionId: "sess-1")
        await runtime.closeExec(sessionId: "sess-1")
        // No terminal event: the closer already knows.
        #expect(events.all == [.started])
        await #expect(throws: SandboxRuntimeError.self) {
            try await runtime.sendExecInput(sessionId: "sess-1", data: nil, eof: true)
        }

        // A replayed start after close must not resurrect the ended session.
        try await runtime.startExec(
            sandboxId: "sb-1", sessionId: "sess-1",
            request: SandboxExecRequest(command: ["sh"], tty: true)
        ) { events.append($0) }
        #expect(events.all == [.started])
    }

    @Test("Sandbox shutdown ends live exec sessions with exactly one closed event")
    func shutdownClosesExecSessions() async throws {
        let runtime = makeRuntime()
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        let events = Recorder<SandboxExecEvent>()
        try await runtime.startExec(
            sandboxId: "sb-1", sessionId: "sess-1",
            request: SandboxExecRequest(command: ["sh"], tty: true)
        ) { events.append($0) }

        try await runtime.shutdownSandbox(sandboxId: "sb-1")
        #expect(events.all == [.started, .closed(reason: "sandbox stopped")])

        // The session is gone; a replayed shutdown emits nothing further.
        try await runtime.shutdownSandbox(sandboxId: "sb-1")
        #expect(events.all.count == 2)
    }

    @Test("Control-plane disconnect ends live exec sessions")
    func disconnectClosesExecSessions() async throws {
        let runtime = makeRuntime()
        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        let events = Recorder<SandboxExecEvent>()
        try await runtime.startExec(
            sandboxId: "sb-1", sessionId: "sess-1",
            request: SandboxExecRequest(command: ["sh"], tty: true)
        ) { events.append($0) }

        await runtime.controlPlaneDisconnected()
        #expect(events.all == [.started, .closed(reason: "control plane disconnected")])
    }

    // MARK: - Workload log emission

    @Test("Running sandboxes emit synthetic log lines while connected, and pause while disconnected")
    func logEmission() async throws {
        let runtime = makeRuntime(logInterval: .milliseconds(10))
        let lines = Recorder<(String, String, String)>()
        await runtime.setSandboxLogHandler { sandboxId, stream, line in
            lines.append((sandboxId, stream, line))
        }
        await runtime.controlPlaneConnected()

        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")

        let emitted = await eventually { lines.all.count >= 2 }
        #expect(emitted)
        let first = try #require(lines.all.first)
        #expect(first.0 == "sb-1")
        #expect(first.1 == "stdout")
        #expect(first.2.contains("simulated workload log line"))

        // Disconnect suspends emission; the line counter carries across.
        await runtime.controlPlaneDisconnected()
        try await Task.sleep(for: .milliseconds(50))
        let countWhileDisconnected = lines.all.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(lines.all.count == countWhileDisconnected)

        // Reconnect resumes for still-running sandboxes.
        await runtime.controlPlaneConnected()
        let resumed = await eventually { lines.all.count > countWhileDisconnected }
        #expect(resumed)

        try await runtime.shutdownSandbox(sandboxId: "sb-1")
    }

    @Test("Shutdown stops a sandbox's log emission")
    func logEmissionStopsOnShutdown() async throws {
        let runtime = makeRuntime(logInterval: .milliseconds(10))
        let lines = Recorder<(String, String, String)>()
        await runtime.setSandboxLogHandler { sandboxId, stream, line in
            lines.append((sandboxId, stream, line))
        }
        await runtime.controlPlaneConnected()

        try await runtime.createSandbox(
            sandboxId: "sb-1", spec: makeSpec(), registryCredential: nil, networkAttachments: [])
        try await runtime.bootSandbox(sandboxId: "sb-1")
        _ = await eventually { lines.all.count >= 1 }

        try await runtime.shutdownSandbox(sandboxId: "sb-1")
        try await Task.sleep(for: .milliseconds(50))
        let countAfterShutdown = lines.all.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(lines.all.count == countAfterShutdown)
    }
}
