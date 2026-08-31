import Foundation
import StratoShared
import Vapor

/// The one local operation the bridge hands back to its owner: turning a
/// broadcast doorbell into whatever this replica can locally do about it.
/// Production's delegate is `AgentService`; tests can substitute a fake. Kept
/// to exactly this method so the seam stays narrow — everything else the bridge
/// needs it reaches through `CoordinationService` and `Application` directly.
///
/// It deliberately does not restore the old `runLocalExchange` seam removed in
/// STR-152. Captured commands only need the narrower delivery acknowledgement;
/// their eventual result follows the ordinary guest-exec stream.
protocol ReplicaBridgeDelegate: AnyObject, Sendable {
    /// Queue one already-encoded agent message on a socket held by this
    /// process. Recorded VM commands use delivery acknowledgement only; their
    /// eventual result arrives as the ordinary guest-exec stream.
    func deliverAgentEnvelope(_ envelope: MessageEnvelope, agentKey: String) async throws

    /// Act on a broadcast doorbell for `agentKey` by waking a poll parked here.
    /// A replica that holds no such poll does nothing, which is the common case
    /// — the doorbell is broadcast precisely so no one has to know in advance
    /// which replica can act on it.
    func deliverDoorbell(agentKey: String) async
}

/// Cross-replica desired-state doorbell and agent-stream delivery.
///
/// This is how a mutation handled by any control-plane replica promptly reaches
/// an agent whose long-poll may be parked on another: one fleet-wide
/// `agent:doorbell` channel every replica listens on, with no routing directory
/// or targeted delivery. The replica holding the parked poll acts; every other
/// replica drops it.
///
/// Captured VM commands add a deliberately narrow second half: the accepting
/// replica resolves `agent:{key}:replica`, publishes an encoded stream envelope
/// to `replica:{id}:rpc`, and waits only for delivery acknowledgement. It does
/// not recreate the correlated agent exchange removed in STR-152; command
/// completion remains durable database state populated by later stream frames.
///
/// It composes `CoordinationService` (the pub/sub channel, itself backed by the
/// Valkey / in-memory `CoordinationStore` adapters) and delegates the one
/// operation that requires local state back to its owner through
/// `ReplicaBridgeDelegate`.
///
/// Doorbells remain a latency optimization. Agent-stream delivery is different:
/// it is acknowledged or rejected, and the durable command is failed when it
/// cannot be delivered.
actor ReplicaMessageBridge {
    private let app: Application
    private let deliveryAcknowledgementTimeout: Duration

    /// The owner that tracks local parked polls (production: `AgentService`).
    /// Weak so the bridge never keeps its owner alive; a nil delegate means an
    /// inbound doorbell is dropped (and logged), which the agent's
    /// unconditional re-fetch repairs.
    private weak var delegate: (any ReplicaBridgeDelegate)?

    private struct PendingDelivery {
        let continuation: CheckedContinuation<Void, Error>
        var timeout: Task<Void, Never>?
    }

    private var pendingDeliveries: [String: PendingDelivery] = [:]

    private enum SubscriptionState {
        case idle
        case arming
        case armed
    }

    /// Health bookkeeping for the replica's pub/sub subscriptions. The store
    /// owns reconnection; this actor arms each channel once and probes the
    /// doorbell channel from the heartbeat loop for observability.
    private var subscriptionState = SubscriptionState.idle
    private var lastProbeSent: Date?
    private var lastProbeReceived: Date?

    /// Set at shutdown. Guards subscription (re-)arming from racing teardown.
    private var isShutDown = false

    init(
        app: Application,
        deliveryAcknowledgementTimeout: Duration = .seconds(10)
    ) {
        self.app = app
        self.deliveryAcknowledgementTimeout = deliveryAcknowledgementTimeout
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
        for (_, pending) in pendingDeliveries {
            pending.timeout?.cancel()
            pending.continuation.resume(throwing: CancellationError())
        }
        pendingDeliveries.removeAll()
    }

    // MARK: - Socket routing and one-way RPC

    @discardableResult
    func recordRoute(agentKey: String) async -> Bool {
        await app.coordination.recordAgentRoute(agentKey: agentKey, replicaId: app.replicaID)
    }

    func clearRoute(agentKey: String) async {
        await app.coordination.clearAgentRoute(agentKey: agentKey, replicaId: app.replicaID)
    }

    struct AgentDeliveryRequest: Codable {
        let rpcId: String
        let replyChannel: String
        let agentKey: String
        let envelope: MessageEnvelope
    }

    struct AgentDeliveryReply: Codable {
        let rpcId: String
        let delivered: Bool
        let error: String?
    }

    enum DeliveryError: Error, LocalizedError {
        case agentNotConnected(String)
        case timedOut
        case deliveryUncertain(String)
        case remote(String)

        /// Only a rejection before the target socket accepted the envelope is
        /// safe to expose as a failed command. A publish/acknowledgement loss
        /// may mean the command is already running, so its durable operation
        /// must remain pending for the guest stream or deadline sweep.
        var isDefinitive: Bool {
            switch self {
            case .agentNotConnected, .remote: true
            case .timedOut, .deliveryUncertain: false
            }
        }

        var errorDescription: String? {
            switch self {
            case .agentNotConnected(let agentKey): return "Agent not connected: \(agentKey)"
            case .timedOut: return "Timed out forwarding the command to the agent socket replica"
            case .deliveryUncertain(let reason): return "Agent delivery outcome is unknown: \(reason)"
            case .remote(let reason): return reason
            }
        }
    }

    /// Queue a stream message on the replica that owns `agentKey`'s socket.
    /// This acknowledges delivery to the WebSocket only; command completion is
    /// reported later through the durable execution record.
    func deliver<T: WebSocketMessage>(_ message: T, agentKey: String) async throws {
        try await deliver(MessageEnvelope(message: message), agentKey: agentKey)
    }

    func deliver(_ envelope: MessageEnvelope, agentKey: String) async throws {
        if app.websocketManager.getConnection(agentKey: agentKey) != nil, let delegate {
            try await delegate.deliverAgentEnvelope(envelope, agentKey: agentKey)
            return
        }

        guard let replicaId = await app.coordination.agentRoute(agentKey: agentKey),
            replicaId != app.replicaID
        else {
            throw DeliveryError.agentNotConnected(agentKey)
        }

        let rpcId = UUID().uuidString
        let request = AgentDeliveryRequest(
            rpcId: rpcId,
            replyChannel: CoordinationService.rpcReplyChannel(replicaId: app.replicaID),
            agentKey: agentKey,
            envelope: envelope)
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)

        try await withCheckedThrowingContinuation { continuation in
            pendingDeliveries[rpcId] = PendingDelivery(continuation: continuation, timeout: nil)
            Task {
                do {
                    try await self.app.coordination.publish(
                        channel: CoordinationService.rpcChannel(replicaId: replicaId), message: payload)
                } catch {
                    self.resolveDelivery(
                        rpcId: rpcId,
                        result: .failure(DeliveryError.deliveryUncertain(error.localizedDescription)))
                    return
                }
                let timeout = Task {
                    try? await Task.sleep(for: self.deliveryAcknowledgementTimeout)
                    guard !Task.isCancelled else { return }
                    self.resolveDelivery(rpcId: rpcId, result: .failure(DeliveryError.timedOut))
                }
                self.attachDeliveryTimeout(timeout, rpcId: rpcId)
            }
        }
    }

    private func handleDeliveryRequest(_ payload: String) async {
        guard
            let request = try? JSONDecoder().decode(
                AgentDeliveryRequest.self, from: Data(payload.utf8))
        else {
            app.logger.warning("Malformed cross-replica agent delivery request")
            return
        }

        let reply: AgentDeliveryReply
        do {
            guard let delegate else { throw DeliveryError.agentNotConnected(request.agentKey) }
            try await delegate.deliverAgentEnvelope(request.envelope, agentKey: request.agentKey)
            reply = AgentDeliveryReply(rpcId: request.rpcId, delivered: true, error: nil)
        } catch {
            reply = AgentDeliveryReply(
                rpcId: request.rpcId, delivered: false, error: error.localizedDescription)
        }

        do {
            let encoded = try JSONEncoder().encode(reply)
            try await app.coordination.publish(
                channel: request.replyChannel, message: String(decoding: encoded, as: UTF8.self))
        } catch {
            app.logger.error("Failed to publish cross-replica agent delivery reply: \(error)")
        }
    }

    private func handleDeliveryReply(_ payload: String) {
        guard
            let reply = try? JSONDecoder().decode(
                AgentDeliveryReply.self, from: Data(payload.utf8))
        else { return }
        resolveDelivery(
            rpcId: reply.rpcId,
            result: reply.delivered
                ? .success(())
                : .failure(DeliveryError.remote(reply.error ?? "Agent delivery failed")))
    }

    private func attachDeliveryTimeout(_ timeout: Task<Void, Never>, rpcId: String) {
        guard pendingDeliveries[rpcId] != nil else {
            timeout.cancel()
            return
        }
        pendingDeliveries[rpcId]?.timeout = timeout
    }

    private func resolveDelivery(rpcId: String, result: Result<Void, Error>) {
        guard let pending = pendingDeliveries.removeValue(forKey: rpcId) else { return }
        pending.timeout?.cancel()
        pending.continuation.resume(with: result)
    }

    // MARK: - Desired-state doorbell (STR-146)

    /// Ring the fleet-wide doorbell for `agentKey`. The caller has already run
    /// the local half inline, so this replica ignores its own echo.
    func ringDoorbell(agentKey: String) async {
        await app.coordination.publishDoorbell(agentKey: agentKey, fromReplica: app.replicaID)
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

    /// Subscribe to the fleet-wide doorbell and per-replica RPC channels. The
    /// coordination store owns reconnection for the lifetime of each call, so
    /// re-arming here would create a second permanent consumer and duplicate
    /// RPC delivery. A failed initial arm may be retried; a completed arm is
    /// idempotent.
    private func startSubscriptions() async {
        guard !isShutDown, !app.didShutdown, subscriptionState == .idle else { return }
        subscriptionState = .arming
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
                Task { await self?.handleDeliveryRequest(payload) }
            }
            try await app.coordination.subscribe(
                channel: CoordinationService.rpcReplyChannel(replicaId: replicaId)
            ) { [weak self] payload in
                Task { await self?.handleDeliveryReply(payload) }
            }
            subscriptionState = .armed
            app.logger.info("Replica doorbell channel subscribed")
        } catch {
            subscriptionState = .idle
            app.logger.error(
                "Failed to subscribe to the desired-state doorbell channel; this replica will not hear doorbells: \(error)"
            )
        }
    }

    /// Verify the doorbell subscription is receiving. The store's permanent
    /// subscription task reconnects after Valkey interruption, so a missed
    /// probe is logged but must not register another handler. Each heartbeat
    /// tick publishes a self-addressed probe for this health signal.
    func verifySubscriptions(now: Date = Date()) async {
        guard !isShutDown, !app.didShutdown else { return }

        if subscriptionState == .idle {
            // The initial arm failed before it established all channels; keep
            // retrying from here.
            await startSubscriptions()
        } else if let sent = lastProbeSent,
            (lastProbeReceived ?? .distantPast) < sent,
            now.timeIntervalSince(sent) > 20
        {
            // The previous tick's probe never arrived. The store's existing
            // subscription task is already reconnecting; registering another
            // handler here would duplicate every later RPC delivery.
            app.logger.warning(
                "Replica subscription probe was not received; awaiting store reconnection")
        }

        lastProbeSent = now
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
                metadata: ["strato.agent.identity": .string(agentKey)])
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
