import Foundation
import StratoShared
import Vapor

/// The one local operation the bridge hands back to its owner: turning a
/// broadcast doorbell into whatever this replica can locally do about it.
/// Production's delegate is `AgentService`; tests can substitute a fake. Kept
/// to exactly this method so the seam stays narrow — everything else the bridge
/// needs it reaches through `CoordinationService` and `Application` directly.
///
/// It had a second method, `runLocalExchange`, which ran a forwarded correlated
/// exchange over a held socket. That went with the cross-replica RPC bridge
/// (STR-152).
protocol ReplicaBridgeDelegate: AnyObject, Sendable {
    /// Act on a broadcast doorbell for `agentKey` by waking a poll parked here.
    /// A replica that holds no such poll does nothing, which is the common case
    /// — the doorbell is broadcast precisely so no one has to know in advance
    /// which replica can act on it.
    func deliverDoorbell(agentKey: String) async
}

/// Cross-replica desired-state doorbell (issue #261, STR-146).
///
/// This is how a mutation handled by any control-plane replica promptly reaches
/// an agent whose long-poll may be parked on another: one fleet-wide
/// `agent:doorbell` channel every replica listens on, with no routing directory
/// or targeted delivery. The replica holding the parked poll acts; every other
/// replica drops it.
///
/// This used to be two halves. The other was correlated request/reply RPC
/// forwarding over `replica:{id}:rpc`, which needed a `agent:{name}:replica`
/// routing directory to find the socket holder and fail fast when nobody held
/// it. Every verb that used it became desired state (ADR 0001 stages 5–9), so
/// both went in STR-152 and what is left needs no directory at all: a broadcast
/// nobody can act on is simply ignored.
///
/// It composes `CoordinationService` (the pub/sub channel, itself backed by the
/// Valkey / in-memory `CoordinationStore` adapters) and delegates the one
/// operation that requires local state back to its owner through
/// `ReplicaBridgeDelegate`.
///
/// Everything the bridge does is a latency optimization: a lost doorbell or a
/// dropped subscription never corrupts state because every agent converges on
/// its own unconditional re-fetch.
actor ReplicaMessageBridge {
    private let app: Application

    /// The owner that tracks local parked polls (production: `AgentService`).
    /// Weak so the bridge never keeps its owner alive; a nil delegate means an
    /// inbound doorbell is dropped (and logged), which the agent's
    /// unconditional re-fetch repairs.
    private weak var delegate: (any ReplicaBridgeDelegate)?

    /// Health bookkeeping for the replica's pub/sub subscriptions (issue #261
    /// review): RediStack pins subscriptions to one dedicated connection and
    /// does not restore them when it drops, so liveness is verified by probing
    /// the doorbell channel from the heartbeat loop.
    private var subscriptionsEstablished = false
    private var lastProbeSent: Date?
    private var lastProbeReceived: Date?

    /// Set at shutdown. Guards subscription (re-)arming from racing teardown.
    private var isShutDown = false

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

    /// Subscribe to the fleet-wide doorbell channel. Called from `start` and
    /// re-armed by `verifySubscriptions()`; failure is logged and fails open —
    /// the replica misses doorbell latency but agents still converge on their
    /// own unconditional re-fetch, so it stays available.
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
            subscriptionsEstablished = true
            app.logger.info(
                "Replica doorbell channel subscribed", metadata: ["replicaId": .string(replicaId)])
        } catch {
            subscriptionsEstablished = false
            app.logger.error(
                "Failed to subscribe to the desired-state doorbell channel; this replica will not hear doorbells: \(error)"
            )
        }
    }

    /// Verify the doorbell subscription is actually receiving (issue #261
    /// review finding). RediStack pins subscriptions to one dedicated
    /// connection and never restores them after a drop (Valkey restart,
    /// failover, network blip) — and a dead subscription is silent: the replica
    /// would stop hearing doorbells and park every poll it holds for the full
    /// hold window without a single error. So each heartbeat tick publishes a
    /// self-addressed probe on the doorbell channel; a probe that hasn't come
    /// back by the next tick means the subscription connection is dead, and it
    /// is re-armed. Runs on the 30s heartbeat tick, bounding the silent window
    /// to about two ticks.
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
