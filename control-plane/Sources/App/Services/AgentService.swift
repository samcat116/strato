import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent
import NIOCore
import NIOConcurrencyHelpers
import Tracing

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
    /// Keyed by the agent's identity key — its full SPIFFE ID
    /// (`spiffe://<trust-domain>/agent/<name>`), never the bare name. Two
    /// organizations may each enroll an `agent-1` once per-org trust domains
    /// are on (issue #613); a name-keyed map would give one org's socket the
    /// other's desired state.
    private var connections: [String: Connection] = [:]

    /// Store the connection for an agent, returning the socket it replaced (a
    /// different instance under the same name) or nil. A non-nil result means
    /// the agent reconnected while its previous socket's close was still
    /// pending: that delayed close will take the `removeConnection(ifCurrent:)`
    /// no-match path and skip its cleanup, so the caller must tear down state
    /// tied to the superseded connection (e.g. console sessions) here instead.
    /// Must be called from the WebSocket's event loop.
    @discardableResult
    func setConnection(agentKey: String, websocket: WebSocket) -> WebSocket? {
        lock.withLock {
            let previous = connections[agentKey]?.websocket
            connections[agentKey] = Connection(websocket: websocket, agentId: nil)
            return previous === websocket ? nil : previous
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

    /// Every locally connected agent that has completed registration, as
    /// (identity key, database UUID) pairs. This is the periodic sync's work
    /// list: each replica syncs exactly the agents whose sockets it holds.
    func registeredAgents() -> [(key: String, agentId: String)] {
        lock.withLock {
            connections.compactMap { key, connection in
                connection.agentId.map { (key: key, agentId: $0) }
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

    /// Exchange IDs whose awaiting task was cancelled before the exchange was
    /// armed (the arming runs in a separate task, so cancellation can win the
    /// race). Consumed at arming time so the continuation resumes immediately
    /// instead of suspending until its timeout. Entries that miss both the
    /// pending map and the arming (cancellation racing a normal completion)
    /// linger, but the only canceller of these waits is shutdown's
    /// background-task drain, so the set is bounded to process teardown.
    private var cancelledExchanges: Set<String> = []

    private var heartbeatTask: Task<Void, Never>?

    /// The startup task that arms the replica pub/sub subscriptions. Tracked
    /// so `shutdown()` can wait for it — otherwise it can still be
    /// subscribing (touching `app` storage) while the application tears down.
    private var startupTask: Task<Void, Never>?

    /// Interval between heartbeat-monitor ticks. Injectable so tests can
    /// exercise the loop (and its shutdown race) without waiting 30s.
    private let heartbeatInterval: Duration

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

    /// Set at application shutdown. Guards against the init task arming the
    /// heartbeat monitor after `shutdown()` already ran.
    private var isShutDown = false

    /// Overrides `AgentVersionTarget.version` for the auto-update sweep.
    /// Test-only: the real target is compiled from the process environment
    /// once, which a test cannot vary.
    private var autoUpdateTargetOverride: String?

    func setAutoUpdateTargetForTesting(_ target: String?) {
        autoUpdateTargetOverride = target
    }

    /// The version auto-updating agents should converge on.
    private var autoUpdateTarget: String? {
        autoUpdateTargetOverride ?? AgentVersionTarget.version
    }

    init(app: Application, heartbeatInterval: Duration = .seconds(30)) {
        self.app = app
        self.heartbeatInterval = heartbeatInterval
        // Start heartbeat monitoring and the replica's pub/sub subscriptions
        // after initialization. The hop through an isolated method is
        // deliberate: a nonisolated init cannot store the task it spawns, and
        // both background tasks must be tracked so `shutdown()` can await
        // them.
        Task { await self.armBackgroundWork() }
    }

    /// Arm the tracked background tasks (heartbeat loop, replica pub/sub
    /// subscriptions). No-op if shutdown already ran.
    ///
    /// Also a no-op when the *application* has shut down: `agentService` is a
    /// lazy getter, so a stray late caller (a detached task from a request or
    /// socket handler running after `asyncShutdown` cleared storage) creates
    /// a fresh service on a dead app. `AgentServiceLifecycleHandler` has
    /// already run by then and nothing will ever shut this instance down, so
    /// an armed heartbeat's first tick touches `app.db` after core teardown
    /// and dies with Vapor's "Core not configured" fatal error — the
    /// recurring CI crash.
    private func armBackgroundWork() {
        guard !isShutDown, !app.didShutdown else { return }
        startHeartbeatMonitoring()
        startupTask = Task {
            await self.app.replicaBridge.start(delegate: self)
        }
    }

    /// Cancel the heartbeat monitoring loop and wait for an in-flight tick to
    /// finish. Called from the application's shutdown lifecycle (see
    /// `AgentServiceLifecycleHandler`): the loop holds the `Application` and
    /// sweeps the database every tick, so a tick that touches `app.db` after
    /// shutdown hits Vapor's "Core not configured" fatal error — long-lived
    /// test processes crash exactly this way. Cancellation interrupts the
    /// loop's sleep immediately, but a tick body already past the sleep is
    /// mid-sweep; awaiting the task's completion keeps Vapor's core alive
    /// until it drains. The startup task (replica pub/sub subscriptions) is
    /// awaited for the same reason. Safe on the actor: it is reentrant at
    /// these suspensions, so the tick can still hop back on to finish.
    func shutdown() async {
        isShutDown = true
        // Close the bridge's subscription re-arm path before we stop driving
        // it; its subscription tasks drain with the Valkey pools.
        await app.replicaBridgeIfCreated?.shutdown()
        startupTask?.cancel()
        heartbeatTask?.cancel()
        if let startupTask {
            await startupTask.value
        }
        startupTask = nil
        // `isShutDown` was set before the await, so the startup task cannot
        // have armed the loop in the meantime — this reads the final value.
        if let heartbeatTask {
            await heartbeatTask.value
        }
        heartbeatTask = nil
    }

    // MARK: - Agent Registration

    /// Registers an agent and returns its database UUID.
    ///
    /// `siteID` and `organizationScope` override what the agent's enrollment
    /// records; callers normally pass neither. Non-nil assigns (or moves) the
    /// agent; nil never clears — both assignments are durable on the agent row.
    /// A *new* agent must end up with an organization scope: agents are
    /// dedicated capacity, and an unowned agent would be invisible to every org
    /// and schedulable by no one.
    func registerAgent(
        _ message: AgentRegisterMessage,
        agentName: String,
        trustDomain: String = PlatformTrustDomain.current,
        identityOrganizationID: UUID? = nil,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) async throws -> UUID {
        try await registerAgent(
            message,
            identity: AgentIdentity(trustDomain: trustDomain, name: agentName),
            identityOrganizationID: identityOrganizationID,
            siteID: siteID,
            organizationScope: organizationScope
        )
    }

    /// Registers an agent by its full identity (trust domain + name).
    ///
    /// `identityOrganizationID` is the organization the agent's *trust domain*
    /// resolves to — nil for the platform domain, which is every agent until
    /// per-org trust domains are switched on (issue #613). It is not an
    /// authorization claim: it only supplies the owning scope when the
    /// enrollment carries none, and refuses a registration whose enrollment
    /// scope belongs to a different organization than the CA that vouched for
    /// the node.
    func registerAgent(
        _ message: AgentRegisterMessage,
        identity: AgentIdentity,
        identityOrganizationID: UUID? = nil,
        siteID: UUID? = nil,
        organizationScope: OrganizationScope? = nil
    ) async throws -> UUID {
        let agentName = identity.name
        let agentKey = identity.key
        let trustDomain = identity.trustDomain

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
        var organizationScope = organizationScope
        var siteID = siteID
        // Set when this registration creates the agent row, so the enrollment it
        // drew its scope from can be marked used after a successful save.
        var newAgentEnrollment: AgentEnrollment?

        // Find existing agent or create new one
        let agent: Agent
        if let existingAgent = try await Agent.query(on: db)
            .filter(\.$trustDomain == trustDomain)
            .filter(\.$name == agentName)
            .first()
        {
            // Update existing agent
            agent = existingAgent
            if existingAgent.version != message.version {
                // The visible confirmation that a self-update (issue #432)
                // landed: the restarted binary re-registers under its name
                // with the new build version.
                app.logger.notice(
                    "Agent re-registered with a new version",
                    metadata: [
                        "agentName": .string(agentName),
                        "previousVersion": .string(existingAgent.version),
                        "version": .string(message.version),
                    ])
            }
            agent.hostname = message.hostname
            agent.version = message.version
            agent.capabilities = message.capabilities
            agent.architecture = message.architecture?.rawValue
            agent.operatingSystem = message.operatingSystem?.rawValue ?? agent.operatingSystem
            agent.hypervisors = message.effectiveHypervisors
            agent.networkCapability = message.networkCapability?.rawValue
            agent.hostInfo = message.hostInfo ?? agent.hostInfo
            agent.sandboxCapable = message.sandboxCapable ?? false
            agent.tpmCapable = message.tpmCapable ?? false
            agent.updateResources(message.resources)
            agent.status = .online
        } else {
            // A brand-new agent takes its scope and site placement from the
            // enrollment an operator created for this name: agents authenticate
            // by SVID and carry no credential that could convey either. Existing
            // agents deliberately skip this — both are durable on the agent row,
            // and re-reading the enrollment on every reconnect would fight an
            // operator who has since moved the agent to another site.
            let enrollment = try await AgentEnrollment.query(on: db)
                .filter(\.$trustDomain == trustDomain)
                .filter(\.$agentName == agentName)
                .sort(\.$createdAt, .descending)
                .first()
            if organizationScope == nil { organizationScope = enrollment?.organizationScope }
            if siteID == nil { siteID = enrollment?.siteID }

            // An org trust domain is a cryptographic statement about *whose*
            // node this is, so it must agree with the enrollment's scope: a
            // node attested by org A's CA may not join org B's capacity, and a
            // node whose enrollment carries no scope at all inherits its
            // domain's org rather than being refused.
            if let identityOrganizationID {
                if let scope = organizationScope {
                    let owner = try await scope.rootOrganizationID(on: db)
                    guard owner == identityOrganizationID else {
                        Telemetry.agentRegistrationFailed(reason: "organization_scope_mismatch")
                        throw AgentServiceError.missingOrganizationScope(agentName: agentName)
                    }
                } else {
                    organizationScope = .organization(identityOrganizationID)
                }
            }

            guard organizationScope != nil else {
                Telemetry.agentRegistrationFailed(reason: "missing_organization_scope")
                throw AgentServiceError.missingOrganizationScope(agentName: agentName)
            }
            // Create new agent
            agent = Agent.from(registration: message, name: agentName, trustDomain: trustDomain)
            agent.status = .online
            newAgentEnrollment = enrollment
        }

        let previousScope = agent.organizationScope
        if let organizationScope, previousScope != organizationScope {
            // A token-driven org change moves dedicated capacity between
            // tenants, so it must honor the same drain invariant as a site
            // change: never move an agent that still hosts VMs (they belong to
            // the old org's projects and would be stranded on foreign
            // hardware). An agent assigned to a site can't change org either —
            // the site's whole OVN deployment belongs to one org. Refusals are
            // logged, not fatal; the agent registers with its previous scope.
            var refusalReason: String?
            if let agentID = agent.id {
                if agent.$site.id != nil {
                    refusalReason = "agent belongs to a site; remove it from the site first"
                } else {
                    let hostedVMs = try await VM.query(on: db)
                        .filter(\.$hypervisorId == agentID.uuidString)
                        .count()
                    let hostedSandboxes = try await Sandbox.query(on: db)
                        .filter(\.$hypervisorId == agentID.uuidString)
                        .count()
                    if hostedVMs > 0 {
                        refusalReason = "agent hosts \(hostedVMs) VM(s); drain it first"
                    } else if hostedSandboxes > 0 {
                        refusalReason = "agent hosts \(hostedSandboxes) sandbox(es); drain it first"
                    }
                }
            }
            if let refusalReason {
                app.logger.error(
                    "Ignoring enrollment organization assignment: \(refusalReason)",
                    metadata: ["agentKey": .string(agentKey)])
            } else {
                agent.organizationScope = organizationScope
            }
        }

        // Persisted so sync assembly (which may run on any replica, from
        // Postgres alone) can key version-dependent shapes on what this agent
        // actually speaks — see `networkAssemblyScope`.
        agent.wireProtocolVersion = protocolVersion

        if let siteID, agent.$site.id != siteID {
            // A token-driven site change must honor the same invariants as the
            // sites API's assign/remove endpoints, or the token becomes a
            // bypass. Never move a site's designated network controller (the
            // old site would point at a non-member and its networks would
            // silently stop being reconciled), and never move an agent that
            // still hosts VMs (their networks would drop out of the NB that
            // has been realizing them). Refusals are logged, not fatal — the
            // agent still registers with its previous site intact. (A
            // brand-new agent row has no id yet and trips neither guard.)
            var refusalReason: String?
            if let agentID = agent.id {
                let controllerships =
                    try await Site.query(on: db)
                    .filter(\.$networkControllerAgent.$id == agentID)
                    .filter(\.$id != siteID)
                    .count()
                if controllerships > 0 {
                    refusalReason = "agent is another site's network controller"
                } else {
                    let hostedVMs = try await VM.query(on: db)
                        .filter(\.$hypervisorId == agentID.uuidString)
                        .count()
                    let hostedSandboxes = try await Sandbox.query(on: db)
                        .filter(\.$hypervisorId == agentID.uuidString)
                        .count()
                    if hostedVMs > 0 {
                        refusalReason = "agent hosts \(hostedVMs) VM(s); drain it first"
                    } else if hostedSandboxes > 0 {
                        refusalReason = "agent hosts \(hostedSandboxes) sandbox(es); drain it first"
                    }
                }
            }
            // A site is one OVN deployment owned by one scope; its members
            // must live within that scope (sibling-OU agents included — see
            // the sites API's assignAgent, which this token path must match).
            if refusalReason == nil {
                let siteScope = try await Site.find(siteID, on: db)?.organizationScope
                let agentScope = agent.organizationScope
                let contained: Bool
                if let siteScope, let agentScope {
                    contained = try await siteScope.contains(agentScope, on: db)
                } else {
                    contained = false
                }
                if !contained {
                    refusalReason = "site's organization scope does not contain the agent's"
                }
            }
            if let refusalReason {
                app.logger.error(
                    "Ignoring enrollment site assignment: \(refusalReason)",
                    metadata: ["agentKey": .string(agentKey), "requestedSite": .string(siteID.uuidString)])
            } else {
                agent.$site.id = siteID
            }
        }

        try await agent.save(on: db)

        // Record that the node completed its first registration. Informational
        // only — an enrollment is not consumed by being redeemed — so a failure
        // here must not fail a registration that has already persisted.
        if let enrollment = newAgentEnrollment, !enrollment.isUsed {
            enrollment.markAsUsed()
            do {
                try await enrollment.save(on: db)
            } catch {
                app.logger.warning(
                    "Failed to mark agent enrollment as used",
                    metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
            }
        }

        guard let agentUUID = agent.id else {
            throw AgentServiceError.invalidResponse("Failed to get agent ID after save")
        }

        // Attach the UUID to the live socket so local routing (sync pushes,
        // RPC forwarding, the periodic sync's work list) can resolve it
        // without a database read. No-op when no socket exists (tests).
        app.websocketManager.associate(agentKey: agentKey, agentId: agentUUID.uuidString)

        // Publish liveness and socket location to the coordination store so
        // every control-plane process — not just the one holding this socket —
        // can see the agent and route mutations to it.
        await app.coordination.recordAgentPresence(agentKey: agentKey)
        await app.replicaBridge.recordRoute(agentKey: agentKey)

        Telemetry.agentConnected()
        Telemetry.recordAgentUp(agentName: Self.displayName(forKey: agentKey), up: true)
        await WebhookEvents.emitAgentPresence(
            agent: agent, connected: true, reason: "registered", on: db, logger: app.logger)
        app.logger.info(
            "Agent registered",
            metadata: [
                "agentId": .string(agentUUID.uuidString),
                "agentKey": .string(agentKey),
                "hostname": .string(message.hostname),
                "version": .string(message.version),
            ])

        return agentUUID
    }

    /// The bare agent name inside an identity key, for logs and metric labels
    /// (a full SPIFFE ID would change every existing dashboard's series).
    nonisolated static func displayName(forKey agentKey: String) -> String {
        AgentIdentity(key: agentKey)?.name ?? agentKey
    }

    /// Resolve an agent's database UUID from its identity key: the local
    /// socket's registration first (no I/O), the database otherwise.
    private func agentId(forKey agentKey: String) async -> String? {
        if let local = app.websocketManager.agentId(agentKey: agentKey) {
            return local
        }
        guard let identity = AgentIdentity(key: agentKey) else { return nil }
        let agent = try? await Agent.query(on: app.db)
            .filter(\.$trustDomain == identity.trustDomain)
            .filter(\.$name == identity.name)
            .first()
        return agent?.id?.uuidString
    }

    /// Whether `vmId` is currently assigned to the agent authenticated as
    /// `agentKey`. Used to reject agent-reported data (VM logs, console)
    /// tagged with a VM the reporting agent doesn't own — otherwise a compromised
    /// agent could forge log entries for another tenant's VM.
    func vmIsOwnedByAgent(vmId: String, agentKey: String) async -> Bool {
        guard let vmUUID = UUID(uuidString: vmId),
            let senderAgentId = await agentId(forKey: agentKey),
            let vm = try? await VM.find(vmUUID, on: app.db)
        else {
            return false
        }
        return vm.hypervisorId == senderAgentId
    }

    /// Whether `sandboxId` is currently assigned to the agent authenticated as
    /// `agentKey` — the sandbox counterpart of `vmIsOwnedByAgent`, guarding
    /// agent-reported sandbox data (workload logs, exec frames) against a
    /// compromised agent forging entries for another tenant's sandbox.
    func sandboxIsOwnedByAgent(sandboxId: String, agentKey: String) async -> Bool {
        guard let sandboxUUID = UUID(uuidString: sandboxId),
            let senderAgentId = await agentId(forKey: agentKey),
            let sandbox = try? await Sandbox.find(sandboxUUID, on: app.db)
        else {
            return false
        }
        return sandbox.hypervisorId == senderAgentId
    }

    /// Resolve an agent's identity key from its database UUID: the local
    /// socket's registration first (no I/O), the database otherwise.
    private func agentKey(forId agentId: String) async -> String? {
        if let local = app.websocketManager.agentKey(agentId: agentId) {
            return local
        }
        guard let agentUUID = UUID(uuidString: agentId) else { return nil }
        let agent = try? await Agent.find(agentUUID, on: app.db)
        return agent?.identity.key
    }

    func unregisterAgent(_ agentId: String, fromAgentKey connectionAgentKey: String) async throws {
        let db = app.db

        // Resolve the target and confirm it belongs to the authenticated
        // connection. Without this an agent could pass another agent's id in the
        // message body and force *that* agent offline (cross-tenant DoS) — the
        // same ownership guard the heartbeat/observed-state handlers enforce.
        guard let agentUUID = UUID(uuidString: agentId),
            let agent = try await Agent.find(agentUUID, on: db)
        else {
            app.logger.warning(
                "Unregister for unknown agent; ignoring", metadata: ["agentId": .string(agentId)])
            return
        }

        guard agent.identity.key == connectionAgentKey else {
            app.logger.warning(
                "Unregister claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "claimedAgentId": .string(agentId),
                    "claimedAgentKey": .string(agent.identity.key),
                    "connectionAgentKey": .string(connectionAgentKey),
                ])
            return
        }

        agent.status = .offline
        try await agent.save(on: db)
        let agentKey = agent.identity.key

        // Fail any in-flight requests waiting on this agent before we drop it
        failPendingRequests(for: agentId)

        app.websocketManager.removeConnection(agentKey: agentKey)
        // The eventual socket close skips its cleanup once the connection is
        // gone (`removeConnection(ifCurrent:)` no longer matches), so console
        // and exec sessions must be torn down here for the graceful-unregister
        // path.
        app.consoleSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        app.sandboxExecSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        await app.replicaBridge.clearRoute(agentKey: agentKey)

        Telemetry.agentDisconnected(reason: "unregister")
        Telemetry.recordAgentUp(agentName: Self.displayName(forKey: agentKey), up: false)
        await WebhookEvents.emitAgentPresence(
            agent: agent, connected: false, reason: "unregistered", on: db, logger: app.logger)
        app.logger.info("Agent unregistered", metadata: ["agentId": .string(agentId)])
    }

    /// Tear down an agent's in-memory state from an operator action
    /// (deregister, force-offline).
    ///
    /// Takes an `AgentIdentity` rather than a `String` **on purpose**. This
    /// used to be an unlabeled `String`, so a bare `agent.name` could be passed
    /// silently — and since nothing is keyed by name any more, the lookup below
    /// missed and every teardown step was skipped. A dedicated type makes that
    /// mistake a compile error rather than a silent no-op.
    func forceUnregisterAgent(_ identity: AgentIdentity) async {
        let agentKey = identity.key
        guard let agentId = await agentId(forKey: agentKey) else {
            app.logger.warning(
                "Cannot force unregister: agent not found by identity key", metadata: ["agentKey": .string(agentKey)])
            return
        }

        // Fail any in-flight requests waiting on this agent before we drop it
        failPendingRequests(for: agentId)

        app.websocketManager.removeConnection(agentKey: agentKey)
        // Same reasoning as `unregisterAgent`: the socket-close handler will
        // not run its cleanup once the connection entry is gone.
        app.consoleSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        app.sandboxExecSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        await app.replicaBridge.clearRoute(agentKey: agentKey)

        app.logger.info(
            "Agent force unregistered",
            metadata: ["agentId": .string(agentId), "agentKey": .string(agentKey)])
    }

    /// Socket-close cleanup. The agent may have already reconnected to another
    /// replica: its route key then names that replica, and this (delayed)
    /// close must not mark the agent offline underneath a live connection.
    func removeAgent(_ agentKey: String) async {
        // Local pending requests die with the local socket regardless of
        // where the agent lives now.
        if let agentId = await agentId(forKey: agentKey) {
            failPendingRequests(for: agentId)
        }

        if case .forward = await app.replicaBridge.remoteRoute(agentKey: agentKey) {
            app.logger.debug(
                "Agent socket closed here but agent is routed to another replica; skipping offline mark",
                metadata: ["agentKey": .string(agentKey)])
            return
        }

        await app.replicaBridge.clearRoute(agentKey: agentKey)

        Telemetry.agentDisconnected(reason: "connection_closed")
        Telemetry.recordAgentUp(agentName: Self.displayName(forKey: agentKey), up: false)

        // Update database status asynchronously
        Task {
            do {
                let db = self.app.db
                if let identity = AgentIdentity(key: agentKey),
                    let agent = try await Agent.query(on: db)
                        .filter(\.$trustDomain == identity.trustDomain)
                        .filter(\.$name == identity.name)
                        .first()
                {
                    agent.status = .offline
                    try await agent.save(on: db)
                    await WebhookEvents.emitAgentPresence(
                        agent: agent, connected: false, reason: "connection_closed",
                        on: db, logger: self.app.logger)
                }
            } catch {
                self.app.logger.error("Failed to update agent offline status in database: \(error)")
            }
        }
    }

    /// `agentKey` identifies the authenticated connection the heartbeat arrived on;
    /// the claimed `agentId` must belong to it, so one agent cannot drive another
    /// agent's resource tracking or VM reconciliation.
    func updateAgentHeartbeat(_ message: AgentHeartbeatMessage, fromAgentKey agentKey: String) async throws {
        let db = app.db
        guard let agentUUID = UUID(uuidString: message.agentId),
            let agent = try await Agent.find(agentUUID, on: db)
        else {
            app.logger.warning("Received heartbeat from unknown agent", metadata: ["agentId": .string(message.agentId)])
            return
        }

        guard agent.identity.key == agentKey else {
            app.logger.warning(
                "Heartbeat claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "claimedAgentId": .string(message.agentId),
                    "claimedAgentKey": .string(agent.identity.key),
                    "connectionAgentKey": .string(agentKey),
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
        await app.coordination.recordAgentPresence(agentKey: agentKey)
        await app.replicaBridge.recordRoute(agentKey: agentKey)

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
                await WebhookEvents.emitVMStateChanged(
                    vm: vm, previous: previous, current: .error, on: db, logger: app.logger)

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
                    try await Task.sleep(for: heartbeatInterval)
                    tick &+= 1

                    // Shutdown cancels mid-tick and awaits the loop; checking
                    // between steps keeps the remaining app-touching work (and
                    // shutdown's wait) as short as possible. The application
                    // check is the last line of defense for a loop that
                    // somehow outlives its app: every step below touches
                    // app.db or app storage, which is a process-killing fatal
                    // error (not a throw) after core teardown.
                    try self.checkTickPreconditions()

                    // Check for stale agents
                    await checkStaleAgents()

                    try self.checkTickPreconditions()

                    // Probe (and re-arm if dead) this replica's pub/sub
                    // subscriptions — a dropped Valkey connection loses them
                    // silently and RediStack does not restore them.
                    await app.replicaBridge.verifySubscriptions()

                    try self.checkTickPreconditions()

                    // Periodic desired-state sync (~60s): the correctness
                    // backstop of the level-triggered design — a dropped or
                    // failed sync is repaired here, so pushes on mutation are
                    // purely a latency optimization (issue #260). Not a
                    // cluster singleton: syncs go over this process's sockets.
                    if tick.isMultiple(of: 2) {
                        await syncDesiredStateToAllAgents()
                    }

                    try self.checkTickPreconditions()

                    // Fail operations stuck pending past their budget and resolve
                    // VMs stuck in a transitional state
                    await sweepStuckOperations()

                    try self.checkTickPreconditions()

                    // Delete sandboxes past their TTL, and reap terminal
                    // sandbox records past the retention window (issue #424).
                    await sweepExpiredSandboxes()

                    try self.checkTickPreconditions()

                    // Advance the agent auto-update rollout one agent at a
                    // time (issue #434).
                    await sweepAgentAutoUpdates()
                } catch {
                    if !Task.isCancelled {
                        app.logger.error("Error in heartbeat monitoring task: \(error)")
                    }
                    // A dead application never comes back: exit rather than
                    // spin on a loop whose every step would be skipped.
                    if app.didShutdown { return }
                }
            }
        }
    }

    /// Throws when the current tick must stop: the task was cancelled, the
    /// service shut down, or the application itself has been torn down.
    private func checkTickPreconditions() throws {
        try Task.checkCancellation()
        guard !isShutDown, !app.didShutdown else {
            throw CancellationError()
        }
    }

    private func checkStaleAgents() async {
        // Shutdown sets this before cancelling the loop; a tick that already
        // slipped past its sleep must not start a database sweep it doesn't
        // need to finish. The app-level check is a backstop for loops armed
        // outside the lifecycle handler's reach: touching `app.db` after
        // core teardown is a process-killing fatal error, not a throw.
        guard !isShutDown, !app.didShutdown else { return }

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
                if await app.coordination.isAgentPresent(agentKey: agent.identity.key) == true {
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
                await WebhookEvents.emitAgentPresence(
                    agent: agent, connected: false, reason: "stale", on: app.db, logger: app.logger)
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
        // Never touch app.db (a fatal error, not a throw, after core
        // teardown) once shutdown has begun — this was the crashing frame of
        // the recurring "Core not configured" CI crash.
        guard !isShutDown, !app.didShutdown else { return }
        // Cluster-singleton: with multiple replicas, only one may sweep per interval.
        guard await app.coordination.acquireSweepLock("stuck_operations") else {
            app.logger.debug("Skipping stuck-operation sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = Date()

        do {
            let pending = try await ResourceOperation.query(on: db)
                .filter(\.$status == .pending)
                .all()

            for operation in pending {
                // A missing creation timestamp yields age 0 and is left for a
                // later sweep (it is set on insert, so this is a safety net).
                let age = now.timeIntervalSince(operation.createdAt ?? now)
                let budget = operation.completionBudgetSeconds
                guard age > budget else { continue }

                // The shared verdict path marks the operation failed (iff still
                // pending) and resolves whatever in-flight state it left on its
                // resource — each resource kind's own `resolveForStuckOperation`.
                // `recordVerdict` logs the failure (the timeout error names the
                // budget), so no separate "stuck past budget" warning here.
                guard let operationID = operation.id else { continue }
                _ = await app.resourceOperationCoordinator.recordVerdict(
                    operationID: operationID, as: .failed,
                    error: "Operation timed out: no completion after \(Int(budget))s",
                    telemetryReason: "stuck_operation", on: app)
            }

            // Transitional VMs with no pending operation: the operation completed
            // (or predates the operations table) but the confirming statusUpdate
            // never landed. Same 120s timeout as the old stuck-VM sweep.
            let timeout: TimeInterval = 120
            let stuckBefore = now.addingTimeInterval(-timeout)
            let transitional = try await VM.query(on: db)
                .filter(\.$status ~~ [.starting, .stopping])
                .filterAged(before: stuckBefore, by: \.$statusChangedAt, fallingBackTo: \.$updatedAt)
                .all()

            for vm in transitional {
                guard let vmID = vm.id else { continue }

                let hasPendingOperation =
                    try await ResourceOperation.query(on: db)
                    .filter(\.$resourceKind == .virtualMachine)
                    .filter(\.$resourceID == vmID)
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

            // Same backstop for sandboxes: transitional with no pending
            // operation means the confirming report never landed.
            let transitionalSandboxes = try await Sandbox.query(on: db)
                .filter(\.$status ~~ [.starting, .stopping])
                .filterAged(before: stuckBefore, by: \.$statusChangedAt, fallingBackTo: \.$updatedAt)
                .all()

            for sandbox in transitionalSandboxes {
                guard let sandboxID = sandbox.id else { continue }

                let hasPendingOperation =
                    try await ResourceOperation.query(on: db)
                    .filter(\.$resourceKind == .sandbox)
                    .filter(\.$resourceID == sandboxID)
                    .filter(\.$status == .pending)
                    .count() > 0
                guard !hasPendingOperation else { continue }

                let previous = sandbox.status
                sandbox.setStatus(.error)
                try await sandbox.save(on: db)

                app.logger.warning(
                    "Sandbox stuck in transitional state past timeout; marking as error",
                    metadata: [
                        "sandboxId": .string(sandboxID.uuidString),
                        "stuckStatus": .string(previous.rawValue),
                        "timeoutSeconds": .string("\(Int(timeout))"),
                    ])
            }

            // Volumes are the one resource kind mutated through the same
            // async-agent-RPC pattern that was never brought under the
            // ResourceOperation umbrella (issue #644), so there is no operation
            // row to sweep. This backstop recovers them directly instead: a
            // volume left in a transitional status past its budget — the only
            // signal we have, since there is no pending operation to consult —
            // is returned to a resting state. Without it, a crash mid-operation
            // (rolling upgrade, OOM kill) strands the volume in that status
            // permanently.
            //
            // The budget is per-status, so SQL filters on the *shortest* of
            // them and the per-status check below narrows the rest: a superset
            // that still keeps the scan off every freshly created volume.
            let shortestVolumeBudget =
                Self.transitionalVolumeStatuses.map(stuckVolumeBudgetSeconds(for:)).min() ?? 0
            let volumeStuckBefore = now.addingTimeInterval(-shortestVolumeBudget)
            let transitionalVolumes = try await Volume.query(on: db)
                .filter(\.$status ~~ Self.transitionalVolumeStatuses)
                .filterAged(before: volumeStuckBefore, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()

            for volume in transitionalVolumes {
                guard let volumeID = volume.id else { continue }
                // `updatedAt` is stamped on the transition into the transitional
                // status; `createdAt` is the fallback for a `.creating` row whose
                // provisioning never started.
                let changedAt = volume.updatedAt ?? volume.createdAt ?? now
                let budget = stuckVolumeBudgetSeconds(for: volume.status)
                guard now.timeIntervalSince(changedAt) > budget else { continue }

                let previous = volume.status
                let resolved: VolumeStatus
                switch previous {
                case .snapshotting, .cloning:
                    // The source volume's data is untouched by an interrupted
                    // snapshot or clone (both read the source; the overlay/target
                    // is a separate row). Return it to a healthy resting state
                    // rather than error it. The orphaned snapshot/clone-target
                    // row is a `.creating` volume/snapshot resolved on its own.
                    resolved = volume.$vm.id != nil ? .attached : .available
                default:
                    // creating/attaching/detaching/resizing: the agent-side
                    // outcome is unknown, so `.error` is the honest, recoverable
                    // state (`canDelete` allows it). Attachment fields are left
                    // as-is deliberately — clearing them and returning to
                    // `.available` would risk re-attaching a volume the agent may
                    // actually have connected to a guest.
                    resolved = .error
                    volume.errorMessage =
                        "Volume operation did not complete (control-plane restart or lost agent "
                        + "response); recovered by the stuck-operation sweep after \(Int(budget))s"
                }
                volume.status = resolved
                try await volume.save(on: db)

                app.logger.warning(
                    "Volume stuck in transitional state past budget; recovered",
                    metadata: [
                        "volumeId": .string(volumeID.uuidString),
                        "stuckStatus": .string(previous.rawValue),
                        "resolvedStatus": .string(resolved.rawValue),
                        "budgetSeconds": .string("\(Int(budget))"),
                    ])
            }
        } catch {
            app.logger.error("Stuck-operation sweep failed: \(error)")
        }
    }

    /// The volume statuses the stuck-volume backstop watches. Kept in one
    /// place because `AddHotPathIndexes` indexes exactly this set (a partial
    /// index on `volumes.status`) — widening the list means widening that
    /// index too, or the sweep falls back to a sequential scan.
    static let transitionalVolumeStatuses: [VolumeStatus] = [
        .creating, .attaching, .detaching, .resizing, .snapshotting, .cloning,
    ]

    /// How long a volume may sit in a given transitional status before the
    /// stuck-operation sweep treats it as lost (issue #644). Volumes carry no
    /// `ResourceOperation` row, so — unlike the VM/sandbox backstops above,
    /// which skip any resource with a pending operation — the sweep cannot tell
    /// an operation still in flight on a live replica from one abandoned by a
    /// crash. It has only elapsed time. Each budget therefore sits comfortably
    /// above the matching `VolumeService` RPC timeout so a legitimately slow
    /// operation on a live replica is never clobbered mid-flight; the extra
    /// margin only delays recovery of a genuinely stuck volume, which is rare.
    private func stuckVolumeBudgetSeconds(for status: VolumeStatus) -> TimeInterval {
        switch status {
        case .creating, .cloning:
            // VolumeService.transferTimeout is 600s (image download / full-disk
            // copy); a live create/clone resolves the row by then.
            return 900
        case .snapshotting:
            // VolumeService.snapshotTimeout is 120s.
            return 300
        case .attaching, .detaching, .resizing:
            // VolumeService.defaultTimeout is 30s.
            return 180
        case .available, .attached, .deleting, .error:
            // Not transitional (or, for `.deleting`, deliberately left to the
            // retryable-delete path); never queried by the sweep above.
            return 300
        }
    }

    // MARK: - Sandbox expiry (issue #424)

    /// How long a terminal sandbox's record is kept by default.
    static let defaultSandboxRetentionHours = 24

    /// The retention window for terminal sandboxes, or nil when retention is
    /// off. `SANDBOX_RETENTION_HOURS` overrides the default; a non-positive
    /// value keeps terminal records — and the quota they still hold — forever,
    /// which is a deliberate opt-in, not the default.
    static var sandboxRetentionHours: Int? {
        guard let raw = Environment.get("SANDBOX_RETENTION_HOURS").flatMap(Int.init) else {
            return defaultSandboxRetentionHours
        }
        return raw > 0 ? raw : nil
    }

    /// Why the expiry sweep is deleting a sandbox. Both reasons end in the
    /// same deletion; they differ only in what started the clock.
    private enum SandboxExpiryReason {
        /// The lifetime budget ran out (`ttl_seconds` from `createdAt`).
        case ttl(seconds: Int)
        /// A terminal sandbox outlived the retention window for its record.
        case retention(hours: Int)

        var description: String {
            switch self {
            case .ttl(let seconds):
                return "TTL of \(seconds)s elapsed"
            case .retention(let hours):
                return "terminal record retained for \(hours)h"
            }
        }
    }

    /// Deletes sandboxes that have outlived either clock (issue #424):
    ///
    /// - **TTL** — `ttl_seconds` past `createdAt`. Sandboxes are ephemeral;
    ///   this is what makes the stored budget real.
    /// - **Retention** — an exited or errored sandbox keeps its terminal
    ///   record (status and exit code) for `SANDBOX_RETENTION_HOURS` so the
    ///   result stays inspectable, then the row goes. Errored sandboxes are
    ///   included because they are terminal too and would otherwise hold their
    ///   quota indefinitely.
    ///
    /// Cluster-singleton via the sweep lock, and level-triggered like every
    /// other sweep: a skipped or crashed pass costs latency, never
    /// correctness, because the next tick recomputes both clocks from scratch.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepExpiredSandboxes() async {
        // Never touch app.db once shutdown has begun — after core teardown
        // that is a process-killing fatal error, not a throw.
        guard !isShutDown, !app.didShutdown else { return }
        guard await app.coordination.acquireSweepLock("sandbox_expiry") else {
            app.logger.debug("Skipping sandbox expiry sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = Date()

        do {
            var expiring: [(sandbox: Sandbox, reason: SandboxExpiryReason)] = []

            // A sandbox already heading for `.absent` is being deleted by
            // something else; leave it to that operation.
            let budgeted = try await Sandbox.query(on: db)
                .filter(\.$desiredStatus != .absent)
                .filter(\.$ttlSeconds != nil)
                .all()
            for sandbox in budgeted where sandbox.isExpired(at: now) {
                expiring.append((sandbox, .ttl(seconds: sandbox.ttlSeconds ?? 0)))
            }

            if let hours = Self.sandboxRetentionHours {
                let window = TimeInterval(hours) * 3600
                // A sandbox already expiring on TTL must not be queued twice:
                // the second `begin` would collide with the first's pending
                // operation and log a spurious conflict.
                let alreadyExpiring = Set(expiring.compactMap(\.sandbox.id))
                // Terminal sandboxes are what accumulates, so the retention
                // window is a SQL predicate rather than a Swift filter over
                // every terminal row ever kept.
                let expiredBefore = now.addingTimeInterval(-window)
                let terminal = try await Sandbox.query(on: db)
                    .filter(\.$desiredStatus != .absent)
                    .filter(\.$status ~~ [.exited, .error])
                    .filterAged(before: expiredBefore, by: \.$statusChangedAt, fallingBackTo: \.$updatedAt)
                    .all()

                for sandbox in terminal {
                    guard let sandboxID = sandbox.id, !alreadyExpiring.contains(sandboxID) else { continue }
                    expiring.append((sandbox, .retention(hours: hours)))
                }
            }

            for (sandbox, reason) in expiring {
                await expireSandbox(sandbox, reason: reason, on: db)
            }
        } catch {
            app.logger.error("Sandbox expiry sweep failed: \(error)")
        }
    }

    /// Deletes one expired sandbox down the same path as `DELETE
    /// /api/sandboxes/:id`: a pending `.delete` operation and desired
    /// `.absent` in one transaction, then either agent teardown (the row goes
    /// once a report confirms absence) or — with no agent to converge on — a
    /// direct record delete. Sharing the path is the point: quota release,
    /// reservation release, and operation accounting all come for free, and
    /// the operation row makes the unattended deletion auditable.
    private func expireSandbox(_ sandbox: Sandbox, reason: SandboxExpiryReason, on db: Database) async {
        guard let sandboxID = sandbox.id else { return }

        var onlineAgentID: String?
        if let agentId = sandbox.hypervisorId, let agent = await getAgentInfo(agentId), agent.status == .online {
            onlineAgentID = agentId
        }

        do {
            let operation = try await ResourceOperation.begin(
                .delete,
                resourceKind: .sandbox,
                resourceID: sandboxID,
                userID: ResourceOperation.systemUserID,
                on: db
            ) { db in
                try await SandboxController.requireSnapshotLineageDeletable(
                    for: sandboxID, on: db)
                sandbox.setDesiredStatus(.absent)
                try await sandbox.save(on: db)
            }

            app.logger.info(
                "Expiring sandbox",
                metadata: [
                    "sandboxId": .string(sandboxID.uuidString),
                    "reason": .string(reason.description),
                    "operationId": .string(operation.id?.uuidString ?? ""),
                ])

            if let onlineAgentID {
                await syncDesiredState(agentId: onlineAgentID)
            } else {
                app.resourceOperationCoordinator.dispatch(
                    operation, resourceKind: .sandbox, resourceID: sandboxID, hypervisorId: nil,
                    dispatch: .directResolution { @Sendable [app = self.app] db in
                        try await SandboxController.performDirectDeletion(sandbox: sandbox, on: db, app: app)
                    }, app: app)
            }
        } catch {
            // `begin` rejects with 409 when an operation is already pending —
            // a user action owns the sandbox right now. Both clocks are
            // recomputed next tick, so an expired sandbox is never dropped,
            // only deferred.
            app.logger.debug(
                "Skipping sandbox expiry: \(error)",
                metadata: ["sandboxId": .string(sandboxID.uuidString)])
        }
    }

    // MARK: - Agent auto-update rollout (issue #434)

    /// How long an assigned agent has to either re-register at its target
    /// version or report a blocker before the sweep treats the silence as a
    /// failed update and halts the rollout. Generous on purpose: it spans the
    /// artifact download (the imperative endpoint already allows 300s for
    /// that alone), the restart, and re-registration.
    static let autoUpdateHealthBudgetSeconds: TimeInterval = 600

    /// Advances the fleet's declarative agent updates one agent at a time
    /// (issue #434). Cluster-singleton via the sweep lock; all rollout state
    /// lives on the agent rows, so any replica can pick up where another
    /// stopped.
    ///
    /// Per tick, each enrolled-and-assigned agent is classified:
    /// - **converged** — re-registered at the target: assignment cleared.
    /// - **stale** — assigned a version the deployment target has moved past:
    ///   reset, including failures, so an old halt never blocks a new target.
    /// - **failed** — a recorded failure (agent-reported, or silence past the
    ///   health budget, recorded here): the rollout halts until an operator
    ///   intervenes or the target changes.
    /// - **parked** — blocked past the health budget (e.g. running
    ///   Firecracker VMs): the assignment stays, level-triggered, so the
    ///   agent converges whenever its blocker clears — but advancement stops
    ///   waiting on it. Parked is marked by a nil `updateAttemptedAt`.
    /// - **waiting** — within budget: the rollout holds.
    ///
    /// Only when nothing is failed or waiting does the sweep assign the next
    /// eligible agent (deterministic name order), after proving the release
    /// actually publishes an artifact for that agent's platform.
    func sweepAgentAutoUpdates() async {
        guard !isShutDown, !app.didShutdown else { return }
        guard let target = autoUpdateTarget else { return }
        guard await app.coordination.acquireSweepLock("agent_auto_update") else {
            app.logger.debug("Skipping auto-update sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = Date()
        let canonicalTarget = AgentVersionTarget.canonical(target)

        do {
            let enrolled = try await Agent.query(on: db)
                .filter(\.$autoUpdate == true)
                .sort(\.$name)
                .all()

            var rolloutHalted = false
            var waitingOnAgent = false

            for agent in enrolled {
                guard let assigned = agent.updateDesiredVersion else { continue }

                // The deployment target moved past this assignment
                // (mid-rollout upgrade): reset everything, including a
                // failure — the old target's halt must not block the new one.
                guard AgentVersionTarget.canonical(assigned) == canonicalTarget else {
                    clearRolloutAssignment(agent)
                    try await agent.save(on: db)
                    continue
                }

                // Converged: the agent re-registered at the target (or was
                // updated by hand, which counts just the same).
                if !AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: assigned) {
                    clearRolloutAssignment(agent)
                    try await agent.save(on: db)
                    Telemetry.agentAutoUpdateConverged()
                    app.logger.notice(
                        "Agent auto-update converged",
                        metadata: [
                            "agentName": .string(agent.name),
                            "version": .string(agent.version),
                        ])
                    continue
                }

                if agent.updateFailureReason != nil {
                    rolloutHalted = true
                    continue
                }

                // Parked earlier (nil clock, see below): the assignment keeps
                // riding the syncs, but the rollout no longer waits on it.
                guard let attemptedAt = agent.updateAttemptedAt else { continue }
                let age = now.timeIntervalSince(attemptedAt)

                if agent.updateBlockedReason != nil {
                    if age > Self.autoUpdateHealthBudgetSeconds {
                        agent.updateAttemptedAt = nil
                        try await agent.save(on: db)
                        Telemetry.agentAutoUpdateParked()
                        app.logger.notice(
                            "Agent auto-update parked: blocked past the health budget; rollout advances without it",
                            metadata: [
                                "agentName": .string(agent.name),
                                "targetVersion": .string(assigned),
                                "blockedReason": .string(agent.updateBlockedReason ?? ""),
                            ])
                    } else {
                        waitingOnAgent = true
                    }
                    continue
                }

                if age > Self.autoUpdateHealthBudgetSeconds {
                    // Silence past the budget: the agent neither converged
                    // nor explained itself — most likely it attempted the
                    // update and never came back. Halt the rollout.
                    agent.updateFailureReason =
                        "did not re-register at \(assigned) within \(Int(Self.autoUpdateHealthBudgetSeconds))s of assignment"
                    try await agent.save(on: db)
                    Telemetry.agentAutoUpdateFailed(reason: "health_budget")
                    app.logger.error(
                        "Agent auto-update failed: agent went silent past the health budget; rollout halted",
                        metadata: [
                            "agentName": .string(agent.name),
                            "targetVersion": .string(assigned),
                        ])
                    rolloutHalted = true
                } else {
                    waitingOnAgent = true
                }
            }

            guard !rolloutHalted && !waitingOnAgent else { return }

            // Nothing in flight and nothing failed: assign the next agent.
            // Eligibility mirrors the imperative endpoint's checks, minus the
            // Firecracker guard — that precondition is evaluated live on the
            // agent, which is the only side that actually knows.
            let next = enrolled.first { agent in
                agent.updateDesiredVersion == nil
                    && AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: target)
                    && agent.isOnline
                    && WireProtocol.supportsDesiredAgentUpdate(agent.wireProtocolVersion ?? 0)
                    && agent.hostOperatingSystem != nil
                    && agent.cpuArchitecture != nil
            }
            guard let next, let nextId = next.id else { return }

            // Prove the release serves this agent's platform before assigning
            // — an unresolvable artifact would leave the agent silently
            // unconverged until the budget halted the whole rollout.
            do {
                _ = try await app.agentArtifactResolver.resolve(
                    version: target,
                    operatingSystem: next.hostOperatingSystem ?? .linux,
                    architecture: next.cpuArchitecture ?? .arm64
                )
            } catch {
                app.logger.warning(
                    "Agent auto-update artifact unresolvable; not assigning (retries next sweep)",
                    metadata: [
                        "agentName": .string(next.name),
                        "targetVersion": .string(target),
                        "error": .string(String(describing: error)),
                    ])
                return
            }

            next.updateDesiredVersion = target
            next.updateAttemptedAt = now
            next.updateBlockedReason = nil
            next.updateFailureReason = nil
            try await next.save(on: db)
            Telemetry.agentAutoUpdateAssigned()
            app.logger.notice(
                "Agent auto-update assigned",
                metadata: [
                    "agentName": .string(next.name),
                    "currentVersion": .string(next.version),
                    "targetVersion": .string(target),
                ])
            // Push the sync now; the periodic timer is only the backstop.
            await syncDesiredState(agentId: nextId.uuidString)
        } catch {
            app.logger.error("Agent auto-update sweep failed: \(error)")
        }
    }

    /// Clears every rollout field on an agent row (converged, stale target,
    /// or withdrawn). Callers save.
    private func clearRolloutAssignment(_ agent: Agent) {
        agent.updateDesiredVersion = nil
        agent.updateAttemptedAt = nil
        agent.updateBlockedReason = nil
        agent.updateFailureReason = nil
    }

    // MARK: - Desired-state sync (issues #260, #261)

    /// Push the authoritative desired state to every registered agent whose
    /// socket this process holds. Called on the periodic timer; failures are
    /// logged and repaired by the next tick. Each replica syncs exactly its
    /// own sockets, so no cluster coordination is needed here.
    func syncDesiredStateToAllAgents() async {
        guard !isShutDown, !app.didShutdown else { return }
        for (name, agentId) in app.websocketManager.registeredAgents() {
            await syncDesiredStateLocally(agentId: agentId, agentKey: name)
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
    /// the shared NB doesn't have yet), so the controller is synced alongside
    /// — and *first*: a non-authoritative peer cannot create a missing switch
    /// itself, so giving the controller's topology sync a head start lets the
    /// common case (first VM on a fresh network) converge on the peer's first
    /// attempt instead of waiting out a dependency-pending retry.
    func syncDesiredState(agentId: String) async {
        if let controllerId = await siteNetworkControllerID(forAgentId: agentId), controllerId != agentId {
            await routeDesiredStateSync(agentId: controllerId)
        }
        await routeDesiredStateSync(agentId: agentId)
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
        if let localName = app.websocketManager.agentKey(agentId: agentId) {
            await syncDesiredStateLocally(agentId: agentId, agentKey: localName)
            return
        }

        guard let name = await agentKey(forId: agentId) else {
            app.logger.warning(
                "Cannot route sync for unknown agent", metadata: ["agentId": .string(agentId)])
            return
        }

        switch await app.replicaBridge.remoteRoute(agentKey: name) {
        case .forward(let replicaId):
            await app.replicaBridge.nudge(agentKey: name, toReplica: replicaId)
        case .noRoute:
            // No route: the agent is offline everywhere. The sync it missed
            // is delivered by the registration-triggered sync on reconnect.
            app.logger.debug(
                "No socket route for agent; sync deferred to reconnect",
                metadata: ["agentKey": .string(name)])
        case .ownReplica:
            // The route says us, but no local socket exists — a connection
            // torn down before its route expired. The reconnect sync (or the
            // holder's periodic timer, wherever the agent lands) is the
            // backstop; nudging ourselves would find the same missing socket.
            break
        }
    }

    /// Assemble and send the full desired-state sync over a locally held
    /// socket. Safe to call redundantly: identical syncs diff to nothing on
    /// the agent.
    private func syncDesiredStateLocally(agentId: String, agentKey: String) async {
        let clock = ContinuousClock()
        let start = clock.now
        await withSpan("agent.desired_state_sync", ofKind: .producer) { span in
            span.attributes["agent.id"] = agentId
            do {
                let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
                try await sendMessageToLocalAgent(message, agentKey: agentKey)
                span.attributes["sync.id"] = message.syncId
                span.attributes["sync.vm_count"] = message.vms.count
                Telemetry.recordDesiredStateSync(
                    outcome: "sent", durationSeconds: (clock.now - start).asSeconds)
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
                span.recordError(error)
                Telemetry.recordDesiredStateSync(
                    outcome: "failed", durationSeconds: (clock.now - start).asSeconds)
                app.logger.warning(
                    "Failed to send desired-state sync (periodic timer will retry)",
                    metadata: [
                        "agentId": .string(agentId),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }
    }

    /// Deliver a cross-replica sync nudge (the `ReplicaBridgeDelegate` hook).
    /// If we (still) hold the agent's socket, push a fresh sync; if not, the
    /// nudge raced a disconnect and the periodic timer wherever the agent lands
    /// is the backstop.
    func deliverNudge(agentKey: String) async {
        guard let agentId = app.websocketManager.agentId(agentKey: agentKey) else {
            app.logger.debug(
                "Nudge for agent without a local socket; ignoring",
                metadata: ["agentKey": .string(agentKey)])
            return
        }
        await syncDesiredStateLocally(agentId: agentId, agentKey: agentKey)
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
    func enqueueObservedStateReport(_ envelope: MessageEnvelope, fromAgentKey agentKey: String) {
        nextReportTailId &+= 1
        let id = nextReportTailId
        let predecessor = reportTails[agentKey]?.task
        let task = Task { [weak self] in
            await predecessor?.value
            await self?.applyObservedStateReport(envelope, fromAgentKey: agentKey)
            await self?.retireReportTail(agentKey: agentKey, id: id)
        }
        reportTails[agentKey] = (id, task)
    }

    /// Drop the chain bookkeeping once the finishing link is still the tail,
    /// so idle agents don't pin their last report task forever.
    private func retireReportTail(agentKey: String, id: UInt64) {
        if reportTails[agentKey]?.id == id {
            reportTails.removeValue(forKey: agentKey)
        }
    }

    /// Handle an agent's full observed-state report: verify the authenticated
    /// connection owns the claimed agent, refresh the agent row's resources and
    /// liveness (mirroring the heartbeat path), then hand the workload contents
    /// to `ObservedStateApplier`.
    ///
    /// `agentKey` identifies the authenticated connection, mirroring the
    /// heartbeat's ownership check. Callers outside tests should go through
    /// `enqueueObservedStateReport` so same-agent reports apply in order.
    func applyObservedStateReport(_ envelope: MessageEnvelope, fromAgentKey agentKey: String) async {
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
        guard agent.identity.key == agentKey else {
            app.logger.warning(
                "Observed-state report claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "claimedAgentId": .string(report.agentId),
                    "connectionAgentKey": .string(agentKey),
                ])
            return
        }

        // Reports carry the same resource snapshot as heartbeats; keep the
        // scheduler's view fresh from whichever arrives.
        agent.updateResources(report.resources)
        agent.status = .online
        applyReportedUpdateStatus(report.agentUpdateStatus, to: agent)
        do {
            try await agent.save(on: app.db)
        } catch {
            app.logger.warning(
                "Failed to persist agent resources from observed-state report: \(error)",
                metadata: ["agentId": .string(report.agentId)])
        }

        // The report arrived over this process's socket: refresh liveness and
        // routing alongside, mirroring the heartbeat path.
        await app.coordination.recordAgentPresence(agentKey: agentKey)
        await app.replicaBridge.recordRoute(agentKey: agentKey)

        do {
            try await app.observedStateApplier.apply(report)
        } catch {
            app.logger.error(
                "Failed to apply observed-state report: \(error)",
                metadata: ["agentId": .string(report.agentId)])
        }
    }

    /// Folds an agent's self-reported update status (issue #434) into its
    /// row, mutating the in-memory model for the caller's save. Reports about
    /// a version other than the row's current assignment are ignored — a
    /// stale in-flight report must not be attributed to a newer rollout
    /// target.
    private func applyReportedUpdateStatus(_ status: ObservedAgentUpdateStatus?, to agent: Agent) {
        guard let status else {
            // Nothing in the way (or nothing desired): clear a stale blocked
            // reason so the API stops surfacing it. Failures stay — they are
            // rollout state, resolved by convergence or operator action.
            agent.updateBlockedReason = nil
            return
        }
        guard let assigned = agent.updateDesiredVersion,
            AgentVersionTarget.canonical(status.targetVersion) == AgentVersionTarget.canonical(assigned)
        else { return }

        switch status.disposition {
        case ObservedAgentUpdateStatus.dispositionFailed:
            // Terminal for this artifact and process lifetime: halt the
            // rollout on the real error instead of waiting out the budget.
            agent.updateBlockedReason = nil
            if agent.updateFailureReason != status.reason {
                agent.updateFailureReason = status.reason
                app.logger.error(
                    "Agent reported its assigned update failed",
                    metadata: [
                        "agentName": .string(agent.name),
                        "targetVersion": .string(status.targetVersion),
                        "reason": .string(status.reason),
                    ])
                Telemetry.agentAutoUpdateFailed(reason: "agent_reported")
            }
        default:
            // `blocked`, and — conservatively — any disposition this build
            // does not know yet.
            if agent.updateBlockedReason != status.reason {
                agent.updateBlockedReason = status.reason
                app.logger.info(
                    "Agent reported its assigned update as blocked",
                    metadata: [
                        "agentName": .string(agent.name),
                        "targetVersion": .string(status.targetVersion),
                        "reason": .string(status.reason),
                    ])
            }
        }
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

    /// Places a sandbox on a Firecracker-capable agent, persists the
    /// placement, and pushes (or nudges) a desired-state sync — the sandbox
    /// half of `createVM`. The pending create operation completes from the
    /// agent's observed-state reports, with the stuck-operation sweep as the
    /// budget backstop.
    ///
    /// Placement requires Firecracker support and the explicit sandbox-runtime
    /// capability (`AgentRegisterMessage.sandboxCapable` folded with a v5+
    /// wire protocol into `supportsSandboxWorkloads`, issue #415). There is no
    /// architecture constraint until tag→digest resolution can read the
    /// image's platform (issue #414); forks inherit the snapshot's recorded
    /// architecture and pinned agent. Sandboxes reserve no disk.
    func createSandbox(sandbox: Sandbox, db: Database) async throws {
        var schedulableAgents = await schedulableAgentsFromDatabase()
        let sandboxId = sandbox.id?.uuidString ?? ""

        var requiredArchitecture: CPUArchitecture?
        if let snapshotID = sandbox.restoredFromSnapshotId {
            guard let snapshot = try await SandboxSnapshot.find(snapshotID, on: db),
                snapshot.isReady
            else {
                throw AgentServiceError.schedulingFailed(
                    "the restore snapshot is unavailable or not ready")
            }
            guard
                SandboxGuestControlProtocol.supportsReidentify(
                    snapshot.guestControlProtocolVersion)
            else {
                throw AgentServiceError.schedulingFailed(
                    "snapshot guest is too old for sandbox forks (need guest control protocol >= \(SandboxGuestControlProtocol.reidentifyMinimumVersion))"
                )
            }

            // Candidates (issue #428): the snapshot's own agent restores from
            // local artifacts; once exported, any agent that satisfies the
            // recorded compatibility constraints (wire v13, same architecture,
            // same Firecracker version, CPU template or identical CPU model)
            // can stage the archive from object storage instead.
            var candidates: [SchedulableAgent] = []
            if let pinnedAgentID = snapshot.agentId,
                let pinned = schedulableAgents.first(where: { $0.id == pinnedAgentID }),
                WireProtocol.supportsSandboxFork(pinned.wireProtocolVersion ?? 0)
            {
                candidates.append(pinned)
            }
            if snapshot.isExported {
                let otherIDs =
                    schedulableAgents
                    .filter { $0.id != snapshot.agentId }
                    .compactMap { UUID(uuidString: $0.id) }
                if !otherIDs.isEmpty {
                    // The compatibility inputs (probed Firecracker version,
                    // host CPU model) live on the agent rows, not in
                    // SchedulableAgent — fetch them for the survivors only.
                    let rows = try await Agent.query(on: db).filter(\.$id ~~ otherIDs).all()
                    let compatibleIDs = Set(
                        rows.filter {
                            SandboxSnapshotCompatibility.restoreBlocker(snapshot: snapshot, target: $0) == nil
                        }.compactMap { $0.id?.uuidString })
                    candidates += schedulableAgents.filter { compatibleIDs.contains($0.id) }
                }
            }
            guard !candidates.isEmpty else {
                if snapshot.isExported {
                    throw AgentServiceError.schedulingFailed(
                        "no schedulable agent is compatible with the restore snapshot (need Firecracker \(SandboxSnapshotCompatibility.normalizedFirecrackerVersion(snapshot.firecrackerVersion) ?? "unknown") on \(snapshot.architecture ?? "unknown"), and a matching CPU template or identical CPU)"
                    )
                }
                throw AgentServiceError.schedulingFailed(
                    "snapshot artifacts are pinned to agent \(snapshot.agentId ?? "unknown"), which is not schedulable; export the snapshot to allow cross-agent placement"
                )
            }
            schedulableAgents = candidates
            if let rawArchitecture = snapshot.architecture {
                guard let architecture = CPUArchitecture(rawValue: rawArchitecture) else {
                    throw AgentServiceError.schedulingFailed(
                        "restore snapshot records unsupported architecture '\(rawArchitecture)'")
                }
                requiredArchitecture = architecture
            }
        }

        // A templated create needs an agent that actually applies
        // `SandboxSpec.cpuTemplate`; a pre-v13 agent would silently boot the
        // guest un-templated while the API reports a template (issue #428).
        if sandbox.cpuTemplate != nil {
            schedulableAgents = schedulableAgents.filter {
                WireProtocol.supportsSandboxSnapshotMobility($0.wireProtocolVersion ?? 0)
            }
            guard !schedulableAgents.isEmpty else {
                throw AgentServiceError.schedulingFailed(
                    "no schedulable agent supports CPU templates (need wire protocol >= \(WireProtocol.sandboxSnapshotMobilityMinimumVersion))"
                )
            }
        }

        let agentId: String
        do {
            agentId = try await app.scheduler.selectAndReserveAgent(
                requirements: VMPlacementRequirements(
                    cpu: sandbox.cpus,
                    memory: sandbox.memory,
                    disk: 0,
                    hypervisorType: .firecracker,
                    architecture: requiredArchitecture,
                    siteID: nil,
                    requiresSandboxRuntime: true
                ),
                vmId: sandboxId,
                from: schedulableAgents,
                coordination: app.coordination,
                vmName: sandbox.name
            )
        } catch let error as SchedulerError {
            app.logger.error("Scheduler failed to find suitable agent for sandbox: \(error)")
            throw AgentServiceError.schedulingFailed(error.description)
        }

        do {
            // Persist the placement, then sync: from here the sandbox is part
            // of the agent's desired state and every path (nudge now, periodic
            // timer later, reconnect sync) will carry it.
            sandbox.hypervisorId = agentId
            try await sandbox.save(on: db)

            app.logger.info(
                "Sandbox creation dispatched via desired-state sync",
                metadata: [
                    "sandboxId": .string(sandboxId),
                    "agentId": .string(agentId),
                ])

            await syncDesiredState(agentId: agentId)
        } catch {
            // The placement never became desired state, so nothing will ever
            // account for the reservation — release it rather than pinning
            // capacity until the TTL.
            await app.coordination.releaseReservation(agentId: agentId, vmId: sandboxId)
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
                if await app.coordination.isAgentPresent(agentKey: agent.identity.key) == false {
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
                siteID: agent.$site.id,
                wireProtocolVersion: agent.wireProtocolVersion,
                // Both signals are required (issue #415): the advertised
                // runtime proves the agent can boot sandboxes, and a v5+
                // protocol proves desired sandbox entries actually reach it.
                supportsSandboxWorkloads: agent.sandboxCapable
                    && WireProtocol.supportsSandboxSync(agent.wireProtocolVersion ?? 0),
                // Same two-signal rule for vTPM (issue #565): swtpm on the host
                // proves it can be realized, and a v17+ protocol proves the
                // machine profile reaches the agent at all.
                supportsVTPM: agent.tpmCapable
                    && WireProtocol.supportsMachineProfile(agent.wireProtocolVersion ?? 0),
                supportsMachineProfile: WireProtocol.supportsMachineProfile(agent.wireProtocolVersion ?? 0)
            )
        }
    }

    // MARK: - Message Sending

    /// Encode and push an envelope over a locally held socket.
    private func sendEnvelope(_ envelope: MessageEnvelope, toLocalAgent agentKey: String) throws {
        guard let websocket = app.websocketManager.getConnection(agentKey: agentKey) else {
            throw AgentServiceError.agentNotFound(agentKey)
        }
        let data = try WireProtocol.makeEncoder().encode(envelope)
        websocket.send(data)
    }

    private func sendMessageToLocalAgent<T: WebSocketMessage>(_ message: T, agentKey: String) async throws {
        try sendEnvelope(MessageEnvelope(message: message), toLocalAgent: agentKey)
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

        if let localName = app.websocketManager.agentKey(agentId: agentId) {
            return try await sendEnvelopeAwaitingLocalResponse(
                envelope, requestId: message.requestId, agentId: agentId,
                agentKey: localName, timeout: timeout)
        }

        guard let name = await agentKey(forId: agentId) else {
            throw AgentServiceError.agentNotFound(agentId)
        }
        guard case .forward(let replicaId) = await app.replicaBridge.remoteRoute(agentKey: name) else {
            // No route: the agent is offline everywhere. A route naming this
            // replica without a local socket is a stale claim from a torn-down
            // connection — the agent is equally unreachable from here.
            throw AgentServiceError.agentNotFound(agentId)
        }

        return try await app.replicaBridge.call(
            envelope, requestId: message.requestId, agentId: agentId,
            agentKey: name, toReplica: replicaId, timeout: timeout)
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
        agentKey: String,
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
                        try self.sendEnvelope(envelope, toLocalAgent: agentKey)

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

    /// Resume a pending local exchange's continuation with `CancellationError`,
    /// or record a tombstone if the exchange hasn't been armed yet (the arming
    /// task consumes it and resumes immediately). Cross-replica RPC waits carry
    /// their own equivalent inside `ReplicaMessageBridge`.
    private func cancelPendingExchange(_ requestId: String) {
        if let continuation = removePendingRequest(requestId) {
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

    /// Like `removePendingRequest`, but only consumes the pending request when
    /// it was actually dispatched to `agentId`. A correlated `success`/`error`
    /// is the one agent→control-plane message that isn't otherwise validated
    /// against the reporting connection, so without this check a compromised
    /// agent that learned another agent's in-flight `requestId` could resolve
    /// that exchange (e.g. spoof a volume-op or reboot result for a VM it does
    /// not host). Mirrors the ownership guards on heartbeat/observed-state.
    private func removePendingRequest(_ requestId: String, ifOwnedBy agentId: String)
        -> CheckedContinuation<AgentServiceResponse, Error>?
    {
        guard let request = pendingRequests[requestId] else { return nil }
        guard request.agentId == agentId else {
            app.logger.warning(
                "Dropping agent response whose requestId is owned by a different agent",
                metadata: [
                    "requestId": .string(requestId),
                    "reportingAgentId": .string(agentId),
                    "ownerAgentId": .string(request.agentId),
                ])
            return nil
        }
        pendingRequests.removeValue(forKey: requestId)
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

    func handleAgentResponse(_ envelope: MessageEnvelope, fromAgentKey agentKey: String) {
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
                    // Other message types are not request/response correlated.
                    return
                }
            } catch {
                app.logger.error("Failed to decode agent response envelope: \(error)")
                return
            }

            // Resolve the reporting connection's agent id so the response can
            // only resolve a request that was dispatched to *this* agent.
            guard let senderAgentId = await self.agentId(forKey: agentKey) else {
                app.logger.warning(
                    "Dropping agent response from a connection with no resolvable agent id",
                    metadata: ["agentKey": .string(agentKey), "requestId": .string(requestId)])
                return
            }

            guard let continuation = self.removePendingRequest(requestId, ifOwnedBy: senderAgentId) else {
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

// MARK: - ReplicaBridgeDelegate

extension AgentService: ReplicaBridgeDelegate {
    /// Holder half of a cross-replica RPC (`ReplicaMessageBridge` hook): run the
    /// forwarded exchange over the locally held socket and await the agent's
    /// correlated response. `deliverNudge` — the delegate's other half — lives
    /// with the desired-state sync code above.
    func runLocalExchange(
        _ envelope: MessageEnvelope,
        requestId: String,
        agentId: String,
        agentKey: String,
        timeout: Duration
    ) async throws -> AgentServiceResponse {
        try await sendEnvelopeAwaitingLocalResponse(
            envelope, requestId: requestId, agentId: agentId, agentKey: agentKey, timeout: timeout)
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
            setStorageValue(WebSocketManagerKey.self, to: newValue)
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
            setStorageValue(AgentServiceKey.self, to: newValue)
        }
    }

    /// The `AgentService` if one has already been created, without lazily
    /// creating it. Shutdown must not instantiate the service (that would arm
    /// the very heartbeat task shutdown exists to cancel).
    var agentServiceIfCreated: AgentService? {
        storage[AgentServiceKey.self]
    }
}

/// Instantiates the agent service at boot; at shutdown, cancels its heartbeat
/// monitor and waits for the loop to exit so the periodic database sweep
/// never outlives the application (an in-flight tick touching `app.db` after
/// core teardown is the "Core not configured" CI crash).
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

extension SandboxStatus {
    /// Sandbox counterpart of `VMStatus.assertsAgentPresence`: running,
    /// stopped (rootfs materialized), and exited sandboxes live in the
    /// agent's managed set. Sandboxes have no `.created`-style pre-placement
    /// status, so callers must additionally skip never-confirmed rows
    /// (`observedGeneration == 0`) — a fresh sandbox's `.stopped` predates
    /// any agent involvement.
    var assertsAgentPresence: Bool {
        self == .running || self == .stopped || self == .exited
    }
}
