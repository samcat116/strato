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

    private func websocketHandler(req: Request, ws: WebSocket) async {
        // Validate registration token on connection
        guard let validatedAgentName = await validateRegistrationToken(req: req, ws: ws) else {
            // Validation failed, connection will be closed by validateRegistrationToken
            return
        }
        
        req.logger.info("Agent WebSocket connection established", metadata: [
            "agentName": .string(validatedAgentName)
        ])

        // Store agent name for this connection
        await req.agentService.setConnectionAgentName(ws, agentName: validatedAgentName)

        ws.onText { ws, text in
            Task {
                await handleWebSocketMessage(req: req, ws: ws, text: text)
            }
        }

        ws.onBinary { _, _ in
            req.logger.warning("Received unexpected binary data from agent")
        }

        ws.onClose.whenComplete { result in
            Task {
                let agentName = await req.agentService.getConnectionAgentName(ws)
                switch result {
                case .success:
                    req.logger.info("Agent WebSocket connection closed normally", metadata: [
                        "agentName": .string(agentName ?? "unknown")
                    ])
                case .failure(let error):
                    req.logger.error("Agent WebSocket connection closed with error: \(error)", metadata: [
                        "agentName": .string(agentName ?? "unknown")
                    ])
                }
                
                // Clean up connection tracking
                await req.agentService.removeConnectionTracking(ws)
            }
        }
    }

    private func handleWebSocketMessage(req: Request, ws: WebSocket, text: String) async {
        do {
            guard let data = text.data(using: .utf8) else {
                req.logger.error("Failed to convert WebSocket text to data")
                return
            }

            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: data)

            switch envelope.type {
            case .agentRegister:
                let message = try envelope.decode(as: AgentRegisterMessage.self)
                try await req.agentService.registerAgent(message, websocket: ws)
                await sendSuccessResponse(ws: ws, requestId: message.requestId, message: "Agent registered successfully")

            case .agentHeartbeat:
                let message = try envelope.decode(as: AgentHeartbeatMessage.self)
                try await req.agentService.updateAgentHeartbeat(message)
                await sendSuccessResponse(ws: ws, requestId: message.requestId, message: "Heartbeat acknowledged")

            case .agentUnregister:
                let message = try envelope.decode(as: AgentUnregisterMessage.self)
                try await req.agentService.unregisterAgent(message.agentId)
                await sendSuccessResponse(ws: ws, requestId: message.requestId, message: "Agent unregistered successfully")

            case .success, .error, .statusUpdate:
                // Handle responses from agents
                await req.agentService.handleAgentResponse(envelope)

            default:
                req.logger.warning("Received unexpected message type from agent: \(envelope.type)")
                await sendErrorResponse(ws: ws, requestId: "", error: "Unexpected message type: \(envelope.type)")
            }

        } catch {
            req.logger.error("Failed to handle WebSocket message: \(error)")
            await sendErrorResponse(ws: ws, requestId: "", error: "Failed to process message: \(error.localizedDescription)")
        }
    }

    private func sendSuccessResponse(ws: WebSocket, requestId: String, message: String) async {
        do {
            let response = SuccessMessage(requestId: requestId, message: message)
            let envelope = try MessageEnvelope(message: response)
            let data = try JSONEncoder().encode(envelope)

            ws.send(data)
        } catch {
            // Log error but don't throw since we're already in an error handling context
            print("Failed to send success response: \(error)")
        }
    }

    private func sendErrorResponse(ws: WebSocket, requestId: String, error: String) async {
        do {
            let response = ErrorMessage(requestId: requestId, error: error)
            let envelope = try MessageEnvelope(message: response)
            let data = try JSONEncoder().encode(envelope)

            ws.send(data)
        } catch {
            // Log error but don't throw since we're already in an error handling context
            print("Failed to send error response: \(error)")
        }
    }
    
    private func validateRegistrationToken(req: Request, ws: WebSocket) async -> String? {
        do {
            // Extract token and agent name from query parameters
            guard let token = req.query[String.self, at: "token"] else {
                await sendErrorResponse(ws: ws, requestId: "", error: "Registration token is required")
                try? await ws.close(code: .unacceptableData)
                return nil
            }
            
            guard let agentName = req.query[String.self, at: "name"] else {
                await sendErrorResponse(ws: ws, requestId: "", error: "Agent name is required")
                try? await ws.close(code: .unacceptableData)
                return nil
            }
            
            // Find and validate the registration token
            guard let registrationToken = try await AgentRegistrationToken.query(on: req.db)
                .filter(\.$token == token)
                .filter(\.$agentName == agentName)
                .first() else {
                await sendErrorResponse(ws: ws, requestId: "", error: "Invalid registration token")
                try? await ws.close(code: .unacceptableData)
                return nil
            }
            
            // Check if token is still valid (not used and not expired)
            guard registrationToken.isValid else {
                let reason = registrationToken.isUsed ? "Registration token has already been used" : "Registration token has expired"
                await sendErrorResponse(ws: ws, requestId: "", error: reason)
                try? await ws.close(code: .unacceptableData)
                return nil
            }
            
            // Mark token as used
            registrationToken.markAsUsed()
            try await registrationToken.save(on: req.db)
            
            req.logger.info("Agent registration token validated", metadata: [
                "agentName": .string(agentName),
                "token": .string(token)
            ])
            
            return agentName
            
        } catch {
            req.logger.error("Error validating registration token: \(error)")
            await sendErrorResponse(ws: ws, requestId: "", error: "Internal server error during token validation")
            try? await ws.close(code: .internalServerError)
            return nil
        }
    }
}
