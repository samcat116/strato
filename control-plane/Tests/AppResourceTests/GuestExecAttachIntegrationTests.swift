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

    enum VMAttachRejection: CaseIterable, Sendable {
        case invalidResourceID
        case sessionNotFound
        case sessionExpired
        case sessionMismatch
        case alreadyAttached

        var status: Int {
            switch self {
            case .invalidResourceID: 400
            case .sessionNotFound: 404
            case .sessionExpired: 410
            case .sessionMismatch: 403
            case .alreadyAttached: 409
            }
        }
    }

    @Test("VM attach authentication and authorization refusals stay in api.request")
    func vmAttachRefusalsAreGenericallyAudited() async throws {
        try await withRunningExecApp { app, port in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Exec Refusal Org")
            let project = try await builder.createProject(
                name: "Exec Refusal Project", description: "p", organization: organization)
            let vm = try await builder.createVM(name: "exec-refusal-vm", project: project)

            let viewer = try await builder.createUser(
                username: "exec-refusal-viewer",
                email: "exec-refusal-viewer@example.com")
            try await builder.addUserToOrganization(
                user: viewer, organization: organization, role: "viewer")
            viewer.currentOrganizationId = try organization.requireID()
            try await viewer.save(on: app.db)
            let viewerAPIKey = try await viewer.generateAPIKey(on: app.db)

            let vmID = try vm.requireID()
            let path =
                "/api/vms/\(vmID.uuidString.lowercased())/exec/\(UUID().uuidString)/attach"
            let url = "ws://127.0.0.1:\(port)\(path)"

            do {
                _ = try await ExecWSClient.connect(
                    url: url,
                    headers: HTTPHeaders(),
                    on: app.eventLoopGroup)
                Issue.record("Expected the unauthenticated WebSocket handshake to fail")
            } catch {
                // Global authorization rejects the missing principal before
                // the upgrade. The persisted generic fact below proves the
                // externally visible status without coupling to WebSocketKit's
                // private handshake-error type.
            }

            var viewerHeaders = HTTPHeaders()
            viewerHeaders.bearerAuthorization = .init(token: viewerAPIKey)
            do {
                _ = try await ExecWSClient.connect(
                    url: url,
                    headers: viewerHeaders,
                    on: app.eventLoopGroup)
                Issue.record("Expected the unauthorized WebSocket handshake to fail")
            } catch {
                // The global IAM gate rejects this viewer with HTTP 403. If a
                // future route shape defers the same decision until after the
                // upgrade, validateExecAccess uses the same forced recorder.
            }

            await app.audit.flush()
            let refusals = try await AuditEvent.query(on: app.db)
                .filter(\.$eventType == "api.request")
                .filter(\.$path == path)
                .sort(\.$createdAt)
                .all()
            #expect(refusals.count == 2)
            let authenticationRefusal = try #require(refusals.first { $0.status == 401 })
            #expect(authenticationRefusal.userID == nil)
            let authorizationRefusal = try #require(refusals.first { $0.status == 403 })
            #expect(authorizationRefusal.userID == viewer.id)
            for refusal in refusals {
                #expect(refusal.method == "GET")
                #expect(refusal.resourceType == "vms")
                #expect(refusal.resourceID == vmID.uuidString)
                #expect(refusal.action == "read")
            }
            #expect(
                try await AuditEvent.query(on: app.db)
                    .filter(\.$eventType == "vm.exec.requested")
                    .count() == 0)
        }
    }

    @Test(
        "VM attach session rejections append one precise generic refusal",
        arguments: VMAttachRejection.allCases)
    func vmAttachSessionRejectionsArePreciselyAudited(
        rejection: VMAttachRejection
    ) async throws {
        try await withRunningExecApp(includeAuditReads: true) { app, port in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Attach Status Org")
            let project = try await builder.createProject(
                name: "Attach Status Project", description: "p", organization: organization)
            let vm = try await builder.createVM(name: "attach-status-vm", project: project)
            let user = try await builder.createUser(
                username: "attach-status-admin",
                email: "attach-status-admin@example.com",
                isSystemAdmin: true)
            let apiKey = try await user.generateAPIKey(on: app.db)

            let vmID = try vm.requireID()
            let sessionID = UUID().uuidString
            let userID = try user.requireID().uuidString
            let manager = app.guestExecSessionManager

            switch rejection {
            case .invalidResourceID, .sessionNotFound:
                break
            case .sessionExpired:
                _ = manager.createPendingSession(
                    sessionId: sessionID,
                    resourceKind: .virtualMachine,
                    resourceId: vmID.uuidString,
                    agentKey: "spiffe://strato.local/agent/attach-status",
                    userId: userID,
                    command: ["/usr/bin/id"],
                    env: nil,
                    workingDir: nil,
                    tty: false,
                    rows: nil,
                    cols: nil,
                    now: Date().addingTimeInterval(
                        -(GuestExecSessionManager.pendingSessionTTL + 1)))
            case .sessionMismatch:
                _ = manager.createPendingSession(
                    sessionId: sessionID,
                    resourceKind: .virtualMachine,
                    resourceId: vmID.uuidString,
                    agentKey: "spiffe://strato.local/agent/attach-status",
                    userId: UUID().uuidString,
                    command: ["/usr/bin/id"],
                    env: nil,
                    workingDir: nil,
                    tty: false,
                    rows: nil,
                    cols: nil)
            case .alreadyAttached:
                let pending = manager.createPendingSession(
                    sessionId: sessionID,
                    resourceKind: .virtualMachine,
                    resourceId: vmID.uuidString,
                    agentKey: "spiffe://strato.local/agent/attach-status",
                    userId: userID,
                    command: ["/usr/bin/id"],
                    env: nil,
                    workingDir: nil,
                    tty: false,
                    rows: nil,
                    cols: nil)
                _ = try manager.attachSession(
                    sessionId: sessionID,
                    resourceKind: .virtualMachine,
                    resourceId: vmID.uuidString,
                    userId: pending.userId,
                    websocket: nil)
            }

            let resourceID =
                rejection == .invalidResourceID ? "not-a-uuid" : vmID.uuidString.lowercased()
            let path = "/api/vms/\(resourceID)/exec/\(sessionID)/attach"
            var headers = HTTPHeaders()
            headers.bearerAuthorization = .init(token: apiKey)

            if rejection == .invalidResourceID {
                do {
                    _ = try await ExecWSClient.connect(
                        url: "ws://127.0.0.1:\(port)\(path)",
                        headers: headers,
                        on: app.eventLoopGroup)
                    Issue.record("Expected the invalid VM ID handshake to fail")
                } catch {
                    // Authorization rejects the malformed resource before the
                    // upgrade; the generic fact below carries the HTTP 400.
                }
            } else {
                let browser = try await ExecWSClient.connect(
                    url: "ws://127.0.0.1:\(port)\(path)",
                    headers: headers,
                    on: app.eventLoopGroup)
                let frame = try await browser.nextControlFrame()
                #expect(frame.type == "error")
                try await browser.waitForClose()
            }

            await app.audit.flush()
            let facts = try await AuditEvent.query(on: app.db)
                .filter(\.$eventType == "api.request")
                .filter(\.$path == path)
                .all()
            #expect(facts.count == 1)
            let refusals = facts.filter { $0.status == rejection.status }
            #expect(refusals.count == 1)
            let refusal = try #require(refusals.first)
            #expect(refusal.method == "GET")
            #expect(refusal.resourceType == "vms")
            #expect(
                refusal.resourceID
                    == (rejection == .invalidResourceID ? resourceID : vmID.uuidString))
            #expect(refusal.action == "read")
            #expect(refusal.metadata == nil)
            #expect(
                try await AuditEvent.query(on: app.db)
                    .filter(\.$eventType == "vm.exec.requested")
                    .count() == 0)
        }
    }

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
                name: "exec-ws-site",
                organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            let enrollment = AgentEnrollment(
                agentName: agentName,
                spiffeID: "spiffe://strato.local/agent/\(agentName)",
                expirationHours: 1,
                siteID: try site.requireID(),
                organizationScope: .organization(try org.requireID()))
            try await enrollment.save(on: app.db)

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
            let apiKey = try await user.generateAPIKey(on: app.db)

            // A real resource in a real project: an id with no row behind it is
            // a truncated IAM chain and is denied outright, admins included.
            let project = try await builder.createProject(
                name: "Exec WS Project", description: "p", organization: org)
            let registeredAgent = try #require(
                try await Agent.query(on: app.db).filter(\.$name == agentName).first())

            let collection: String
            let resourceId: String
            switch resourceKind {
            case .sandbox:
                let sandbox = try await builder.createSandbox(name: "exec-ws-sb", project: project)
                sandbox.hypervisorId = try registeredAgent.requireID().uuidString
                sandbox.setStatus(.running)
                try await sandbox.save(on: app.db)
                collection = "sandboxes"
                resourceId = try sandbox.requireID().uuidString
            case .virtualMachine:
                let vm = try await builder.createVM(name: "exec-ws-vm", project: project)
                vm.hypervisorId = try registeredAgent.requireID().uuidString
                vm.guestAgentEnabled = true
                vm.setStatus(.running)
                try await vm.save(on: app.db)
                collection = "vms"
                resourceId = try vm.requireID().uuidString
            }

            // Exercise the public POST route rather than seeding the manager:
            // both resource kinds must mint the same single-use session shape.
            let environmentSentinel = "STR84_ENVIRONMENT_MUST_NOT_REACH_AUDIT"
            let workingDirectorySentinel = "/STR84/WORKING-DIRECTORY-MUST-NOT-REACH-AUDIT"
            let mintResponse = try await app.client.post(
                URI(string: "http://127.0.0.1:\(port)/api/\(collection)/\(resourceId)/exec")
            ) { req in
                req.headers.bearerAuthorization = .init(token: apiKey)
                try req.content.encode(
                    ExecMintRequest(
                        command: ["/bin/echo", "hello"],
                        env: ["STR84_SECRET": environmentSentinel],
                        workingDir: workingDirectorySentinel,
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

            await app.audit.flush()
            let requested = try await AuditEvent.query(on: app.db)
                .filter(\.$eventType == "vm.exec.requested")
                .all()
            switch resourceKind {
            case .sandbox:
                #expect(requested.isEmpty)
            case .virtualMachine:
                #expect(requested.count == 1)
                let event = try #require(requested.first)
                let metadata = try #require(event.metadata)
                #expect(event.resourceType == "vms")
                #expect(event.resourceID == resourceId)
                #expect(metadata["correlationID"] == session.sessionId)
                #expect(metadata["argv"] == #"["/bin/echo","hello"]"#)
                #expect(metadata["outcome"] == "accepted")
                #expect(metadata["phase"] == "requested")
                for prohibitedKey in [
                    "env", "environment", "workingDir", "stdin", "stdout", "stderr", "output",
                    "terminalFrames",
                ] {
                    #expect(metadata[prohibitedKey] == nil)
                }
                let persistedMetadata = try JSONEncoder().encode(metadata)
                let persistedText = String(decoding: persistedMetadata, as: UTF8.self)
                #expect(!persistedText.contains(environmentSentinel))
                #expect(!persistedText.contains(workingDirectorySentinel))
            }

            // WebSocket authentication is checked before the single-use
            // token is consumed, so a rejected attach cannot burn a valid
            // session minted by the user.
            do {
                _ = try await ExecWSClient.connect(
                    url: "ws://127.0.0.1:\(port)\(session.websocketPath)",
                    headers: HTTPHeaders(),
                    on: app.eventLoopGroup)
                Issue.record("Expected the unauthenticated WebSocket handshake to fail")
            } catch {
                // Missing credentials are rejected with HTTP 401 before the
                // WebSocket upgrade; the pending session must remain usable.
            }
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
            #expect(start.env == ["STR84_SECRET": environmentSentinel])
            #expect(start.workingDir == workingDirectorySentinel)
            #expect(start.tty == true)

            if resourceKind == .virtualMachine {
                await app.audit.flush()
                let attachSuccesses = try await AuditEvent.query(on: app.db)
                    .filter(\.$eventType == "api.request")
                    .filter(\.$path == session.websocketPath)
                    .filter(\.$status == Int(HTTPResponseStatus.switchingProtocols.code))
                    .all()
                #expect(attachSuccesses.count == 1)
                let attachSuccess = try #require(attachSuccesses.first)
                #expect(attachSuccess.resourceType == "vms")
                #expect(attachSuccess.resourceID == resourceId)
                #expect(attachSuccess.adminBypass == true)
                #expect(attachSuccess.metadata == nil)
            }

            // Agent reports the spawn; the browser sees the ready frame.
            agent.send(
                text: try encodeEnvelope(
                    GuestExecStartedMessage(sessionId: session.sessionId)))
            let ready = try await browser.nextControlFrame()
            #expect(ready.type == "ready")
            await app.audit.flush()
            let startedEvents = try await AuditEvent.query(on: app.db)
                .filter(\.$eventType == "vm.exec.started")
                .all()
            switch resourceKind {
            case .sandbox:
                #expect(startedEvents.isEmpty)
            case .virtualMachine:
                #expect(startedEvents.count == 1)
                #expect(startedEvents.first?.resourceID == resourceId)
                #expect(startedEvents.first?.metadata?["correlationID"] == session.sessionId)
                #expect(startedEvents.first?.metadata?["outcome"] == "started")
            }

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
            await app.audit.flush()
            let endedEvents = try await AuditEvent.query(on: app.db)
                .filter(\.$eventType == "vm.exec.ended")
                .all()
            switch resourceKind {
            case .sandbox:
                #expect(endedEvents.isEmpty)
            case .virtualMachine:
                #expect(endedEvents.count == 1)
                #expect(endedEvents.first?.resourceID == resourceId)
                #expect(endedEvents.first?.metadata?["correlationID"] == session.sessionId)
                #expect(endedEvents.first?.metadata?["outcome"] == "exited")
                #expect(endedEvents.first?.metadata?["exitCode"] == "0")
            }

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

private func withRunningExecApp(
    includeAuditReads: Bool = false,
    _ test: (Application, Int) async throws -> Void
) async throws {
    try await withApp { app in
        if includeAuditReads {
            var config = AuditConfig.fromConfiguration(app.controlPlaneConfiguration)
            config.includeReads = true
            app.audit = AuditService(app: app, config: config)
        }
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
