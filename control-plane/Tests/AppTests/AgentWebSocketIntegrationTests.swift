import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOWebSocket
import StratoShared
import Testing
import Vapor

@testable import App

/// End-to-end tests for the agent WebSocket handshake in
/// ``AgentWebSocketController``. These bind a real Vapor HTTP server on an
/// ephemeral loopback port and drive it with a genuine WebSocket client so the
/// full upgrade → authenticate → buffer → register path executes exactly as it
/// does in production — the XFCC/mTLS auth branch (the only one there is), the
/// frame buffering that protects the register frame that arrives immediately
/// after upgrade, and the refusals that apply when SPIRE is unconfigured or no
/// client certificate is presented. None of this is reachable through Vapor's
/// in-memory `test()` harness, which never performs a WebSocket upgrade.
@Suite("Agent WebSocket Integration", .serialized)
struct AgentWebSocketIntegrationTests {

    /// New agents take their owning organization from their enrollment row.
    private func makeOrg(app: Application) async throws -> Organization {
        let org = Organization(name: "WS Org", description: "org for WS tests")
        try await org.save(on: app.db)
        return org
    }

    /// Enable SPIRE mTLS auth without a trust bundle: with
    /// `hasTrustBundle == false` the XFCC `URI=` alone establishes identity
    /// (relying on Envoy's own verification), which is what these tests drive.
    /// The client dials 127.0.0.1, so the controller's local-sidecar check —
    /// the reason a spoofed XFCC from the pod network is refused — passes.
    private func enableSPIRE(on app: Application) {
        let config = SPIREServiceConfig(
            enabled: true,
            trustDomain: "strato.local"
        )
        app.spireService = SPIREService(config: config, logger: app.logger, httpClient: app.client)
    }

    private func xfccHeaders(agentName: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.add(
            name: "X-Forwarded-Client-Cert",
            value: "URI=spiffe://strato.local/agent/\(agentName)")
        return headers
    }

    // MARK: - (1) mTLS happy path: the enrollment supplies scope and site

    @Test("An mTLS-authenticated agent registers and inherits its enrollment's org scope and site")
    func mtlsRegistrationInheritsEnrollmentScopeAndSite() async throws {
        try await withRunningApp { app, port in
            self.enableSPIRE(on: app)

            let agentName = "mtls-agent"
            let org = try await self.makeOrg(app: app)
            let site = Site(name: "ws-dc", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)

            // An SVID authenticates the node's identity but carries neither the
            // owning org nor the site: both come from the enrollment an operator
            // created for this name, resolved inside `registerAgent`.
            let enrollment = AgentEnrollment(
                agentName: agentName,
                spiffeID: "spiffe://strato.local/agent/\(agentName)",
                expirationHours: 1,
                siteID: try site.requireID(),
                organizationScope: .organization(try org.requireID()))
            try await enrollment.save(on: app.db)

            let client = try await AgentTestClient.connect(
                app: app, port: port, name: agentName, headers: self.xfccHeaders(agentName: agentName))
            let registerJSON = try encodeRegister(agentName: agentName)
            client.send(registerJSON)

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .agentRegisterResponse)

            let response = try envelope.decode(as: AgentRegisterResponseMessage.self)
            #expect(response.name == agentName)

            // A successful registration triggers an immediate desired-state sync;
            // draining it here also confirms that background DB work has settled
            // before the assertions below read the store.
            try await client.expectDesiredStateSync()

            let agent = try #require(
                try await Agent.query(on: app.db).filter(\.$name == agentName).first())
            #expect(agent.$organization.id == org.id)
            #expect(agent.$site.id == site.id)

            // The enrollment is marked used, but survives: unlike a single-use
            // token it is not consumed by being redeemed.
            let reloaded = try #require(try await AgentEnrollment.find(enrollment.id, on: app.db))
            #expect(reloaded.isUsed == true)
            #expect(reloaded.usedAt != nil)

            try await client.close()
        }
    }

    // MARK: - (2) Frames arriving during authentication are buffered, not dropped

    @Test("A register frame sent immediately after upgrade is buffered through auth and still processed")
    func registerFrameSentImmediatelyAfterUpgradeIsProcessed() async throws {
        try await withRunningApp { app, port in
            self.enableSPIRE(on: app)

            let agentName = "agent-buffered"
            let org = try await self.makeOrg(app: app)
            let enrollment = AgentEnrollment(
                agentName: agentName,
                spiffeID: "spiffe://strato.local/agent/\(agentName)",
                expirationHours: 1,
                organizationScope: .organization(try org.requireID()))
            try await enrollment.save(on: app.db)

            // Send the register frame from inside the upgrade callback — the
            // earliest possible moment, while the server's SPIFFE identity
            // validation is still in flight. Without the controller's pre-auth
            // frame buffer this frame would race ahead of `state.agentName` being
            // set and be dropped, and registration would never complete.
            let registerJSON = try encodeRegister(agentName: agentName)
            let client = try await AgentTestClient.connect(
                app: app, port: port, name: agentName, headers: self.xfccHeaders(agentName: agentName),
                sendOnUpgrade: registerJSON)

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .agentRegisterResponse)

            let response = try envelope.decode(as: AgentRegisterResponseMessage.self)
            #expect(response.name == agentName)

            try await client.expectDesiredStateSync()
            try await client.close()
        }
    }

    // MARK: - (3) Registration still refuses agents that can't be reconciled

    @Test("A register frame below the state-sync protocol floor is refused with an error frame")
    func registrationRefusesUnsupportedProtocolVersion() async throws {
        try await withRunningApp { app, port in
            self.enableSPIRE(on: app)

            let agentName = "agent-old"
            let org = try await self.makeOrg(app: app)
            let enrollment = AgentEnrollment(
                agentName: agentName,
                spiffeID: "spiffe://strato.local/agent/\(agentName)",
                expirationHours: 1,
                organizationScope: .organization(try org.requireID()))
            try await enrollment.save(on: app.db)

            let client = try await AgentTestClient.connect(
                app: app, port: port, name: agentName, headers: self.xfccHeaders(agentName: agentName))
            // protocolVersion 0 is below `stateSyncMinimumVersion`: such an agent
            // would register and then never converge anything, so it is refused.
            let registerJSON = try encodeRegister(agentName: agentName, protocolVersion: 0)
            client.send(registerJSON)

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .error)

            let error = try envelope.decode(as: ErrorMessage.self)
            #expect(error.code == ErrorMessage.ErrorCode.unsupportedProtocolVersion)

            let agentCount = try await Agent.query(on: app.db).count()
            #expect(agentCount == 0)

            try await client.close()
        }
    }

    // MARK: - (4) Refusals: no SPIRE configured, and no client certificate

    @Test("A control plane without SPIRE configured refuses the agent socket outright")
    func socketRefusedWhenSPIREUnconfigured() async throws {
        try await withRunningApp { app, port in
            // No `app.spireService`: mTLS is the only agent auth path, so nothing
            // the agent could present would ever authenticate here.
            #expect(app.spireService == nil)

            let agentName = "unconfigured-agent"
            let client = try await AgentTestClient.connect(
                app: app, port: port, name: agentName, headers: self.xfccHeaders(agentName: agentName))

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .error)
            let error = try envelope.decode(as: ErrorMessage.self)
            let mentionsSPIRE = error.error.contains("SPIRE")
            #expect(mentionsSPIRE)

            let closeCode = try await client.waitForClose()
            #expect(closeCode == .policyViolation)

            // Nothing registered: the register frame never gets a chance to run.
            let agentCount = try await Agent.query(on: app.db).count()
            #expect(agentCount == 0)
        }
    }

    @Test("With SPIRE enabled, a connection presenting no client certificate is closed")
    func socketRefusedWithoutClientCertificate() async throws {
        try await withRunningApp { app, port in
            self.enableSPIRE(on: app)

            let agentName = "certless-agent"
            let org = try await self.makeOrg(app: app)
            let enrollment = AgentEnrollment(
                agentName: agentName,
                spiffeID: "spiffe://strato.local/agent/\(agentName)",
                expirationHours: 1,
                organizationScope: .organization(try org.requireID()))
            try await enrollment.save(on: app.db)

            // No XFCC header at all. With token auth gone there is nothing to
            // downgrade to, so this is fatal regardless of SPIRE_REQUIRE_CLIENT_CERT.
            let client = try await AgentTestClient.connect(
                app: app, port: port, name: agentName, headers: HTTPHeaders())

            let envelope = try await client.nextEnvelope()
            #expect(envelope.type == .error)

            let closeCode = try await client.waitForClose()
            #expect(closeCode == .unacceptableData)

            let agentCount = try await Agent.query(on: app.db).count()
            #expect(agentCount == 0)
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
    /// if none arrives within the timeout. The timeout is generous: CI runs the
    /// suite with `--parallel` on a cold runner, where event-loop scheduling can
    /// stall for many seconds while dozens of suites start up; on the happy path
    /// the wait returns immediately.
    func nextEnvelope(timeout: Duration = .seconds(30)) async throws -> MessageEnvelope {
        guard let data = try await withTimeout(timeout, { [frames] in await frames.next() }) else {
            throw TimeoutError()
        }
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

    /// Await the server closing the connection and report the close code it
    /// sent. Refusal paths are only fully observable here: the controller sends
    /// an error frame *and* closes with a code that tells the agent whether the
    /// rejection was about policy (never retry as-is) or its credentials.
    func waitForClose(timeout: Duration = .seconds(30)) async throws -> WebSocketErrorCode? {
        let closed: Void? = try await withTimeout(timeout) { [ws] in
            try? await ws.onClose.get()
        }
        guard closed != nil else { throw TimeoutError() }
        return ws.closeCode
    }
}

/// Serializes inbound WebSocket frames (delivered on NIO event loops) into an
/// async queue a single consumer can await.
///
/// The wait is cancellation-aware and resumes with nil on cancellation. This
/// is load-bearing for `withTimeout`: `withThrowingTaskGroup` waits for its
/// cancelled children before returning, so a wait that ignored cancellation
/// would turn every real timeout into a suite-wide hang instead of a
/// `TimeoutError`.
private actor FrameCollector {
    private var buffered: [Data] = []
    private var waiter: (id: UInt64, continuation: CheckedContinuation<Data?, Never>)?
    private var nextWaiterID: UInt64 = 0

    func deliver(_ data: Data) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: data)
        } else {
            buffered.append(data)
        }
    }

    func next() async -> Data? {
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
