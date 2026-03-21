import Foundation
import Vapor
import StratoShared
import NIOConcurrencyHelpers

/// Manages console sessions between frontend WebSockets and agents
/// This is NOT an actor to avoid event loop conflicts with NIO WebSockets
final class ConsoleSessionManager: @unchecked Sendable {
    private let lock = NIOLock()
    private let app: Application

    /// Maps sessionId -> frontend WebSocket
    private var frontendConnections: [String: WebSocket] = [:]

    /// Maps sessionId -> ConsoleSessionInfo
    private var sessions: [String: ConsoleSessionInfo] = [:]

    /// Maps vmId -> Set of sessionIds (multiple users can view same console)
    private var vmSessions: [String: Set<String>] = [:]

    struct ConsoleSessionInfo: Sendable {
        let sessionId: String
        let vmId: String
        let agentName: String
        let userId: String?
        let createdAt: Date
    }

    init(app: Application) {
        self.app = app
    }

    // MARK: - Session Management

    /// Register a new console session
    func createSession(
        sessionId: String,
        vmId: String,
        agentName: String,
        userId: String?,
        websocket: WebSocket
    ) {
        lock.withLock {
            let sessionInfo = ConsoleSessionInfo(
                sessionId: sessionId,
                vmId: vmId,
                agentName: agentName,
                userId: userId,
                createdAt: Date()
            )

            sessions[sessionId] = sessionInfo
            frontendConnections[sessionId] = websocket

            if vmSessions[vmId] == nil {
                vmSessions[vmId] = []
            }
            vmSessions[vmId]?.insert(sessionId)
        }

        app.logger.info("Console session created", metadata: [
            "sessionId": .string(sessionId),
            "vmId": .string(vmId),
            "agentName": .string(agentName)
        ])
    }

    /// Remove a console session
    func removeSession(sessionId: String) {
        lock.withLock {
            if let sessionInfo = sessions.removeValue(forKey: sessionId) {
                frontendConnections.removeValue(forKey: sessionId)
                vmSessions[sessionInfo.vmId]?.remove(sessionId)

                if vmSessions[sessionInfo.vmId]?.isEmpty == true {
                    vmSessions.removeValue(forKey: sessionInfo.vmId)
                }

                app.logger.info("Console session removed", metadata: [
                    "sessionId": .string(sessionId),
                    "vmId": .string(sessionInfo.vmId)
                ])
            }
        }
    }

    /// Get session info
    func getSession(sessionId: String) -> ConsoleSessionInfo? {
        lock.withLock {
            sessions[sessionId]
        }
    }

    /// Get all sessions for a VM
    func getSessionsForVM(vmId: String) -> [ConsoleSessionInfo] {
        lock.withLock {
            guard let sessionIds = vmSessions[vmId] else { return [] }
            return sessionIds.compactMap { sessions[$0] }
        }
    }

    /// Check if session exists
    func hasSession(sessionId: String) -> Bool {
        lock.withLock {
            sessions[sessionId] != nil
        }
    }

    // MARK: - Data Routing

    /// Route console data from agent to frontend(s)
    func routeToFrontend(vmId: String, sessionId: String, data: Data) {
        let websocket: WebSocket? = lock.withLock {
            frontendConnections[sessionId]
        }

        guard let ws = websocket else {
            app.logger.warning("No frontend connection for session", metadata: [
                "sessionId": .string(sessionId),
                "vmId": .string(vmId)
            ])
            return
        }

        // Send binary data to frontend
        ws.send([UInt8](data))
    }

    /// Notify the frontend that the console is ready for input
    func notifyFrontendReady(sessionId: String) {
        let websocket: WebSocket? = lock.withLock {
            frontendConnections[sessionId]
        }

        guard let ws = websocket else {
            app.logger.warning("No frontend connection for session to notify ready", metadata: [
                "sessionId": .string(sessionId)
            ])
            return
        }

        app.logger.info("Notifying frontend that console is ready", metadata: [
            "sessionId": .string(sessionId)
        ])

        // Send a "ready" text message to the frontend
        ws.send("ready")
    }

    /// Route user input from frontend to agent
    func routeToAgent(sessionId: String, data: Data) async throws {
        let sessionInfo: ConsoleSessionInfo? = lock.withLock {
            sessions[sessionId]
        }

        guard let session = sessionInfo else {
            throw ConsoleSessionError.sessionNotFound(sessionId)
        }

        // Send console data to agent via AgentService
        let message = ConsoleDataMessage(
            vmId: session.vmId,
            sessionId: sessionId,
            rawData: data
        )

        try await sendMessageToAgent(message, agentName: session.agentName)
    }

    /// Send console connect message to agent
    func sendConsoleConnect(sessionId: String, vmId: String, agentName: String) async throws {
        app.logger.info("Sending console connect to agent", metadata: [
            "sessionId": .string(sessionId),
            "vmId": .string(vmId),
            "agentName": .string(agentName)
        ])

        let message = ConsoleConnectMessage(
            vmId: vmId,
            sessionId: sessionId
        )

        try await sendMessageToAgent(message, agentName: agentName)

        app.logger.info("Console connect message sent successfully", metadata: [
            "sessionId": .string(sessionId),
            "vmId": .string(vmId)
        ])
    }

    /// Send console disconnect message to agent
    func sendConsoleDisconnect(sessionId: String) async throws {
        let sessionInfo: ConsoleSessionInfo? = lock.withLock {
            sessions[sessionId]
        }

        guard let session = sessionInfo else {
            // Session already removed, nothing to do
            return
        }

        let message = ConsoleDisconnectMessage(
            vmId: session.vmId,
            sessionId: sessionId
        )

        try await sendMessageToAgent(message, agentName: session.agentName)
    }

    // MARK: - Private Helpers

    private func sendMessageToAgent<T: WebSocketMessage>(_ message: T, agentName: String) async throws {
        app.logger.debug("Looking up WebSocket for agent", metadata: ["agentName": .string(agentName)])

        guard let websocket = app.websocketManager.getConnection(agentName: agentName) else {
            app.logger.error("Agent WebSocket not found", metadata: ["agentName": .string(agentName)])
            throw ConsoleSessionError.agentNotConnected(agentName)
        }

        let envelope = try MessageEnvelope(message: message)
        let data = try JSONEncoder().encode(envelope)

        app.logger.debug("Sending message to agent", metadata: [
            "agentName": .string(agentName),
            "messageType": .string(message.type.rawValue),
            "dataSize": .stringConvertible(data.count)
        ])

        websocket.send(data)
    }
}

// MARK: - Errors

enum ConsoleSessionError: Error, LocalizedError {
    case sessionNotFound(String)
    case agentNotConnected(String)
    case vmNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let sessionId):
            return "Console session not found: \(sessionId)"
        case .agentNotConnected(let agentName):
            return "Agent not connected: \(agentName)"
        case .vmNotRunning(let vmId):
            return "VM is not running: \(vmId)"
        }
    }
}

// MARK: - Application Extension

extension Application {
    private struct ConsoleSessionManagerKey: StorageKey {
        typealias Value = ConsoleSessionManager
    }

    var consoleSessionManager: ConsoleSessionManager {
        get {
            if let existing = storage[ConsoleSessionManagerKey.self] {
                return existing
            }
            let new = ConsoleSessionManager(app: self)
            storage[ConsoleSessionManagerKey.self] = new
            return new
        }
        set {
            storage[ConsoleSessionManagerKey.self] = newValue
        }
    }
}

extension Request {
    var consoleSessionManager: ConsoleSessionManager {
        return application.consoleSessionManager
    }
}
