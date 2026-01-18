import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent

struct AgentWebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let agentRoutes = routes.grouped("agent")
        agentRoutes.webSocket("ws", onUpgrade: websocketHandler)
    }

    // Non-async handler - runs on WebSocket's event loop
    private func websocketHandler(req: Request, ws: WebSocket) {
        // Extract token and agent name from query parameters
        guard let token = req.query[String.self, at: "token"],
              let agentName = req.query[String.self, at: "name"] else {
            sendErrorResponse(ws: ws, requestId: "", error: "Registration token and agent name are required")
            _ = ws.close(code: .unacceptableData)
            return
        }

        // Set up message handlers IMMEDIATELY to prevent message loss
        // Messages will be buffered until validation completes
        // Note: All access to these variables happens on ws.eventLoop, so no actual concurrency
        final class MessageState: @unchecked Sendable {
            var buffer: [String] = []
            var isValidated = false
        }
        let state = MessageState()

        ws.onText { ws, text in
            if state.isValidated {
                self.handleWebSocketMessage(req: req, ws: ws, text: text, agentName: agentName)
            } else {
                // Buffer messages until validation completes
                state.buffer.append(text)
            }
        }

        ws.onBinary { ws, buffer in
            req.logger.info("Received WebSocket binary message from agent", metadata: ["agentName": .string(agentName), "bytes": .string("\(buffer.readableBytes)")])
            // Convert binary buffer to string and process as text message
            if let text = buffer.getString(at: 0, length: buffer.readableBytes) {
                if state.isValidated {
                    self.handleWebSocketMessage(req: req, ws: ws, text: text, agentName: agentName)
                } else {
                    // Buffer messages until validation completes
                    state.buffer.append(text)
                }
            } else {
                req.logger.error("Failed to convert binary buffer to string")
            }
        }

        ws.onClose.whenComplete { result in
            switch result {
            case .success:
                req.logger.info("Agent WebSocket connection closed normally", metadata: [
                    "agentName": .string(agentName)
                ])
            case .failure(let error):
                req.logger.error("Agent WebSocket connection closed with error: \(error)", metadata: [
                    "agentName": .string(agentName)
                ])
            }

            // Clean up connection tracking
            req.application.websocketManager.removeConnection(agentName: agentName)

            // Mark agent as offline asynchronously
            Task {
                await req.agentService.removeAgent(agentName)
            }
        }

        // Validate registration token using EventLoopFuture
        validateRegistrationToken(req: req, ws: ws, token: token, agentName: agentName)
            .flatMap { isValid -> EventLoopFuture<Void> in
                guard isValid else {
                    return ws.eventLoop.makeSucceededFuture(())
                }

                req.logger.info("Agent WebSocket connection established", metadata: [
                    "agentName": .string(agentName)
                ])

                // Store WebSocket for this agent - we're already on the WebSocket's event loop
                req.application.websocketManager.setConnection(agentName: agentName, websocket: ws)

                // Mark as validated and process buffered messages
                state.isValidated = true
                req.logger.info("Processing \(state.buffer.count) buffered messages", metadata: ["agentName": .string(agentName)])

                for text in state.buffer {
                    self.handleWebSocketMessage(req: req, ws: ws, text: text, agentName: agentName)
                }
                state.buffer.removeAll()

                return ws.eventLoop.makeSucceededFuture(())
            }
            .whenFailure { error in
                req.logger.error("WebSocket handler error: \(error)")
                _ = ws.close(code: .unexpectedServerError)
            }
    }

    private func validateRegistrationToken(
        req: Request,
        ws: WebSocket,
        token: String,
        agentName: String
    ) -> EventLoopFuture<Bool> {
        // Query database for token
        let query = AgentRegistrationToken.query(on: req.db)
            .filter(\.$token == token)
            .filter(\.$agentName == agentName)
            .first()

        return query.flatMapThrowing { registrationToken -> Bool in
            guard let registrationToken = registrationToken else {
                self.sendErrorResponse(ws: ws, requestId: "", error: "Invalid registration token")
                _ = ws.close(code: .unacceptableData)
                return false
            }

            guard registrationToken.isValid else {
                self.sendErrorResponse(ws: ws, requestId: "", error: "Registration token is invalid or expired")
                _ = ws.close(code: .unacceptableData)
                return false
            }

            // Mark token as used
            registrationToken.markAsUsed()

            // Save asynchronously
            Task {
                try? await registrationToken.save(on: req.db)
            }

            req.logger.info("Agent registration token validated", metadata: [
                "agentName": .string(agentName),
                "token": .string(token)
            ])

            return true
        }.flatMapErrorThrowing { error in
            req.logger.error("Error validating registration token: \(error)")
            self.sendErrorResponse(ws: ws, requestId: "", error: "Internal server error during token validation")
            _ = ws.close(code: .unexpectedServerError)
            return false
        }
    }

    private func handleWebSocketMessage(req: Request, ws: WebSocket, text: String, agentName: String) {
        req.logger.info("Processing WebSocket message", metadata: [
            "agentName": .string(agentName),
            "messageLength": .string("\(text.count)"),
            "rawTextPreview": .string(String(text.prefix(500)))
        ])

        guard let data = text.data(using: .utf8) else {
            req.logger.error("Failed to convert WebSocket text to data")
            return
        }

        do {
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)
            req.logger.info("Decoded message envelope", metadata: ["type": .string("\(envelope.type)"), "agentName": .string(agentName)])

            switch envelope.type {
            case .agentRegister:
                let message = try envelope.decode(as: AgentRegisterMessage.self)
                Task {
                    do {
                        let agentUUID = try await req.agentService.registerAgent(message, agentName: agentName)
                        // Send registration response with the assigned UUID
                        let response = AgentRegisterResponseMessage(
                            requestId: message.requestId,
                            agentId: agentUUID.uuidString,
                            name: agentName
                        )
                        self.sendMessage(ws: ws, message: response)
                    } catch {
                        req.logger.error("Failed to register agent: \(error)")
                        self.sendErrorResponse(ws: ws, requestId: message.requestId, error: "Failed to register agent: \(error.localizedDescription)")
                    }
                }

            case .agentHeartbeat:
                let message = try envelope.decode(as: AgentHeartbeatMessage.self)
                Task {
                    do {
                        try await req.agentService.updateAgentHeartbeat(message)
                        self.sendSuccessResponse(ws: ws, requestId: message.requestId, message: "Heartbeat acknowledged")
                    } catch {
                        req.logger.error("Failed to update heartbeat: \(error)")
                        self.sendErrorResponse(ws: ws, requestId: message.requestId, error: "Failed to update heartbeat")
                    }
                }

            case .agentUnregister:
                let message = try envelope.decode(as: AgentUnregisterMessage.self)
                Task {
                    do {
                        try await req.agentService.unregisterAgent(message.agentId)
                        self.sendSuccessResponse(ws: ws, requestId: message.requestId, message: "Agent unregistered successfully")
                    } catch {
                        req.logger.error("Failed to unregister agent: \(error)")
                        self.sendErrorResponse(ws: ws, requestId: message.requestId, error: "Failed to unregister agent")
                    }
                }

            case .success, .error, .statusUpdate:
                // Handle responses from agents
                Task {
                    await req.agentService.handleAgentResponse(envelope)
                }

            case .consoleData:
                // Route console data from agent to frontend
                let message = try envelope.decode(as: ConsoleDataMessage.self)
                if let data = message.rawData {
                    req.consoleSessionManager.routeToFrontend(
                        vmId: message.vmId,
                        sessionId: message.sessionId,
                        data: data
                    )
                }

            case .consoleConnected:
                let message = try envelope.decode(as: ConsoleConnectedMessage.self)
                req.logger.info("Console connected confirmation from agent", metadata: [
                    "vmId": .string(message.vmId),
                    "sessionId": .string(message.sessionId)
                ])
                // Notify the frontend that the console is ready for input
                req.consoleSessionManager.notifyFrontendReady(sessionId: message.sessionId)

            case .consoleDisconnected:
                let message = try envelope.decode(as: ConsoleDisconnectedMessage.self)
                req.logger.info("Console disconnected from agent", metadata: [
                    "vmId": .string(message.vmId),
                    "sessionId": .string(message.sessionId),
                    "reason": .string(message.reason ?? "unknown")
                ])
                // Clean up the session
                req.consoleSessionManager.removeSession(sessionId: message.sessionId)

            default:
                req.logger.warning("Received unexpected message type from agent: \(envelope.type)")
                sendErrorResponse(ws: ws, requestId: "", error: "Unexpected message type: \(envelope.type)")
            }

        } catch {
            req.logger.error("Failed to handle WebSocket message: \(error)")
            sendErrorResponse(ws: ws, requestId: "", error: "Failed to process message: \(error.localizedDescription)")
        }
    }

    private func sendMessage<T: WebSocketMessage>(ws: WebSocket, message: T) {
        do {
            let envelope = try MessageEnvelope(message: message)
            let data = try JSONEncoder().encode(envelope)
            ws.send(data)
        } catch {
            print("Failed to send message: \(error)")
        }
    }

    private func sendSuccessResponse(ws: WebSocket, requestId: String, message: String) {
        do {
            let response = SuccessMessage(requestId: requestId, message: message)
            let envelope = try MessageEnvelope(message: response)
            let data = try JSONEncoder().encode(envelope)
            ws.send(data)
        } catch {
            print("Failed to send success response: \(error)")
        }
    }

    private func sendErrorResponse(ws: WebSocket, requestId: String, error: String) {
        do {
            let response = ErrorMessage(requestId: requestId, error: error)
            let envelope = try MessageEnvelope(message: response)
            let data = try JSONEncoder().encode(envelope)
            ws.send(data)
        } catch {
            print("Failed to send error response: \(error)")
        }
    }
}
