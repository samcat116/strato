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
                    "agentName": .string(session.agentName),
                ])

            // Inbound frames flow through a single serial pump: the frame
            // handlers yield synchronously (preserving WebSocket arrival
            // order) and one task relays them to the agent one at a time.
            // Spawning a Task per frame would let the scheduler transpose
            // rapid stdin frames (fast typing, paste), corrupting what runs
            // in the sandbox. Errors are still handled per frame.
            let (frames, frameContinuation) = AsyncStream.makeStream(of: InboundFrame.self)
            Task {
                for await frame in frames {
                    do {
                        switch frame {
                        case .input(let data):
                            try await manager.routeInput(sessionId: sessionId, data: data)
                        case .resize(let rows, let cols):
                            try await manager.routeResize(sessionId: sessionId, rows: rows, cols: cols)
                        }
                    } catch {
                        req.logger.error("Failed to route exec frame to agent: \(error)")
                    }
                }
            }

            // Binary frames are stdin bytes for the exec process.
            ws.onBinary { _, buffer in
                let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) ?? []
                frameContinuation.yield(.input(Data(bytes)))
            }

            // Text frames are JSON control messages; only resize is defined.
            // Unknown or malformed frames are ignored.
            ws.onText { _, text in
                guard let resize = Self.decodeResizeFrame(text) else { return }
                frameContinuation.yield(.resize(rows: resize.rows, cols: resize.cols))
            }

            ws.onClose.whenComplete { result in
                // No more inbound frames: let the pump drain what it has and
                // exit.
                frameContinuation.finish()
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

                // Tell the agent to tear the exec down before removing the
                // session. A no-op if the agent already reported exit/closed
                // (the session is gone by then).
                Task {
                    defer {
                        manager.removeSession(sessionId: sessionId)
                    }
                    try? await manager.sendExecClose(sessionId: sessionId, reason: "browser disconnected")
                }
            }

            // Kick off the exec on the agent.
            do {
                try await manager.sendExecStart(for: session)
            } catch {
                req.logger.error("Failed to start sandbox exec on agent: \(error)")
                manager.removeSession(sessionId: sessionId)
                try? await ws.send(#"{"type":"error","message":"Failed to start exec session on agent"}"#)
                try? await ws.close(code: .unexpectedServerError)
            }
        }
    }

    /// One browser → control-plane frame, queued for the per-connection
    /// serial pump.
    private enum InboundFrame: Sendable {
        case input(Data)
        case resize(rows: Int, cols: Int)
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

    /// Authenticates the request and re-checks the SpiceDB `exec` permission
    /// on the sandbox. Returns the user ID on success; on any failure it
    /// reports the error over the socket, closes it, and returns nil.
    /// Mirrors `ConsoleWebSocketController.validateConsoleAccess`: authorize
    /// before loading the resource, with system-admin and dev-bypass parity.
    private func validateExecAccess(
        req: Request,
        ws: WebSocket,
        sandboxId: UUID
    ) async -> String? {
        do {
            // First, get the user (either from auth or dev bypass)
            let user: User?
            if let authenticated = req.auth.get(User.self) {
                user = authenticated
            } else if req.application.environment == .development,
                Environment.get("DEV_AUTH_BYPASS") == "true"
            {
                req.logger.debug("Sandbox exec WebSocket attempting dev auth bypass")
                user = try await User.query(on: req.db)
                    .filter(\.$username == "dev")
                    .first()
            } else {
                user = nil
            }

            guard let user else {
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
            // Consistent with SpiceDBAuthMiddleware: system admins and the
            // dev-auth bypass skip the permission check.
            let devBypass =
                req.application.environment == .development
                && Environment.get("DEV_AUTH_BYPASS") == "true"
            let hasPermission: Bool
            if user.isSystemAdmin || devBypass {
                hasPermission = true
            } else {
                hasPermission = try await req.spicedb.checkPermission(
                    subject: userId,
                    permission: "exec",
                    resource: "sandbox",
                    resourceId: sandboxId.uuidString
                )
            }

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
