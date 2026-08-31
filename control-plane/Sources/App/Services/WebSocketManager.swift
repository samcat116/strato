import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent
import NIOCore
import NIOConcurrencyHelpers
import SQLKit
import Tracing
import Metrics

/// Thread-safe WebSocket connection manager
/// This is NOT an actor to avoid event loop conflicts with NIO
/// WebSocket objects are event-loop-bound and must only be accessed from their event loop
/// Safety: every access to `connections` and its mutable `Connection` values is
/// inside `lock`; callers remain responsible for the documented WebSocket event
/// loop precondition after retrieving a socket.
final class WebSocketManager: @unchecked Sendable {
    private struct Connection {
        let websocket: WebSocket
        let frameProcessor: AgentWebSocketFrameProcessor
        /// Database UUID of the agent, learned at registration (the socket is
        /// accepted before the register message arrives, so it starts nil).
        var agentId: String?
    }

    private let lock = NIOLock()
    /// Keyed by the agent's identity key — its full SPIFFE ID
    /// (`spiffe://<trust-domain>/agent/<name>`), never the bare name. Two
    /// organizations may each enroll an `agent-1` once per-org trust domains
    /// are on (issue #613); a name-keyed map would give one org's socket the
    /// other's desired state.
    private var connections: [String: Connection] = [:]

    /// Store the connection for an agent, returning the frame processor it
    /// replaced (a different socket under the same name) or nil. A non-nil
    /// result means the agent reconnected while its previous socket's close
    /// was still pending: that delayed close will take the
    /// `removeConnection(ifCurrent:)`
    /// no-match path and skip its cleanup, so the caller must tear down state
    /// tied to the superseded connection (e.g. console or guest-exec sessions)
    /// here instead.
    /// Must be called from the WebSocket's event loop.
    @discardableResult
    func setConnection(
        agentKey: String, websocket: WebSocket,
        frameProcessor: AgentWebSocketFrameProcessor
    ) -> AgentWebSocketFrameProcessor? {
        lock.withLock {
            let previous = connections[agentKey]
            connections[agentKey] = Connection(
                websocket: websocket, frameProcessor: frameProcessor, agentId: nil)
            return previous?.websocket === websocket ? nil : previous?.frameProcessor
        }
    }

    /// Attach the agent's database UUID to its live connection once
    /// registration resolves it. No-op if the socket is already gone.
    func associate(agentKey: String, agentId: String) {
        lock.withLock {
            connections[agentKey]?.agentId = agentId
        }
    }

    /// Returns the WebSocket for an agent - must be used on WebSocket's event loop
    func getConnection(agentKey: String) -> WebSocket? {
        lock.withLock {
            connections[agentKey]?.websocket
        }
    }

    /// The locally connected agent's identity key for a database UUID, or nil
    /// when this process doesn't hold the agent's socket (another replica may).
    func agentKey(agentId: String) -> String? {
        lock.withLock {
            connections.first(where: { $0.value.agentId == agentId })?.key
        }
    }

    /// The database UUID a locally connected agent registered with, if any.
    func agentId(agentKey: String) -> String? {
        lock.withLock {
            connections[agentKey]?.agentId
        }
    }

    /// Remove connection by agent identity key
    func removeConnection(agentKey: String) {
        lock.withLock {
            _ = connections.removeValue(forKey: agentKey)
        }
    }

    /// Remove the connection for an agent only if the stored socket is the given
    /// instance. Used by close handlers so a delayed close from a replaced
    /// connection cannot tear down its successor (e.g. after an agent reconnects
    /// under the same name). Returns true when the connection was removed.
    func removeConnection(agentKey: String, ifCurrent websocket: WebSocket) -> Bool {
        lock.withLock {
            guard connections[agentKey]?.websocket === websocket else { return false }
            connections.removeValue(forKey: agentKey)
            return true
        }
    }

}
