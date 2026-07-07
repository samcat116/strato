import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import StratoShared
import Testing
import Vapor

@testable import App

/// End-to-end tests for the agent WebSocket handshake in
/// ``AgentWebSocketController``. These bind a real Vapor HTTP server on an
/// ephemeral loopback port and drive it with a genuine WebSocket client so the
/// full upgrade → authenticate → buffer → register path executes exactly as it
/// does in production — the token/XFCC auth branches, the frame buffering that
/// protects the register frame that arrives immediately after upgrade, the
/// reconnect-token rotation, and the failed-registration token restore. None of
/// this is reachable through Vapor's in-memory `test()` harness, which never
/// performs a WebSocket upgrade.
@Suite("Agent WebSocket Integration", .serialized)
struct AgentWebSocketIntegrationTests {

    // MARK: - (1) Token auth happy path

    @Test("Token auth registers, rotates the reconnect token, and consumes the presented token")
    func tokenAuthRotatesReconnectToken() async throws {
        try await withRunningApp { app, port in
            let agentName = "agent-happy"
            let presented = AgentRegistrationToken(agentName: agentName, expirationHours: 1)
            try await presented.save(on: app.db)
            let presentedValue = presented.token

            var headers = HTTPHeaders()
            headers.bearerAuthorization = .init(token: presentedValue)

            let client = try await AgentTestClient.connect(app: app, port: port, name: agentName, headers: headers)
            let registerJSON = try encodeRegister(agentName: agentName)
            client.send(registerJSON)

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .agentRegisterResponse)

            let response = try envelope.decode(as: AgentRegisterResponseMessage.self)
            let reconnectToken = try #require(response.reconnectToken)
            #expect(reconnectToken != presentedValue)

            // A successful registration triggers an immediate desired-state sync;
            // draining it here also confirms that background DB work has settled
            // before teardown.
            try await client.expectDesiredStateSync()

            // The presented single-use token is now consumed.
            let reloadedPresented = try await AgentRegistrationToken.query(on: app.db)
                .filter(\.$token == presentedValue)
                .first()
            let presentedIsUsed = reloadedPresented?.isUsed
            #expect(presentedIsUsed == true)

            // A fresh, unused token was minted for the agent's next reconnect.
            let rotated = try await AgentRegistrationToken.query(on: app.db)
                .filter(\.$token == reconnectToken)
                .first()
            let rotatedRow = try #require(rotated)
            #expect(rotatedRow.agentName == agentName)
            #expect(rotatedRow.isUsed == false)
            #expect(rotatedRow.isValid == true)

            try await client.close()
        }
    }

    // MARK: - (2) mTLS auth never mints a reconnect token

    @Test("mTLS (XFCC) auth mints no reconnect token even when a bearer header is present")
    func mtlsAuthDoesNotMintReconnectToken() async throws {
        try await withRunningApp { app, port in
            // Enable SPIRE but load no trust bundle: with `hasTrustBundle == false`
            // the XFCC `URI=` alone establishes identity (relying on Envoy's own
            // verification), which is all this path needs to exercise the gating.
            let config = SPIREServiceConfig(
                enabled: true,
                trustDomain: "strato.local",
                requireClientCert: true
            )
            app.spireService = SPIREService(config: config, logger: app.logger, httpClient: app.client)

            let agentName = "mtls-agent"
            var headers = HTTPHeaders()
            headers.add(
                name: "X-Forwarded-Client-Cert",
                value: "URI=spiffe://strato.local/agent/\(agentName)")
            // A bearer header on an mTLS connection must be ignored: the connection
            // did not authenticate via the token path, so no reconnect token is due.
            headers.bearerAuthorization = .init(token: "unrelated-bearer-token")

            let client = try await AgentTestClient.connect(app: app, port: port, name: agentName, headers: headers)
            let registerJSON = try encodeRegister(agentName: agentName)
            client.send(registerJSON)

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .agentRegisterResponse)

            let response = try envelope.decode(as: AgentRegisterResponseMessage.self)
            #expect(response.reconnectToken == nil)

            // Drain the post-registration desired-state sync before asserting on
            // the store, so background DB work has settled.
            try await client.expectDesiredStateSync()

            // No stray reconnect token should have been written to the store either.
            let tokenCount = try await AgentRegistrationToken.query(on: app.db).count()
            #expect(tokenCount == 0)

            try await client.close()
        }
    }

    // MARK: - (3) Frames arriving during authentication are buffered, not dropped

    @Test("A register frame sent immediately after upgrade is buffered through auth and still processed")
    func registerFrameSentImmediatelyAfterUpgradeIsProcessed() async throws {
        try await withRunningApp { app, port in
            let agentName = "agent-buffered"
            let presented = AgentRegistrationToken(agentName: agentName, expirationHours: 1)
            try await presented.save(on: app.db)

            var headers = HTTPHeaders()
            headers.bearerAuthorization = .init(token: presented.token)

            // Send the register frame from inside the upgrade callback — the
            // earliest possible moment, while the server's token validation (a DB
            // round-trip) is still in flight. Without the controller's pre-auth
            // frame buffer this frame would race ahead of `state.agentName` being
            // set and be dropped, and registration would never complete.
            let registerJSON = try encodeRegister(agentName: agentName)
            let client = try await AgentTestClient.connect(
                app: app, port: port, name: agentName, headers: headers, sendOnUpgrade: registerJSON)

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .agentRegisterResponse)

            let response = try envelope.decode(as: AgentRegisterResponseMessage.self)
            #expect(response.name == agentName)
            #expect(response.reconnectToken != nil)

            try await client.expectDesiredStateSync()
            try await client.close()
        }
    }

    // MARK: - (4) Failed registration restores the presented token

    @Test("Failed registration restores the presented token so the agent is not locked out")
    func failedRegistrationRestoresPresentedToken() async throws {
        try await withRunningApp { app, port in
            let agentName = "agent-fail"
            let presented = AgentRegistrationToken(agentName: agentName, expirationHours: 1)
            try await presented.save(on: app.db)
            let presentedValue = presented.token

            var headers = HTTPHeaders()
            headers.bearerAuthorization = .init(token: presentedValue)

            let client = try await AgentTestClient.connect(app: app, port: port, name: agentName, headers: headers)
            // protocolVersion 0 is below `stateSyncMinimumVersion`, so registration
            // fails with `unsupportedProtocolVersion` after the token was already
            // consumed at connect — exercising the restore path.
            let registerJSON = try encodeRegister(agentName: agentName, protocolVersion: 0)
            client.send(registerJSON)

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .error)

            let error = try envelope.decode(as: ErrorMessage.self)
            #expect(error.code == ErrorMessage.ErrorCode.unsupportedProtocolVersion)

            // The restore runs before the error response is sent, so the token is
            // already valid again by the time we observe the error.
            let reloaded = try await AgentRegistrationToken.query(on: app.db)
                .filter(\.$token == presentedValue)
                .first()
            let restored = try #require(reloaded)
            #expect(restored.isUsed == false)
            #expect(restored.usedAt == nil)
            #expect(restored.isValid == true)

            try await client.close()
        }
    }
}

// MARK: - Running-server harness

/// Configure and migrate a fresh test application, bind its HTTP server on an
/// ephemeral loopback port, and hand the bound port to the test. The server and
/// application are always torn down, even if the test body throws.
private func withRunningApp(_ test: (Application, Int) async throws -> Void) async throws {
    try await withApp { app in
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            guard let port = app.http.server.shared.localAddress?.port else {
                Issue.record("HTTP server did not report a bound port")
                await drainAndStopServer(app)
                return
            }
            try await test(app, port)
        } catch {
            await drainAndStopServer(app)
            throw error
        }
        await drainAndStopServer(app)
    }
}

/// Stop the bound server and wait for the controller's fire-and-forget teardown
/// work to finish touching the database before the outer `asyncShutdown()` tears
/// down the connection pool. The WS close handler marks the agent offline via a
/// detached task, and registration kicks off a desired-state sync — both run
/// after their request returns, so shutting the pool without waiting trips
/// AsyncKit's "ConnectionPool.shutdown() was not called before deinit" assertion.
private func drainAndStopServer(_ app: Application) async {
    await app.server.shutdown()
    // Bounded quiescence poll (mirrors the repo's other agent suites): wait until
    // no agent is left marked online, always running a few iterations so any
    // read-only teardown task on a never-registered agent also drains.
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

/// A thin async wrapper around a WebSocketKit client connection to the agent
/// endpoint. Collects inbound frames (the control plane replies with binary
/// frames) and exposes them as decoded envelopes with a timeout.
private final class AgentTestClient: Sendable {
    private let ws: WebSocket
    private let frames: FrameCollector

    private init(ws: WebSocket, frames: FrameCollector) {
        self.ws = ws
        self.frames = frames
    }

    static func connect(
        app: Application,
        port: Int,
        name: String,
        headers: HTTPHeaders,
        sendOnUpgrade: String? = nil
    ) async throws -> AgentTestClient {
        let frames = FrameCollector()

        let ws: WebSocket = try await withCheckedThrowingContinuation { continuation in
            // Resume from the upgrade callback — that is where the socket is
            // actually handed over and confirmed ready. The connect future can
            // complete before this callback runs, so it is used only to surface a
            // connection failure. A one-shot guard keeps resumption single even in
            // the (theoretical) event both fire.
            let resumed = NIOLockedValueBox(false)
            let future = WebSocket.connect(
                to: "ws://127.0.0.1:\(port)/agent/ws?name=\(name)",
                headers: headers,
                on: app.eventLoopGroup
            ) { ws in
                ws.onBinary { _, buffer in
                    let data = Data(buffer.readableBytesView)
                    Task { await frames.deliver(data) }
                }
                ws.onText { _, string in
                    let data = Data(string.utf8)
                    Task { await frames.deliver(data) }
                }
                if let sendOnUpgrade {
                    ws.send(sendOnUpgrade)
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
        return AgentTestClient(ws: ws, frames: frames)
    }

    /// Send a text frame. The server accepts both text and binary on the agent
    /// socket; text keeps the wire payload human-readable in logs.
    func send(_ text: String) {
        ws.send(text)
    }

    /// Await the next inbound frame, decoded as a wire envelope, failing the test
    /// if none arrives within the timeout.
    func nextEnvelope(timeout: Duration = .seconds(5)) async throws -> MessageEnvelope {
        let data = try await withTimeout(timeout) { [frames] in await frames.next() }
        return try WireProtocol.makeDecoder().decode(MessageEnvelope.self, from: data)
    }

    /// Consume the desired-state sync the control plane pushes immediately after a
    /// successful registration. Reading it both asserts the sync happens and lets
    /// the server-side `assembleDesiredState` DB work settle before teardown.
    func expectDesiredStateSync() async throws {
        let envelope = try await nextEnvelope()
        #expect(envelope.type == .desiredState)
    }

    func close() async throws {
        try await ws.close().get()
    }
}

/// Serializes inbound WebSocket frames (delivered on NIO event loops) into an
/// async queue a single consumer can await.
private actor FrameCollector {
    private var buffered: [Data] = []
    private var waiter: CheckedContinuation<Data, Never>?

    func deliver(_ data: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            buffered.append(data)
        }
    }

    func next() async -> Data {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

private struct TimeoutError: Error {}

/// Race an async operation against a deadline, throwing `TimeoutError` if the
/// operation does not finish first. Keeps a hung handshake from stalling the
/// whole suite.
private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }
        guard let result = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return result
    }
}

/// Encode an `AgentRegisterMessage` envelope to a JSON string suitable for
/// sending as a WebSocket text frame.
private func encodeRegister(
    agentName: String,
    protocolVersion: Int = WireProtocol.currentVersion
) throws -> String {
    let message = AgentRegisterMessage(
        agentId: agentName,
        hostname: "test-host",
        version: "1.0.0",
        capabilities: ["qemu"],
        resources: AgentResources(
            totalCPU: 4,
            availableCPU: 4,
            totalMemory: Int64(8 * 1024 * 1024 * 1024),
            availableMemory: Int64(8 * 1024 * 1024 * 1024),
            totalDisk: Int64(100 * 1024 * 1024 * 1024),
            availableDisk: Int64(100 * 1024 * 1024 * 1024)
        ),
        protocolVersion: protocolVersion
    )
    let envelope = try MessageEnvelope(message: message)
    let data = try WireProtocol.makeEncoder().encode(envelope)
    return String(decoding: data, as: UTF8.self)
}
