import Foundation
import Vapor
import StratoShared
import NIOConcurrencyHelpers

/// Manages console sessions between frontend WebSockets and agents
/// This is NOT an actor to avoid event loop conflicts with NIO WebSockets
///
/// Safety: `app` is immutable and every access to the four mutable maps is
/// inside `lock`. WebSockets may leave the map, but this manager invokes them
/// only through their event-loop-safe APIs.
final class ConsoleSessionManager: @unchecked Sendable {
    private let lock = NIOLock()
    private let app: Application

    /// Maps sessionId -> frontend WebSocket
    private var frontendConnections: [String: WebSocket] = [:]

    /// Maps sessionId -> ConsoleSessionInfo
    private var sessions: [String: ConsoleSessionInfo] = [:]

    /// Maps vmId -> Set of sessionIds (multiple users can view same console)
    private var vmSessions: [String: Set<String>] = [:]

    /// Graphics sessions minted by `POST .../console/vnc` but not yet attached
    /// (issue #566). The serial console upgrades in one step and never lands
    /// here.
    private var pendingSessions: [String: PendingConsoleSession] = [:]

    /// How long a minted graphics session may go unattached. Long enough for a
    /// browser to open a socket, short enough that an abandoned mint cannot be
    /// replayed later.
    static let pendingSessionTTL: TimeInterval = 60

    struct ConsoleSessionInfo: Sendable {
        let sessionId: String
        let vmId: String
        let agentKey: String
        let userId: String?
        /// Which of the VM's consoles this session carries. The agent needs it
        /// to pick a socket; the control plane keeps it for logs and so a
        /// graphics session is never confused with a serial one.
        let stream: ConsoleStream
        let createdAt: Date
        /// Whether the browser has been told the console is live.
        ///
        /// This is what decides whether a teardown may still explain itself: a
        /// failure *before* ready arrives on a socket nobody has claimed, so
        /// the reason can be written to it. After ready the socket belongs to
        /// the console's own protocol — noVNC in the graphics case — and a text
        /// frame injected there would be read as part of the byte stream.
        var readyNotified: Bool = false
    }

    /// A minted-but-not-yet-attached graphics session.
    struct PendingConsoleSession: Sendable {
        let sessionId: String
        let vmId: String
        let agentKey: String
        let userId: String
        let expiresAt: Date
    }

    init(app: Application) {
        self.app = app
    }

    // MARK: - Session Management

    /// Register a new console session
    func createSession(
        sessionId: String,
        vmId: String,
        agentKey: String,
        userId: String?,
        stream: ConsoleStream = .serial,
        websocket: WebSocket?
    ) {
        lock.withLock {
            let sessionInfo = ConsoleSessionInfo(
                sessionId: sessionId,
                vmId: vmId,
                agentKey: agentKey,
                userId: userId,
                stream: stream,
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
                "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                "strato.vm.id": .string(vmId),
                "strato.agent.identity": .string(agentKey),
            ])
    }

    // MARK: - Pending graphics sessions (issue #566)

    /// Mint a graphics session for a request that has already passed every
    /// check. Returns it (including `expiresAt`) for the 201 response.
    ///
    /// The graphics console is minted over HTTP and attached separately, unlike
    /// the serial console which upgrades in one step. The reason is error
    /// reporting: a display can be unavailable for several distinct reasons —
    /// the VM was created headless, its agent is too old, its socket lives on
    /// another replica — and each deserves a status code the client can act on.
    /// Reported instead as a text frame on an already-upgraded socket, they
    /// would all reach noVNC as an unexplained disconnect.
    func createPendingVNCSession(
        vmId: String,
        agentKey: String,
        userId: String,
        now: Date = Date()
    ) -> PendingConsoleSession {
        let session = PendingConsoleSession(
            sessionId: UUID().uuidString,
            vmId: vmId,
            agentKey: agentKey,
            userId: userId,
            expiresAt: now.addingTimeInterval(Self.pendingSessionTTL)
        )

        lock.withLock {
            sweepExpiredPendingLocked(now: now)
            pendingSessions[session.sessionId] = session
        }

        app.logger.info(
            "Graphics console session minted",
            metadata: [
                "strato.session.kind": .string("console"), "strato.session.id": .string(session.sessionId),
                "strato.vm.id": .string(vmId),
                "strato.agent.identity": .string(agentKey),
            ])
        return session
    }

    /// Consume a pending graphics session and bind the browser WebSocket to it.
    ///
    /// Single-use, and validated against the VM and the user it was minted for:
    /// the session id is the only credential on the attach URL, so a leaked one
    /// must not let a different user — or a different VM's tab — attach.
    ///
    /// `websocket` is optional only so unit tests can drive the lifecycle
    /// without a live socket; the controller always passes one.
    @discardableResult
    func attachVNCSession(
        sessionId: String,
        vmId: String,
        userId: String,
        websocket: WebSocket?,
        now: Date = Date()
    ) throws -> PendingConsoleSession {
        let session = try lock.withLock { () -> PendingConsoleSession in
            if sessions[sessionId] != nil {
                throw ConsoleSessionError.alreadyAttached(sessionId)
            }
            guard let pending = pendingSessions[sessionId] else {
                sweepExpiredPendingLocked(now: now)
                throw ConsoleSessionError.sessionNotFound(sessionId)
            }
            guard pending.expiresAt > now else {
                pendingSessions.removeValue(forKey: sessionId)
                throw ConsoleSessionError.sessionExpired(sessionId)
            }
            // Compare as UUIDs so casing differences between the minted id and
            // the path parameter cannot cause a false mismatch.
            let vmMatches = UUID(uuidString: pending.vmId) == UUID(uuidString: vmId)
            let userMatches = UUID(uuidString: pending.userId) == UUID(uuidString: userId)
            guard vmMatches, userMatches else {
                throw ConsoleSessionError.sessionMismatch(sessionId)
            }

            pendingSessions.removeValue(forKey: sessionId)
            sessions[sessionId] = ConsoleSessionInfo(
                sessionId: sessionId,
                vmId: pending.vmId,
                agentKey: pending.agentKey,
                userId: pending.userId,
                stream: .vnc,
                createdAt: now
            )
            if let websocket {
                frontendConnections[sessionId] = websocket
            }
            vmSessions[pending.vmId, default: []].insert(sessionId)
            return pending
        }

        app.logger.info(
            "Graphics console session attached",
            metadata: [
                "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                "strato.vm.id": .string(session.vmId),
                "strato.agent.identity": .string(session.agentKey),
            ])
        return session
    }

    /// Drop pending sessions past their TTL. Lazy rather than timer-driven:
    /// mints are rare, so sweeping on each one is cheaper than a background
    /// task and has no lifecycle of its own. Caller holds the lock.
    private func sweepExpiredPendingLocked(now: Date) {
        pendingSessions = pendingSessions.filter { $0.value.expiresAt > now }
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
                        "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                        "strato.vm.id": .string(sessionInfo.vmId),
                    ])
            }
        }
    }

    /// Agent-initiated session teardown, closing the browser socket with the
    /// agent's reason.
    ///
    /// Without this a console the agent could not open leaves the browser
    /// waiting forever: the agent's failure reply is an `ErrorMessage`
    /// correlated by `requestId`, and console connects are sent fire-and-forget
    /// with no pending request to match it against, so it is dropped. The
    /// disconnect notification is a stream event keyed by `sessionId`, which
    /// does route — so it is what carries the bad news to the browser.
    ///
    /// The reason must travel as a **data** frame, not on the close frame:
    /// WebSocketKit's `close(code:)` writes a two-byte status code and nothing
    /// else, so a browser's `event.reason` is always empty and noVNC's
    /// `disconnect` event carries nothing either. Sending it as data is the
    /// only way the text reaches anyone.
    ///
    /// It is sent only *before* `ready`, which is exactly when these failures
    /// happen. After ready the socket belongs to the console's own protocol —
    /// injecting a text frame into a live RFB stream would be worse than
    /// staying quiet — and a post-ready teardown is an ordinary disconnect the
    /// UI already reports.
    func closeSession(sessionId: String, fromAgentKey agentKey: String, reason: String?) {
        let target = lock.withLock { () -> (websocket: WebSocket, session: ConsoleSessionInfo)? in
            guard let session = sessions[sessionId], session.agentKey == agentKey,
                let websocket = frontendConnections[sessionId]
            else { return nil }
            return (websocket, session)
        }

        // A browser-initiated teardown gets here too, with the socket already
        // closing; closing it again is a no-op.
        if let target {
            if !target.session.readyNotified, let reason {
                // Same shapes the two frontends already parse: JSON control
                // frames for the graphics console, an `error: ` prefix for the
                // serial one.
                target.websocket.send(
                    target.session.stream == .vnc ? Self.errorControlFrame(reason) : "error: \(reason)")
            }
            _ = target.websocket.close(code: .normalClosure)
        }
        removeSession(sessionId: sessionId, fromAgentKey: agentKey)
        if let reason {
            app.logger.debug(
                "Console session closed by agent",
                metadata: [
                    "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                    "reason": .string(reason),
                ])
        }
    }

    /// Agent-initiated session teardown (the agent reported its console
    /// disconnected). Verify the reporting agent owns the session before
    /// removing it, so a compromised agent cannot tear down another session by
    /// guessing its (random) id. The frontend-initiated `removeSession` needs
    /// no such check — a browser can only ever close its own session.
    func removeSession(sessionId: String, fromAgentKey agentKey: String) {
        let owns = lock.withLock { () -> Bool in
            guard let session = sessions[sessionId] else { return false }
            return session.agentKey == agentKey
        }
        guard owns else {
            app.logger.warning(
                "Dropping console disconnect from an agent that does not own the session",
                metadata: [
                    "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
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

    /// Tear down every console session targeting `agentKey` because its
    /// socket is gone (crash, network drop, or graceful unregister). Each
    /// attached browser gets a terminal error frame and a close — instead of
    /// a silently frozen terminal whose keystrokes go nowhere.
    func closeAllSessions(forAgent agentKey: String, reason: String) {
        let closed: [(sessionId: String, websocket: WebSocket?)] = lock.withLock {
            var closed: [(String, WebSocket?)] = []
            // Minted-but-unattached graphics sessions go too: the socket they
            // were minted against is gone, so attaching one later could only
            // fail — and it would fail after the upgrade, where saying why is
            // hardest.
            pendingSessions = pendingSessions.filter { $0.value.agentKey != agentKey }
            for (sessionId, session) in sessions where session.agentKey == agentKey {
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
                    "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
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
    /// ownership gate `GuestExecSessionManager.frontendConnection` enforces.
    private func frontendConnection(
        sessionId: String, fromAgentKey agentKey: String, event: String
    ) -> WebSocket? {
        let (session, websocket) = lock.withLock {
            (sessions[sessionId], frontendConnections[sessionId])
        }
        guard let session else {
            app.logger.debug(
                "Console \(event) for unknown session",
                metadata: [
                    "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
                ])
            return nil
        }
        guard session.agentKey == agentKey else {
            app.logger.warning(
                "Dropping console \(event) from an agent that does not own the session",
                metadata: [
                    "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
                    "strato.agent.session.identity": .string(session.agentKey),
                ])
            return nil
        }
        return websocket
    }

    /// Route console data from agent to frontend(s)
    func routeToFrontend(vmId: String, sessionId: String, data: Data, fromAgentKey agentKey: String) {
        guard let ws = frontendConnection(sessionId: sessionId, fromAgentKey: agentKey, event: "data")
        else {
            return
        }

        // Send binary data to frontend
        ws.send([UInt8](data))
    }

    /// Notify the frontend that the console is ready for input
    func notifyFrontendReady(sessionId: String, fromAgentKey agentKey: String) {
        guard let ws = frontendConnection(sessionId: sessionId, fromAgentKey: agentKey, event: "ready")
        else {
            return
        }

        app.logger.info(
            "Notifying frontend that console is ready",
            metadata: [
                "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
            ])

        // The serial console's frontend parses the bare string `ready`; the
        // graphics console uses the JSON control frames the exec path
        // established, because once noVNC owns the socket it treats every text
        // frame as its own and an unstructured one is unparseable.
        let stream = lock.withLock { () -> ConsoleStream in
            sessions[sessionId]?.readyNotified = true
            return sessions[sessionId]?.stream ?? .serial
        }
        ws.send(stream == .vnc ? Self.readyControlFrame : "ready")
    }

    /// The last control frame the graphics console sends. Everything after it
    /// is RFB: noVNC is attached to the socket by then and would read a later
    /// text frame as part of its own stream, so a post-ready failure closes the
    /// socket without explanation rather than corrupting it.
    static let readyControlFrame = #"{"type":"ready"}"#

    private struct ErrorControlFrame: Encodable {
        let type = "error"
        let message: String
    }

    /// A pre-ready failure, in the same JSON shape.
    ///
    /// Encoded rather than interpolated: these messages now carry text the
    /// *agent* wrote, and hand-rolled escaping that covers `\` and `"` still
    /// emits invalid JSON for a reason containing a newline — which the
    /// frontend would silently drop in its parse `catch`, turning an
    /// explanatory failure back into a blank one.
    static func errorControlFrame(_ message: String) -> String {
        guard let data = try? JSONEncoder().encode(ErrorControlFrame(message: message)),
            let json = String(data: data, encoding: .utf8)
        else {
            return #"{"type":"error","message":"Console unavailable"}"#
        }
        return json
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

        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    /// Send console connect message to agent
    func sendConsoleConnect(
        sessionId: String, vmId: String, agentKey: String, stream: ConsoleStream = .serial
    ) async throws {
        app.logger.info(
            "Sending console connect to agent",
            metadata: [
                "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                "strato.vm.id": .string(vmId),
                "strato.agent.identity": .string(agentKey),
                "stream": .string(stream.rawValue),
            ])

        // Omit the selector for a serial connect, so the frame a pre-v23 agent
        // receives is byte-identical to the one it already handles.
        let message = ConsoleConnectMessage(
            vmId: vmId,
            sessionId: sessionId,
            stream: stream == .serial ? nil : stream
        )

        try await sendMessageToAgent(message, agentKey: agentKey)

        app.logger.info(
            "Console connect message sent successfully",
            metadata: [
                "strato.session.kind": .string("console"), "strato.session.id": .string(sessionId),
                "strato.vm.id": .string(vmId),
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

        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    // MARK: - Private Helpers

    private func sendMessageToAgent<T: WebSocketMessage>(_ message: T, agentKey: String) async throws {
        app.logger.debug("Looking up WebSocket for agent", metadata: ["strato.agent.identity": .string(agentKey)])

        guard let websocket = app.websocketManager.getConnection(agentKey: agentKey) else {
            app.logger.error("Agent WebSocket not found", metadata: ["strato.agent.identity": .string(agentKey)])
            throw ConsoleSessionError.agentNotConnected(agentKey)
        }

        let data = try WireProtocol.encodeEnvelope(message)

        app.logger.debug(
            "Sending message to agent",
            metadata: [
                "strato.agent.identity": .string(agentKey),
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
    case sessionExpired(String)
    case sessionMismatch(String)
    case alreadyAttached(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let sessionId):
            return "Console session not found: \(sessionId)"
        case .agentNotConnected(let agentKey):
            return "Agent not connected: \(agentKey)"
        case .vmNotRunning(let vmId):
            return "VM is not running: \(vmId)"
        case .sessionExpired(let sessionId):
            return "Console session expired: \(sessionId)"
        case .sessionMismatch(let sessionId):
            return "Console session does not belong to this VM and user: \(sessionId)"
        case .alreadyAttached(let sessionId):
            return "Console session is already attached: \(sessionId)"
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
            setStorageValue(ConsoleSessionManagerKey.self, to: newValue)
        }
    }
}

extension Request {
    var consoleSessionManager: ConsoleSessionManager {
        return application.consoleSessionManager
    }
}
