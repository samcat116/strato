import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

/// End-to-end tests for the VM and sandbox guest-exec WebSocket routes: a real Vapor
/// server on an ephemeral port, a genuine agent WebSocket registered through
/// the production handshake, and a genuine browser WebSocket attaching to a
/// minted exec session. Regression test for the control-plane crash where
/// attaching killed the process before the agent ever received
/// `guest_exec_start` — none of this path is reachable through Vapor's
/// in-memory `test()` harness, which never performs a WebSocket upgrade.
@Suite("Guest Exec Attach Integration", .serialized)
struct GuestExecAttachIntegrationTests {

    @Test(
        "VM and sandbox routes preserve raw framing and support multiplexed framing",
        arguments: [GuestResourceKind.sandbox, GuestResourceKind.virtualMachine],
        ExecTestOutputMode.allCases)
    func attachRelaysExecStartAndFrames(
        resourceKind: GuestResourceKind,
        outputMode: ExecTestOutputMode
    ) async throws {
        try await withRunningExecApp { app, port in
            // A real agent socket, registered through the production handshake:
            // SPIFFE/mTLS, the only way an agent authenticates. SPIRE is enabled
            // without a trust bundle, so the XFCC `URI=` alone establishes
            // identity (as it does behind an Envoy that verified the cert), and
            // the enrollment row supplies the org scope a new agent needs.
            let agentName = "exec-attach-agent"
            app.spireService = SPIREService(
                config: SPIREServiceConfig(enabled: true, trustDomain: "strato.local"),
                logger: app.logger,
                httpClient: app.client)

            let org = Organization(name: "Exec WS Org", description: "org for exec attach test")
            try await org.save(on: app.db)
            let site = Site(
                name: "exec-ws-dc",
                organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            let enrollment = TestAgentEnrollment(
                agentName: agentName,
                spiffeID: "spiffe://strato.local/agent/\(agentName)",
                expirationHours: 1,
                siteID: try site.requireID(),
                organizationScope: .organization(try org.requireID()))
            _ = try await saveTestAgentEnrollment(enrollment, on: app.db)

            var agentHeaders = HTTPHeaders()
            agentHeaders.add(
                name: "X-Forwarded-Client-Cert",
                value: "URI=spiffe://strato.local/agent/\(agentName)")
            let agent = try await ExecWSClient.connect(
                url: "ws://127.0.0.1:\(port)/agent/ws?name=\(agentName)",
                headers: agentHeaders,
                on: app.eventLoopGroup)
            agent.send(text: try encodeGuestExecAgentRegister(agentName: agentName))
            let registered = try await agent.nextEnvelope()
            #expect(registered.type == .agentRegisterResponse)

            // A user whose API key authenticates the browser socket. System
            // admin, so attach authorization flows through the
            // platform-system-admin policy without bindings.
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "execattach",
                email: "execattach@example.com",
                displayName: "Exec Attach",
                isSystemAdmin: true
            )
            let apiKey = try await user.generateAPIKey(on: app)

            // A real resource in a real project: an id with no row behind it is
            // a truncated IAM chain and is denied outright, admins included.
            let project = try await builder.createProject(
                name: "Exec WS Project", description: "p", organization: org)
            let registeredAgent = try #require(
                try await LegacyAgentStore.agents(name: agentName, on: app.db).first)

            let collection: String
            let resourceId: String
            switch resourceKind {
            case .sandbox:
                var sandbox = try await builder.createSandbox(name: "exec-ws-sb", project: project)
                sandbox.hypervisorId = try registeredAgent.requireID().uuidString
                sandbox.setStatus(.running)
                try await sandbox.save(on: app.db)
                collection = "sandboxes"
                resourceId = try sandbox.requireID().uuidString
            case .virtualMachine:
                var vm = try await builder.createVM(name: "exec-ws-vm", project: project)
                vm.hypervisorId = try registeredAgent.requireID().uuidString
                vm.guestAgentEnabled = true
                vm.setStatus(.running)
                try await vm.save(on: app.db)
                collection = "vms"
                resourceId = try vm.requireID().uuidString
            }

            // Exercise the public POST route rather than seeding the manager:
            // both resource kinds must mint the same single-use session shape.
            let mintResponse = try await app.client.post(
                URI(string: "http://127.0.0.1:\(port)/api/\(collection)/\(resourceId)/exec")
            ) { req in
                req.headers.bearerAuthorization = .init(token: apiKey)
                try req.content.encode(
                    ExecMintRequest(
                        command: ["/bin/echo", "hello"], env: nil, workingDir: nil,
                        tty: true, rows: 24, cols: 80,
                        // Omission is deliberate: it proves the existing
                        // browser request remains raw without opting in.
                        outputMode: outputMode == .raw ? nil : outputMode.rawValue))
            }
            #expect(mintResponse.status == .created)
            let session = try mintResponse.content.decode(ExecMintResponse.self)
            #expect(
                session.websocketPath
                    == "/api/\(collection)/\(resourceId)/exec/\(session.sessionId)/attach")
            #expect(session.outputMode == outputMode.rawValue)

            // WebSocket authentication is checked before the single-use
            // token is consumed, so a rejected attach cannot burn a valid
            // session minted by the user.
            let authenticationError = await #expect(throws: (any Error).self) {
                try await ExecWSClient.connect(
                    url: "ws://127.0.0.1:\(port)\(session.websocketPath)",
                    headers: HTTPHeaders(),
                    on: app.eventLoopGroup)
            }
            #expect(String(reflecting: authenticationError).contains("401 Unauthorized"))
            #expect(app.guestExecSessionManager.hasPendingSession(sessionId: session.sessionId))

            // The browser attaches over a real WebSocket upgrade.
            var browserHeaders = HTTPHeaders()
            browserHeaders.bearerAuthorization = .init(token: apiKey)
            let browser = try await ExecWSClient.connect(
                url: "ws://127.0.0.1:\(port)\(session.websocketPath)",
                headers: browserHeaders,
                on: app.eventLoopGroup)

            // The agent must receive the exec start (skipping any periodic
            // desired-state syncs that share the socket).
            let start: GuestExecStartMessage = try await {
                while true {
                    let envelope = try await agent.nextEnvelope()
                    if envelope.type == .desiredState { continue }
                    #expect(envelope.type == .guestExecStart)
                    return try envelope.decode(as: GuestExecStartMessage.self)
                }
            }()
            #expect(start.sessionId == session.sessionId)
            #expect(start.resourceKind == resourceKind)
            #expect(start.resourceId == resourceId)
            #expect(start.command == ["/bin/echo", "hello"])
            #expect(start.tty == true)

            // Agent reports the spawn; the browser sees the ready frame.
            agent.send(
                text: try encodeEnvelope(
                    GuestExecStartedMessage(sessionId: session.sessionId)))
            let ready = try await browser.nextControlFrame()
            #expect(ready.type == "ready")

            // A session token is single-use even while the first attachment
            // remains active.
            let duplicate = try await ExecWSClient.connect(
                url: "ws://127.0.0.1:\(port)\(session.websocketPath)",
                headers: browserHeaders,
                on: app.eventLoopGroup)
            let duplicateError = try await duplicate.nextControlFrame()
            #expect(duplicateError.type == "error")
            try await duplicate.waitForClose()

            // Output bytes flow to the browser as a binary frame.
            agent.send(
                text: try encodeEnvelope(
                    GuestExecOutputMessage(
                        sessionId: session.sessionId, stream: "stdout",
                        rawData: Data("hello\n".utf8))))
            let output = try await browser.nextFrame()
            #expect(
                output
                    == .binary(
                        outputMode.frame(streamTag: 0x01, payload: Data("hello\n".utf8))))
            agent.send(
                text: try encodeEnvelope(
                    GuestExecOutputMessage(
                        sessionId: session.sessionId, stream: "stderr",
                        rawData: Data("warning\n".utf8))))
            let errorOutput = try await browser.nextFrame()
            #expect(
                errorOutput
                    == .binary(
                        outputMode.frame(streamTag: 0x02, payload: Data("warning\n".utf8))))

            // Unknown text controls are ignored; the following valid resize
            // is the only agent-bound event produced by this pair of frames.
            browser.send(text: #"{"type":"future-control","value":1}"#)
            browser.send(text: #"{"type":"resize","cols":120,"rows":40}"#)
            let resizeEnvelope = try await agent.nextEnvelope(skipping: [.desiredState])
            #expect(resizeEnvelope.type == .guestExecResize)
            let resize = try resizeEnvelope.decode(as: GuestExecResizeMessage.self)
            #expect(resize.sessionId == session.sessionId)
            #expect(resize.cols == 120)
            #expect(resize.rows == 40)

            // Browser stdin flows to the agent as guest_exec_input.
            browser.send(binary: Data("ls\n".utf8))
            let inputEnvelope = try await agent.nextEnvelope(skipping: [.desiredState])
            #expect(inputEnvelope.type == .guestExecInput)
            let input = try inputEnvelope.decode(as: GuestExecInputMessage.self)
            #expect(input.sessionId == session.sessionId)
            #expect(input.rawData == Data("ls\n".utf8))
            #expect(input.eof == false)

            // Redirected stdin completion is an explicit control frame, not
            // an empty data frame.
            browser.send(text: #"{"type":"stdin_eof"}"#)
            let eofEnvelope = try await agent.nextEnvelope(skipping: [.desiredState])
            #expect(eofEnvelope.type == .guestExecInput)
            let eof = try eofEnvelope.decode(as: GuestExecInputMessage.self)
            #expect(eof.sessionId == session.sessionId)
            #expect(eof.rawData == nil)
            #expect(eof.eof == true)

            // Exit tears the session down and closes the browser socket.
            agent.send(
                text: try encodeEnvelope(
                    GuestExecExitMessage(sessionId: session.sessionId, exitCode: 0)))
            let exit = try await browser.nextControlFrame()
            #expect(exit.type == "exit")
            #expect(exit.exitCode == 0)
            try await browser.waitForClose()
            #expect(app.guestExecSessionManager.getSession(sessionId: session.sessionId) == nil)

            try await agent.close()
        }
    }
}

private struct ExecMintRequest: Content {
    let command: [String]
    let env: [String: String]?
    let workingDir: String?
    let tty: Bool?
    let rows: Int?
    let cols: Int?
    let outputMode: String?
}

private struct ExecMintResponse: Content {
    let sessionId: String
    let websocketPath: String
    let expiresAt: Date
    let outputMode: String?
}

enum ExecTestOutputMode: String, CaseIterable, Sendable {
    case raw
    case multiplexed

    func frame(streamTag: UInt8, payload: Data) -> Data {
        switch self {
        case .raw:
            payload
        case .multiplexed:
            Data([streamTag]) + payload
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
        let agents = (try? await Agent.all(on: app.db)) ?? []
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
        guard let frame = try await withExecTimeout(timeout, { [frames] in await frames.next() }) else {
            throw ExecTimeoutError()
        }
        return frame
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
    /// skipping other envelope types that share the socket.
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

    /// Polls rather than awaiting `onClose.get()`: the future wait is not
    /// cancellation-aware, and on a timeout the task group would wait forever
    /// on a close that can only arrive after test teardown.
    func waitForClose(timeout: Duration = .seconds(30)) async throws {
        _ = try await withExecTimeout(timeout) { [ws] () -> Bool? in
            while !ws.isClosed {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return nil
                }
            }
            return true
        }
    }

    func close() async throws {
        try await ws.close().get()
    }
}

/// Serializes inbound WebSocket frames (delivered on NIO event loops) into an
/// async queue a single consumer can await.
///
/// The wait is cancellation-aware and resumes with nil on cancellation. This
/// is load-bearing for `withExecTimeout`: `withThrowingTaskGroup` waits for
/// its cancelled children before returning, so a wait that ignored
/// cancellation would turn every real timeout into a suite-wide hang instead
/// of an `ExecTimeoutError`.
private actor ExecFrameCollector {
    private var buffered: [WSFrame] = []
    private var waiter: (id: UInt64, continuation: CheckedContinuation<WSFrame?, Never>)?
    private var nextWaiterID: UInt64 = 0

    func deliver(_ frame: WSFrame) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: frame)
        } else {
            buffered.append(frame)
        }
    }

    func next() async -> WSFrame? {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        let id = nextWaiterID
        nextWaiterID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancellation that lands before the waiter is armed is caught
                // here; cancellation after runs cancelWaiter, which resumes it.
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiter = (id, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UInt64) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
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

/// A VM-vsock and sandbox-capable agent at the current wire protocol version.
private func encodeGuestExecAgentRegister(agentName: String) throws -> String {
    try encodeEnvelope(
        AgentRegisterMessage(
            agentId: agentName,
            hostname: "test-host",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16,
                availableCPU: 16,
                totalMemory: 1 << 34,
                availableMemory: 1 << 34,
                totalDisk: 1 << 40,
                availableDisk: 1 << 40
            ),
            hypervisors: [
                HypervisorSupport(
                    type: .qemu,
                    available: true,
                    accelerated: true,
                    capabilities: .capabilities(for: .qemu),
                    supportsVsock: true,
                    supportsGuestExec: true)
            ],
            protocolVersion: WireProtocol.currentVersion,
            sandboxCapable: true
        ))
}
