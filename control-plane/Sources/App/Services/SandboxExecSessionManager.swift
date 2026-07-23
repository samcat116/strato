import Foundation
import NIOConcurrencyHelpers
import StratoShared
import Vapor

/// Manages sandbox exec sessions (issue #423) between browser WebSockets and
/// agents, closely modeled on `ConsoleSessionManager`.
///
/// A session has two phases:
/// 1. **Pending** — minted by `POST /api/sandboxes/:id/exec`. Records who may
///    attach (the creating user), which sandbox/agent the exec targets, and
///    the exec request itself. Expires after `pendingSessionTTL` if never
///    attached; expired entries are swept lazily on access.
/// 2. **Attached** — the browser connected to
///    `/api/sandboxes/:id/exec/:sessionId/attach` and the
///    `SandboxExecStartMessage` went to the agent. Frames are relayed both
///    ways until exit/close.
///
/// Like the console path, messages go to the agent only over a *local*
/// WebSocket (`app.websocketManager`): exec requires the control-plane
/// replica that holds the agent's socket (single-replica limitation, accepted
/// and documented in `docs/architecture/sandboxes.md`).
///
/// This is NOT an actor to avoid event loop conflicts with NIO WebSockets.
final class SandboxExecSessionManager: @unchecked Sendable {
    /// How long a pending session may sit unattached before it expires.
    static let pendingSessionTTL: TimeInterval = 60

    private let lock = NIOLock()
    private let app: Application

    /// Sessions minted by the exec endpoint, awaiting a browser attach.
    private var pendingSessions: [String: PendingExecSession] = [:]

    /// Maps sessionId -> attached session info.
    private var sessions: [String: AttachedExecSession] = [:]

    /// Maps sessionId -> browser WebSocket.
    private var frontendConnections: [String: WebSocket] = [:]

    /// Maps sandboxId -> attached sessionIds (multiple execs may run at once).
    private var sandboxSessions: [String: Set<String>] = [:]

    /// A minted-but-not-yet-attached exec session: everything needed to build
    /// the `SandboxExecStartMessage` once the browser attaches.
    struct PendingExecSession: Sendable {
        let sessionId: String
        let sandboxId: String
        let agentKey: String
        let userId: String
        let command: [String]
        let env: [String: String]?
        let workingDir: String?
        let tty: Bool
        let rows: Int?
        let cols: Int?
        let createdAt: Date
        let expiresAt: Date
    }

    struct AttachedExecSession: Sendable {
        let sessionId: String
        let sandboxId: String
        let agentKey: String
        let userId: String
        let attachedAt: Date
    }

    init(app: Application) {
        self.app = app
    }

    // MARK: - Pending sessions

    /// Mint a pending session for a validated exec request. Returns the
    /// session (including `expiresAt`) for the 201 response.
    func createPendingSession(
        sandboxId: String,
        agentKey: String,
        userId: String,
        command: [String],
        env: [String: String]?,
        workingDir: String?,
        tty: Bool,
        rows: Int?,
        cols: Int?,
        now: Date = Date()
    ) -> PendingExecSession {
        let session = PendingExecSession(
            sessionId: UUID().uuidString,
            sandboxId: sandboxId,
            agentKey: agentKey,
            userId: userId,
            command: command,
            env: env,
            workingDir: workingDir,
            tty: tty,
            rows: rows,
            cols: cols,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.pendingSessionTTL)
        )

        lock.withLock {
            sweepExpiredPendingLocked(now: now)
            pendingSessions[session.sessionId] = session
        }

        app.logger.info(
            "Sandbox exec session created",
            metadata: [
                "sessionId": .string(session.sessionId),
                "sandboxId": .string(sandboxId),
                "agentKey": .string(agentKey),
            ])

        return session
    }

    /// Whether a pending (unexpired, unattached) session exists.
    func hasPendingSession(sessionId: String, now: Date = Date()) -> Bool {
        lock.withLock {
            sweepExpiredPendingLocked(now: now)
            return pendingSessions[sessionId] != nil
        }
    }

    // MARK: - Attach

    /// Consume a pending session and bind the browser WebSocket to it.
    ///
    /// Validates that the session exists, has not expired, targets `sandboxId`,
    /// and was minted for `userId`. On success the session moves from pending
    /// to attached and the returned value carries the exec request for
    /// `sendExecStart(for:)`.
    ///
    /// `websocket` is optional only so unit tests can exercise the lifecycle
    /// without a live socket; the controller always passes one.
    func attachSession(
        sessionId: String,
        sandboxId: String,
        userId: String,
        websocket: WebSocket?,
        now: Date = Date()
    ) throws -> PendingExecSession {
        let session = try lock.withLock { () -> PendingExecSession in
            if sessions[sessionId] != nil {
                throw SandboxExecSessionError.alreadyAttached(sessionId)
            }
            guard let pending = pendingSessions[sessionId] else {
                sweepExpiredPendingLocked(now: now)
                throw SandboxExecSessionError.sessionNotFound(sessionId)
            }
            guard pending.expiresAt > now else {
                pendingSessions.removeValue(forKey: sessionId)
                throw SandboxExecSessionError.sessionExpired(sessionId)
            }
            // Compare as UUIDs so casing differences cannot cause a false
            // mismatch between the minted id and the path parameter.
            let sandboxMatches = UUID(uuidString: pending.sandboxId) == UUID(uuidString: sandboxId)
            let userMatches = UUID(uuidString: pending.userId) == UUID(uuidString: userId)
            guard sandboxMatches, userMatches else {
                throw SandboxExecSessionError.sessionMismatch(sessionId)
            }

            pendingSessions.removeValue(forKey: sessionId)
            sessions[sessionId] = AttachedExecSession(
                sessionId: sessionId,
                sandboxId: pending.sandboxId,
                agentKey: pending.agentKey,
                userId: pending.userId,
                attachedAt: now
            )
            if let websocket {
                frontendConnections[sessionId] = websocket
            }
            sandboxSessions[pending.sandboxId, default: []].insert(sessionId)
            return pending
        }

        app.logger.info(
            "Sandbox exec session attached",
            metadata: [
                "sessionId": .string(sessionId),
                "sandboxId": .string(session.sandboxId),
                "agentKey": .string(session.agentKey),
            ])

        return session
    }

    // MARK: - Session lifecycle

    /// Remove an attached session (browser gone, exec ended, or start failed).
    func removeSession(sessionId: String) {
        lock.withLock {
            guard let session = sessions.removeValue(forKey: sessionId) else { return }
            frontendConnections.removeValue(forKey: sessionId)
            sandboxSessions[session.sandboxId]?.remove(sessionId)
            if sandboxSessions[session.sandboxId]?.isEmpty == true {
                sandboxSessions.removeValue(forKey: session.sandboxId)
            }
            app.logger.info(
                "Sandbox exec session removed",
                metadata: [
                    "sessionId": .string(sessionId),
                    "sandboxId": .string(session.sandboxId),
                ])
        }
    }

    /// Get attached session info.
    func getSession(sessionId: String) -> AttachedExecSession? {
        lock.withLock {
            sessions[sessionId]
        }
    }

    /// All attached sessions for a sandbox.
    func getSessionsForSandbox(sandboxId: String) -> [AttachedExecSession] {
        lock.withLock {
            guard let sessionIds = sandboxSessions[sandboxId] else { return [] }
            return sessionIds.compactMap { sessions[$0] }
        }
    }

    /// Tear down every session targeting `agentKey` because its socket is
    /// gone (crash, network drop, or graceful unregister). Each attached
    /// browser gets a terminal error frame and a close — instead of a
    /// silently frozen terminal — and pending sessions that could never
    /// start are dropped.
    func closeAllSessions(forAgent agentKey: String, reason: String) {
        let closed: [(sessionId: String, websocket: WebSocket?)] = lock.withLock {
            for (sessionId, pending) in pendingSessions where pending.agentKey == agentKey {
                pendingSessions.removeValue(forKey: sessionId)
            }
            var closed: [(String, WebSocket?)] = []
            for (sessionId, session) in sessions where session.agentKey == agentKey {
                sessions.removeValue(forKey: sessionId)
                let websocket = frontendConnections.removeValue(forKey: sessionId)
                sandboxSessions[session.sandboxId]?.remove(sessionId)
                if sandboxSessions[session.sandboxId]?.isEmpty == true {
                    sandboxSessions.removeValue(forKey: session.sandboxId)
                }
                closed.append((sessionId, websocket))
            }
            return closed
        }

        for (sessionId, websocket) in closed {
            app.logger.info(
                "Closed sandbox exec session: agent disconnected",
                metadata: [
                    "sessionId": .string(sessionId),
                    "agentKey": .string(agentKey),
                ])
            guard let websocket else { continue }
            websocket.send(Self.controlFrame(BrowserControlFrame(type: "error", message: reason)))
            _ = websocket.close(code: .normalClosure)
        }
    }

    // MARK: - Browser → agent

    /// Send the exec start message to the agent for a freshly attached session.
    func sendExecStart(for session: PendingExecSession) async throws {
        let message = SandboxExecStartMessage(
            sandboxId: session.sandboxId,
            sessionId: session.sessionId,
            command: session.command,
            env: session.env,
            workingDir: session.workingDir,
            tty: session.tty,
            rows: session.rows,
            cols: session.cols
        )
        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    /// Relay browser stdin bytes (and/or EOF) to the agent.
    func routeInput(sessionId: String, data: Data?, eof: Bool = false) async throws {
        guard let session = getSession(sessionId: sessionId) else {
            throw SandboxExecSessionError.sessionNotFound(sessionId)
        }
        let message: SandboxExecInputMessage
        if let data {
            message = SandboxExecInputMessage(sessionId: sessionId, rawData: data, eof: eof)
        } else {
            message = SandboxExecInputMessage(sessionId: sessionId, eof: eof)
        }
        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    /// Relay a browser resize request to the agent.
    func routeResize(sessionId: String, rows: Int, cols: Int) async throws {
        guard let session = getSession(sessionId: sessionId) else {
            throw SandboxExecSessionError.sessionNotFound(sessionId)
        }
        let message = SandboxExecResizeMessage(sessionId: sessionId, rows: rows, cols: cols)
        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    /// Tell the agent to tear down the exec session (browser disconnected).
    /// A no-op when the session is already gone (e.g. removed after exit).
    func sendExecClose(sessionId: String, reason: String? = nil) async throws {
        guard let session = getSession(sessionId: sessionId) else { return }
        let message = SandboxExecCloseMessage(sessionId: sessionId, reason: reason)
        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    // MARK: - Agent → browser

    /// The exec process spawned: tell the browser it may start sending input.
    func handleStarted(sessionId: String, fromAgentKey agentKey: String) {
        guard let ws = frontendConnection(sessionId: sessionId, fromAgentKey: agentKey, event: "started")
        else { return }
        ws.send(Self.controlFrame(BrowserControlFrame(type: "ready")))
    }

    /// Output bytes from the exec process, relayed to the browser as a binary
    /// frame (stdout and stderr interleaved).
    func handleOutput(sessionId: String, fromAgentKey agentKey: String, data: Data) {
        guard let ws = frontendConnection(sessionId: sessionId, fromAgentKey: agentKey, event: "output")
        else {
            // An entirely unknown session (control-plane restart, or the
            // session was already cleaned up) means the agent is streaming
            // into the void: tell it to tear down its orphaned bridge. Not
            // sent on an agent-name mismatch — a known session stays intact.
            // Replying to every such frame (rather than deduplicating) is
            // deliberate: the agent's exec close is idempotent and the burst
            // is bounded by the frames already in flight when the close
            // round-trips.
            let sessionExists = lock.withLock { sessions[sessionId] != nil }
            if !sessionExists {
                sendOrphanedBridgeClose(sessionId: sessionId, toAgentKey: agentKey)
            }
            return
        }
        ws.send([UInt8](data))
    }

    /// The exec process ended: report the exit code and close normally.
    func handleExit(sessionId: String, fromAgentKey agentKey: String, exitCode: Int) {
        guard let ws = frontendConnection(sessionId: sessionId, fromAgentKey: agentKey, event: "exit")
        else {
            removeSessionIfOwned(sessionId: sessionId, byAgentKey: agentKey)
            return
        }
        ws.send(Self.controlFrame(BrowserControlFrame(type: "exit", exitCode: exitCode)))
        _ = ws.close(code: .normalClosure)
        removeSession(sessionId: sessionId)
    }

    /// The exec session ended without an exit code (spawn failure, vsock
    /// died, sandbox stopped): report the error and close.
    func handleClosed(sessionId: String, fromAgentKey agentKey: String, reason: String?) {
        guard let ws = frontendConnection(sessionId: sessionId, fromAgentKey: agentKey, event: "closed")
        else {
            removeSessionIfOwned(sessionId: sessionId, byAgentKey: agentKey)
            return
        }
        let message = reason ?? "exec session closed by agent"
        ws.send(Self.controlFrame(BrowserControlFrame(type: "error", message: message)))
        _ = ws.close(code: .normalClosure)
        removeSession(sessionId: sessionId)
    }

    // MARK: - Private helpers

    /// Resolve the browser socket for an agent-reported event, enforcing that
    /// the reporting agent is the one the session was created against —
    /// otherwise a compromised agent could inject frames into another
    /// tenant's exec session by guessing session ids.
    private func frontendConnection(
        sessionId: String, fromAgentKey agentKey: String, event: String
    ) -> WebSocket? {
        let (session, websocket) = lock.withLock {
            (sessions[sessionId], frontendConnections[sessionId])
        }
        guard let session else {
            app.logger.debug(
                "Sandbox exec \(event) for unknown session",
                metadata: ["sessionId": .string(sessionId), "agentKey": .string(agentKey)])
            return nil
        }
        guard session.agentKey == agentKey else {
            app.logger.warning(
                "Dropping sandbox exec \(event) from an agent that does not own the session",
                metadata: [
                    "sessionId": .string(sessionId),
                    "agentKey": .string(agentKey),
                    "sessionAgentName": .string(session.agentKey),
                ])
            return nil
        }
        return websocket
    }

    /// Best-effort `SandboxExecCloseMessage` to an agent that reported output
    /// for a session this control plane does not know, so the agent tears the
    /// orphaned bridge down instead of streaming forever. Errors are swallowed:
    /// this is advisory, and the agent's own sandbox-stop path also reaps
    /// bridges.
    private func sendOrphanedBridgeClose(sessionId: String, toAgentKey agentKey: String) {
        guard let websocket = app.websocketManager.getConnection(agentKey: agentKey) else { return }
        let message = SandboxExecCloseMessage(sessionId: sessionId, reason: "unknown exec session")
        guard
            let envelope = try? MessageEnvelope(message: message),
            let data = try? WireProtocol.makeEncoder().encode(envelope)
        else { return }
        websocket.send(data)
        app.logger.debug(
            "Sent exec close for unknown session back to reporting agent",
            metadata: ["sessionId": .string(sessionId), "agentKey": .string(agentKey)])
    }

    /// Remove a session on a terminal agent event when no browser socket is
    /// bound (unit tests, or the browser already went away), still requiring
    /// the reporting agent to own the session.
    private func removeSessionIfOwned(sessionId: String, byAgentKey agentKey: String) {
        let owned = lock.withLock {
            sessions[sessionId]?.agentKey == agentKey
        }
        if owned {
            removeSession(sessionId: sessionId)
        }
    }

    /// JSON control frame sent to the browser as a text message.
    private struct BrowserControlFrame: Encodable {
        let type: String
        var exitCode: Int?
        var message: String?
    }

    private static func controlFrame(_ frame: BrowserControlFrame) -> String {
        guard let data = try? JSONEncoder().encode(frame),
            let text = String(data: data, encoding: .utf8)
        else {
            // Encodable String/Int fields cannot fail to encode in practice;
            // fall back to a bare error frame just in case.
            return #"{"type":"error","message":"internal encoding error"}"#
        }
        return text
    }

    /// Must be called while holding `lock`.
    private func sweepExpiredPendingLocked(now: Date) {
        for (sessionId, pending) in pendingSessions where pending.expiresAt <= now {
            pendingSessions.removeValue(forKey: sessionId)
            app.logger.debug(
                "Expired unattached sandbox exec session",
                metadata: ["sessionId": .string(sessionId), "sandboxId": .string(pending.sandboxId)])
        }
    }

    /// Console parity: agent messages go out over this replica's socket only.
    /// The exec endpoint already refused the request when the agent's socket
    /// lives on another replica.
    private func sendMessageToAgent<T: WebSocketMessage>(_ message: T, agentKey: String) async throws {
        guard let websocket = app.websocketManager.getConnection(agentKey: agentKey) else {
            app.logger.error(
                "Agent WebSocket not found for sandbox exec message",
                metadata: ["agentKey": .string(agentKey)])
            throw SandboxExecSessionError.agentNotConnected(agentKey)
        }

        let envelope = try MessageEnvelope(message: message)
        let data = try WireProtocol.makeEncoder().encode(envelope)
        websocket.send(data)
    }
}

// MARK: - Errors

enum SandboxExecSessionError: Error, LocalizedError, Equatable {
    case sessionNotFound(String)
    case sessionExpired(String)
    case sessionMismatch(String)
    case alreadyAttached(String)
    case agentNotConnected(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let sessionId):
            return "Exec session not found: \(sessionId)"
        case .sessionExpired(let sessionId):
            return "Exec session expired: \(sessionId)"
        case .sessionMismatch(let sessionId):
            return "Exec session does not match this sandbox or user: \(sessionId)"
        case .alreadyAttached(let sessionId):
            return "Exec session is already attached: \(sessionId)"
        case .agentNotConnected(let agentKey):
            return "Agent not connected: \(agentKey)"
        }
    }
}

// MARK: - Application Extension

extension Application {
    private struct SandboxExecSessionManagerKey: StorageKey, LockKey {
        typealias Value = SandboxExecSessionManager
    }

    var sandboxExecSessionManager: SandboxExecSessionManager {
        get {
            lazyService(SandboxExecSessionManagerKey.self) { SandboxExecSessionManager(app: self) }
        }
        set {
            setStorageValue(SandboxExecSessionManagerKey.self, to: newValue)
        }
    }
}

extension Request {
    var sandboxExecSessionManager: SandboxExecSessionManager {
        return application.sandboxExecSessionManager
    }
}
