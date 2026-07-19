import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import StratoShared
import Testing
import Vapor

@testable import App

/// End-to-end test for the sandbox exec attach WebSocket
/// (`GET /api/sandboxes/:id/exec/:sessionId/attach`, issue #423): a real Vapor
/// server on an ephemeral port, a genuine agent WebSocket registered through
/// the production handshake, and a genuine browser WebSocket attaching to a
/// minted exec session. Regression test for the control-plane crash where
/// attaching killed the process before the agent ever received
/// `sandbox_exec_start` — none of this path is reachable through Vapor's
/// in-memory `test()` harness, which never performs a WebSocket upgrade.
@Suite("Sandbox Exec Attach Integration", .serialized)
struct SandboxExecAttachIntegrationTests {

    @Test("Browser attach relays exec start to the agent and ready/output/exit back to the browser")
    func attachRelaysExecStartAndFrames() async throws {
        try await withRunningExecApp { app, port in
            // A real agent socket, registered through the production handshake.
            let agentName = "exec-attach-agent"
            let org = Organization(name: "Exec WS Org", description: "org for exec attach test")
            try await org.save(on: app.db)
            let presented = AgentRegistrationToken(
                agentName: agentName, expirationHours: 1,
                organizationScope: .organization(try org.requireID()))
            try await presented.save(on: app.db)

            var agentHeaders = HTTPHeaders()
            agentHeaders.bearerAuthorization = .init(token: presented.token)
            let agent = try await ExecWSClient.connect(
                url: "ws://127.0.0.1:\(port)/agent/ws?name=\(agentName)",
                headers: agentHeaders,
                on: app.eventLoopGroup)
            agent.send(text: try encodeSandboxAgentRegister(agentName: agentName))
            let registered = try await agent.nextEnvelope()
            #expect(registered.type == .agentRegisterResponse)

            // A user whose API key authenticates the browser socket. System
            // admin, so the attach authorization path does not depend on
            // SpiceDB relationships this test never writes.
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "execattach",
                email: "execattach@example.com",
                displayName: "Exec Attach",
                isSystemAdmin: true
            )
            let apiKey = try await user.generateAPIKey(on: app.db)

            // A pending exec session, exactly as POST /exec mints it.
            let sandboxId = UUID().uuidString
            let session = app.sandboxExecSessionManager.createPendingSession(
                sandboxId: sandboxId,
                agentName: agentName,
                userId: try user.requireID().uuidString,
                command: ["/bin/echo", "hello"],
                env: nil,
                workingDir: nil,
                tty: true,
                rows: 24,
                cols: 80
            )

            // The browser attaches over a real WebSocket upgrade.
            var browserHeaders = HTTPHeaders()
            browserHeaders.bearerAuthorization = .init(token: apiKey)
            let browser = try await ExecWSClient.connect(
                url: "ws://127.0.0.1:\(port)/api/sandboxes/\(sandboxId)/exec/\(session.sessionId)/attach",
                headers: browserHeaders,
                on: app.eventLoopGroup)

            // The agent must receive the exec start (skipping any periodic
            // desired-state syncs that share the socket).
            let start: SandboxExecStartMessage = try await {
                while true {
                    let envelope = try await agent.nextEnvelope()
                    if envelope.type == .desiredState { continue }
                    #expect(envelope.type == .sandboxExecStart)
                    return try envelope.decode(as: SandboxExecStartMessage.self)
                }
            }()
            #expect(start.sessionId == session.sessionId)
            #expect(start.sandboxId == sandboxId)
            #expect(start.command == ["/bin/echo", "hello"])
            #expect(start.tty == true)

            // Agent reports the spawn; the browser sees the ready frame.
            agent.send(
                text: try encodeEnvelope(
                    SandboxExecStartedMessage(sandboxId: sandboxId, sessionId: session.sessionId)))
            let ready = try await browser.nextControlFrame()
            #expect(ready.type == "ready")

            // Output bytes flow to the browser as a binary frame.
            agent.send(
                text: try encodeEnvelope(
                    SandboxExecOutputMessage(
                        sessionId: session.sessionId, stream: "stdout", rawData: Data("hello\n".utf8))))
            let output = try await browser.nextFrame()
            #expect(output == .binary(Data("hello\n".utf8)))

            // Browser stdin flows to the agent as sandbox_exec_input.
            browser.send(binary: Data("ls\n".utf8))
            let inputEnvelope = try await agent.nextEnvelope(skipping: [.desiredState])
            #expect(inputEnvelope.type == .sandboxExecInput)
            let input = try inputEnvelope.decode(as: SandboxExecInputMessage.self)
            #expect(input.sessionId == session.sessionId)
            #expect(input.rawData == Data("ls\n".utf8))

            // Exit tears the session down and closes the browser socket.
            agent.send(
                text: try encodeEnvelope(
                    SandboxExecExitMessage(sessionId: session.sessionId, exitCode: 0)))
            let exit = try await browser.nextControlFrame()
            #expect(exit.type == "exit")
            #expect(exit.exitCode == 0)
            try await browser.waitForClose()
            #expect(app.sandboxExecSessionManager.getSession(sessionId: session.sessionId) == nil)

            try await agent.close()
        }
    }
}

// MARK: - Running-server harness (mirrors AgentWebSocketIntegrationTests)

private func withRunningExecApp(_ test: (Application, Int) async throws -> Void) async throws {
    try await withApp { app in
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            guard let port = app.http.server.shared.localAddress?.port else {
                Issue.record("HTTP server did not report a bound port")
                await drainAndStopExecServer(app)
                return
            }
            try await test(app, port)
        } catch {
            await drainAndStopExecServer(app)
            throw error
        }
        await drainAndStopExecServer(app)
    }
}

/// Stop the server and wait for the agent controller's fire-and-forget
/// teardown (agent offline marking, post-registration sync) to finish touching
/// the database before the pool shuts down.
private func drainAndStopExecServer(_ app: Application) async {
    await app.server.shutdown()
    for iteration in 0..<200 {
        try? await Task.sleep(for: .milliseconds(10))
        let agents = (try? await Agent.query(on: app.db).all()) ?? []
        let stillOnline = agents.contains { $0.status == .online }
        if !stillOnline && iteration >= 3 {
            break
        }
    }
}

// MARK: - WebSocket test client

private enum WSFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

/// A thin async wrapper around a WebSocketKit client connection: collects
/// inbound frames into an async queue and exposes them with a timeout. Used
/// for both sides of the relay (the fake agent and the fake browser).
private final class ExecWSClient: Sendable {
    private let ws: WebSocket
    private let frames: ExecFrameCollector

    private init(ws: WebSocket, frames: ExecFrameCollector) {
        self.ws = ws
        self.frames = frames
    }

    static func connect(
        url: String,
        headers: HTTPHeaders,
        on eventLoopGroup: any EventLoopGroup
    ) async throws -> ExecWSClient {
        let frames = ExecFrameCollector()

        let ws: WebSocket = try await withCheckedThrowingContinuation { continuation in
            let resumed = NIOLockedValueBox(false)
            let future = WebSocket.connect(to: url, headers: headers, on: eventLoopGroup) { ws in
                ws.onBinary { _, buffer in
                    let data = Data(buffer.readableBytesView)
                    Task { await frames.deliver(.binary(data)) }
                }
                ws.onText { _, string in
                    Task { await frames.deliver(.text(string)) }
                }
                let shouldResume = resumed.withLockedValue { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: ws)
                }
            }
            future.whenFailure { error in
                let shouldResume = resumed.withLockedValue { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    continuation.resume(throwing: error)
                }
            }
        }
        return ExecWSClient(ws: ws, frames: frames)
    }

    func send(text: String) {
        ws.send(text)
    }

    func send(binary: Data) {
        ws.send([UInt8](binary))
    }

    // Timeouts are generous: CI runs the suite with `--parallel` on a cold
    // runner, where event-loop scheduling can stall for many seconds while
    // dozens of suites start up. On the happy path the waits return
    // immediately, so the headroom costs nothing.
    func nextFrame(timeout: Duration = .seconds(30)) async throws -> WSFrame {
        try await withExecTimeout(timeout) { [frames] in await frames.next() }
    }

    /// Await the next inbound frame decoded as a browser-facing JSON control
    /// frame (`{"type": ..., "exitCode": ..., "message": ...}`).
    func nextControlFrame(timeout: Duration = .seconds(30)) async throws -> ControlFrame {
        let frame = try await nextFrame(timeout: timeout)
        guard case .text(let text) = frame else {
            throw ExecUnexpectedFrameError(frame: frame)
        }
        return try JSONDecoder().decode(ControlFrame.self, from: Data(text.utf8))
    }

    struct ControlFrame: Decodable {
        let type: String
        let exitCode: Int?
        let message: String?
    }

    /// Await the next inbound frame decoded as a wire envelope, optionally
    /// skipping envelope types that share the socket (periodic syncs).
    func nextEnvelope(
        skipping: Set<MessageType> = [],
        timeout: Duration = .seconds(30)
    ) async throws -> MessageEnvelope {
        while true {
            let frame = try await nextFrame(timeout: timeout)
            let data: Data
            switch frame {
            case .binary(let d): data = d
            case .text(let s): data = Data(s.utf8)
            }
            let envelope = try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: data)
            if skipping.contains(envelope.type) { continue }
            return envelope
        }
    }

    func waitForClose(timeout: Duration = .seconds(30)) async throws {
        let onClose = ws.onClose
        try await withExecTimeout(timeout) {
            try? await onClose.get()
        }
    }

    func close() async throws {
        try await ws.close().get()
    }
}

/// Serializes inbound WebSocket frames (delivered on NIO event loops) into an
/// async queue a single consumer can await.
private actor ExecFrameCollector {
    private var buffered: [WSFrame] = []
    private var waiter: CheckedContinuation<WSFrame, Never>?

    func deliver(_ frame: WSFrame) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else {
            buffered.append(frame)
        }
    }

    func next() async -> WSFrame {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private struct ExecTimeoutError: Error {}

private struct ExecUnexpectedFrameError: Error {
    let frame: WSFrame
}

private func withExecTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ExecTimeoutError()
        }
        guard let result = try await group.next() else { throw ExecTimeoutError() }
        group.cancelAll()
        return result
    }
}

private func encodeEnvelope<T: WebSocketMessage>(_ message: T) throws -> String {
    let envelope = try MessageEnvelope(message: message)
    let data = try WireProtocol.makeEncoder().encode(envelope)
    return String(decoding: data, as: UTF8.self)
}

/// A sandbox-capable agent registration at the current wire protocol version.
private func encodeSandboxAgentRegister(agentName: String) throws -> String {
    try encodeEnvelope(
        AgentRegisterMessage(
            agentId: agentName,
            hostname: "test-host",
            version: "1.0.0",
            capabilities: ["firecracker"],
            resources: AgentResources(
                totalCPU: 16,
                availableCPU: 16,
                totalMemory: 1 << 34,
                availableMemory: 1 << 34,
                totalDisk: 1 << 40,
                availableDisk: 1 << 40
            ),
            protocolVersion: WireProtocol.currentVersion,
            sandboxCapable: true
        ))
}
