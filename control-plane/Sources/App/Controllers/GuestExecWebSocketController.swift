import Fluent
import Foundation
import StratoShared
import Vapor

/// Shared HTTP contract for minting a VM or sandbox exec session.
struct GuestExecRequest: Content {
    let command: [String]
    let env: [String: String]?
    let workingDir: String?
    let tty: Bool?
    let rows: Int?
    let cols: Int?
    let outputMode: GuestExecOutputMode?

    func validate() throws {
        guard !command.isEmpty else {
            throw Abort(.badRequest, reason: "'command' must be a non-empty array of strings")
        }
        try Validate.stringList(command, "command", maxEntries: 128)
        try Validate.stringMap(env, "env", maxEntries: 128)
        _ = try Validate.text(workingDir, "workingDir")
        guard !command[0].isEmpty else {
            throw Abort(.badRequest, reason: "The executable in 'command' must not be empty")
        }
        guard command.allSatisfy({ !$0.contains("\0") }) else {
            throw Abort(.badRequest, reason: "Entries in 'command' must not contain NUL characters")
        }
        if let env {
            for (key, value) in env {
                guard
                    !key.isEmpty, !key.contains("="), !key.contains("\0"),
                    !value.contains("\0")
                else {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Environment keys must be non-empty and contain neither '=' nor NUL; values must not contain NUL"
                    )
                }
            }
        }
        guard workingDir?.contains("\0") != true else {
            throw Abort(.badRequest, reason: "'workingDir' must not contain NUL characters")
        }
    }
}

/// Browser-facing output framing. Raw mode is the original terminal contract;
/// multiplexed mode keeps stdout and stderr distinct for script-oriented CLI
/// callers without changing the agent wire protocol.
enum GuestExecOutputMode: String, Content, Sendable {
    case raw
    case multiplexed
}

/// Shared response contract consumed by the reusable browser terminal flow.
struct GuestExecSessionResponse: Content {
    let sessionId: String
    let websocketPath: String
    let expiresAt: Date
    /// Echoed so a client never silently assumes multiplexing against an older
    /// control plane that ignored the request field.
    let outputMode: GuestExecOutputMode?
}

/// WebSocket endpoints attaching a browser to a VM or sandbox exec session,
/// modeled on `ConsoleWebSocketController`.
///
/// Flow: `POST /api/{vms|sandboxes}/:id/exec` mints a pending session; the
/// browser then connects to that resource's exec attach route. This handler
/// re-authorizes (`vm:exec` or `sandbox:exec`), consumes the pending
/// session, sends the `GuestExecStartMessage` to the agent, and relays
/// frames until the exec ends or the browser disconnects.
///
/// Browser frame contract:
/// - browser → CP: binary frames are stdin bytes; text frames are JSON
///   control messages (`{"type":"resize","cols":C,"rows":R}` or
///   `{"type":"stdin_eof"}`); unknown text frames are ignored.
/// - CP → browser: `{"type":"ready"}` once the process spawned; binary frames
///   are raw output bytes or a stream tag (0x01 stdout, 0x02 stderr) followed
///   by output bytes when the session selected multiplexed mode;
///   `{"type":"exit","exitCode":N}` then a normal close when it exits;
///   `{"type":"error","message":"..."}` then a close on abnormal end.
struct GuestExecWebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let sandboxRoutes = routes.grouped("api", "sandboxes")
        sandboxRoutes.webSocket(
            ":sandboxID", "exec", ":sessionID", "attach",
            onUpgrade: { req, ws in
                websocketHandler(req: req, ws: ws, resource: .sandbox)
            })

        let vmRoutes = routes.grouped("api", "vms")
        vmRoutes.webSocket(
            ":vmID", "exec", ":sessionID", "attach",
            onUpgrade: { req, ws in
                websocketHandler(req: req, ws: ws, resource: .virtualMachine)
            })
    }

    private enum Resource: Sendable {
        case sandbox
        case virtualMachine

        var kind: GuestResourceKind {
            switch self {
            case .sandbox: .sandbox
            case .virtualMachine: .virtualMachine
            }
        }

        var parameterName: String {
            switch self {
            case .sandbox: "sandboxID"
            case .virtualMachine: "vmID"
            }
        }

        var iamAction: String {
            switch self {
            case .sandbox: "sandbox:exec"
            case .virtualMachine: "vm:exec"
            }
        }

        var nodeType: IAMNodeType {
            switch self {
            case .sandbox: .sandbox
            case .virtualMachine: .virtualMachine
            }
        }

        var displayName: String {
            switch self {
            case .sandbox: "sandbox"
            case .virtualMachine: "VM"
            }
        }

        var logName: String {
            switch self {
            case .sandbox: "Sandbox"
            case .virtualMachine: "VM"
            }
        }
    }

    // Non-async handler - runs on WebSocket's event loop
    private func websocketHandler(req: Request, ws: WebSocket, resource: Resource) {
        guard let resourceIdString = req.parameters.get(resource.parameterName),
            let resourceId = UUID(uuidString: resourceIdString),
            let sessionId = req.parameters.get("sessionID"),
            !sessionId.isEmpty
        else {
            Task {
                await req.recordAPIRequestAudit(
                    status: .badRequest,
                    force: true,
                    failOpen: true,
                    redactErrorDetails: true)
                try? await ws.send(
                    #"{"type":"error","message":"Invalid \#(resource.displayName) or session ID"}"#)
                try? await ws.close(code: .unacceptableData)
            }
            return
        }

        Task {
            // Authenticate + authorize before touching the session, mirroring
            // the console's validate-before-load ordering.
            guard
                let userId = await validateExecAccess(
                    req: req, ws: ws, resource: resource, resourceId: resourceId)
            else {
                return
            }

            let manager = req.guestExecSessionManager

            // Consume the pending session: it must exist, be unexpired, target
            // this resource, and have been minted for this user.
            let session: GuestExecSessionManager.PendingExecSession
            do {
                session = try manager.attachSession(
                    sessionId: sessionId,
                    resourceKind: resource.kind,
                    resourceId: resourceId.uuidString,
                    userId: userId,
                    websocket: ws
                )
            } catch {
                let rejectionStatus = Self.attachRejectionStatus(for: error)
                req.logger.warning(
                    "\(resource.logName) exec attach rejected: \(error)",
                    metadata: [
                        "resourceKind": .string(resource.kind.rawValue),
                        "resourceId": .string(resourceId.uuidString),
                        "sessionId": .string(sessionId),
                    ])
                await req.recordAPIRequestAudit(
                    status: rejectionStatus,
                    force: true,
                    failOpen: true,
                    redactErrorDetails: true)
                try? await ws.send(#"{"type":"error","message":"Invalid, expired, or already attached exec session"}"#)
                try? await ws.close(code: .policyViolation)
                return
            }

            req.logger.info(
                "\(resource.logName) exec WebSocket connection established",
                metadata: [
                    "resourceKind": .string(resource.kind.rawValue),
                    "resourceId": .string(resourceId.uuidString),
                    "sessionId": .string(sessionId),
                    "agentName": .string(session.agentKey),
                ])

            // Everything sent to the agent for this session flows through a
            // single serial pump: the frame handlers yield synchronously
            // (preserving WebSocket arrival order) and one task relays events
            // to the agent one at a time. Spawning a Task per frame would let
            // the scheduler transpose rapid stdin frames (fast typing, paste),
            // corrupting what runs in the guest. The exec start and the
            // browser-disconnect close ride the same pump — enqueued first and
            // last respectively — so a browser that disconnects while attach
            // setup is still in flight cannot make the close overtake the
            // start on the agent socket and orphan the exec process. Errors
            // are still handled per event.
            let (events, eventContinuation) = AsyncStream.makeStream(of: SessionEvent.self)
            Task {
                // Whether the start message reached the agent: a close only
                // needs sending for a session the agent may have spawned.
                var started = false
                for await event in events {
                    switch event {
                    case .start:
                        do {
                            try await manager.sendExecStart(for: session)
                            started = true
                        } catch {
                            req.logger.error("Failed to start guest exec on agent: \(error)")
                            await manager.endSession(
                                sessionId: sessionId,
                                outcome: .refused,
                                reason: "Could not dispatch exec start: \(error.localizedDescription)")
                            try? await ws.send(
                                #"{"type":"error","message":"Failed to start exec session on agent"}"#)
                            try? await ws.close(code: .unexpectedServerError)
                        }
                    case .input(let data):
                        do {
                            try await manager.routeInput(sessionId: sessionId, data: data)
                        } catch {
                            req.logger.error("Failed to route exec input to agent: \(error)")
                        }
                    case .resize(let rows, let cols):
                        do {
                            try await manager.routeResize(sessionId: sessionId, rows: rows, cols: cols)
                        } catch {
                            req.logger.error("Failed to route exec resize to agent: \(error)")
                        }
                    case .stdinEOF:
                        do {
                            try await manager.routeInput(sessionId: sessionId, data: nil, eof: true)
                        } catch {
                            req.logger.error("Failed to route exec stdin EOF to agent: \(error)")
                        }
                    case .browserClosed:
                        // Tell the agent to tear the exec down before removing
                        // the session. A no-op if the agent already reported
                        // exit/closed (the session is gone by then); skipped
                        // entirely when the start never reached the agent.
                        if started {
                            try? await manager.sendExecClose(sessionId: sessionId, reason: "browser disconnected")
                        }
                        await manager.endSession(
                            sessionId: sessionId,
                            outcome: .terminated,
                            reason: "browser disconnected")
                    }
                }
            }

            // The start is the pump's first event — enqueued before the frame
            // handlers exist, so no input/resize/close can precede it.
            eventContinuation.yield(.start)

            // WebSocketKit's frame-callback setters are loop-bound
            // (`NIOLoopBoundBox`): calling them from this task — which runs on
            // the concurrent executor, not the socket's event loop — trips
            // `EventLoop.preconditionInEventLoop` and kills the whole process.
            // Register them via an explicit hop to the socket's event loop.
            ws.eventLoop.execute {
                // Binary frames are stdin bytes for the exec process.
                ws.onBinary { _, buffer in
                    let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) ?? []
                    eventContinuation.yield(.input(Data(bytes)))
                }

                // Text frames are JSON control messages. Unknown or malformed
                // frames are ignored for forward compatibility.
                ws.onText { _, text in
                    switch Self.decodeClientControlFrame(text) {
                    case .resize(let rows, let cols):
                        eventContinuation.yield(.resize(rows: rows, cols: cols))
                    case .stdinEOF:
                        eventContinuation.yield(.stdinEOF)
                    case nil:
                        break
                    }
                }
            }

            ws.onClose.whenComplete { result in
                switch result {
                case .success:
                    req.logger.info(
                        "\(resource.logName) exec WebSocket connection closed",
                        metadata: [
                            "resourceKind": .string(resource.kind.rawValue),
                            "resourceId": .string(resourceId.uuidString),
                            "sessionId": .string(sessionId),
                        ])
                case .failure(let error):
                    req.logger.error(
                        "\(resource.logName) exec WebSocket connection closed with error: \(error)",
                        metadata: [
                            "resourceKind": .string(resource.kind.rawValue),
                            "resourceId": .string(resourceId.uuidString),
                            "sessionId": .string(sessionId),
                        ])
                }

                // The teardown is the pump's last event: everything already
                // queued (including the start) reaches the agent first.
                eventContinuation.yield(.browserClosed)
                eventContinuation.finish()
            }
        }
    }

    /// One event on the per-connection serial pump: the initial exec start,
    /// browser frames, and the browser-disconnect teardown, in strict order.
    private enum SessionEvent: Sendable {
        case start
        case input(Data)
        case resize(rows: Int, cols: Int)
        case stdinEOF
        case browserClosed
    }

    private struct ClientControlFrame: Decodable {
        let type: String
        let cols: Int?
        let rows: Int?
    }

    private enum ClientControl: Sendable {
        case resize(rows: Int, cols: Int)
        case stdinEOF
    }

    private static func decodeClientControlFrame(_ text: String) -> ClientControl? {
        guard let data = text.data(using: .utf8),
            let frame = try? JSONDecoder().decode(ClientControlFrame.self, from: data)
        else {
            return nil
        }
        switch frame.type {
        case "resize":
            guard let rows = frame.rows, let cols = frame.cols else { return nil }
            return .resize(rows: rows, cols: cols)
        case "stdin_eof":
            return .stdinEOF
        default:
            return nil
        }
    }

    private static func attachRejectionStatus(for error: any Error) -> HTTPResponseStatus {
        switch error as? GuestExecSessionError {
        case .sessionNotFound:
            return .notFound
        case .sessionExpired:
            return .gone
        case .sessionMismatch:
            return .forbidden
        case .alreadyAttached:
            return .conflict
        case .agentNotConnected:
            return .internalServerError
        case nil:
            return (error as? any AbortError)?.status ?? .internalServerError
        }
    }

    /// Authenticates the request and re-checks the resource's exec permission.
    /// Returns the user ID on success; on any failure it
    /// reports the error over the socket, closes it, and returns nil.
    /// Mirrors `ConsoleWebSocketController.validateConsoleAccess`: authorize
    /// before loading the resource.
    private func validateExecAccess(
        req: Request,
        ws: WebSocket,
        resource: Resource,
        resourceId: UUID
    ) async -> String? {
        do {
            guard let user = req.auth.get(User.self) else {
                req.logger.warning("Guest exec WebSocket authentication failed - no user found")
                await req.recordAPIRequestAudit(
                    status: .unauthorized,
                    force: true,
                    failOpen: true,
                    redactErrorDetails: true)
                try? await ws.send(#"{"type":"error","message":"Authentication required"}"#)
                try? await ws.close(code: .policyViolation)
                return nil
            }

            guard let userId = user.id?.uuidString, !userId.isEmpty else {
                await req.recordAPIRequestAudit(
                    status: .unauthorized,
                    force: true,
                    failOpen: true,
                    redactErrorDetails: true)
                try? await ws.send(#"{"type":"error","message":"Invalid user session"}"#)
                try? await ws.close(code: .policyViolation)
                return nil
            }

            // Authorize before touching the pending session, so a session id
            // cannot outlive a revoked permission and become a standing grant.
            let hasPermission = try await req.can(
                resource.iamAction, on: IAMNode(type: resource.nodeType, id: resourceId))

            guard hasPermission else {
                req.logger.warning(
                    "\(resource.logName) exec access denied",
                    metadata: [
                        "resourceKind": .string(resource.kind.rawValue),
                        "resourceId": .string(resourceId.uuidString),
                        "userId": .string(userId),
                    ])
                await req.recordAPIRequestAudit(
                    status: .forbidden,
                    force: true,
                    failOpen: true,
                    redactErrorDetails: true)
                try? await ws.send(
                    #"{"type":"error","message":"You do not have permission to exec into this \#(resource.displayName)"}"#
                )
                try? await ws.close(code: .policyViolation)
                return nil
            }

            return userId
        } catch {
            req.logger.error("Guest exec WebSocket handler error: \(error)")
            let status = (error as? any AbortError)?.status ?? .internalServerError
            await req.recordAPIRequestAudit(
                status: status,
                error: error,
                force: true,
                failOpen: true,
                redactErrorDetails: true)
            try? await ws.close(code: .unexpectedServerError)
            return nil
        }
    }
}
