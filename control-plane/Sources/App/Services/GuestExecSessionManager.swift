import Foundation
import NIOConcurrencyHelpers
import StratoShared
import Vapor

/// Manages guest exec sessions between browser WebSockets and agents, closely
/// modeled on `ConsoleSessionManager`.
///
/// A session has two phases:
/// 1. **Pending** — minted by `POST /api/{vms|sandboxes}/:id/exec`. Records who
///    may attach (the creating user), which resource/agent the exec targets,
///    and the exec request itself. Expires after `pendingSessionTTL` if never
///    attached; expired entries are swept lazily on access.
/// 2. **Attached** — the browser connected to the resource's exec attach route
///    and the `GuestExecStartMessage` went to the agent. Frames are relayed both
///    ways until exit/close.
///
/// Like the console path, messages go to the agent only over a *local*
/// WebSocket (`app.websocketManager`): exec requires the control-plane
/// replica that holds the agent's socket (single-replica limitation, accepted
/// and documented in `docs/architecture/multi-replica.md`).
///
/// This is NOT an actor to avoid event loop conflicts with NIO WebSockets.
/// Safety: `app` is immutable and every access to pending, attached, browser,
/// and resource-index state is inside `lock`. Returned session values are
/// immutable snapshots rather than references to that state.
final class GuestExecSessionManager: @unchecked Sendable {
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

    /// Maps a kind-aware resource key to its attached session ids.
    private var resourceSessions: [ResourceKey: Set<String>] = [:]

    private struct ResourceKey: Hashable {
        let kind: GuestResourceKind
        let id: String

        init(kind: GuestResourceKind, id: String) {
            self.kind = kind
            self.id = UUID(uuidString: id)?.uuidString ?? id
        }
    }

    /// A minted-but-not-yet-attached exec session: everything needed to build
    /// the `GuestExecStartMessage` once the browser attaches.
    struct PendingExecSession: Sendable {
        let sessionId: String
        let resourceKind: GuestResourceKind
        let resourceId: String
        let agentKey: String
        let userId: String
        let command: [String]
        let env: [String: String]?
        let workingDir: String?
        let tty: Bool
        let rows: Int?
        let cols: Int?
        let outputMode: GuestExecOutputMode
        /// Immutable VM-only attribution retained until every asynchronous
        /// lifecycle fact has been emitted. Sandbox exec deliberately leaves
        /// this nil and never produces `vm.exec.*` audit events.
        let auditContext: VMGuestExecutionAuditContext?
        let createdAt: Date
        let expiresAt: Date
    }

    struct AttachedExecSession: Sendable {
        let sessionId: String
        let resourceKind: GuestResourceKind
        let resourceId: String
        let agentKey: String
        let userId: String
        let outputMode: GuestExecOutputMode
        let auditContext: VMGuestExecutionAuditContext?
        var agentConfirmedStarted: Bool
        var agentConfirmedStartedAt: Date?
        let attachedAt: Date
    }

    init(app: Application) {
        self.app = app
    }

    // MARK: - Pending sessions

    /// Mint a pending session for a validated exec request. Returns the
    /// session (including `expiresAt`) for the 201 response.
    func createPendingSession(
        sessionId: String = UUID().uuidString,
        resourceKind: GuestResourceKind,
        resourceId: String,
        agentKey: String,
        userId: String,
        command: [String],
        env: [String: String]?,
        workingDir: String?,
        tty: Bool,
        rows: Int?,
        cols: Int?,
        outputMode: GuestExecOutputMode = .raw,
        auditContext: VMGuestExecutionAuditContext? = nil,
        now: Date = Date()
    ) -> PendingExecSession {
        let session = PendingExecSession(
            sessionId: sessionId,
            resourceKind: resourceKind,
            resourceId: resourceId,
            agentKey: agentKey,
            userId: userId,
            command: command,
            env: env,
            workingDir: workingDir,
            tty: tty,
            rows: rows,
            cols: cols,
            outputMode: outputMode,
            auditContext: auditContext,
            createdAt: now,
            expiresAt: now.addingTimeInterval(Self.pendingSessionTTL)
        )

        lock.withLock {
            sweepExpiredPendingLocked(now: now)
            pendingSessions[session.sessionId] = session
        }

        app.logger.info(
            "Guest exec session created",
            metadata: [
                "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(session.sessionId),
                "resourceKind": .string(resourceKind.rawValue),
                LogMetadata.guestResourceIDKey(for: resourceKind): .string(resourceId),
                "strato.agent.identity": .string(agentKey),
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
    /// Validates that the session exists, has not expired, targets the supplied
    /// resource, and was minted for `userId`. On success the session moves from
    /// pending to attached and the returned value carries the exec request for
    /// `sendExecStart(for:)`.
    ///
    /// `websocket` is optional only so unit tests can exercise the lifecycle
    /// without a live socket; the controller always passes one.
    func attachSession(
        sessionId: String,
        resourceKind: GuestResourceKind,
        resourceId: String,
        userId: String,
        websocket: WebSocket?,
        now: Date = Date()
    ) throws -> PendingExecSession {
        let session = try lock.withLock { () -> PendingExecSession in
            if sessions[sessionId] != nil {
                throw GuestExecSessionError.alreadyAttached(sessionId)
            }
            guard let pending = pendingSessions[sessionId] else {
                sweepExpiredPendingLocked(now: now)
                throw GuestExecSessionError.sessionNotFound(sessionId)
            }
            guard pending.expiresAt > now else {
                pendingSessions.removeValue(forKey: sessionId)
                throw GuestExecSessionError.sessionExpired(sessionId)
            }
            // Compare as UUIDs so casing differences cannot cause a false
            // mismatch between the minted id and the path parameter.
            let resourceMatches =
                pending.resourceKind == resourceKind
                && UUID(uuidString: pending.resourceId) == UUID(uuidString: resourceId)
            let userMatches = UUID(uuidString: pending.userId) == UUID(uuidString: userId)
            guard resourceMatches, userMatches else {
                throw GuestExecSessionError.sessionMismatch(sessionId)
            }

            pendingSessions.removeValue(forKey: sessionId)
            sessions[sessionId] = AttachedExecSession(
                sessionId: sessionId,
                resourceKind: pending.resourceKind,
                resourceId: pending.resourceId,
                agentKey: pending.agentKey,
                userId: pending.userId,
                outputMode: pending.outputMode,
                auditContext: pending.auditContext,
                agentConfirmedStarted: false,
                agentConfirmedStartedAt: nil,
                attachedAt: now
            )
            if let websocket {
                frontendConnections[sessionId] = websocket
            }
            resourceSessions[
                ResourceKey(kind: pending.resourceKind, id: pending.resourceId), default: []
            ].insert(sessionId)
            return pending
        }

        app.logger.info(
            "Guest exec session attached",
            metadata: [
                "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                "resourceKind": .string(session.resourceKind.rawValue),
                LogMetadata.guestResourceIDKey(for: session.resourceKind): .string(
                    session.resourceId),
                "strato.agent.identity": .string(session.agentKey),
            ])

        return session
    }

    // MARK: - Session lifecycle

    /// End an attached session from a control-plane-owned terminal path (start
    /// delivery failure or browser/operator termination). The locked removal is
    /// the idempotency claim: whichever terminal path takes the session first is
    /// the only one allowed to append `vm.exec.ended`.
    func endSession(
        sessionId: String,
        outcome: VMGuestExecutionAudit.ExecEndOutcome,
        exitCode: Int? = nil,
        reason: String? = nil,
        timestamp: Date? = nil
    ) async {
        guard let removed = removeSession(sessionId: sessionId, timestamp: timestamp) else { return }
        await recordEnded(
            removed,
            outcome: outcome,
            exitCode: exitCode,
            reason: reason)
    }

    /// Get attached session info.
    func getSession(sessionId: String) -> AttachedExecSession? {
        lock.withLock {
            sessions[sessionId]
        }
    }

    /// All attached sessions for one guest resource.
    func getSessions(resourceKind: GuestResourceKind, resourceId: String) -> [AttachedExecSession] {
        lock.withLock {
            let resourceKey = ResourceKey(kind: resourceKind, id: resourceId)
            guard let sessionIds = resourceSessions[resourceKey] else { return [] }
            return sessionIds.compactMap { sessions[$0] }
        }
    }

    /// Tear down every session targeting `agentKey` because its socket is
    /// gone (crash, network drop, or graceful unregister). Each attached
    /// browser gets a terminal error frame and a close — instead of a
    /// silently frozen terminal — and pending sessions that could never
    /// start are dropped.
    func closeAllSessions(
        forAgent agentKey: String,
        reason: String,
        timestamp: Date? = nil
    ) async {
        let closed: [RemovedExecSession] = lock.withLock {
            let pendingSessionIds = pendingSessions.values
                .filter { $0.agentKey == agentKey }
                .map(\.sessionId)
            for sessionId in pendingSessionIds {
                pendingSessions.removeValue(forKey: sessionId)
            }
            var closed: [RemovedExecSession] = []
            let attachedSessionIds = sessions.values
                .filter { $0.agentKey == agentKey }
                .map(\.sessionId)
            for sessionId in attachedSessionIds {
                if let removed = removeSessionLocked(
                    sessionId: sessionId, timestamp: timestamp)
                {
                    closed.append(removed)
                }
            }
            return closed
        }

        // User-facing teardown is independent of audit availability. Close every
        // browser first, then enqueue the append-only facts after the lock and
        // session side effects are complete.
        for removed in closed {
            app.logger.info(
                "Closed guest exec session: agent disconnected",
                metadata: [
                    "strato.session.kind": .string("guest_exec"),
                    "strato.session.id": .string(removed.session.sessionId),
                    "strato.agent.identity": .string(agentKey),
                ])
            guard let websocket = removed.websocket else { continue }
            Self.sendControlFrameAndClose(
                BrowserControlFrame(type: "error", message: reason), to: websocket)
        }
        for removed in closed {
            await recordEnded(removed, outcome: .disconnected, reason: reason)
        }
    }

    // MARK: - Browser → agent

    /// Send the exec start message to the agent for a freshly attached session.
    func sendExecStart(for session: PendingExecSession) async throws {
        let message = GuestExecStartMessage(
            resourceKind: session.resourceKind,
            resourceId: session.resourceId,
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
            throw GuestExecSessionError.sessionNotFound(sessionId)
        }
        let message: GuestExecInputMessage
        if let data {
            message = GuestExecInputMessage(sessionId: sessionId, rawData: data, eof: eof)
        } else {
            message = GuestExecInputMessage(sessionId: sessionId, eof: eof)
        }
        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    /// Relay a browser resize request to the agent.
    func routeResize(sessionId: String, rows: Int, cols: Int) async throws {
        guard let session = getSession(sessionId: sessionId) else {
            throw GuestExecSessionError.sessionNotFound(sessionId)
        }
        let message = GuestExecResizeMessage(sessionId: sessionId, rows: rows, cols: cols)
        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    /// Tell the agent to tear down the exec session (browser disconnected).
    /// A no-op when the session is already gone (e.g. removed after exit).
    func sendExecClose(sessionId: String, reason: String? = nil) async throws {
        guard let session = getSession(sessionId: sessionId) else { return }
        let message = GuestExecCloseMessage(sessionId: sessionId, reason: reason)
        try await sendMessageToAgent(message, agentKey: session.agentKey)
    }

    // MARK: - Agent → browser

    /// The exec process spawned: tell the browser it may start sending input.
    func handleStarted(
        sessionId: String,
        fromAgentKey agentKey: String,
        timestamp: Date? = nil
    ) async {
        let transition = claimAgentConfirmedStart(
            sessionId: sessionId, fromAgentKey: agentKey, timestamp: timestamp)
        switch transition {
        case .started(let session, let websocket):
            if let websocket {
                Self.sendControlFrame(BrowserControlFrame(type: "ready"), to: websocket)
            }
            if let context = session.auditContext,
                let startedAt = session.agentConfirmedStartedAt
            {
                let auditRecord = VMGuestExecutionAudit.makeExecStartedRecord(
                    context,
                    timestamp: startedAt)
                await app.audit.recordFailOpen(auditRecord)
            }
        case .duplicate:
            app.logger.debug(
                "Ignoring duplicate guest exec started event",
                metadata: [
                    "strato.session.kind": .string("guest_exec"),
                    "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
                ])
        case .unknown:
            app.logger.debug(
                "Guest exec started for unknown session",
                metadata: [
                    "strato.session.kind": .string("guest_exec"),
                    "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
                ])
        case .wrongAgent(let expectedAgentKey):
            logWrongAgent(
                event: "started",
                sessionId: sessionId,
                reportingAgentKey: agentKey,
                expectedAgentKey: expectedAgentKey)
        }
    }

    /// Output bytes from the exec process. Raw sessions retain the browser
    /// terminal contract; multiplexed sessions receive one stream tag byte
    /// followed by the exact agent payload.
    func handleOutput(sessionId: String, fromAgentKey agentKey: String, stream: String, data: Data) {
        guard
            let connection = frontendConnection(
                sessionId: sessionId, fromAgentKey: agentKey, event: "output")
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
        switch connection.outputMode {
        case .raw:
            connection.websocket.send([UInt8](data))
        case .multiplexed:
            let tag: UInt8
            switch stream {
            case "stdout": tag = 0x01
            case "stderr": tag = 0x02
            default:
                app.logger.warning(
                    "Dropping guest exec output with unknown stream",
                    metadata: [
                        "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                        "stream": .string(stream),
                    ])
                return
            }
            var frame = [UInt8]()
            frame.reserveCapacity(data.count + 1)
            frame.append(tag)
            frame.append(contentsOf: data)
            connection.websocket.send(frame)
        }
    }

    /// The exec process ended: report the exit code and close normally.
    func handleExit(
        sessionId: String,
        fromAgentKey agentKey: String,
        exitCode: Int,
        timestamp: Date? = nil
    ) async {
        switch removeSession(
            sessionId: sessionId, ownedBy: agentKey, timestamp: timestamp)
        {
        case .removed(let removed):
            if let websocket = removed.websocket {
                Self.sendControlFrameAndClose(
                    BrowserControlFrame(type: "exit", exitCode: exitCode), to: websocket)
            }
            await recordEnded(removed, outcome: .exited, exitCode: exitCode)
        case .unknown:
            app.logger.debug(
                "Guest exec exit for unknown session",
                metadata: [
                    "strato.session.kind": .string("guest_exec"),
                    "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
                ])
        case .wrongAgent(let expectedAgentKey):
            logWrongAgent(
                event: "exit",
                sessionId: sessionId,
                reportingAgentKey: agentKey,
                expectedAgentKey: expectedAgentKey)
        }
    }

    /// The exec session ended without an exit code (spawn failure, vsock
    /// died, sandbox stopped): report the error and close.
    func handleClosed(
        sessionId: String,
        fromAgentKey agentKey: String,
        reason: String?,
        timestamp: Date? = nil
    ) async {
        switch removeSession(
            sessionId: sessionId, ownedBy: agentKey, timestamp: timestamp)
        {
        case .removed(let removed):
            let message = reason ?? "exec session closed by agent"
            if let websocket = removed.websocket {
                Self.sendControlFrameAndClose(
                    BrowserControlFrame(type: "error", message: message), to: websocket)
            }
            await recordEnded(
                removed,
                outcome: removed.session.agentConfirmedStarted ? .disconnected : .refused,
                reason: message)
        case .unknown:
            app.logger.debug(
                "Guest exec closed for unknown session",
                metadata: [
                    "strato.session.kind": .string("guest_exec"),
                    "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
                ])
        case .wrongAgent(let expectedAgentKey):
            logWrongAgent(
                event: "closed",
                sessionId: sessionId,
                reportingAgentKey: agentKey,
                expectedAgentKey: expectedAgentKey)
        }
    }

    // MARK: - Private helpers

    /// Resolve the browser socket for an agent-reported event, enforcing that
    /// the reporting agent is the one the session was created against —
    /// otherwise a compromised agent could inject frames into another
    /// tenant's exec session by guessing session ids.
    private struct FrontendConnection {
        let websocket: WebSocket
        let outputMode: GuestExecOutputMode
    }

    private struct RemovedExecSession {
        let session: AttachedExecSession
        let websocket: WebSocket?
        let endedAt: Date
    }

    private enum AgentConfirmedStartTransition {
        case started(AttachedExecSession, WebSocket?)
        case duplicate
        case unknown
        case wrongAgent(expectedAgentKey: String)
    }

    private enum OwnedSessionRemoval {
        case removed(RemovedExecSession)
        case unknown
        case wrongAgent(expectedAgentKey: String)
    }

    private func claimAgentConfirmedStart(
        sessionId: String,
        fromAgentKey agentKey: String,
        timestamp: Date?
    ) -> AgentConfirmedStartTransition {
        lock.withLock {
            guard var session = sessions[sessionId] else { return .unknown }
            guard session.agentKey == agentKey else {
                return .wrongAgent(expectedAgentKey: session.agentKey)
            }
            guard !session.agentConfirmedStarted else { return .duplicate }
            session.agentConfirmedStarted = true
            session.agentConfirmedStartedAt = timestamp ?? Date()
            sessions[sessionId] = session
            return .started(session, frontendConnections[sessionId])
        }
    }

    private func removeSession(
        sessionId: String,
        timestamp: Date?
    ) -> RemovedExecSession? {
        lock.withLock {
            removeSessionLocked(sessionId: sessionId, timestamp: timestamp)
        }
    }

    private func removeSession(
        sessionId: String,
        ownedBy agentKey: String,
        timestamp: Date?
    ) -> OwnedSessionRemoval {
        lock.withLock {
            guard let session = sessions[sessionId] else { return .unknown }
            guard session.agentKey == agentKey else {
                return .wrongAgent(expectedAgentKey: session.agentKey)
            }
            guard
                let removed = removeSessionLocked(
                    sessionId: sessionId, timestamp: timestamp)
            else { return .unknown }
            return .removed(removed)
        }
    }

    /// Must be called while holding `lock`.
    private func removeSessionLocked(
        sessionId: String,
        timestamp: Date?
    ) -> RemovedExecSession? {
        guard let session = sessions.removeValue(forKey: sessionId) else { return nil }
        let observedAt = timestamp ?? Date()
        let endedAt: Date
        if let startedAt = session.agentConfirmedStartedAt {
            endedAt = max(observedAt, startedAt.addingTimeInterval(0.000_001))
        } else {
            endedAt = observedAt
        }
        let websocket = frontendConnections.removeValue(forKey: sessionId)
        let resourceKey = ResourceKey(kind: session.resourceKind, id: session.resourceId)
        resourceSessions[resourceKey]?.remove(sessionId)
        if resourceSessions[resourceKey]?.isEmpty == true {
            resourceSessions.removeValue(forKey: resourceKey)
        }
        app.logger.info(
            "Guest exec session removed",
            metadata: [
                "strato.session.kind": .string("guest_exec"),
                "strato.session.id": .string(sessionId),
                "resourceKind": .string(session.resourceKind.rawValue),
                LogMetadata.guestResourceIDKey(for: session.resourceKind): .string(
                    session.resourceId),
            ])
        return RemovedExecSession(session: session, websocket: websocket, endedAt: endedAt)
    }

    private func recordEnded(
        _ removed: RemovedExecSession,
        outcome: VMGuestExecutionAudit.ExecEndOutcome,
        exitCode: Int? = nil,
        reason: String? = nil
    ) async {
        guard let context = removed.session.auditContext else { return }
        let auditRecord = VMGuestExecutionAudit.makeExecEndedRecord(
            context,
            outcome: outcome,
            exitCode: exitCode,
            reason: reason,
            timestamp: removed.endedAt)
        await app.audit.recordFailOpen(auditRecord)
    }

    private func logWrongAgent(
        event: String,
        sessionId: String,
        reportingAgentKey: String,
        expectedAgentKey: String
    ) {
        app.logger.warning(
            "Dropping guest exec \(event) from an agent that does not own the session",
            metadata: [
                "strato.session.kind": .string("guest_exec"),
                "strato.session.id": .string(sessionId),
                "strato.agent.identity": .string(reportingAgentKey),
                "strato.agent.session.identity": .string(expectedAgentKey),
            ])
    }

    private func frontendConnection(
        sessionId: String, fromAgentKey agentKey: String, event: String
    ) -> FrontendConnection? {
        let (session, websocket) = lock.withLock {
            (sessions[sessionId], frontendConnections[sessionId])
        }
        guard let session else {
            app.logger.debug(
                "Guest exec \(event) for unknown session",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
                ])
            return nil
        }
        guard session.agentKey == agentKey else {
            app.logger.warning(
                "Dropping guest exec \(event) from an agent that does not own the session",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                    "strato.agent.identity": .string(agentKey),
                    "strato.agent.session.identity": .string(session.agentKey),
                ])
            return nil
        }
        guard let websocket else { return nil }
        return FrontendConnection(websocket: websocket, outputMode: session.outputMode)
    }

    /// Best-effort `GuestExecCloseMessage` to an agent that reported output
    /// for a session this control plane does not know, so the agent tears the
    /// orphaned bridge down instead of streaming forever. Errors are swallowed:
    /// this is advisory, and the agent's own sandbox-stop path also reaps
    /// bridges.
    private func sendOrphanedBridgeClose(sessionId: String, toAgentKey agentKey: String) {
        guard let websocket = app.websocketManager.getConnection(agentKey: agentKey) else { return }
        let message = GuestExecCloseMessage(sessionId: sessionId, reason: "unknown exec session")
        guard let data = try? WireProtocol.encodeEnvelope(message) else { return }
        websocket.send(data)
        app.logger.debug(
            "Sent exec close for unknown session back to reporting agent",
            metadata: [
                "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                "strato.agent.identity": .string(agentKey),
            ])
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

    /// Queue browser delivery without awaiting socket I/O. Lifecycle audit
    /// must not depend on whether a broken browser can accept its final frame.
    private static func sendControlFrame(_ frame: BrowserControlFrame, to websocket: WebSocket) {
        websocket.send(controlFrame(frame))
    }

    private static func sendControlFrameAndClose(
        _ frame: BrowserControlFrame,
        to websocket: WebSocket
    ) {
        sendControlFrame(frame, to: websocket)
        _ = websocket.close(code: .normalClosure)
    }

    /// Must be called while holding `lock`.
    private func sweepExpiredPendingLocked(now: Date) {
        for (sessionId, pending) in pendingSessions where pending.expiresAt <= now {
            pendingSessions.removeValue(forKey: sessionId)
            app.logger.debug(
                "Expired unattached guest exec session",
                metadata: [
                    "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                    "resourceKind": .string(pending.resourceKind.rawValue),
                    LogMetadata.guestResourceIDKey(for: pending.resourceKind): .string(
                        pending.resourceId),
                ])
        }
    }

    /// Console parity: agent messages go out over this replica's socket only.
    /// The exec endpoint already refused the request when the agent's socket
    /// lives on another replica.
    private func sendMessageToAgent<T: WebSocketMessage>(_ message: T, agentKey: String) async throws {
        guard let websocket = app.websocketManager.getConnection(agentKey: agentKey) else {
            app.logger.error(
                "Agent WebSocket not found for guest exec message",
                metadata: ["strato.agent.identity": .string(agentKey)])
            throw GuestExecSessionError.agentNotConnected(agentKey)
        }

        let data = try WireProtocol.encodeEnvelope(message)
        websocket.send(data)
    }
}

// MARK: - Errors

enum GuestExecSessionError: Error, LocalizedError, Equatable {
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
            return "Exec session does not match this resource or user: \(sessionId)"
        case .alreadyAttached(let sessionId):
            return "Exec session is already attached: \(sessionId)"
        case .agentNotConnected(let agentKey):
            return "Agent not connected: \(agentKey)"
        }
    }
}

// MARK: - Application Extension

extension Application {
    private struct GuestExecSessionManagerKey: StorageKey, LockKey {
        typealias Value = GuestExecSessionManager
    }

    var guestExecSessionManager: GuestExecSessionManager {
        get {
            lazyService(GuestExecSessionManagerKey.self) { GuestExecSessionManager(app: self) }
        }
        set {
            setStorageValue(GuestExecSessionManagerKey.self, to: newValue)
        }
    }
}

extension Request {
    var guestExecSessionManager: GuestExecSessionManager {
        return application.guestExecSessionManager
    }
}
