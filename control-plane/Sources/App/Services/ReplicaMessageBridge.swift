import Foundation
import StratoShared
import Vapor

/// The local operations the bridge forwards back to its owner: running a
/// correlated exchange over a held socket (the RPC holder half) and turning a
/// broadcast doorbell into whatever this replica can locally do about it.
/// Production's delegate is `AgentService`; tests can substitute a fake. Kept
/// to exactly these two methods so the seam stays narrow — everything else the
/// bridge needs it reaches through `CoordinationService` and `Application`
/// directly.
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

    /// Act on a broadcast doorbell for `agentKey`: wake a poll parked here and
    /// push a fresh sync if this process holds the socket of a push-mode agent.
    /// A replica that can do neither does nothing, which is the common case —
    /// the doorbell is broadcast to everyone precisely so no one has to know
    /// in advance who can act on it.
    func deliverDoorbell(agentKey: String) async
}

/// Cross-replica message bridge (issue #261).
///
/// The control plane runs as multiple replicas and an agent's WebSocket lives
/// on exactly one of them. This is how any replica reaches an agent whose
/// socket it does not hold: it owns the socket-route bookkeeping, the
/// desired-state doorbell, and the correlated request/reply RPC forwarding —
/// the cross-replica machinery that used to sit inside `AgentService`.
///
/// The two halves now work differently on purpose. **Desired state** is
/// broadcast (STR-146): one `agent:doorbell` channel every replica listens on,
/// no routing directory, no targeted delivery. **Imperative RPC** still routes,
/// because it needs a reply and needs to fail fast when nobody holds the socket
/// — broadcasting it would turn "agent is offline" from an immediate error into
/// a 30s timeout. So `agent:{name}:replica` survives here and only here, until
/// stages 5–9 convert the last imperative exchange and STR-152 deletes both.
///
/// It composes `CoordinationService` (pub/sub channels and route keys, itself
/// backed by the Valkey / in-memory `CoordinationStore` adapters) and delegates
/// the two operations that require local state back to its owner through
/// `ReplicaBridgeDelegate`. `AgentService` keeps the local-socket mechanics;
/// everything about *which replica* holds a socket and *how to forward* to it
/// lives here.
///
/// Everything the bridge does is a latency optimization: a lost doorbell, a
/// dropped subscription, or a failed RPC never corrupts state — a pull-mode
/// agent converges on its own unconditional re-fetch, and a push-mode agent on
/// the periodic sync timer.
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
    /// the doorbell channel from the heartbeat loop.
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
    /// can forward imperative RPCs here. Binds this process's replica id so
    /// callers never thread it through.
    func recordRoute(agentKey: String) async {
        await app.coordination.recordAgentRoute(agentKey: agentKey, replicaId: app.replicaID)
    }

    /// Clear this replica's claim on `agentKey`'s socket (compare-and-delete on
    /// our own id, so a successor's claim is never torn down).
    func clearRoute(agentKey: String) async {
        await app.coordination.clearAgentRoute(agentKey: agentKey, replicaId: app.replicaID)
    }

    /// Where an imperative exchange for `agentKey` should go when this replica
    /// does *not* hold the socket locally. A pure function of the route key
    /// relative to this replica's id.
    ///
    /// Desired state no longer asks: it rings the broadcast doorbell, which
    /// needs no answer to this question at all.
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

    // MARK: - Desired-state doorbell (STR-146)

    /// Ring the fleet-wide doorbell for `agentKey`. The caller has already run
    /// the local half inline, so this replica ignores its own echo.
    func ringDoorbell(agentKey: String) async {
        await app.coordination.publishDoorbell(agentKey: agentKey, fromReplica: app.replicaID)
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

    /// Agent-key sentinel published on the doorbell channel to verify the
    /// subscription connection is alive. Cannot collide with a real doorbell:
    /// those carry SPIFFE IDs, and a leading NUL is not a legal one.
    ///
    /// The doorbell channel is shared by the whole fleet, so a probe is only
    /// ours when the payload's publisher id is ours — every replica sees every
    /// other replica's probes and must ignore them, or a dead subscription
    /// would look alive on the strength of a neighbor's traffic.
    static let subscriptionProbeMessage = "\u{0}subscription-probe"

    /// Subscribe to the doorbell channel and this replica's RPC channels.
    /// Called from `start` and re-armed by `verifySubscriptions()`; failure is
    /// logged and fails open — the replica misses doorbell latency (agents
    /// still converge on their own re-fetch, and push-mode agents on the
    /// periodic timer) and cannot serve cross-replica exchanges, but stays
    /// available.
    ///
    /// Safe to call repeatedly: RediStack replaces the receiver when the
    /// channel is already subscribed on a live connection, and leases a fresh
    /// pub/sub connection when the previous one died.
    private func startSubscriptions() async {
        guard !isShutDown, !app.didShutdown else { return }
        let replicaId = app.replicaID
        do {
            try await app.coordination.subscribe(
                channel: CoordinationService.doorbellChannel
            ) { [weak self] payload in
                Task { await self?.handleDoorbell(payload) }
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
                "Failed to subscribe to replica coordination channels; desired-state doorbells and cross-replica RPCs are unavailable on this replica: \(error)"
            )
        }
    }

    /// Verify the pub/sub subscriptions are actually receiving (issue #261
    /// review finding). RediStack pins subscriptions to one dedicated
    /// connection and never restores them after a drop (Valkey restart,
    /// failover, network blip) — and a dead subscription is silent: this
    /// replica would keep *publishing* RPCs whose replies it can no longer
    /// hear, failing every cross-replica exchange by timeout — and it would
    /// stop hearing doorbells, silently parking every poll it holds for the
    /// full hold window. So each heartbeat tick publishes a self-addressed
    /// probe on the doorbell channel; a probe that hasn't come back by the next
    /// tick means the subscription connection is dead, and everything is
    /// re-armed. Runs on the 30s heartbeat tick, bounding the silent window to
    /// about two ticks.
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
                channel: CoordinationService.doorbellChannel,
                message: CoordinationService.doorbellPayload(
                    agentKey: Self.subscriptionProbeMessage, fromReplica: app.replicaID)
            )
        } catch {
            // Publishing needs Valkey too; when it's down entirely the next
            // tick's missed probe re-arms once it returns.
            app.logger.warning("Failed to publish subscription probe: \(error)")
        }
    }

    /// Test seam: whether the most recently published subscription probe has
    /// been received back on the doorbell channel.
    var lastSubscriptionProbeRoundTripped: Bool {
        guard let sent = lastProbeSent else { return false }
        return (lastProbeReceived ?? .distantPast) >= sent
    }

    /// A doorbell names an agent whose desired state changed somewhere in the
    /// fleet. Two payloads are dropped before the delegate ever sees them:
    ///
    /// - **Our own echo.** The publisher already ran the local half inline
    ///   before broadcasting, so acting again here would assemble and push the
    ///   same sync twice.
    /// - **Another replica's probe.** Probes are self-addressed liveness
    ///   checks; counting a neighbor's would make a dead subscription look
    ///   alive on the strength of someone else's traffic.
    func handleDoorbell(_ payload: String) async {
        guard let (replicaId, agentKey) = CoordinationService.parseDoorbell(payload) else {
            app.logger.warning(
                "Malformed desired-state doorbell payload; ignoring",
                metadata: ["payload": .string(payload)])
            return
        }
        if agentKey == Self.subscriptionProbeMessage {
            if replicaId == app.replicaID { lastProbeReceived = Date() }
            return
        }
        guard replicaId != app.replicaID else { return }
        guard let delegate else {
            app.logger.debug(
                "Doorbell received before the bridge delegate was set; ignoring",
                metadata: ["agentKey": .string(agentKey)])
            return
        }
        await delegate.deliverDoorbell(agentKey: agentKey)
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
            setStorageValue(ReplicaMessageBridgeKey.self, to: newValue)
        }
    }

    /// The bridge only if one already exists, without lazily creating it —
    /// shutdown must not instantiate it.
    var replicaBridgeIfCreated: ReplicaMessageBridge? {
        storage[ReplicaMessageBridgeKey.self]
    }
}
