import Foundation
import StratoShared
import ControlPlanePostgres
import Vapor

/// The graphics console (issue #566): a VM's VNC framebuffer, relayed to noVNC
/// in the browser. Effectively websockify with Strato's authorization in front.
///
/// Two steps, following sandbox exec rather than the serial console:
/// `POST /api/vms/:vmID/console/vnc` validates everything and mints a session;
/// the browser then opens `GET /api/vms/:vmID/console/vnc/:sessionID/attach`.
/// The split exists because a display can be unavailable for several distinct
/// reasons — the VM was created headless, its agent is too old to realize one,
/// its socket is held by another replica — and each is worth a status code the
/// client can act on. Reported as text frames on an already-upgraded socket
/// they would all reach noVNC as an unexplained disconnect.
///
/// Browser frame contract:
/// - browser → CP: binary frames are RFB client messages. Text frames are
///   ignored; there is no control channel, because noVNC owns the socket.
/// - CP → browser: `{"type":"error","message":"…"}` for anything that goes
///   wrong before the console is live, then `{"type":"ready"}` once the agent
///   has attached to the VM's VNC socket — after which **every** frame is
///   binary RFB. A failure past that point just closes the socket: writing text
///   into the middle of an RFB stream would corrupt it, and the close frame
///   cannot carry an explanation anyway (WebSocketKit's `close(code:)` sends a
///   two-byte status code and nothing else).
struct VNCWebSocketController: RouteCollection {
    private let database: PostgresStoreContext

    init(database: PostgresStoreContext) {
        self.database = database
    }
    /// Bound on the attach socket. The browser's side of RFB is small — key and
    /// pointer events, update requests — but a clipboard paste arrives as one
    /// `ClientCutText`, which comfortably exceeds Vapor's 16 KiB default (the
    /// serial console and exec sockets simply take that default).
    private static let maxFrameSize = 1 << 20

    /// `console` is deliberately not added to the guarded resource's
    /// `actionVerbs`: doing so would also retarget the *serial* console's
    /// existing GET, which is out of scope here. The mint therefore derives
    /// `update` from `AuthorizationMiddleware`'s generic POST mapping, and the
    /// handler's own `view_console` check is what actually gates it. Both sit
    /// at the **editor** tier in `RoleRegistry`, so the middleware never
    /// narrows the audience below what the console check already requires.
    func boot(routes: RoutesBuilder) throws {
        let vmRoutes = routes.grouped("api", "vms")
        vmRoutes.post(":vmID", "console", "vnc", use: createSession)
        vmRoutes.webSocket(
            ":vmID", "console", "vnc", ":sessionID", "attach",
            maxFrameSize: .init(integerLiteral: Self.maxFrameSize),
            onUpgrade: websocketHandler)
    }

    /// What `POST .../console/vnc` returns: where to attach, and by when.
    struct VNCSessionResponse: Content {
        let sessionId: String
        let websocketPath: String
        let expiresAt: Date
    }

    // MARK: - Mint

    /// Validates a graphics console request and mints a single-use session.
    ///
    /// Every check that can be made before an upgrade is made here, so the
    /// client gets a status code and a reason instead of a dead socket.
    func createSession(req: Request) async throws -> Response {
        guard let vmIdString = req.parameters.get("vmID"),
            let vmId = UUID(uuidString: vmIdString)
        else {
            throw Abort(.badRequest, reason: "Invalid VM ID")
        }

        guard let user = req.auth.get(User.self), let userId = user.id?.uuidString else {
            throw Abort(.unauthorized, reason: "Authentication required")
        }

        // Authorize before loading the VM, so unauthorized users cannot probe
        // arbitrary VM UUIDs by telling the failure modes apart. A graphics
        // console is a keyboard and a mouse, and `vm:viewConsole` says so — a
        // restricted credential is intersected against that action rather than
        // against the request's HTTP method (STR-115), which is what the
        // scope-era carve-out here had to approximate.
        guard try await req.can("vm:viewConsole", on: IAMNode(type: .virtualMachine, id: vmId)) else {
            req.logger.warning(
                "Graphics console access denied",
                metadata: ["vmId": .string(vmId.uuidString), "userId": .string(userId)])
            throw Abort(.forbidden, reason: "You do not have permission to access this VM console")
        }

        guard let vm = try await VM.find(vmId, on: database) else {
            throw Abort(.notFound, reason: "VM not found")
        }

        // The display device is fixed in the hypervisor process's arguments, so
        // this is not a transient state a restart clears — say what actually
        // has to happen.
        guard vm.graphicsConsole else {
            throw Abort(
                .conflict,
                reason: "This VM has no graphics console: it was created without a display. "
                    + "Recreate the VM with the display enabled.")
        }

        guard vm.status == .running else {
            throw Abort(.conflict, reason: "VM is not running")
        }

        guard let agentIdString = vm.hypervisorId,
            let agentId = UUID(uuidString: agentIdString),
            let agent = try await Agent.find(agentId, on: database)
        else {
            throw Abort(.conflict, reason: "VM has no assigned hypervisor")
        }

        // Console traffic rides the agent's own WebSocket, which lives on
        // exactly one replica; there is no cross-replica byte-stream forwarding
        // (see docs/architecture/multi-replica.md). Fail here, where it is a
        // 503 the client can retry through the service, rather than inside an
        // upgraded socket.
        guard req.application.websocketManager.getConnection(agentKey: agent.identity.key) != nil else {
            throw Abort(
                .serviceUnavailable,
                reason: "Agent '\(agent.name)' is not connected to this control-plane replica; "
                    + "the graphics console requires the replica holding the agent socket")
        }

        let session = req.consoleSessionManager.createPendingVNCSession(
            vmId: vmId.uuidString,
            agentKey: agent.identity.key,
            userId: userId
        )

        let body = VNCSessionResponse(
            sessionId: session.sessionId,
            websocketPath: "/api/vms/\(vmId.uuidString)/console/vnc/\(session.sessionId)/attach",
            expiresAt: session.expiresAt
        )
        let response = Response(status: .created)
        try response.content.encode(body)
        return response
    }

    // MARK: - Attach

    // Non-async handler - runs on WebSocket's event loop
    private func websocketHandler(req: Request, ws: WebSocket) {
        guard let vmIdString = req.parameters.get("vmID"),
            let vmId = UUID(uuidString: vmIdString),
            let sessionId = req.parameters.get("sessionID"),
            !sessionId.isEmpty
        else {
            ws.send(ConsoleSessionManager.errorControlFrame("Invalid VM or session ID"))
            _ = ws.close(code: .unacceptableData)
            return
        }

        Task {
            // Re-authenticate and re-authorize on the upgrade: the session id
            // is a capability, not a substitute for the caller's permissions,
            // and a grant can be revoked between mint and attach.
            guard let user = req.auth.get(User.self), let userId = user.id?.uuidString else {
                try? await ws.send(ConsoleSessionManager.errorControlFrame("Authentication required"))
                try? await ws.close(code: .policyViolation)
                return
            }
            guard
                (try? await req.can("vm:viewConsole", on: IAMNode(type: .virtualMachine, id: vmId))) == true
            else {
                try? await ws.send(
                    ConsoleSessionManager.errorControlFrame(
                        "You do not have permission to access this VM console"))
                try? await ws.close(code: .policyViolation)
                return
            }

            let manager = req.consoleSessionManager

            // Consume the pending session: it must exist, be unexpired, target
            // this VM, and have been minted for this user.
            let session: ConsoleSessionManager.PendingConsoleSession
            do {
                session = try manager.attachVNCSession(
                    sessionId: sessionId,
                    vmId: vmId.uuidString,
                    userId: userId,
                    websocket: ws
                )
            } catch {
                req.logger.warning(
                    "Graphics console attach rejected: \(error)",
                    metadata: [
                        "vmId": .string(vmId.uuidString),
                        "sessionId": .string(sessionId),
                    ])
                try? await ws.send(
                    ConsoleSessionManager.errorControlFrame(
                        "Invalid, expired, or already attached console session"))
                try? await ws.close(code: .policyViolation)
                return
            }

            req.logger.info(
                "Graphics console WebSocket connection established",
                metadata: [
                    "vmId": .string(vmId.uuidString),
                    "sessionId": .string(sessionId),
                    "agentKey": .string(session.agentKey),
                ])

            // Everything bound for the agent goes through one serial pump: the
            // frame handlers yield synchronously, preserving WebSocket arrival
            // order, and a single task relays events one at a time. A Task per
            // frame would let the scheduler transpose them, and RFB does not
            // survive that — the server reads a length-prefixed message header,
            // then exactly that many bytes, so one transposition desynchronizes
            // the connection permanently. The connect rides the same pump
            // first and the browser-disconnect last, so a browser that leaves
            // mid-setup cannot make its teardown overtake its connect and
            // strand the agent's bridge.
            let (events, eventContinuation) = AsyncStream.makeStream(of: SessionEvent.self)
            Task {
                var connected = false
                for await event in events {
                    switch event {
                    case .connect:
                        do {
                            try await manager.sendConsoleConnect(
                                sessionId: sessionId,
                                vmId: vmId.uuidString,
                                agentKey: session.agentKey,
                                stream: .vnc
                            )
                            connected = true
                        } catch {
                            req.logger.error("Failed to connect to agent graphics console: \(error)")
                            manager.removeSession(sessionId: sessionId)
                            try? await ws.send(
                                ConsoleSessionManager.errorControlFrame(
                                    "Failed to attach to the VM's graphics console"))
                            try? await ws.close(code: .unexpectedServerError)
                        }
                    case .input(let data):
                        do {
                            try await manager.routeToAgent(sessionId: sessionId, data: data)
                        } catch {
                            req.logger.error("Failed to route graphics console input to agent: \(error)")
                        }
                    case .browserClosed:
                        // Only worth telling the agent to tear down a bridge it
                        // may actually have opened.
                        if connected {
                            try? await manager.sendConsoleDisconnect(sessionId: sessionId)
                        }
                        manager.removeSession(sessionId: sessionId)
                    }
                }
            }

            // The connect is the pump's first event — enqueued before the frame
            // handlers exist, so no input or close can precede it.
            eventContinuation.yield(.connect)

            // WebSocketKit's frame-callback setters are loop-bound
            // (`NIOLoopBoundBox`): calling them from this task — which runs on
            // the concurrent executor, not the socket's event loop — trips
            // `EventLoop.preconditionInEventLoop` and kills the whole process.
            // Register them via an explicit hop to the socket's event loop.
            ws.eventLoop.execute {
                ws.onBinary { _, buffer in
                    let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) ?? []
                    eventContinuation.yield(.input(Data(bytes)))
                }
                // No text frames are defined in this direction. Unlike the
                // serial console — which forwards text as keystrokes — RFB is
                // binary throughout, so a text frame here is noise and
                // forwarding it would inject bytes into the protocol stream.
                ws.onText { _, _ in }
            }

            ws.onClose.whenComplete { result in
                switch result {
                case .success:
                    req.logger.info(
                        "Graphics console WebSocket connection closed",
                        metadata: [
                            "vmId": .string(vmId.uuidString),
                            "sessionId": .string(sessionId),
                        ])
                case .failure(let error):
                    req.logger.error(
                        "Graphics console WebSocket connection closed with error: \(error)",
                        metadata: [
                            "vmId": .string(vmId.uuidString),
                            "sessionId": .string(sessionId),
                        ])
                }

                eventContinuation.yield(.browserClosed)
                eventContinuation.finish()
            }
        }
    }

    /// One event on the per-connection serial pump, in strict order.
    private enum SessionEvent: Sendable {
        case connect
        case input(Data)
        case browserClosed
    }
}
