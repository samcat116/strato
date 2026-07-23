import Foundation
import StratoShared
import Vapor

/// The local-socket operations the bridge forwards back to its owner: running
/// a correlated exchange over a held socket (the RPC holder half) and turning
/// a nudge into a local desired-state sync. Production's delegate is
/// `AgentService`; tests can substitute a fake. Kept to exactly these two
/// methods so the seam stays narrow — everything else the bridge needs it
/// reaches through `CoordinationService` and `Application` directly.
protocol ReplicaBridgeDelegate: AnyObject, Sendable {
    /// Run a forwarded exchange over the locally held socket and await the
    /// agent's correlated response. Called only after the bridge has confirmed
    /// this process holds the socket; a throw is reported to the requester as
    /// `unreachable`.
    func runLocalExchange(
        _ envelope: MessageEnvelope,
        requestId: String,
        agentId: String,
        agentKey: String,
        timeout: Duration
    ) async throws -> AgentServiceResponse

    /// Deliver a sync nudge: push a fresh desired-state sync if this process
    /// (still) holds the agent's socket, otherwise ignore it.
    func deliverNudge(agentKey: String) async
}

/// Cross-replica message bridge (issue #261).
///
/// The control plane runs as multiple replicas and an agent's WebSocket lives
/// on exactly one of them. This is how any replica reaches an agent whose
/// socket it does not hold: it owns the socket-route bookkeeping, the
/// sync-nudge fan-out, and the correlated request/reply RPC forwarding — the
/// cross-replica machinery that used to sit inside `AgentService`.
///
/// It composes `CoordinationService` (pub/sub channels and route keys, itself
/// backed by the Valkey / in-memory `CoordinationStore` adapters) and delegates
/// the two operations that require the local socket back to its owner through
/// `ReplicaBridgeDelegate`. `AgentService` keeps the local-socket mechanics;
/// everything about *which replica* holds a socket and *how to forward* to it
/// lives here.
///
/// Everything the bridge does is a latency optimization over the periodic
/// desired-state sync, which stays the correctness backstop: a lost nudge, a
/// dropped subscription, or a failed RPC never corrupts state — the agent
/// converges on the next periodic sync regardless.
actor ReplicaMessageBridge {
    private let app: Application

    /// The owner that holds agent sockets locally (production: `AgentService`).
    /// Weak so the bridge never keeps its owner alive; a nil delegate means an
    /// inbound exchange or nudge is dropped (and logged), which the periodic
    /// sync repairs.
    private weak var delegate: (any ReplicaBridgeDelegate)?

    /// Requester-side halves of cross-replica RPCs awaiting a reply on this
    /// replica's reply channel, keyed by RPC ID. Request-scoped: an entry lives
    /// for one HTTP request's await and resolves by reply or timeout.
    private var pendingRPCs: [String: PendingRPC] = [:]

    /// RPC IDs whose awaiting task was cancelled before the RPC was armed (the
    /// arming runs in a separate task, so cancellation can win the race).
    /// Consumed at arming time so the continuation resumes immediately instead
    /// of suspending until its timeout.
    private var cancelledRPCs: Set<String> = []

    /// Health bookkeeping for the replica's pub/sub subscriptions (issue #261
    /// review): RediStack pins subscriptions to one dedicated connection and
    /// does not restore them when it drops, so liveness is verified by probing
    /// our own nudge channel from the heartbeat loop.
    private var subscriptionsEstablished = false
    private var lastProbeSent: Date?
    private var lastProbeReceived: Date?

    /// Set at shutdown. Guards subscription (re-)arming from racing teardown.
    private var isShutDown = false

    /// A cross-replica RPC awaiting its reply message.
    private struct PendingRPC {
        let continuation: CheckedContinuation<AgentServiceResponse, Error>
        var timeoutTask: Task<Void, Never>?
    }

    init(app: Application) {
        self.app = app
    }

    // MARK: - Lifecycle

    /// Record the delegate and arm this replica's channel subscriptions. Driven
    /// by `AgentService`'s tracked startup task so shutdown ordering (awaiting
    /// the arming before teardown) stays owned in one place.
    func start(delegate: any ReplicaBridgeDelegate) async {
        self.delegate = delegate
        guard !isShutDown, !app.didShutdown else { return }
        await startSubscriptions()
    }

    /// Stop the bridge from re-arming subscriptions. The subscription tasks
    /// themselves live on `app.valkeyTasks` and are drained by the Valkey
    /// shutdown; this only closes the re-arm path (`verifySubscriptions`).
    func shutdown() {
        isShutDown = true
    }

    // MARK: - Socket routing

    /// Advertise that this replica holds `agentKey`'s socket so other replicas
    /// can route sync nudges and RPCs here. Binds this process's replica id so
    /// callers never thread it through.
    func recordRoute(agentKey: String) async {
        await app.coordination.recordAgentRoute(agentKey: agentKey, replicaId: app.replicaID)
    }

    /// Clear this replica's claim on `agentKey`'s socket (compare-and-delete on
    /// our own id, so a successor's claim is never torn down).
    func clearRoute(agentKey: String) async {
        await app.coordination.clearAgentRoute(agentKey: agentKey, replicaId: app.replicaID)
    }

    /// Where a message for `agentKey` should go when this replica does *not*
    /// hold the socket locally. A pure function of the route key relative to
    /// this replica's id, so both the imperative RPC path and the sync-nudge
    /// path share one decision.
    enum RemoteRoute: Sendable, Equatable {
        /// Another replica holds the socket; forward to it.
        case forward(replicaId: String)
        /// No route recorded — the agent is offline everywhere.
        case noRoute
        /// The route names this replica, but the caller already found no local
        /// socket: a stale claim from a connection torn down before its route
        /// key expired.
        case ownReplica
    }

    func remoteRoute(agentKey: String) async -> RemoteRoute {
        guard let route = await app.coordination.agentRoute(agentKey: agentKey) else {
            return .noRoute
        }
        return route == app.replicaID ? .ownReplica : .forward(replicaId: route)
    }

    /// Publish a sync nudge for `agentKey` to the replica holding its socket.
    func nudge(agentKey: String, toReplica replicaId: String) async {
        await app.coordination.publishNudge(agentKey: agentKey, toReplica: replicaId)
    }

    // MARK: - Cross-replica RPC bridge (issue #261)

    /// Wire format for forwarding a correlated agent exchange to the replica
    /// holding the agent's socket. Serialized as JSON on the RPC channels.
    struct AgentRPCRequest: Codable {
        let rpcId: String
        let replyChannel: String
        let agentId: String
        let agentKey: String
        let envelope: MessageEnvelope
        let timeoutSeconds: Double
    }

    enum AgentRPCOutcome: String, Codable {
        case success
        case error
        /// The routed replica could not complete the exchange (socket gone,
        /// send failure, or its local timeout).
        case unreachable
    }

    struct AgentRPCReply: Codable {
        let rpcId: String
        let outcome: AgentRPCOutcome
        let data: AnyCodableValue?
        let error: String?
        let details: String?
    }

    /// Requester half: publish the exchange to the holder's RPC channel and
    /// await the reply on our own reply channel. The local deadline runs a
    /// little past the holder's, so the holder's specific verdict (agent error,
    /// its own timeout) normally wins over our generic one.
    ///
    /// Cancellation-aware for the same reason as the local path: shutdown's
    /// background-task drain must be able to cut this wait short.
    func call(
        _ envelope: MessageEnvelope,
        requestId: String,
        agentId: String,
        agentKey: String,
        toReplica replicaId: String,
        timeout: Duration
    ) async throws -> AgentServiceResponse {
        let request = AgentRPCRequest(
            rpcId: requestId,
            replyChannel: CoordinationService.rpcReplyChannel(replicaId: app.replicaID),
            agentId: agentId,
            agentKey: agentKey,
            envelope: envelope,
            timeoutSeconds: Self.seconds(of: timeout)
        )
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let channel = CoordinationService.rpcChannel(replicaId: replicaId)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    guard !self.consumeRPCCancellation(requestId) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.pendingRPCs[requestId] = PendingRPC(continuation: continuation)
                    do {
                        try await self.app.coordination.publish(channel: channel, message: payload)
                    } catch {
                        // The request never left this process; fail fast.
                        if let pending = self.removePendingRPC(requestId) {
                            pending.resume(throwing: error)
                        }
                        return
                    }
                    let timeoutTask = Task {
                        try? await Task.sleep(for: timeout + .seconds(5))
                        guard !Task.isCancelled else { return }
                        self.timeoutRPC(requestId)
                    }
                    self.attachRPCTimeout(timeoutTask, to: requestId)
                }
            }
        } onCancel: {
            Task { await self.cancelPendingRPC(requestId) }
        }
    }

    /// Holder half: run the forwarded exchange over our local socket and
    /// publish the verdict to the requester's reply channel.
    func handleRPCRequest(_ payload: String) async {
        let request: AgentRPCRequest
        do {
            request = try JSONDecoder().decode(AgentRPCRequest.self, from: Data(payload.utf8))
        } catch {
            app.logger.error("Failed to decode cross-replica RPC request: \(error)")
            return
        }

        let reply: AgentRPCReply
        if app.websocketManager.getConnection(agentKey: request.agentKey) != nil, let delegate {
            do {
                let response = try await delegate.runLocalExchange(
                    request.envelope, requestId: request.rpcId, agentId: request.agentId,
                    agentKey: request.agentKey, timeout: .seconds(request.timeoutSeconds))
                switch response {
                case .success(let data):
                    reply = AgentRPCReply(
                        rpcId: request.rpcId, outcome: .success, data: data, error: nil, details: nil)
                case .error(let error, let details):
                    reply = AgentRPCReply(
                        rpcId: request.rpcId, outcome: .error, data: nil, error: error, details: details)
                }
            } catch {
                reply = AgentRPCReply(
                    rpcId: request.rpcId, outcome: .unreachable, data: nil,
                    error: error.localizedDescription, details: nil)
            }
        } else {
            // The route pointed here but the socket is gone (disconnect racing
            // the routing key's TTL); tell the requester promptly instead of
            // letting it wait out its deadline.
            reply = AgentRPCReply(
                rpcId: request.rpcId, outcome: .unreachable, data: nil,
                error: "agent socket is not held by the routed replica", details: nil)
        }

        do {
            let data = try JSONEncoder().encode(reply)
            try await app.coordination.publish(
                channel: request.replyChannel, message: String(decoding: data, as: UTF8.self))
        } catch {
            app.logger.error(
                "Failed to publish cross-replica RPC reply; requester will time out: \(error)",
                metadata: ["rpcId": .string(request.rpcId)])
        }
    }

    /// Requester half, reply side: resolve the awaiting continuation.
    func handleRPCReply(_ payload: String) async {
        let reply: AgentRPCReply
        do {
            reply = try JSONDecoder().decode(AgentRPCReply.self, from: Data(payload.utf8))
        } catch {
            app.logger.error("Failed to decode cross-replica RPC reply: \(error)")
            return
        }

        guard let continuation = removePendingRPC(reply.rpcId) else { return }
        switch reply.outcome {
        case .success:
            continuation.resume(returning: .success(reply.data))
        case .error:
            continuation.resume(returning: .error(reply.error ?? "unknown agent error", reply.details))
        case .unreachable:
            continuation.resume(throwing: AgentServiceError.connectionLost)
        }
    }

    private func removePendingRPC(_ rpcId: String) -> CheckedContinuation<AgentServiceResponse, Error>? {
        guard let pending = pendingRPCs.removeValue(forKey: rpcId) else { return nil }
        pending.timeoutTask?.cancel()
        return pending.continuation
    }

    private func attachRPCTimeout(_ task: Task<Void, Never>, to rpcId: String) {
        guard pendingRPCs[rpcId] != nil else {
            task.cancel()
            return
        }
        pendingRPCs[rpcId]?.timeoutTask = task
    }

    private func timeoutRPC(_ rpcId: String) {
        if let continuation = removePendingRPC(rpcId) {
            continuation.resume(throwing: AgentServiceError.requestTimeout)
        }
    }

    /// Resume a pending RPC's continuation with `CancellationError`, or record
    /// a tombstone if the RPC hasn't been armed yet (the arming task consumes
    /// it and resumes immediately).
    private func cancelPendingRPC(_ rpcId: String) {
        if let continuation = removePendingRPC(rpcId) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledRPCs.insert(rpcId)
        }
    }

    /// Whether the awaiting task was cancelled before the RPC was armed;
    /// consumes the tombstone.
    private func consumeRPCCancellation(_ rpcId: String) -> Bool {
        cancelledRPCs.remove(rpcId) != nil
    }

    private static func seconds(of duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    // MARK: - Replica pub/sub subscriptions (issue #261)

    /// Sentinel published to our own nudge channel to verify the subscription
    /// connection is alive. Cannot collide with a real nudge: nudges carry
    /// agent names, and a leading NUL is not a legal agent name.
    static let subscriptionProbeMessage = "\u{0}subscription-probe"

    /// Subscribe to this replica's nudge and RPC channels. Called from `start`
    /// and re-armed by `verifySubscriptions()`; failure is logged and fails
    /// open — the replica misses nudge latency (its periodic timer still
    /// converges its own agents) and cannot serve cross-replica exchanges, but
    /// stays available.
    ///
    /// Safe to call repeatedly: RediStack replaces the receiver when the
    /// channel is already subscribed on a live connection, and leases a fresh
    /// pub/sub connection when the previous one died.
    private func startSubscriptions() async {
        guard !isShutDown, !app.didShutdown else { return }
        let replicaId = app.replicaID
        do {
            try await app.coordination.subscribe(
                channel: CoordinationService.nudgeChannel(replicaId: replicaId)
            ) { [weak self] agentKey in
                Task { await self?.handleNudge(agentKey: agentKey) }
            }
            try await app.coordination.subscribe(
                channel: CoordinationService.rpcChannel(replicaId: replicaId)
            ) { [weak self] payload in
                Task { await self?.handleRPCRequest(payload) }
            }
            try await app.coordination.subscribe(
                channel: CoordinationService.rpcReplyChannel(replicaId: replicaId)
            ) { [weak self] payload in
                Task { await self?.handleRPCReply(payload) }
            }
            subscriptionsEstablished = true
            app.logger.info(
                "Replica coordination channels subscribed", metadata: ["replicaId": .string(replicaId)])
        } catch {
            subscriptionsEstablished = false
            app.logger.error(
                "Failed to subscribe to replica coordination channels; cross-replica nudges and RPCs are unavailable on this replica: \(error)"
            )
        }
    }

    /// Verify the pub/sub subscriptions are actually receiving (issue #261
    /// review finding). RediStack pins subscriptions to one dedicated
    /// connection and never restores them after a drop (Valkey restart,
    /// failover, network blip) — and a dead subscription is silent: this
    /// replica would keep *publishing* RPCs whose replies it can no longer
    /// hear, failing every cross-replica exchange by timeout. So each heartbeat
    /// tick publishes a probe to our own nudge channel; a probe that hasn't
    /// come back by the next tick means the subscription connection is dead,
    /// and everything is re-armed. Runs on the 30s heartbeat tick, bounding the
    /// silent window to about two ticks.
    func verifySubscriptions() async {
        guard !isShutDown, !app.didShutdown else { return }

        if !subscriptionsEstablished {
            // The initial subscribe failed; keep retrying from here.
            await startSubscriptions()
        } else if let sent = lastProbeSent,
            (lastProbeReceived ?? .distantPast) < sent,
            Date().timeIntervalSince(sent) > 20
        {
            // The previous tick's probe never arrived: the subscription
            // connection is dead even though publishes still work.
            app.logger.warning(
                "Replica subscription probe was not received; re-establishing channel subscriptions",
                metadata: ["replicaId": .string(app.replicaID)])
            await startSubscriptions()
        }

        lastProbeSent = Date()
        do {
            try await app.coordination.publish(
                channel: CoordinationService.nudgeChannel(replicaId: app.replicaID),
                message: Self.subscriptionProbeMessage
            )
        } catch {
            // Publishing needs Valkey too; when it's down entirely the next
            // tick's missed probe re-arms once it returns.
            app.logger.warning("Failed to publish subscription probe: \(error)")
        }
    }

    /// Test seam: whether the most recently published subscription probe has
    /// been received back on the nudge channel.
    var lastSubscriptionProbeRoundTripped: Bool {
        guard let sent = lastProbeSent else { return false }
        return (lastProbeReceived ?? .distantPast) >= sent
    }

    /// A nudge names an agent whose desired state changed on another replica.
    /// The probe sentinel is consumed here for subscription liveness; a real
    /// nudge is handed to the delegate, which syncs the agent if it still holds
    /// its socket (and otherwise ignores it — the nudge raced a disconnect and
    /// the periodic timer wherever the agent lands is the backstop).
    func handleNudge(agentKey: String) async {
        if agentKey == Self.subscriptionProbeMessage {
            lastProbeReceived = Date()
            return
        }
        guard let delegate else {
            app.logger.debug(
                "Nudge received before the bridge delegate was set; ignoring",
                metadata: ["agentKey": .string(agentKey)])
            return
        }
        await delegate.deliverNudge(agentKey: agentKey)
    }
}

// MARK: - Application extension

extension Application {
    private struct ReplicaMessageBridgeKey: StorageKey, LockKey {
        typealias Value = ReplicaMessageBridge
    }

    /// The cross-replica message bridge. Lazily created; `AgentService` arms it
    /// (records the delegate and subscriptions) as part of its startup task and
    /// tears it down in `shutdown()`.
    var replicaBridge: ReplicaMessageBridge {
        get {
            lazyService(ReplicaMessageBridgeKey.self) { ReplicaMessageBridge(app: self) }
        }
        set {
            storage[ReplicaMessageBridgeKey.self] = newValue
        }
    }

    /// The bridge only if one already exists, without lazily creating it —
    /// shutdown must not instantiate it.
    var replicaBridgeIfCreated: ReplicaMessageBridge? {
        storage[ReplicaMessageBridgeKey.self]
    }
}
