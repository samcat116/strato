import Fluent
import Foundation
import StratoShared
import Vapor

/// WebSocket endpoint attaching a browser to a sandbox exec session
/// (issue #423), modeled on `ConsoleWebSocketController`.
///
/// Flow: `POST /api/sandboxes/:id/exec` mints a pending session; the browser
/// then connects to `GET /api/sandboxes/:id/exec/:sessionId/attach`. This
/// handler re-authorizes (`exec` on the sandbox), consumes the pending
/// session, sends the `SandboxExecStartMessage` to the agent, and relays
/// frames until the exec ends or the browser disconnects.
///
/// Browser frame contract:
/// - browser → CP: binary frames are stdin bytes; text frames are JSON
///   control messages (`{"type":"resize","cols":C,"rows":R}`); unknown text
///   frames are ignored.
/// - CP → browser: `{"type":"ready"}` once the process spawned; binary frames
///   are output bytes (stdout/stderr interleaved);
///   `{"type":"exit","exitCode":N}` then a normal close when it exits;
///   `{"type":"error","message":"..."}` then a close on abnormal end.
struct SandboxExecWebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let sandboxRoutes = routes.grouped("api", "sandboxes")
        sandboxRoutes.webSocket(":sandboxID", "exec", ":sessionID", "attach", onUpgrade: websocketHandler)
    }

    // Non-async handler - runs on WebSocket's event loop
    private func websocketHandler(req: Request, ws: WebSocket) {
        guard let sandboxIdString = req.parameters.get("sandboxID"),
            let sandboxId = UUID(uuidString: sandboxIdString),
            let sessionId = req.parameters.get("sessionID"),
            !sessionId.isEmpty
        else {
            ws.send(#"{"type":"error","message":"Invalid sandbox or session ID"}"#)
            _ = ws.close(code: .unacceptableData)
            return
        }

        Task {
            // Authenticate + authorize before touching the session, mirroring
            // the console's validate-before-load ordering.
            guard let userId = await validateExecAccess(req: req, ws: ws, sandboxId: sandboxId) else {
                return
            }

            let manager = req.sandboxExecSessionManager

            // Consume the pending session: it must exist, be unexpired, target
            // this sandbox, and have been minted for this user.
            let session: SandboxExecSessionManager.PendingExecSession
            do {
                session = try manager.attachSession(
                    sessionId: sessionId,
                    sandboxId: sandboxId.uuidString,
                    userId: userId,
                    websocket: ws
                )
            } catch {
                req.logger.warning(
                    "Sandbox exec attach rejected: \(error)",
                    metadata: [
                        "sandboxId": .string(sandboxId.uuidString),
                        "sessionId": .string(sessionId),
                    ])
                try? await ws.send(#"{"type":"error","message":"Invalid, expired, or already attached exec session"}"#)
                try? await ws.close(code: .policyViolation)
                return
            }

            req.logger.info(
                "Sandbox exec WebSocket connection established",
                metadata: [
                    "sandboxId": .string(sandboxId.uuidString),
                    "sessionId": .string(sessionId),
                    "agentName": .string(session.agentKey),
                ])

            // Everything sent to the agent for this session flows through a
            // single serial pump: the frame handlers yield synchronously
            // (preserving WebSocket arrival order) and one task relays events
            // to the agent one at a time. Spawning a Task per frame would let
            // the scheduler transpose rapid stdin frames (fast typing, paste),
            // corrupting what runs in the sandbox. The exec start and the
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
                            req.logger.error("Failed to start sandbox exec on agent: \(error)")
                            manager.removeSession(sessionId: sessionId)
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
                    case .browserClosed:
                        // Tell the agent to tear the exec down before removing
                        // the session. A no-op if the agent already reported
                        // exit/closed (the session is gone by then); skipped
                        // entirely when the start never reached the agent.
                        if started {
                            try? await manager.sendExecClose(sessionId: sessionId, reason: "browser disconnected")
                        }
                        manager.removeSession(sessionId: sessionId)
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

                // Text frames are JSON control messages; only resize is defined.
                // Unknown or malformed frames are ignored.
                ws.onText { _, text in
                    guard let resize = Self.decodeResizeFrame(text) else { return }
                    eventContinuation.yield(.resize(rows: resize.rows, cols: resize.cols))
                }
            }

            ws.onClose.whenComplete { result in
                switch result {
                case .success:
                    req.logger.info(
                        "Sandbox exec WebSocket connection closed",
                        metadata: [
                            "sandboxId": .string(sandboxId.uuidString),
                            "sessionId": .string(sessionId),
                        ])
                case .failure(let error):
                    req.logger.error(
                        "Sandbox exec WebSocket connection closed with error: \(error)",
                        metadata: [
                            "sandboxId": .string(sandboxId.uuidString),
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
        case browserClosed
    }

    private struct ResizeFrame: Decodable {
        let type: String
        let cols: Int
        let rows: Int
    }

    private static func decodeResizeFrame(_ text: String) -> ResizeFrame? {
        guard let data = text.data(using: .utf8),
            let frame = try? JSONDecoder().decode(ResizeFrame.self, from: data),
            frame.type == "resize"
        else {
            return nil
        }
        return frame
    }

    /// Authenticates the request and re-checks the `exec` permission
    /// on the sandbox. Returns the user ID on success; on any failure it
    /// reports the error over the socket, closes it, and returns nil.
    /// Mirrors `ConsoleWebSocketController.validateConsoleAccess`: authorize
    /// before loading the resource.
    private func validateExecAccess(
        req: Request,
        ws: WebSocket,
        sandboxId: UUID
    ) async -> String? {
        do {
            guard let user = req.auth.get(User.self) else {
                req.logger.warning("Sandbox exec WebSocket authentication failed - no user found")
                try? await ws.send(#"{"type":"error","message":"Authentication required"}"#)
                try? await ws.close(code: .policyViolation)
                return nil
            }

            guard let userId = user.id?.uuidString, !userId.isEmpty else {
                try? await ws.send(#"{"type":"error","message":"Invalid user session"}"#)
                try? await ws.close(code: .policyViolation)
                return nil
            }

            // Authorize before loading the sandbox, so unauthorized users
            // cannot probe arbitrary sandbox UUIDs via distinct errors.
            let hasPermission = try await req.can("exec", on: "sandbox", id: sandboxId.uuidString)

            guard hasPermission else {
                req.logger.warning(
                    "Sandbox exec access denied",
                    metadata: [
                        "sandboxId": .string(sandboxId.uuidString),
                        "userId": .string(userId),
                    ])
                try? await ws.send(
                    #"{"type":"error","message":"You do not have permission to exec into this sandbox"}"#)
                try? await ws.close(code: .policyViolation)
                return nil
            }

            return userId
        } catch {
            req.logger.error("Sandbox exec WebSocket handler error: \(error)")
            try? await ws.close(code: .unexpectedServerError)
            return nil
        }
    }
}
