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
        websocket: WebSocket?
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
            if let websocket {
                frontendConnections[sessionId] = websocket
            }

            if vmSessions[vmId] == nil {
                vmSessions[vmId] = []
            }
            vmSessions[vmId]?.insert(sessionId)
        }

        app.logger.info(
            "Console session created",
            metadata: [
                "sessionId": .string(sessionId),
                "vmId": .string(vmId),
                "agentName": .string(agentName),
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

                app.logger.info(
                    "Console session removed",
                    metadata: [
                        "sessionId": .string(sessionId),
                        "vmId": .string(sessionInfo.vmId),
                    ])
            }
        }
    }

    /// Agent-initiated session teardown (the agent reported its console
    /// disconnected). Verify the reporting agent owns the session before
    /// removing it, so a compromised agent cannot tear down another session by
    /// guessing its (random) id. The frontend-initiated `removeSession` needs
    /// no such check — a browser can only ever close its own session.
    func removeSession(sessionId: String, fromAgentNamed agentName: String) {
        let owns = lock.withLock { () -> Bool in
            guard let session = sessions[sessionId] else { return false }
            return session.agentName == agentName
        }
        guard owns else {
            app.logger.warning(
                "Dropping console disconnect from an agent that does not own the session",
                metadata: [
                    "sessionId": .string(sessionId),
                    "agentName": .string(agentName),
                ])
            return
        }
        removeSession(sessionId: sessionId)
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

    /// Tear down every console session targeting `agentName` because its
    /// socket is gone (crash, network drop, or graceful unregister). Each
    /// attached browser gets a terminal error frame and a close — instead of
    /// a silently frozen terminal whose keystrokes go nowhere.
    func closeAllSessions(forAgent agentName: String, reason: String) {
        let closed: [(sessionId: String, websocket: WebSocket?)] = lock.withLock {
            var closed: [(String, WebSocket?)] = []
            for (sessionId, session) in sessions where session.agentName == agentName {
                sessions.removeValue(forKey: sessionId)
                let websocket = frontendConnections.removeValue(forKey: sessionId)
                vmSessions[session.vmId]?.remove(sessionId)
                if vmSessions[session.vmId]?.isEmpty == true {
                    vmSessions.removeValue(forKey: session.vmId)
                }
                closed.append((sessionId, websocket))
            }
            return closed
        }

        for (sessionId, websocket) in closed {
            app.logger.info(
                "Closed console session: agent disconnected",
                metadata: [
                    "sessionId": .string(sessionId),
                    "agentName": .string(agentName),
                ])
            guard let websocket else { continue }
            websocket.send("error: \(reason)")
            _ = websocket.close(code: .normalClosure)
        }
    }

    // MARK: - Data Routing

    /// Resolve the browser socket for an agent-reported console event, but only
    /// when the reporting agent owns the session. Without this an agent that
    /// learned another session's (random) id could inject console bytes into,
    /// or signal readiness on, a session it does not host. Mirrors the
    /// ownership gate `SandboxExecSessionManager.frontendConnection` enforces.
    private func frontendConnection(
        sessionId: String, fromAgentNamed agentName: String, event: String
    ) -> WebSocket? {
        let (session, websocket) = lock.withLock {
            (sessions[sessionId], frontendConnections[sessionId])
        }
        guard let session else {
            app.logger.debug(
                "Console \(event) for unknown session",
                metadata: ["sessionId": .string(sessionId), "agentName": .string(agentName)])
            return nil
        }
        guard session.agentName == agentName else {
            app.logger.warning(
                "Dropping console \(event) from an agent that does not own the session",
                metadata: [
                    "sessionId": .string(sessionId),
                    "agentName": .string(agentName),
                    "sessionAgentName": .string(session.agentName),
                ])
            return nil
        }
        return websocket
    }

    /// Route console data from agent to frontend(s)
    func routeToFrontend(vmId: String, sessionId: String, data: Data, fromAgentNamed agentName: String) {
        guard let ws = frontendConnection(sessionId: sessionId, fromAgentNamed: agentName, event: "data")
        else {
            return
        }

        // Send binary data to frontend
        ws.send([UInt8](data))
    }

    /// Notify the frontend that the console is ready for input
    func notifyFrontendReady(sessionId: String, fromAgentNamed agentName: String) {
        guard let ws = frontendConnection(sessionId: sessionId, fromAgentNamed: agentName, event: "ready")
        else {
            return
        }

        app.logger.info(
            "Notifying frontend that console is ready",
            metadata: [
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
        app.logger.info(
            "Sending console connect to agent",
            metadata: [
                "sessionId": .string(sessionId),
                "vmId": .string(vmId),
                "agentName": .string(agentName),
            ])

        let message = ConsoleConnectMessage(
            vmId: vmId,
            sessionId: sessionId
        )

        try await sendMessageToAgent(message, agentName: agentName)

        app.logger.info(
            "Console connect message sent successfully",
            metadata: [
                "sessionId": .string(sessionId),
                "vmId": .string(vmId),
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
        let data = try WireProtocol.makeEncoder().encode(envelope)

        app.logger.debug(
            "Sending message to agent",
            metadata: [
                "agentName": .string(agentName),
                "messageType": .string(message.type.rawValue),
                "dataSize": .stringConvertible(data.count),
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
    private struct ConsoleSessionManagerKey: StorageKey, LockKey {
        typealias Value = ConsoleSessionManager
    }

    var consoleSessionManager: ConsoleSessionManager {
        get {
            lazyService(ConsoleSessionManagerKey.self) { ConsoleSessionManager(app: self) }
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
