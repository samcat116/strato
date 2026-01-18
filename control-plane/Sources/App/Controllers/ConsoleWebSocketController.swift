import Foundation
import Vapor
import StratoShared
import Fluent

struct ConsoleWebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // WebSocket endpoint for VM console: /api/vms/:vmID/console
        let vmRoutes = routes.grouped("api", "vms")
        vmRoutes.webSocket(":vmID", "console", onUpgrade: websocketHandler)
    }

    // Non-async handler - runs on WebSocket's event loop
    private func websocketHandler(req: Request, ws: WebSocket) {
        // Extract VM ID from path
        guard let vmIdString = req.parameters.get("vmID"),
              let vmId = UUID(uuidString: vmIdString) else {
            ws.send("error: Invalid VM ID")
            _ = ws.close(code: .unacceptableData)
            return
        }

        // Generate unique session ID
        let sessionId = UUID().uuidString

        // Validate session and VM access using EventLoopFuture
        validateConsoleAccess(req: req, ws: ws, vmId: vmId, sessionId: sessionId)
            .flatMap { validationResult -> EventLoopFuture<Void> in
                guard let result = validationResult else {
                    return ws.eventLoop.makeSucceededFuture(())
                }

                let (_, agentName, userId) = result

                req.logger.info("Console WebSocket connection established", metadata: [
                    "vmId": .string(vmIdString),
                    "sessionId": .string(sessionId),
                    "agentName": .string(agentName)
                ])

                // Create session in ConsoleSessionManager
                req.consoleSessionManager.createSession(
                    sessionId: sessionId,
                    vmId: vmIdString,
                    agentName: agentName,
                    userId: userId,
                    websocket: ws
                )

                // Set up message handlers for user input
                ws.onBinary { ws, buffer in
                    // User is typing - send to agent
                    let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) ?? []
                    let data = Data(bytes)

                    Task {
                        do {
                            try await req.consoleSessionManager.routeToAgent(sessionId: sessionId, data: data)
                        } catch {
                            req.logger.error("Failed to route console input to agent: \(error)")
                        }
                    }
                }

                ws.onText { ws, text in
                    // User input as text - convert to data and send to agent
                    guard let data = text.data(using: .utf8) else { return }

                    Task {
                        do {
                            try await req.consoleSessionManager.routeToAgent(sessionId: sessionId, data: data)
                        } catch {
                            req.logger.error("Failed to route console input to agent: \(error)")
                        }
                    }
                }

                ws.onClose.whenComplete { result in
                    switch result {
                    case .success:
                        req.logger.info("Console WebSocket connection closed normally", metadata: [
                            "vmId": .string(vmIdString),
                            "sessionId": .string(sessionId)
                        ])
                    case .failure(let error):
                        req.logger.error("Console WebSocket connection closed with error: \(error)", metadata: [
                            "vmId": .string(vmIdString),
                            "sessionId": .string(sessionId)
                        ])
                    }

                    // Clean up session
                    req.consoleSessionManager.removeSession(sessionId: sessionId)

                    // Notify agent to disconnect console
                    Task {
                        try? await req.consoleSessionManager.sendConsoleDisconnect(sessionId: sessionId)
                    }
                }

                // Send console connect message to agent
                Task {
                    do {
                        try await req.consoleSessionManager.sendConsoleConnect(
                            sessionId: sessionId,
                            vmId: vmIdString,
                            agentName: agentName
                        )
                    } catch {
                        req.logger.error("Failed to connect to agent console: \(error)")
                        try? await ws.send("error: Failed to connect to VM console")
                        try? await ws.close(code: .unexpectedServerError)
                    }
                }

                return ws.eventLoop.makeSucceededFuture(())
            }
            .whenFailure { error in
                req.logger.error("Console WebSocket handler error: \(error)")
                _ = ws.close(code: .unexpectedServerError)
            }
    }

    private func validateConsoleAccess(
        req: Request,
        ws: WebSocket,
        vmId: UUID,
        sessionId: String
    ) -> EventLoopFuture<(VM, String, String?)?> {
        // First, get the user (either from auth or dev bypass)
        let userFuture: EventLoopFuture<User?>

        if let user = req.auth.get(User.self) {
            // User already authenticated via middleware
            userFuture = ws.eventLoop.makeSucceededFuture(user)
        } else if req.application.environment == .development,
                  Environment.get("DEV_AUTH_BYPASS") == "true" {
            // Dev mode bypass - look up dev user from database
            req.logger.debug("Console WebSocket attempting dev auth bypass")
            userFuture = User.query(on: req.db)
                .filter(\.$username == "dev")
                .first()
        } else {
            userFuture = ws.eventLoop.makeSucceededFuture(nil)
        }

        return userFuture.flatMap { user -> EventLoopFuture<(VM, String, String?)?> in
            guard let user = user else {
                req.logger.warning("Console WebSocket authentication failed - no user found")
                ws.send("error: Authentication required")
                _ = ws.close(code: .policyViolation)
                return ws.eventLoop.makeSucceededFuture(nil)
            }

            req.logger.debug("Console WebSocket authenticated as user: \(user.username)")

            // Query VM from database
            return VM.find(vmId, on: req.db).flatMap { vm -> EventLoopFuture<(VM, String, String?)?> in
                guard let vm = vm else {
                    ws.send("error: VM not found")
                    _ = ws.close(code: .unacceptableData)
                    return ws.eventLoop.makeSucceededFuture(nil)
                }

                // Check if VM is running
                guard vm.status == .running else {
                    ws.send("error: VM is not running")
                    _ = ws.close(code: .unacceptableData)
                    return ws.eventLoop.makeSucceededFuture(nil)
                }

                // Check if VM has an assigned hypervisor (agent UUID)
                guard let agentIdString = vm.hypervisorId,
                      let agentId = UUID(uuidString: agentIdString) else {
                    ws.send("error: VM has no assigned hypervisor")
                    _ = ws.close(code: .unexpectedServerError)
                    return ws.eventLoop.makeSucceededFuture(nil)
                }

                // Look up agent to get the agent name (WebSocket connections are keyed by name)
                return Agent.find(agentId, on: req.db).flatMap { agent -> EventLoopFuture<(VM, String, String?)?> in
                    guard let agent = agent else {
                        ws.send("error: Agent not found for VM")
                        _ = ws.close(code: .unexpectedServerError)
                        return ws.eventLoop.makeSucceededFuture(nil)
                    }

                    // TODO: Add permission check via SpiceDB
                    // For now, allow any authenticated user to access console

                    return ws.eventLoop.makeSucceededFuture((vm, agent.name, user.id?.uuidString))
                }
            }
        }
    }
}
