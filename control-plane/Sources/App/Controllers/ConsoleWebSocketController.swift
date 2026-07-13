import Fluent
import Foundation
import StratoShared
import Vapor

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
            let vmId = UUID(uuidString: vmIdString)
        else {
            ws.send("error: Invalid VM ID")
            _ = ws.close(code: .unacceptableData)
            return
        }

        // Generate unique session ID
        let sessionId = UUID().uuidString

        Task {
            // Validate session and VM access
            guard let (agentName, userId) = await validateConsoleAccess(req: req, ws: ws, vmId: vmId) else {
                return
            }

            req.logger.info(
                "Console WebSocket connection established",
                metadata: [
                    "vmId": .string(vmIdString),
                    "sessionId": .string(sessionId),
                    "agentName": .string(agentName),
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
                    req.logger.info(
                        "Console WebSocket connection closed normally",
                        metadata: [
                            "vmId": .string(vmIdString),
                            "sessionId": .string(sessionId),
                        ])
                case .failure(let error):
                    req.logger.error(
                        "Console WebSocket connection closed with error: \(error)",
                        metadata: [
                            "vmId": .string(vmIdString),
                            "sessionId": .string(sessionId),
                        ])
                }

                // Notify agent to disconnect console before removing session
                Task {
                    defer {
                        req.consoleSessionManager.removeSession(sessionId: sessionId)
                    }
                    try? await req.consoleSessionManager.sendConsoleDisconnect(sessionId: sessionId)
                }
            }

            // Send console connect message to agent
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
    }

    /// Authenticates and authorizes the console request, then resolves the
    /// VM's agent. Returns the agent name and user ID on success; on any
    /// failure it reports the error over the socket, closes it, and returns
    /// nil.
    private func validateConsoleAccess(
        req: Request,
        ws: WebSocket,
        vmId: UUID
    ) async -> (agentName: String, userId: String?)? {
        do {
            // First, get the user (either from auth or dev bypass)
            let user: User?
            if let authenticated = req.auth.get(User.self) {
                // User already authenticated via middleware
                user = authenticated
            } else if req.application.environment == .development,
                Environment.get("DEV_AUTH_BYPASS") == "true"
            {
                // Dev mode bypass - look up dev user from database
                req.logger.debug("Console WebSocket attempting dev auth bypass")
                user = try await User.query(on: req.db)
                    .filter(\.$username == "dev")
                    .first()
            } else {
                user = nil
            }

            guard let user else {
                req.logger.warning("Console WebSocket authentication failed - no user found")
                try? await ws.send("error: Authentication required")
                try? await ws.close(code: .policyViolation)
                return nil
            }

            guard let userId = user.id?.uuidString, !userId.isEmpty else {
                try? await ws.send("error: Invalid user session")
                try? await ws.close(code: .policyViolation)
                return nil
            }

            req.logger.debug("Console WebSocket authenticated as user: \(user.username)")

            // Authorize before loading the VM, so unauthorized users cannot probe
            // arbitrary VM UUIDs via distinct "VM not found" / "not running" errors.
            // Consistent with SpiceDBAuthMiddleware: system admins and the dev-auth
            // bypass skip the permission check.
            let devBypass =
                req.application.environment == .development
                && Environment.get("DEV_AUTH_BYPASS") == "true"
            let hasPermission: Bool
            if user.isSystemAdmin || devBypass {
                hasPermission = true
            } else {
                hasPermission = try await req.spicedb.checkPermission(
                    subject: userId,
                    permission: "view_console",
                    resource: "virtual_machine",
                    resourceId: vmId.uuidString
                )
            }

            guard hasPermission else {
                req.logger.warning(
                    "Console access denied",
                    metadata: [
                        "vmId": .string(vmId.uuidString),
                        "userId": .string(userId),
                    ])
                try? await ws.send("error: You do not have permission to access this VM console")
                try? await ws.close(code: .policyViolation)
                return nil
            }

            // Query VM from database
            guard let vm = try await VM.find(vmId, on: req.db) else {
                try? await ws.send("error: VM not found")
                try? await ws.close(code: .unacceptableData)
                return nil
            }

            // Check if VM is running
            guard vm.status == .running else {
                try? await ws.send("error: VM is not running")
                try? await ws.close(code: .unacceptableData)
                return nil
            }

            // Check if VM has an assigned hypervisor (agent UUID)
            guard let agentIdString = vm.hypervisorId,
                let agentId = UUID(uuidString: agentIdString)
            else {
                try? await ws.send("error: VM has no assigned hypervisor")
                try? await ws.close(code: .unexpectedServerError)
                return nil
            }

            // Look up agent to get the agent name (WebSocket connections are keyed by name)
            guard let agent = try await Agent.find(agentId, on: req.db) else {
                try? await ws.send("error: Agent not found for VM")
                try? await ws.close(code: .unexpectedServerError)
                return nil
            }

            return (agent.name, userId)
        } catch {
            req.logger.error("Console WebSocket handler error: \(error)")
            try? await ws.close(code: .unexpectedServerError)
            return nil
        }
    }
}
