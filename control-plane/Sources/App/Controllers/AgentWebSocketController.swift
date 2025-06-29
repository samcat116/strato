import Foundation
import Vapor
import StratoShared
import NIOWebSocket

struct AgentWebSocketController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let agentRoutes = routes.grouped("agent")
        agentRoutes.webSocket("ws", onUpgrade: websocketHandler)
    }
    
    private func websocketHandler(req: Request, ws: WebSocket) {
        req.logger.info("Agent WebSocket connection established")
        
        ws.onText { ws, text in
            Task {
                await handleWebSocketMessage(req: req, ws: ws, text: text)
            }
        }
        
        ws.onBinary { ws, buffer in
            req.logger.warning("Received unexpected binary data from agent")
        }
        
        ws.onClose.whenComplete { result in
            switch result {
            case .success:
                req.logger.info("Agent WebSocket connection closed normally")
            case .failure(let error):
                req.logger.error("Agent WebSocket connection closed with error: \(error)")
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
                await req.agentService.registerAgent(message, websocket: ws)
                await sendSuccessResponse(ws: ws, requestId: message.requestId, message: "Agent registered successfully")
                
            case .agentHeartbeat:
                let message = try envelope.decode(as: AgentHeartbeatMessage.self)
                await req.agentService.updateAgentHeartbeat(message)
                await sendSuccessResponse(ws: ws, requestId: message.requestId, message: "Heartbeat acknowledged")
                
            case .agentUnregister:
                let message = try envelope.decode(as: AgentUnregisterMessage.self)
                await req.agentService.unregisterAgent(message.agentId)
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
            
            try await ws.send(data)
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
            
            try await ws.send(data)
        } catch {
            // Log error but don't throw since we're already in an error handling context
            print("Failed to send error response: \(error)")
        }
    }
}