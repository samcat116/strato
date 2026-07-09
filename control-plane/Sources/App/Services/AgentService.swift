import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent
import NIOCore
import NIOConcurrencyHelpers

/// Thread-safe WebSocket connection manager
/// This is NOT an actor to avoid event loop conflicts with NIO
/// WebSocket objects are event-loop-bound and must only be accessed from their event loop
final class WebSocketManager: @unchecked Sendable {
    private struct Connection {
        let websocket: WebSocket
        /// Database UUID of the agent, learned at registration (the socket is
        /// accepted before the register message arrives, so it starts nil).
        var agentId: String?
    }

    private let lock = NIOLock()
    private var connections: [String: Connection] = [:]  // Agent name -> connection

    /// Must be called from the WebSocket's event loop
    func setConnection(agentName: String, websocket: WebSocket) {
        lock.withLock {
            connections[agentName] = Connection(websocket: websocket, agentId: nil)
        }
    }

    /// Attach the agent's database UUID to its live connection once
    /// registration resolves it. No-op if the socket is already gone.
    func associate(agentName: String, agentId: String) {
        lock.withLock {
            connections[agentName]?.agentId = agentId
        }
    }

    /// Returns the WebSocket for an agent - must be used on WebSocket's event loop
    func getConnection(agentName: String) -> WebSocket? {
        lock.withLock {
            connections[agentName]?.websocket
        }
    }

    /// The locally connected agent's name for a database UUID, or nil when
    /// this process doesn't hold the agent's socket (another replica may).
    func agentName(agentId: String) -> String? {
        lock.withLock {
            connections.first(where: { $0.value.agentId == agentId })?.key
        }
    }

    /// The database UUID a locally connected agent registered with, if any.
    func agentId(agentName: String) -> String? {
        lock.withLock {
            connections[agentName]?.agentId
        }
    }

    /// Remove connection by agent name
    func removeConnection(agentName: String) {
        lock.withLock {
            _ = connections.removeValue(forKey: agentName)
        }
    }

    /// Remove the connection for an agent only if the stored socket is the given
    /// instance. Used by close handlers so a delayed close from a replaced
    /// connection cannot tear down its successor (e.g. after an agent reconnects
    /// under the same name). Returns true when the connection was removed.
    func removeConnection(agentName: String, ifCurrent websocket: WebSocket) -> Bool {
        lock.withLock {
            guard connections[agentName]?.websocket === websocket else { return false }
            connections.removeValue(forKey: agentName)
            return true
        }
    }

    /// Get all agent names (for diagnostics)
    func getAllAgentNames() -> [String] {
        lock.withLock {
            Array(connections.keys)
        }
    }

    /// Every locally connected agent that has completed registration, as
    /// (name, database UUID) pairs. This is the periodic sync's work list:
    /// each replica syncs exactly the agents whose sockets it holds.
    func registeredAgents() -> [(name: String, agentId: String)] {
        lock.withLock {
            connections.compactMap { name, connection in
                connection.agentId.map { (name: name, agentId: $0) }
            }
        }
    }
}

actor AgentService {
    private let app: Application

    /// In-flight request/response exchanges on *this process's* sockets, keyed
    /// by request ID. This is per-connection correlation state, not a registry:
    /// requests are only ever armed for locally socketed agents, and every
    /// entry dies with its socket (or its timeout). Cross-replica callers reach
    /// it through the RPC bridge below, never directly.
    private var pendingRequests: [String: PendingRequest] = [:]

    /// Requester-side halves of cross-replica RPCs awaiting a reply on this
    /// replica's reply channel, keyed by RPC ID. Request-scoped: an entry
    /// lives for one HTTP request's await and resolves by reply or timeout.
    private var pendingRPCs: [String: PendingRPC] = [:]

    /// Exchange IDs whose awaiting task was cancelled before the exchange was
    /// armed (the arming runs in a separate task, so cancellation can win the
    /// race). Consumed at arming time so the continuation resumes immediately
    /// instead of suspending until its timeout. Entries that miss both the
    /// pending maps and the arming (cancellation racing a normal completion)
    /// linger, but the only canceller of these waits is shutdown's
    /// background-task drain, so the set is bounded to process teardown.
    private var cancelledExchanges: Set<String> = []

    private var heartbeatTask: Task<Void, Never>?

    /// A request awaiting a response from a specific agent.
    /// Tracking the agent lets us fail all of an agent's in-flight requests when it disconnects.
    private struct PendingRequest {
        let agentId: String
        let continuation: CheckedContinuation<AgentServiceResponse, Error>
        /// The timeout armed for this request, cancelled whenever the request
        /// is removed (normal response, disconnect, or the timeout firing itself)
        /// so a completed request never leaves a timer sleeping to no purpose.
        var timeoutTask: Task<Void, Never>?
    }

    /// A cross-replica RPC awaiting its reply message.
    private struct PendingRPC {
        let continuation: CheckedContinuation<AgentServiceResponse, Error>
        var timeoutTask: Task<Void, Never>?
    }

    /// Health bookkeeping for the replica's pub/sub subscriptions (issue
    /// #261 review): RediStack pins subscriptions to one dedicated connection
    /// and does not restore them when it drops, so liveness is verified by
    /// probing our own nudge channel from the heartbeat loop.
    private var subscriptionsEstablished = false
    private var lastProbeSent: Date?
    private var lastProbeReceived: Date?

    /// Set at application shutdown. Guards against the init task arming the
    /// heartbeat monitor after `shutdown()` already ran.
    private var isShutDown = false

    init(app: Application) {
        self.app = app
        // Start heartbeat monitoring and the replica's pub/sub subscriptions
        // after initialization
        Task {
            await startHeartbeatMonitoring()
            await startReplicaSubscriptions()
        }
    }

    /// Cancel the heartbeat monitoring loop. Called from the application's
    /// shutdown lifecycle (see `AgentServiceLifecycleHandler`): the loop holds
    /// the `Application` and sweeps the database every 30 seconds, so a tick
    /// that fires after shutdown would hit Vapor's "Core not configured"
    /// fatal error — long-lived test processes crash exactly this way.
    func shutdown() {
        isShutDown = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Agent Registration

    /// Registers an agent and returns its database UUID.
    ///
    /// `siteID` is the site carried by the redeemed registration token, if any.
    /// Non-nil assigns (or moves) the agent; nil never clears — the assignment
    /// is durable on the agent row, and rotated reconnect tokens don't carry it.
    func registerAgent(_ message: AgentRegisterMessage, agentName: String, siteID: UUID? = nil) async throws -> UUID {
        // The imperative message path is gone (issue #261): an agent that
        // cannot be driven by desired-state syncs would register successfully
        // and then never converge anything — every operation would time out
        // against its budget. Refuse it up front with the real reason.
        let protocolVersion = message.protocolVersion ?? 0
        guard WireProtocol.supportsStateSync(protocolVersion) else {
            Telemetry.agentRegistrationFailed(reason: "unsupported_protocol")
            throw AgentServiceError.unsupportedProtocolVersion(agentName: agentName, version: protocolVersion)
        }

        let db = app.db

        // Find existing agent or create new one
        let agent: Agent
        if let existingAgent = try await Agent.query(on: db)
            .filter(\.$name == agentName)
            .first()
        {
            // Update existing agent
            agent = existingAgent
            agent.hostname = message.hostname
            agent.version = message.version
            agent.capabilities = message.capabilities
            agent.architecture = message.architecture?.rawValue
            agent.hypervisors = message.effectiveHypervisors
            agent.networkCapability = message.networkCapability?.rawValue
            agent.updateResources(message.resources)
            agent.status = .online
        } else {
            // Create new agent
            agent = Agent.from(registration: message, name: agentName)
            agent.status = .online
        }

        // Persisted so sync assembly (which may run on any replica, from
        // Postgres alone) can key version-dependent shapes on what this agent
        // actually speaks — see `networkAssemblyScope`.
        agent.wireProtocolVersion = protocolVersion

        if let siteID {
            // Never move a site's designated network controller by token
            // redemption: the old site would be left pointing at a non-member
            // and its networks would silently stop being reconciled. The move
            // must go through the sites API, which re-designates first. (A
            // brand-new agent row has no id yet and can't hold a designation.)
            var orphansControllership = false
            if let agentID = agent.id {
                orphansControllership =
                    try await Site.query(on: db)
                    .filter(\.$networkControllerAgent.$id == agentID)
                    .filter(\.$id != siteID)
                    .count() > 0
            }
            if orphansControllership {
                app.logger.error(
                    "Ignoring registration-token site assignment: agent is another site's network controller",
                    metadata: ["agentName": .string(agentName), "requestedSite": .string(siteID.uuidString)])
            } else {
                agent.$site.id = siteID
            }
        }

        try await agent.save(on: db)

        guard let agentUUID = agent.id else {
            throw AgentServiceError.invalidResponse("Failed to get agent ID after save")
        }

        // Attach the UUID to the live socket so local routing (sync pushes,
        // RPC forwarding, the periodic sync's work list) can resolve it
        // without a database read. No-op when no socket exists (tests).
        app.websocketManager.associate(agentName: agentName, agentId: agentUUID.uuidString)

        // Publish liveness and socket location to the coordination store so
        // every control-plane process — not just the one holding this socket —
        // can see the agent and route mutations to it.
        await app.coordination.recordAgentPresence(agentName: agentName)
        await app.coordination.recordAgentRoute(agentName: agentName, replicaId: app.replicaID)

        Telemetry.agentConnected()
        Telemetry.recordAgentUp(agentName: agentName, up: true)
        app.logger.info(
            "Agent registered",
            metadata: [
                "agentId": .string(agentUUID.uuidString),
                "agentName": .string(agentName),
                "hostname": .string(message.hostname),
                "version": .string(message.version),
            ])

        return agentUUID
    }

    /// Resolve an agent's database UUID from its name: the local socket's
    /// registration first (no I/O), the database otherwise.
    private func agentId(forName agentName: String) async -> String? {
        if let local = app.websocketManager.agentId(agentName: agentName) {
            return local
        }
        let agent = try? await Agent.query(on: app.db)
            .filter(\.$name == agentName)
            .first()
        return agent?.id?.uuidString
    }

    /// Resolve an agent's name from its database UUID: the local socket's
    /// registration first (no I/O), the database otherwise.
    private func agentName(forId agentId: String) async -> String? {
        if let local = app.websocketManager.agentName(agentId: agentId) {
            return local
        }
        guard let agentUUID = UUID(uuidString: agentId) else { return nil }
        let agent = try? await Agent.find(agentUUID, on: app.db)
        return agent?.name
    }

    func unregisterAgent(_ agentId: String) async throws {
        let db = app.db

        // Update database using UUID
        var agentName: String?
        if let agentUUID = UUID(uuidString: agentId),
            let agent = try await Agent.find(agentUUID, on: db)
        {
            agent.status = .offline
            try await agent.save(on: db)
            agentName = agent.name
        }

        // Fail any in-flight requests waiting on this agent before we drop it
        failPendingRequests(for: agentId)

        if let name = agentName {
            app.websocketManager.removeConnection(agentName: name)
            await app.coordination.clearAgentRoute(agentName: name, replicaId: app.replicaID)
        }

        Telemetry.agentDisconnected(reason: "unregister")
        if let name = agentName {
            Telemetry.recordAgentUp(agentName: name, up: false)
        }
        app.logger.info("Agent unregistered", metadata: ["agentId": .string(agentId)])
    }

    func forceUnregisterAgent(_ agentName: String) async {
        guard let agentId = await agentId(forName: agentName) else {
            app.logger.warning(
                "Cannot force unregister: agent not found by name", metadata: ["agentName": .string(agentName)])
            return
        }

        // Fail any in-flight requests waiting on this agent before we drop it
        failPendingRequests(for: agentId)

        app.websocketManager.removeConnection(agentName: agentName)
        await app.coordination.clearAgentRoute(agentName: agentName, replicaId: app.replicaID)

        app.logger.info(
            "Agent force unregistered",
            metadata: ["agentId": .string(agentId), "agentName": .string(agentName)])
    }

    /// Socket-close cleanup. The agent may have already reconnected to another
    /// replica: its route key then names that replica, and this (delayed)
    /// close must not mark the agent offline underneath a live connection.
    func removeAgent(_ agentName: String) async {
        // Local pending requests die with the local socket regardless of
        // where the agent lives now.
        if let agentId = await agentId(forName: agentName) {
            failPendingRequests(for: agentId)
        }

        if let route = await app.coordination.agentRoute(agentName: agentName),
            route != app.replicaID
        {
            app.logger.debug(
                "Agent socket closed here but agent is routed to another replica; skipping offline mark",
                metadata: ["agentName": .string(agentName)])
            return
        }

        await app.coordination.clearAgentRoute(agentName: agentName, replicaId: app.replicaID)

        Telemetry.agentDisconnected(reason: "connection_closed")
        Telemetry.recordAgentUp(agentName: agentName, up: false)

        // Update database status asynchronously
        Task {
            do {
                let db = self.app.db
                if let agent = try await Agent.query(on: db)
                    .filter(\.$name == agentName)
                    .first()
                {
                    agent.status = .offline
                    try await agent.save(on: db)
                }
            } catch {
                self.app.logger.error("Failed to update agent offline status in database: \(error)")
            }
        }
    }

    /// `agentName` identifies the authenticated connection the heartbeat arrived on;
    /// the claimed `agentId` must belong to it, so one agent cannot drive another
    /// agent's resource tracking or VM reconciliation.
    func updateAgentHeartbeat(_ message: AgentHeartbeatMessage, fromAgentNamed agentName: String) async throws {
        let db = app.db
        guard let agentUUID = UUID(uuidString: message.agentId),
            let agent = try await Agent.find(agentUUID, on: db)
        else {
            app.logger.warning("Received heartbeat from unknown agent", metadata: ["agentId": .string(message.agentId)])
            return
        }

        guard agent.name == agentName else {
            app.logger.warning(
                "Heartbeat claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "claimedAgentId": .string(message.agentId),
                    "claimedAgentName": .string(agent.name),
                    "connectionAgentName": .string(agentName),
                ])
            return
        }

        // The database row is the registry (issue #261): the scheduler and
        // every other replica read resources and liveness from here, so the
        // write is awaited, not fire-and-forget.
        agent.updateResources(message.resources)
        agent.status = .online
        try await agent.save(on: db)

        // Refresh the agent's presence and socket-route keys so liveness and
        // routing stay visible cluster-wide. The heartbeat arrived over this
        // process's socket, so the route is ours to claim.
        await app.coordination.recordAgentPresence(agentName: agentName)
        await app.coordination.recordAgentRoute(agentName: agentName, replicaId: app.replicaID)

        // This heartbeat's resource report accounts for every VM the agent
        // lists, so any placement reservation still held for one of them
        // would double-count from now until its TTL — release them. This is
        // the release path for successful creates (the dispatch is
        // fire-and-forget, so no correlated response ever arrives).
        await app.coordination.releaseReservations(agentId: message.agentId, vmIds: message.runningVMs)

        // Reconcile the VMs the agent reports against what the database expects.
        Task {
            await self.reconcileVMs(forAgentId: message.agentId, reportedVMs: message.runningVMs)
        }

        app.logger.debug("Agent heartbeat updated", metadata: ["agentId": .string(message.agentId)])
    }

    /// Reconciles an agent's reported set of managed VMs against the database.
    ///
    /// An agent's heartbeat lists every VM it is managing (running, paused, or
    /// shut-down-but-not-deleted). If the database believes a VM lives on this agent
    /// but the agent no longer reports it — e.g. the agent crashed and lost the VM,
    /// or the process died — the database's view is stale and we mark the VM `.error`
    /// so it surfaces for operator attention instead of appearing healthy.
    private func reconcileVMs(forAgentId agentId: String, reportedVMs: [String]) async {
        let db = app.db
        let managed = Set(reportedVMs)

        do {
            let dbVMs = try await VM.query(on: db)
                .filter(\.$hypervisorId == agentId)
                .all()

            var divergent = 0
            for vm in dbVMs {
                guard let vmId = vm.id?.uuidString else { continue }

                // Only established states are safe to reconcile on absence:
                //  - `.created` may still be mid-creation (image download / first boot)
                //  - transitional and `.error`/`.unknown` states are handled by the sweep
                // so an absent VM in those states is expected and left alone.
                // `.shutdown` counts as established: agents keep shut-down-but-not-deleted
                // VMs in their managed set, so one missing from the heartbeat was lost
                // (e.g. agent restart) and a later start would fail with vmNotFound.
                guard vm.status.assertsAgentPresence, !managed.contains(vmId) else { continue }

                let previous = vm.status
                vm.setStatus(.error)
                try await vm.save(on: db)
                divergent += 1
                Telemetry.vmEnteredError(reason: "reconciliation")

                app.logger.warning(
                    "VM missing from agent heartbeat; marking as error",
                    metadata: [
                        "vmId": .string(vmId),
                        "agentId": .string(agentId),
                        "previousStatus": .string(previous.rawValue),
                    ])
            }

            // Orphans: VMs the agent reports that the database does not map to it.
            let knownIds = Set(dbVMs.compactMap { $0.id?.uuidString })
            let orphans = managed.subtracting(knownIds)
            if !orphans.isEmpty {
                app.logger.warning(
                    "Agent reports VMs unknown to control plane",
                    metadata: [
                        "agentId": .string(agentId),
                        "orphanVMs": .string(orphans.sorted().joined(separator: ",")),
                    ])
            }

            if divergent > 0 {
                app.logger.info(
                    "Reconciliation marked \(divergent) VM(s) as error", metadata: ["agentId": .string(agentId)])
            }
        } catch {
            app.logger.error("VM reconciliation failed for agent \(agentId): \(error)")
        }
    }

    // MARK: - Heartbeat Monitoring

    /// Whether the heartbeat loop is currently armed. Test seam for verifying that
    /// the shutdown hook tears it down.
    var isHeartbeatActive: Bool {
        heartbeatTask != nil
    }

    private func startHeartbeatMonitoring() {
        // Don't (re)arm the loop if shutdown already raced ahead of init.
        guard !isShutDown else { return }
        heartbeatTask = Task {
            var tick = 0
            while !Task.isCancelled {
                do {
                    // Sleep for 30 seconds
                    try await Task.sleep(for: .seconds(30))
                    tick &+= 1

                    // Check for stale agents
                    await checkStaleAgents()

                    // Probe (and re-arm if dead) this replica's pub/sub
                    // subscriptions — a dropped Valkey connection loses them
                    // silently and RediStack does not restore them.
                    await verifyReplicaSubscriptions()

                    // Periodic desired-state sync (~60s): the correctness
                    // backstop of the level-triggered design — a dropped or
                    // failed sync is repaired here, so pushes on mutation are
                    // purely a latency optimization (issue #260). Not a
                    // cluster singleton: syncs go over this process's sockets.
                    if tick.isMultiple(of: 2) {
                        await syncDesiredStateToAllAgents()
                    }

                    // Fail operations stuck pending past their budget and resolve
                    // VMs stuck in a transitional state
                    await sweepStuckOperations()
                } catch {
                    if !Task.isCancelled {
                        app.logger.error("Error in heartbeat monitoring task: \(error)")
                    }
                }
            }
        }
    }

    private func checkStaleAgents() async {
        let now = Date()
        let staleThreshold: TimeInterval = 60  // 60 seconds

        do {
            let onlineAgents = try await Agent.query(on: app.db)
                .filter(\.$status == .online)
                .all()

            // Export per-agent heartbeat staleness as a gauge every cycle so
            // alerting can watch an agent go quiet before the sweep removes
            // it. Every heartbeat lands in the database regardless of which
            // replica received it, so `last_heartbeat` is the cluster view.
            for agent in onlineAgents {
                guard let lastHeartbeat = agent.lastHeartbeat else { continue }
                Telemetry.recordHeartbeatStaleness(
                    agentName: agent.name,
                    seconds: now.timeIntervalSince(lastHeartbeat)
                )
            }

            // Not gated on a sweep lock even though the state is shared:
            // in-flight requests on this process's sockets can only be failed
            // here, the offline write is idempotent, and the presence check
            // keeps replicas from disagreeing — an agent heartbeating through
            // any replica keeps a live presence key and is skipped.
            for agent in onlineAgents {
                let heartbeatAge = agent.lastHeartbeat.map { now.timeIntervalSince($0) } ?? .infinity
                guard heartbeatAge > staleThreshold else { continue }

                // A live presence key means *some* replica is hearing from
                // the agent even though the row hasn't been touched — e.g. a
                // write raced this read. When the store can't answer, fall
                // back to the heartbeat-age verdict alone.
                if await app.coordination.isAgentPresent(agentName: agent.name) == true {
                    app.logger.debug(
                        "Agent heartbeat is stale in the database but presence key is live; skipping",
                        metadata: ["agentName": .string(agent.name)])
                    continue
                }

                if let agentId = agent.id?.uuidString {
                    failPendingRequests(for: agentId)
                }

                agent.status = .offline
                try await agent.save(on: app.db)

                Telemetry.agentDisconnected(reason: "stale")
                Telemetry.recordAgentUp(agentName: agent.name, up: false)
                app.logger.info(
                    "Agent heartbeat stale past threshold; marked offline",
                    metadata: ["agentName": .string(agent.name)])
            }
        } catch {
            app.logger.error("Stale-agent sweep failed: \(error)")
        }
    }

    /// Fails operations stuck `pending` past their per-kind budget and resolves the
    /// affected VM's in-flight status (issue #259). This is the restart backstop:
    /// while the dispatching process lives, the awaited agent response (or its
    /// timeout) completes the operation; after a crash, only this sweep does.
    /// It also broadens the old stuck-VM sweep — transitional VMs with no pending
    /// operation (e.g. a lost statusUpdate after a completed operation) still
    /// resolve to `.error`.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepStuckOperations() async {
        // Cluster-singleton: with multiple replicas, only one may sweep per interval.
        guard await app.coordination.acquireSweepLock("stuck_operations") else {
            app.logger.debug("Skipping stuck-operation sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = Date()

        do {
            let pending = try await VMOperation.query(on: db)
                .filter(\.$status == .pending)
                .all()

            for operation in pending {
                // A missing creation timestamp yields age 0 and is left for a
                // later sweep (it is set on insert, so this is a safety net).
                let age = now.timeIntervalSince(operation.createdAt ?? now)
                let budget = operation.kind.completionBudgetSeconds
                guard age > budget else { continue }

                guard
                    try await operation.completeIfPending(
                        as: .failed,
                        error: "Operation timed out: no completion after \(Int(budget))s",
                        on: db
                    )
                else { continue }

                // Resolve the VM state the operation left in flight. `.created`
                // only counts as stuck for a create — for every other kind it is
                // a legitimate resting state.
                if let vm = try await VM.find(operation.vmID, on: db) {
                    var changed = false
                    if vm.status.isTransitional || (operation.kind == .create && vm.status == .created) {
                        vm.setStatus(.error)
                        changed = true
                        Telemetry.vmEnteredError(reason: "stuck_operation")
                    }
                    // The operation failed: realign desired state with observed
                    // reality so the unachieved intent (e.g. a delete's
                    // `.absent`) doesn't linger and replay destructively on a
                    // later sync or protocol upgrade (issue #260).
                    if vm.revertDesiredToObserved() {
                        changed = true
                    }
                    if changed {
                        try await vm.save(on: db)
                    }
                }

                app.logger.warning(
                    "Operation stuck pending past budget; marking as failed",
                    metadata: [
                        "operationId": .string(operation.id?.uuidString ?? ""),
                        "vmId": .string(operation.vmID.uuidString),
                        "kind": .string(operation.kind.rawValue),
                        "budgetSeconds": .string("\(Int(budget))"),
                    ])
            }

            // Transitional VMs with no pending operation: the operation completed
            // (or predates the operations table) but the confirming statusUpdate
            // never landed. Same 120s timeout as the old stuck-VM sweep.
            let timeout: TimeInterval = 120
            let transitional = try await VM.query(on: db)
                .filter(\.$status ~~ [.starting, .stopping])
                .all()

            for vm in transitional {
                let changedAt = vm.statusChangedAt ?? vm.updatedAt ?? now
                guard now.timeIntervalSince(changedAt) > timeout, let vmID = vm.id else { continue }

                let hasPendingOperation =
                    try await VMOperation.query(on: db)
                    .filter(\.$vmID == vmID)
                    .filter(\.$status == .pending)
                    .count() > 0
                // A pending operation owns this VM's resolution via its own budget.
                guard !hasPendingOperation else { continue }

                let previous = vm.status
                vm.setStatus(.error)
                try await vm.save(on: db)
                Telemetry.vmEnteredError(reason: "stuck_transition")

                app.logger.warning(
                    "VM stuck in transitional state past timeout; marking as error",
                    metadata: [
                        "vmId": .string(vmID.uuidString),
                        "stuckStatus": .string(previous.rawValue),
                        "timeoutSeconds": .string("\(Int(timeout))"),
                    ])
            }
        } catch {
            app.logger.error("Stuck-operation sweep failed: \(error)")
        }
    }

    // MARK: - Desired-state sync (issues #260, #261)

    /// Push the authoritative desired state to every registered agent whose
    /// socket this process holds. Called on the periodic timer; failures are
    /// logged and repaired by the next tick. Each replica syncs exactly its
    /// own sockets, so no cluster coordination is needed here.
    func syncDesiredStateToAllAgents() async {
        for (name, agentId) in app.websocketManager.registeredAgents() {
            await syncDesiredStateLocally(agentId: agentId, agentName: name)
        }
    }

    /// Trigger a desired-state sync for an agent from any replica. When this
    /// process holds the agent's socket the sync is assembled and pushed
    /// directly (the local short-circuit); otherwise the replica named by the
    /// routing key is nudged over pub/sub and assembles it from Postgres
    /// there. Both halves are latency optimizations — a lost nudge is
    /// repaired by the holder's periodic sync timer.
    ///
    /// A mutation on one agent can change what its site's network controller
    /// must realize (a VM landing on any site node may reference a network
    /// the shared NB doesn't have yet), so the controller is synced alongside.
    func syncDesiredState(agentId: String) async {
        await routeDesiredStateSync(agentId: agentId)
        if let controllerId = await siteNetworkControllerID(forAgentId: agentId), controllerId != agentId {
            await routeDesiredStateSync(agentId: controllerId)
        }
    }

    /// The agent id of the site network controller responsible for the given
    /// agent's networks, or nil for site-less agents / unconfigured sites.
    /// Best-effort: on lookup failure the periodic sync timer still converges
    /// the controller.
    private func siteNetworkControllerID(forAgentId agentId: String) async -> String? {
        guard let agentUUID = UUID(uuidString: agentId) else { return nil }
        do {
            guard let agent = try await Agent.find(agentUUID, on: app.db),
                let siteID = agent.$site.id,
                let site = try await Site.find(siteID, on: app.db)
            else { return nil }
            return site.$networkControllerAgent.id?.uuidString
        } catch {
            app.logger.debug("Site controller lookup failed: \(error)")
            return nil
        }
    }

    private func routeDesiredStateSync(agentId: String) async {
        if let localName = app.websocketManager.agentName(agentId: agentId) {
            await syncDesiredStateLocally(agentId: agentId, agentName: localName)
            return
        }

        guard let name = await agentName(forId: agentId) else {
            app.logger.warning(
                "Cannot route sync for unknown agent", metadata: ["agentId": .string(agentId)])
            return
        }

        guard let route = await app.coordination.agentRoute(agentName: name) else {
            // No route: the agent is offline everywhere. The sync it missed
            // is delivered by the registration-triggered sync on reconnect.
            app.logger.debug(
                "No socket route for agent; sync deferred to reconnect",
                metadata: ["agentName": .string(name)])
            return
        }

        if route == app.replicaID {
            // The route says us, but no local socket exists — a connection
            // torn down before its route expired. The reconnect sync (or the
            // holder's periodic timer, wherever the agent lands) is the
            // backstop; nudging ourselves would find the same missing socket.
            return
        }

        await app.coordination.publishNudge(agentName: name, toReplica: route)
    }

    /// Assemble and send the full desired-state sync over a locally held
    /// socket. Safe to call redundantly: identical syncs diff to nothing on
    /// the agent.
    private func syncDesiredStateLocally(agentId: String, agentName: String) async {
        do {
            let message = try await assembleDesiredState(agentId: agentId)
            try await sendMessageToLocalAgent(message, agentName: agentName)
            app.logger.debug(
                "Desired-state sync sent",
                metadata: [
                    "agentId": .string(agentId),
                    "syncId": .string(message.syncId),
                    "vmCount": .stringConvertible(message.vms.count),
                ])
        } catch {
            // Dropped syncs are safe: the periodic timer re-sends the full
            // state, so this is logged rather than retried inline.
            app.logger.warning(
                "Failed to send desired-state sync (periodic timer will retry)",
                metadata: [
                    "agentId": .string(agentId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    // MARK: - Replica pub/sub (issue #261)

    /// Sentinel published to our own nudge channel to verify the subscription
    /// connection is alive. Cannot collide with a real nudge: nudges carry
    /// agent names, and a leading NUL is not a legal agent name.
    static let subscriptionProbeMessage = "\u{0}subscription-probe"

    /// Subscribe to this replica's nudge and RPC channels. Called from init
    /// and re-armed by `verifyReplicaSubscriptions()`; failure is logged and
    /// fails open — the replica misses nudge latency (its periodic timer
    /// still converges its own agents) and cannot serve cross-replica
    /// exchanges, but stays available.
    ///
    /// Safe to call repeatedly: RediStack replaces the receiver when the
    /// channel is already subscribed on a live connection, and leases a fresh
    /// pub/sub connection when the previous one died.
    private func startReplicaSubscriptions() async {
        guard !isShutDown else { return }
        let replicaId = app.replicaID
        do {
            try await app.coordination.subscribe(
                channel: CoordinationService.nudgeChannel(replicaId: replicaId)
            ) { [weak self] agentName in
                Task { await self?.handleNudge(agentName: agentName) }
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
    /// hear, failing every cross-replica exchange by timeout. So each
    /// heartbeat tick publishes a probe to our own nudge channel; a probe
    /// that hasn't come back by the next tick means the subscription
    /// connection is dead, and everything is re-armed. Runs on the 30s
    /// heartbeat tick, bounding the silent window to about two ticks.
    func verifyReplicaSubscriptions() async {
        guard !isShutDown else { return }

        if !subscriptionsEstablished {
            // The initial subscribe failed; keep retrying from here.
            await startReplicaSubscriptions()
        } else if let sent = lastProbeSent,
            (lastProbeReceived ?? .distantPast) < sent,
            Date().timeIntervalSince(sent) > 20
        {
            // The previous tick's probe never arrived: the subscription
            // connection is dead even though publishes still work.
            app.logger.warning(
                "Replica subscription probe was not received; re-establishing channel subscriptions",
                metadata: ["replicaId": .string(app.replicaID)])
            await startReplicaSubscriptions()
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
    /// If we (still) hold its socket, push a fresh sync; if not, the nudge
    /// raced a disconnect and the periodic timer wherever the agent lands is
    /// the backstop.
    func handleNudge(agentName: String) async {
        if agentName == Self.subscriptionProbeMessage {
            lastProbeReceived = Date()
            return
        }
        guard let agentId = app.websocketManager.agentId(agentName: agentName) else {
            app.logger.debug(
                "Nudge for agent without a local socket; ignoring",
                metadata: ["agentName": .string(agentName)])
            return
        }
        await syncDesiredStateLocally(agentId: agentId, agentName: agentName)
    }

    /// The full authoritative VM set for an agent, straight from Postgres —
    /// no in-memory VM-to-agent map involved. Signed image URLs are re-issued
    /// on every assembly so long-desired VMs never carry expired links.
    /// Internal rather than private so tests can assert assembly contents.
    func assembleDesiredState(agentId: String) async throws -> DesiredStateMessage {
        let db = app.db
        let vms = try await VM.query(on: db)
            .filter(\.$hypervisorId == agentId)
            .with(\.$volumes)
            .with(\.$networkInterfaces)
            // Artifacts loaded too so buildImageInfo emits the typed artifact
            // set (kernel/rootfs distribution, issue #214) rather than the
            // legacy single-file fallback.
            .with(\.$sourceImage) { image in
                image.with(\.$artifacts)
            }
            .all()

        // DHCP/DNS config the agent programs into OVN lives on the logical
        // network, not the NIC row, so fetch the networks once and index by name
        // for the spec builder. Few rows; a full scan is cheaper than per-VM
        // lookups.
        let networksByName = try await Dictionary(
            LogicalNetwork.query(on: db).all().map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var entries: [DesiredVMState] = []
        for vm in vms {
            guard let vmId = vm.id else { continue }
            let image = vm.sourceImage
            let spec = VMSpecBuilder.buildVMSpecWithVolumes(
                from: vm,
                image: image,
                volumes: vm.volumes,
                networkInterfaces: vm.networkInterfaces,
                networks: networksByName
            )

            // Image download info lets the agent materialize a VM it doesn't
            // have yet. Best effort: a VM whose image is missing/not-ready can
            // still be synced for status changes on its existing disks — but
            // loudly, because for a not-yet-created VM a nil imageInfo means
            // the agent will refuse the diskless create and fail the pending
            // operation with that reason.
            var imageInfo: ImageInfo?
            if let image, image.status == .ready {
                do {
                    let controlPlaneURL = Environment.get("CONTROL_PLANE_URL") ?? "http://localhost:8080"
                    imageInfo = try VMSpecBuilder.buildImageInfo(
                        from: image,
                        controlPlaneURL: controlPlaneURL,
                        agentName: agentId,
                        signingKey: URLSigningService.getSigningKey(from: app)
                    )
                } catch {
                    app.logger.warning(
                        "Failed to build image info for desired-state sync",
                        metadata: [
                            "vmId": .string(vmId.uuidString),
                            "imageId": .string(image.id?.uuidString ?? ""),
                            "error": .string(error.localizedDescription),
                        ])
                }
            } else if vm.$sourceImage.id != nil {
                app.logger.warning(
                    "VM references an image that is missing or not ready; syncing without image info",
                    metadata: ["vmId": .string(vmId.uuidString)])
            }

            entries.append(
                DesiredVMState(
                    vmId: vmId,
                    hypervisorType: vm.hypervisorType,
                    spec: spec,
                    desiredStatus: vm.desiredStatus,
                    generation: vm.generation,
                    imageInfo: imageInfo
                ))
        }

        // First-class network desired state (issue #342): the logical networks
        // the agent should realize as level-triggered desired state (switches,
        // per-project routers, SNAT uplinks). Which networks — and whether this
        // agent may write topology at all — depends on its site membership
        // (issue #343); see `networkAssemblyScope`.
        let scope = try await networkAssemblyScope(agentId: agentId, ownVMs: vms, on: db)
        let networkStates =
            scope.networkNames
            .sorted()
            .compactMap { name -> DesiredNetworkState? in
                guard let network = networksByName[name], let networkId = network.id else { return nil }
                return DesiredNetworkState(
                    networkId: networkId,
                    name: network.name,
                    subnet: network.subnet,
                    gateway: network.gateway,
                    routerKey: network.routerKey,
                    externalAccess: network.externalAccess,
                    generation: Int64(network.generation)
                )
            }

        return DesiredStateMessage(
            vms: entries, networks: networkStates, networksAuthoritative: scope.authoritative)
    }

    /// Which networks an agent's sync should carry, and whether the agent is
    /// the topology authority for the NB it writes to (issue #343).
    ///
    /// - Site-less agent (legacy single-node model): it owns a private local
    ///   NB, so it is always authoritative, scoped to the networks its own
    ///   VMs reference — a network with no VM on the host needn't exist there.
    /// - Sited agent designated as the site's network controller: the whole
    ///   site shares one NB and this agent is its single topology writer, so
    ///   it gets every network referenced by any VM in the site plus every
    ///   network pinned to the site (pinned-but-unused networks are realized
    ///   ahead of their first VM).
    /// - Any other sited agent: non-authoritative and empty. It still binds
    ///   its own VMs' ports to the shared NB, but topology belongs to the
    ///   controller — two level-triggered writers would fight over teardown.
    private func networkAssemblyScope(
        agentId: String, ownVMs: [VM], on db: any Database
    ) async throws -> (networkNames: Set<String>, authoritative: Bool) {
        let ownReferences = Set(ownVMs.flatMap { $0.networkInterfaces.map(\.network) })

        guard let agentUUID = UUID(uuidString: agentId),
            let agent = try await Agent.find(agentUUID, on: db),
            let siteID = agent.$site.id,
            let site = try await Site.find(siteID, on: db)
        else {
            return (ownReferences, true)
        }

        // A pre-v4 agent doesn't know `networksAuthoritative` and would read
        // the non-authoritative shape (networks: [] + false) as an
        // authoritative teardown of its whole L3 topology. Keep it on the
        // legacy per-node scoping — its binary predates `ovn_northbound`, so
        // it is writing its own local NB anyway, not the site's shared one.
        guard WireProtocol.supportsSiteAuthority(agent.wireProtocolVersion ?? 0) else {
            app.logger.warning(
                "Sited agent registered with a pre-site-authority protocol; syncing legacy per-node networks",
                metadata: [
                    "agentName": .string(agent.name),
                    "site": .string(site.name),
                    "protocolVersion": .stringConvertible(agent.wireProtocolVersion ?? 0),
                ])
            return (ownReferences, true)
        }

        guard let controllerID = site.$networkControllerAgent.id else {
            // No designated controller: nobody may author topology, so the
            // site's networks are realized nowhere until one is set. Loud —
            // this is a misconfiguration, not a transient.
            app.logger.warning(
                "Site has no network controller; its networks will not be reconciled",
                metadata: ["site": .string(site.name), "agentName": .string(agent.name)])
            return ([], false)
        }
        guard controllerID == agentUUID else {
            return ([], false)
        }

        let siteAgentIDs = try await Agent.query(on: db)
            .filter(\.$site.$id == siteID)
            .all()
            .compactMap { $0.id?.uuidString }
        let siteVMs = try await VM.query(on: db)
            .filter(\.$hypervisorId ~~ siteAgentIDs)
            .with(\.$networkInterfaces)
            .all()
        var names = Set(siteVMs.flatMap { $0.networkInterfaces.map(\.network) })
        let pinned = try await LogicalNetwork.query(on: db)
            .filter(\.$site.$id == siteID)
            .all()
        names.formUnion(pinned.map(\.name))
        return (names, true)
    }

    // MARK: - Observed-state reports (issue #260)

    /// Tail of the per-agent report-application chain (keyed by agent name)
    /// plus the id that identifies it, so a finished chain link only retires
    /// its own bookkeeping.
    private var reportTails: [String: (id: UInt64, task: Task<Void, Never>)] = [:]
    private var nextReportTailId: UInt64 = 0

    /// Serialize observed-state report application per agent. `applyObserved-
    /// StateReport` suspends repeatedly (coordination store, per-VM database
    /// writes), so applying each report in an independent task would let actor
    /// reentrancy interleave two reports from the same agent — and a stale
    /// report finishing last could flip `vm.status` backwards and fire
    /// spurious drift telemetry. Chaining on the previous report preserves the
    /// agent's own send order.
    func enqueueObservedStateReport(_ envelope: MessageEnvelope, fromAgentNamed agentName: String) {
        nextReportTailId &+= 1
        let id = nextReportTailId
        let predecessor = reportTails[agentName]?.task
        let task = Task { [weak self] in
            await predecessor?.value
            await self?.applyObservedStateReport(envelope, fromAgentNamed: agentName)
            await self?.retireReportTail(agentName: agentName, id: id)
        }
        reportTails[agentName] = (id, task)
    }

    /// Drop the chain bookkeeping once the finishing link is still the tail,
    /// so idle agents don't pin their last report task forever.
    private func retireReportTail(agentName: String, id: UInt64) {
        if reportTails[agentName]?.id == id {
            reportTails.removeValue(forKey: agentName)
        }
    }

    /// Apply an agent's full observed-state report: update observed status and
    /// generation, complete pending operations whose target state is now
    /// observed, confirm deletions by absence, and surface drift.
    ///
    /// `agentName` identifies the authenticated connection, mirroring the
    /// heartbeat's ownership check. Callers outside tests should go through
    /// `enqueueObservedStateReport` so same-agent reports apply in order.
    func applyObservedStateReport(_ envelope: MessageEnvelope, fromAgentNamed agentName: String) async {
        let report: ObservedStateReport
        do {
            report = try envelope.decode(as: ObservedStateReport.self)
        } catch {
            app.logger.error("Failed to decode observed-state report: \(error)")
            return
        }

        guard let agentUUID = UUID(uuidString: report.agentId),
            let agent = try? await Agent.find(agentUUID, on: app.db)
        else {
            app.logger.warning(
                "Observed-state report from unknown agent", metadata: ["agentId": .string(report.agentId)])
            return
        }
        guard agent.name == agentName else {
            app.logger.warning(
                "Observed-state report claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "claimedAgentId": .string(report.agentId),
                    "connectionAgentName": .string(agentName),
                ])
            return
        }

        // Reports carry the same resource snapshot as heartbeats; keep the
        // scheduler's view fresh from whichever arrives.
        agent.updateResources(report.resources)
        agent.status = .online
        do {
            try await agent.save(on: app.db)
        } catch {
            app.logger.warning(
                "Failed to persist agent resources from observed-state report: \(error)",
                metadata: ["agentId": .string(report.agentId)])
        }

        // The report arrived over this process's socket: refresh liveness and
        // routing alongside, mirroring the heartbeat path.
        await app.coordination.recordAgentPresence(agentName: agentName)
        await app.coordination.recordAgentRoute(agentName: agentName, replicaId: app.replicaID)

        // Every reported VM is accounted for in the agent's resource figures,
        // so any placement reservation still held for one would double-count.
        await app.coordination.releaseReservations(
            agentId: report.agentId, vmIds: report.vms.map { $0.vmId.uuidString })

        do {
            try await applyReportToDatabase(report)
        } catch {
            app.logger.error(
                "Failed to apply observed-state report: \(error)",
                metadata: ["agentId": .string(report.agentId)])
        }
    }

    private func applyReportToDatabase(_ report: ObservedStateReport) async throws {
        let db = app.db
        let reported = Dictionary(
            report.vms.map { ($0.vmId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let dbVMs = try await VM.query(on: db)
            .filter(\.$hypervisorId == report.agentId)
            .all()

        for vm in dbVMs {
            guard let vmID = vm.id else { continue }
            if let observed = reported[vmID] {
                try await applyObservedVMState(vm: vm, observed: observed, on: db)
            } else {
                try await handleReportedAbsence(vm: vm, agentId: report.agentId, on: db)
            }
        }
    }

    /// Apply one settled (or failing) observation to its VM row and resolve
    /// any pending operation it satisfies.
    private func applyObservedVMState(vm: VM, observed: ObservedVMState, on db: Database) async throws {
        let vmID = try vm.requireID()

        // Still converging: progress only. The status is not settled, so it
        // must not overwrite the row or complete operations.
        if observed.convergencePhase != nil {
            app.logger.debug(
                "VM converging on agent",
                metadata: [
                    "vmId": .string(vmID.uuidString),
                    "phase": .string(observed.convergencePhase ?? ""),
                    "targetGeneration": .stringConvertible(vm.generation),
                ])
            return
        }

        let pendingOperation = try await VMOperation.query(on: db)
            .filter(\.$vmID == vmID)
            .filter(\.$status == .pending)
            .first()

        var changed = false
        if observed.observedGeneration > vm.observedGeneration {
            vm.observedGeneration = observed.observedGeneration
            changed = true
        }

        if vm.status != observed.status, observed.status != .unknown || vm.status.isTransitional {
            let previous = vm.status
            vm.setStatus(observed.status)
            changed = true

            // Drift telemetry: an out-of-band change (no operation in flight
            // asked for anything) means agent reality moved on its own — e.g.
            // a guest powered itself off, or someone paused it over QMP.
            if pendingOperation == nil, !previous.isTransitional {
                app.logger.warning(
                    "VM state drifted without a pending operation",
                    metadata: [
                        "vmId": .string(vmID.uuidString),
                        "previousStatus": .string(previous.rawValue),
                        "observedStatus": .string(observed.status.rawValue),
                    ])
                Telemetry.vmDriftDetected()
            }
        }
        if changed {
            try await vm.save(on: db)
        }

        guard let operation = pendingOperation else { return }

        // Deletions complete by absence from the report, never by a status.
        if operation.kind == .delete || vm.desiredStatus == .absent {
            return
        }

        if observed.observedGeneration >= vm.generation, vm.desiredStatus.isSatisfied(by: observed.status) {
            // The agent converged to the current generation and the observed
            // status satisfies the desired one: the operation reached its goal.
            _ = try await operation.completeIfPending(as: .succeeded, error: nil, on: db)
        } else if let lastError = observed.lastError, observed.failedGeneration == vm.generation {
            // The agent tried to converge to *this* generation and failed —
            // the failedGeneration match is what distinguishes that from a
            // stale error still carried on heartbeats while a newer operation
            // waits for its first attempt. Fail the operation with the real
            // reason instead of waiting out its completion budget.
            if try await operation.completeIfPending(as: .failed, error: lastError, on: db) {
                var failedChanged = false
                if observed.status == .unknown {
                    // The VM has no settled presence on the agent (e.g. the
                    // create never got off the ground) — surface it as error
                    // rather than leaving a healthy-looking resting state.
                    vm.setStatus(.error)
                    failedChanged = true
                    Telemetry.vmEnteredError(reason: "convergence_failed")
                }
                // The intent was not achieved and the user has been told: stop
                // pursuing it. Realigning desired with observed keeps a failed
                // operation from leaving latent divergence that a later sync
                // (or the reconciler's next generation) would replay.
                if vm.revertDesiredToObserved() {
                    failedChanged = true
                }
                if failedChanged {
                    try await vm.save(on: db)
                }
            }
        }
    }

    /// A VM the database maps to this agent is absent from its full report:
    /// either a confirmed deletion (desired absent) or genuine loss.
    private func handleReportedAbsence(vm: VM, agentId: String, on db: Database) async throws {
        let vmID = try vm.requireID()

        if vm.desiredStatus == .absent {
            // Deletion confirmed. Complete the operation first, then remove
            // the row: if we crash in between, the next report retries the
            // (idempotent) removal, whereas removing first would leave a
            // pending operation with nothing to resolve it but the sweep.
            if let operation = try await VMOperation.query(on: db)
                .filter(\.$vmID == vmID)
                .filter(\.$status == .pending)
                .first()
            {
                _ = try await operation.completeIfPending(as: .succeeded, error: nil, on: db)
            }

            try await db.transaction { db in
                try await vm.delete(on: db)
                try await QuotaEnforcementService.release(for: vm, on: db)
            }
            await app.coordination.releaseReservation(agentId: agentId, vmId: vmID.uuidString)

            app.logger.info(
                "VM deletion confirmed by agent report; record removed",
                metadata: ["vmId": .string(vmID.uuidString), "agentId": .string(agentId)])
            return
        }

        // Same established-state rule as the heartbeat reconciliation: only
        // states that assert live agent presence are safe to escalate on
        // absence. (`.created` may be mid-create on an agent that hasn't
        // received the sync yet.) The reconcile loop will re-create the VM on
        // its next sync; if it succeeds, a later report restores the status.
        guard vm.status.assertsAgentPresence else { return }

        let previous = vm.status
        vm.setStatus(.error)
        try await vm.save(on: db)
        Telemetry.vmEnteredError(reason: "reconciliation")
        app.logger.warning(
            "VM missing from agent observed-state report; marking as error until re-converged",
            metadata: [
                "vmId": .string(vmID.uuidString),
                "agentId": .string(agentId),
                "previousStatus": .string(previous.rawValue),
            ])
    }

    // MARK: - VM Operations

    /// Places a VM on an agent selected by the scheduler, persists the
    /// placement, and pushes (or nudges) a desired-state sync. The pending
    /// create operation completes from the agent's observed-state reports,
    /// with the stuck-operation sweep as the budget backstop. The placement
    /// reservation self-releases once the agent's reports account for the VM
    /// (or by TTL on failure).
    /// - Parameters:
    ///   - vm: The VM to create
    ///   - db: Database connection
    ///   - strategy: Optional scheduling strategy override
    ///   - image: Optional source image (its architecture constrains placement)
    func createVM(
        vm: VM,
        db: Database,
        strategy: SchedulingStrategy? = nil,
        image: Image? = nil
    ) async throws {
        let schedulableAgents = await schedulableAgentsFromDatabase()
        let vmId = vm.id?.uuidString ?? ""

        // A network pinned to a site exists only in that site's OVN
        // deployment, so it pins the VM's placement (issue #343).
        let requiredSiteID = try await pinnedSiteID(for: vm, on: db)

        // Use scheduler to select the best agent and atomically reserve the
        // VM's resources on it, so a concurrent create can't place against
        // the same capacity (issue #258).
        let agentId: String
        do {
            agentId = try await app.scheduler.selectAndReserveAgent(
                requirements: SchedulerService.placementRequirements(
                    for: vm, architecture: image?.architecture, siteID: requiredSiteID),
                vmId: vmId,
                from: schedulableAgents,
                coordination: app.coordination,
                strategy: strategy,
                vmName: vm.name
            )
        } catch let error as SchedulerError {
            app.logger.error("Scheduler failed to find suitable agent: \(error)")
            // Preserve the scheduler's reason (unsupported hypervisor, arch
            // mismatch, insufficient resources, ...) instead of collapsing
            // every placement failure into a generic "no agent available".
            throw AgentServiceError.schedulingFailed(error.description)
        }

        do {
            // Persist the placement, then sync: from here the VM is part of
            // the agent's desired state and every path (nudge now, periodic
            // timer later, reconnect sync) will carry it.
            vm.hypervisorId = agentId
            try await vm.save(on: db)

            app.logger.info(
                "VM creation dispatched via desired-state sync",
                metadata: [
                    "vmId": .string(vmId),
                    "agentId": .string(agentId),
                ])

            await syncDesiredState(agentId: agentId)
        } catch {
            // The placement never became desired state, so nothing will ever
            // account for the reservation — release it rather than pinning
            // capacity until the TTL.
            await app.coordination.releaseReservation(agentId: agentId, vmId: vmId)
            throw error
        }
    }

    /// The site a VM's placement is pinned to, derived from its NICs'
    /// networks: attaching a site-pinned network confines the VM to that
    /// site's agents. NICs are persisted before placement runs, so the rows
    /// are authoritative here. Networks pinned to different sites cannot
    /// coexist on one VM — no host is in both sites.
    private func pinnedSiteID(for vm: VM, on db: Database) async throws -> UUID? {
        guard let vmID = vm.id else { return nil }
        let nics = try await VMNetworkInterface.query(on: db)
            .filter(\.$vm.$id == vmID)
            .all()
        let names = Set(nics.map(\.network))
        guard !names.isEmpty else { return nil }

        let networks = try await LogicalNetwork.query(on: db)
            .filter(\.$name ~~ names)
            .all()
        let siteIDs = Set(networks.compactMap { $0.$site.id })
        guard siteIDs.count <= 1 else {
            throw AgentServiceError.schedulingFailed(
                "VM attaches networks pinned to different sites; no host can satisfy both")
        }
        return siteIDs.first
    }

    /// Dispatch a correlated VM command (reboot — an action, not a state, so
    /// it cannot ride the level-triggered sync) and await the agent's
    /// success/error response, routing through the socket-holding replica if
    /// it isn't us. The agent replies only after the operation ran on the
    /// hypervisor, so `timeout` should be the operation kind's full completion
    /// budget. Callers record the verdict on the operation row (issue #259).
    func performVMOperationAwaitingResponse(
        _ operation: MessageType,
        vmId: String,
        timeout: Duration
    ) async throws -> AgentServiceResponse {
        guard let vmUUID = UUID(uuidString: vmId),
            let vm = try await VM.find(vmUUID, on: app.db),
            let agentId = vm.hypervisorId
        else {
            throw AgentServiceError.vmNotMapped(vmId)
        }

        let message = VMOperationMessage(type: operation, vmId: vmId)

        app.logger.info(
            "VM operation dispatched",
            metadata: [
                "operation": .string(operation.rawValue),
                "vmId": .string(vmId),
                "agentId": .string(agentId),
            ])

        return try await sendMessageToAgentWithResponse(message, agentId: agentId, timeout: timeout)
    }

    // MARK: - Agent Selection

    /// The scheduler's view of the fleet, assembled from the shared registry:
    /// agent rows (resources refreshed by heartbeats through any replica) and
    /// per-agent VM counts, filtered to agents whose presence key is live.
    func schedulableAgentsFromDatabase() async -> [SchedulableAgent] {
        do {
            let agents = try await Agent.query(on: app.db)
                .filter(\.$status == .online)
                .all()

            let placedVMs = try await VM.query(on: app.db)
                .filter(\.$hypervisorId != nil)
                .all()
            var runningVMCounts: [String: Int] = [:]
            for vm in placedVMs {
                if let hypervisorId = vm.hypervisorId {
                    runningVMCounts[hypervisorId, default: 0] += 1
                }
            }

            var present: [Agent] = []
            for agent in agents {
                // Fail open on nil (store unavailable): the row said online,
                // and refusing all placement would couple VM creation to
                // Valkey harder than issue #258's degradation policy allows.
                if await app.coordination.isAgentPresent(agentName: agent.name) == false {
                    continue
                }
                present.append(agent)
            }

            return Self.schedulableAgents(from: present, runningVMCounts: runningVMCounts)
        } catch {
            app.logger.error("Failed to load schedulable agents from database: \(error)")
            return []
        }
    }

    /// Pure transform from agent rows to the scheduler's view. Kept
    /// `nonisolated static` so it can be unit-tested without the actor.
    nonisolated static func schedulableAgents(
        from agents: [Agent],
        runningVMCounts: [String: Int]
    ) -> [SchedulableAgent] {
        return agents.compactMap { agent in
            guard let agentId = agent.id?.uuidString else { return nil }
            return SchedulableAgent(
                id: agentId,  // Database UUID (as String)
                name: agent.name,  // Human-readable name
                totalCPU: agent.totalCPU,
                availableCPU: agent.availableCPU,
                totalMemory: agent.totalMemory,
                availableMemory: agent.availableMemory,
                totalDisk: agent.totalDisk,
                availableDisk: agent.availableDisk,
                status: agent.status,
                runningVMCount: runningVMCounts[agentId] ?? 0,
                supportedHypervisors: agent.supportedHypervisors,
                architecture: agent.cpuArchitecture,
                supportsInterVMNetworking: agent.supportsInterVMNetworking,
                siteID: agent.$site.id
            )
        }
    }

    // MARK: - Message Sending

    /// Encode and push an envelope over a locally held socket.
    private func sendEnvelope(_ envelope: MessageEnvelope, toLocalAgent agentName: String) throws {
        guard let websocket = app.websocketManager.getConnection(agentName: agentName) else {
            throw AgentServiceError.agentNotFound(agentName)
        }
        let data = try WireProtocol.makeEncoder().encode(envelope)
        websocket.send(data)
    }

    private func sendMessageToLocalAgent<T: WebSocketMessage>(_ message: T, agentName: String) async throws {
        try sendEnvelope(MessageEnvelope(message: message), toLocalAgent: agentName)
    }

    /// Send a message to an agent and await the correlated success/error
    /// response, wherever the agent's socket lives: a locally armed
    /// continuation when this process holds it, or an exchange forwarded to
    /// the socket-holding replica over the coordination store's RPC channels
    /// otherwise. This is the path for the few remaining imperative exchanges
    /// — volume operations and reboot, which are actions rather than states
    /// and so cannot ride the level-triggered sync. The timeout should be
    /// sized to the operation: metadata ops finish in seconds, while
    /// image-backed volume creation or a clone can copy gigabytes.
    func sendMessageToAgentWithResponse<T: WebSocketMessage>(
        _ message: T,
        agentId: String,
        timeout: Duration = .seconds(30)
    ) async throws -> AgentServiceResponse {
        let envelope = try MessageEnvelope(message: message)

        if let localName = app.websocketManager.agentName(agentId: agentId) {
            return try await sendEnvelopeAwaitingLocalResponse(
                envelope, requestId: message.requestId, agentId: agentId,
                agentName: localName, timeout: timeout)
        }

        guard let name = await agentName(forId: agentId) else {
            throw AgentServiceError.agentNotFound(agentId)
        }
        guard let route = await app.coordination.agentRoute(agentName: name),
            route != app.replicaID
        else {
            // No route: the agent is offline everywhere. A route naming this
            // replica without a local socket is a stale claim from a torn-down
            // connection — the agent is equally unreachable from here.
            throw AgentServiceError.agentNotFound(agentId)
        }

        return try await sendRPC(
            envelope, requestId: message.requestId, agentId: agentId,
            agentName: name, toReplica: route, timeout: timeout)
    }

    /// Arm a pending-request continuation, push the envelope over the local
    /// socket, and await the agent's correlated response (or the timeout).
    ///
    /// Cancellation-aware: cancelling the awaiting task resumes the
    /// continuation with `CancellationError` instead of leaving it suspended
    /// until the timeout — shutdown's background-task drain relies on this to
    /// cut multi-minute agent-response budgets short.
    private func sendEnvelopeAwaitingLocalResponse(
        _ envelope: MessageEnvelope,
        requestId: String,
        agentId: String,
        agentName: String,
        timeout: Duration
    ) async throws -> AgentServiceResponse {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    guard !self.consumeExchangeCancellation(requestId) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        // Store continuation for response handling
                        self.storePendingRequest(requestId, agentId: agentId, continuation: continuation)

                        // Send message
                        try self.sendEnvelope(envelope, toLocalAgent: agentName)

                        // Arm a timeout, tracking its handle so a normal response can
                        // cancel it instead of leaving a task dangling per request.
                        let timeoutTask = Task {
                            try? await Task.sleep(for: timeout)
                            guard !Task.isCancelled else { return }
                            self.timeoutRequest(requestId)
                        }
                        self.attachTimeout(timeoutTask, to: requestId)
                    } catch {
                        _ = self.removePendingRequest(requestId)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelPendingExchange(requestId) }
        }
    }

    /// Resume a pending exchange's continuation with `CancellationError`, or
    /// record a tombstone if the exchange hasn't been armed yet (the arming
    /// task consumes it and resumes immediately).
    private func cancelPendingExchange(_ requestId: String) {
        if let continuation = removePendingRequest(requestId) {
            continuation.resume(throwing: CancellationError())
        } else if let continuation = removePendingRPC(requestId) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledExchanges.insert(requestId)
        }
    }

    /// Whether the awaiting task was cancelled before the exchange was armed;
    /// consumes the tombstone.
    private func consumeExchangeCancellation(_ requestId: String) -> Bool {
        cancelledExchanges.remove(requestId) != nil
    }

    // MARK: - Cross-replica RPC bridge (issue #261)

    /// Wire format for forwarding a correlated agent exchange to the replica
    /// holding the agent's socket. Serialized as JSON on the RPC channels.
    struct AgentRPCRequest: Codable {
        let rpcId: String
        let replyChannel: String
        let agentId: String
        let agentName: String
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
    /// little past the holder's, so the holder's specific verdict (agent
    /// error, its own timeout) normally wins over our generic one.
    private func sendRPC(
        _ envelope: MessageEnvelope,
        requestId: String,
        agentId: String,
        agentName: String,
        toReplica replicaId: String,
        timeout: Duration
    ) async throws -> AgentServiceResponse {
        let request = AgentRPCRequest(
            rpcId: requestId,
            replyChannel: CoordinationService.rpcReplyChannel(replicaId: app.replicaID),
            agentId: agentId,
            agentName: agentName,
            envelope: envelope,
            timeoutSeconds: Self.seconds(of: timeout)
        )
        let payload = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let channel = CoordinationService.rpcChannel(replicaId: replicaId)

        // Cancellation-aware for the same reason as the local path: shutdown's
        // background-task drain must be able to cut this wait short.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    guard !self.consumeExchangeCancellation(requestId) else {
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
            Task { await self.cancelPendingExchange(requestId) }
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
        if app.websocketManager.getConnection(agentName: request.agentName) != nil {
            do {
                let response = try await sendEnvelopeAwaitingLocalResponse(
                    request.envelope, requestId: request.rpcId, agentId: request.agentId,
                    agentName: request.agentName, timeout: .seconds(request.timeoutSeconds))
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

    private static func seconds(of duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    private func storePendingRequest(
        _ requestId: String, agentId: String, continuation: CheckedContinuation<AgentServiceResponse, Error>
    ) {
        pendingRequests[requestId] = PendingRequest(agentId: agentId, continuation: continuation)
    }

    /// Associates a timeout task with a still-pending request. If the request has
    /// already resolved (a fast response beat the timeout being armed), the task is
    /// cancelled immediately so it doesn't linger.
    private func attachTimeout(_ task: Task<Void, Never>, to requestId: String) {
        guard pendingRequests[requestId] != nil else {
            task.cancel()
            return
        }
        pendingRequests[requestId]?.timeoutTask = task
    }

    private func removePendingRequest(_ requestId: String) -> CheckedContinuation<AgentServiceResponse, Error>? {
        guard let request = pendingRequests.removeValue(forKey: requestId) else { return nil }
        request.timeoutTask?.cancel()
        return request.continuation
    }

    private func timeoutRequest(_ requestId: String) {
        if let continuation = removePendingRequest(requestId) {
            continuation.resume(throwing: AgentServiceError.requestTimeout)
        }
    }

    /// Fail all in-flight requests targeting an agent that has gone away, so callers
    /// get a prompt error instead of waiting for the per-request timeout.
    private func failPendingRequests(for agentId: String, reason: AgentServiceError = .connectionLost) {
        let affected = pendingRequests.filter { $0.value.agentId == agentId }
        guard !affected.isEmpty else { return }

        for (requestId, request) in affected {
            pendingRequests.removeValue(forKey: requestId)
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: reason)
        }

        app.logger.info(
            "Failed \(affected.count) in-flight request(s) for disconnected agent",
            metadata: [
                "agentId": .string(agentId)
            ])
    }

    // MARK: - Response Handling

    func handleAgentResponse(_ envelope: MessageEnvelope) {
        Task {
            // Extract the original request's ID from the typed payload so we can
            // correlate the response with the continuation that is waiting for it.
            let requestId: String
            do {
                switch envelope.type {
                case .success:
                    requestId = try envelope.decode(as: SuccessMessage.self).requestId
                case .error:
                    requestId = try envelope.decode(as: ErrorMessage.self).requestId
                default:
                    // Other message types (e.g. unsolicited statusUpdate) are not
                    // request/response correlated and are handled elsewhere.
                    return
                }
            } catch {
                app.logger.error("Failed to decode agent response envelope: \(error)")
                return
            }

            guard let continuation = self.removePendingRequest(requestId) else {
                return
            }

            do {
                switch envelope.type {
                case .success:
                    let message = try envelope.decode(as: SuccessMessage.self)
                    continuation.resume(returning: .success(message.data))
                case .error:
                    let message = try envelope.decode(as: ErrorMessage.self)
                    continuation.resume(returning: .error(message.error, message.details))
                default:
                    continuation.resume(throwing: AgentServiceError.invalidResponse("Unexpected response type"))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Applies an unsolicited VM status update reported by an agent to the database.
    /// This is how transitional states (.starting/.stopping) get confirmed into their
    /// terminal states (.running/.shutdown/.paused) once the agent completes the work.
    /// `agentName` identifies the authenticated connection the update arrived on, so
    /// an agent can only mutate VMs the database actually maps to it.
    func applyStatusUpdate(_ envelope: MessageEnvelope, fromAgentNamed agentName: String) {
        Task {
            let update: StatusUpdateMessage
            do {
                update = try envelope.decode(as: StatusUpdateMessage.self)
            } catch {
                app.logger.error("Failed to decode status update from agent: \(error)")
                return
            }

            guard let vmUUID = UUID(uuidString: update.vmId) else {
                app.logger.warning(
                    "Status update referenced an invalid VM id", metadata: ["vmId": .string(update.vmId)])
                return
            }

            guard let senderAgentId = await self.agentId(forName: agentName) else {
                app.logger.warning(
                    "Status update from unregistered agent; ignoring",
                    metadata: [
                        "vmId": .string(update.vmId),
                        "agentName": .string(agentName),
                    ])
                return
            }

            do {
                guard let vm = try await VM.find(vmUUID, on: app.db) else {
                    app.logger.warning("Status update for unknown VM", metadata: ["vmId": .string(update.vmId)])
                    return
                }

                guard vm.hypervisorId == senderAgentId else {
                    app.logger.warning(
                        "Status update from agent that does not own the VM; ignoring",
                        metadata: [
                            "vmId": .string(update.vmId),
                            "agentName": .string(agentName),
                            "senderAgentId": .string(senderAgentId),
                            "owningAgentId": .string(vm.hypervisorId ?? "none"),
                        ])
                    return
                }

                // The owning agent is reporting on this VM, so its resource
                // reports now account for it: the placement reservation (if
                // one is still held) has served its purpose. No-op otherwise.
                await self.app.coordination.releaseReservation(agentId: senderAgentId, vmId: update.vmId)

                guard vm.status != update.status else { return }

                // A transitional state means a control-plane-initiated operation is in
                // flight. Only the confirmation that completes that transition (or an
                // error) may land; anything else is a delayed update from an operation
                // that predates the transition — the controller guards (canStart/canStop/
                // canPause) make any other concurrent operation impossible — and applying
                // it would mask the in-flight one (e.g. a late `Paused` overwriting
                // `.stopping`, hiding a lost stop from the sweep).
                if vm.status.isTransitional {
                    let expected: Set<VMStatus> =
                        vm.status == .starting
                        ? [.running, .error]
                        : [.shutdown, .error]
                    guard expected.contains(update.status) else {
                        app.logger.warning(
                            "Ignoring stale agent status update during in-flight operation",
                            metadata: [
                                "vmId": .string(update.vmId),
                                "current": .string(vm.status.rawValue),
                                "reported": .string(update.status.rawValue),
                            ])
                        return
                    }
                }

                let previous = vm.status
                vm.setStatus(update.status)
                try await vm.save(on: app.db)
                if update.status == .error {
                    // The agent pushed an error state — e.g. a failed create/boot.
                    Telemetry.vmEnteredError(reason: "agent_reported")
                }

                app.logger.info(
                    "Applied agent status update",
                    metadata: [
                        "vmId": .string(update.vmId),
                        "from": .string(previous.rawValue),
                        "to": .string(update.status.rawValue),
                    ])
            } catch {
                app.logger.error("Failed to apply status update for VM \(update.vmId): \(error)")
            }
        }
    }

    // MARK: - Agent Status

    /// Every agent known to the cluster, from the shared registry. Rows are
    /// written by whichever replica hears from an agent, so this view is the
    /// same on all replicas.
    func getAgentList() async -> [Agent] {
        do {
            return try await Agent.query(on: app.db).all()
        } catch {
            app.logger.error("Failed to load agent list from database: \(error)")
            return []
        }
    }

    func getAgentInfo(_ agentId: String) async -> Agent? {
        guard let agentUUID = UUID(uuidString: agentId) else { return nil }
        return try? await Agent.find(agentUUID, on: app.db)
    }
}

// MARK: - Application Extension

extension Application {
    private struct WebSocketManagerKey: StorageKey, LockKey {
        typealias Value = WebSocketManager
    }

    var websocketManager: WebSocketManager {
        get {
            lazyService(WebSocketManagerKey.self) { WebSocketManager() }
        }
        set {
            storage[WebSocketManagerKey.self] = newValue
        }
    }

    private struct AgentServiceKey: StorageKey, LockKey {
        typealias Value = AgentService
    }

    var agentService: AgentService {
        get {
            lazyService(AgentServiceKey.self) { AgentService(app: self) }
        }
        set {
            storage[AgentServiceKey.self] = newValue
        }
    }

    /// The `AgentService` if one has already been created, without lazily
    /// creating it. Shutdown must not instantiate the service (that would arm
    /// the very heartbeat task shutdown exists to cancel).
    var agentServiceIfCreated: AgentService? {
        storage[AgentServiceKey.self]
    }
}

/// Instantiates the agent service at boot and cancels its heartbeat monitor
/// at shutdown so the periodic database sweep never outlives the application.
struct AgentServiceLifecycleHandler: LifecycleHandler {
    /// Force creation at boot: the service's heartbeat/sweep loop and — since
    /// issue #261 — this replica's nudge/RPC channel subscriptions must be
    /// live even before the first request or agent connection would have
    /// created it lazily. Runs in `didBootAsync` so the Redis pools the
    /// subscriptions need already exist.
    func didBootAsync(_ application: Application) async throws {
        _ = application.agentService
    }

    func shutdownAsync(_ application: Application) async {
        await application.agentServiceIfCreated?.shutdown()
    }
}

extension Request {
    var agentService: AgentService {
        return application.agentService
    }
}

extension VMStatus {
    /// States that assert live agent presence: agents keep running, paused,
    /// and shut-down-but-not-deleted VMs in their managed set, so one of these
    /// missing from a heartbeat or observed-state report means the agent lost
    /// it. `.created` may be mid-create, and transitional/diagnostic states
    /// are owned by the sweep — absence in those states is expected.
    var assertsAgentPresence: Bool {
        self == .running || self == .paused || self == .shutdown
    }
}
