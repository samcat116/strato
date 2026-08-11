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

}

actor AgentService {
    private let app: Application

    private var heartbeatTask: Task<Void, Never>?

    /// Last successful presence refresh per local socket. The wire sends both a
    /// heartbeat and an observed report every 20 seconds; refreshing on every
    /// frame doubles Valkey traffic without extending liveness. Half the TTL
    /// leaves a full retry window after a failed write.
    private var presenceRefreshedAt: [String: ContinuousClock.Instant] = [:]
    private static let presenceRefreshInterval: Duration =
        .seconds(Int64(CoordinationService.presenceTTLSeconds / 2))

    /// Keep the durable heartbeat comfortably inside the same 60-second
    /// liveness window while coalescing identical heartbeat/report pairs.
    private static let databaseHeartbeatRefreshInterval =
        TimeInterval(CoordinationService.presenceTTLSeconds / 2)

    /// The last refused sync this replica has logged per agent (STR-98).
    /// A refusal rides on every observed report until the agent's guard
    /// clears, so without this one stuck refusal would log and count on every
    /// heartbeat instead of once per refused sync. Replica-local: after a
    /// restart the first report re-logs, which is the right side to err on.
    private var reportedTeardownRefusalSyncIds: [String: String] = [:]

    /// The startup task that arms the replica pub/sub subscriptions. Tracked
    /// so `shutdown()` can wait for it — otherwise it can still be
    /// subscribing (touching `app` storage) while the application tears down.
    private var startupTask: Task<Void, Never>?

    /// Interval between heartbeat-monitor ticks. Injectable so tests can
    /// exercise the loop (and its shutdown race) without waiting 30s.
    private let heartbeatInterval: Duration

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

        // Strato deploys the control plane and agents as one wire-contract
        // unit. Refuse any skew before creating state or starting sync.
        let protocolVersion = message.protocolVersion
        guard protocolVersion == WireProtocol.currentVersion else {
            Telemetry.agentRegistrationFailed(reason: "unsupported_protocol")
            throw AgentServiceError.unsupportedProtocolVersion(agentName: agentName, version: protocolVersion)
        }

        let db = app.db
        var organizationScope = organizationScope
        var siteID = siteID
        let dependencyObservations = normalizedDependencyObservations(
            message.dependencyObservations, agentName: agentName)
        let dependencyObservationsReceivedAt = Date()
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
            if siteID == nil { siteID = existingAgent.$site.id }
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
            agent.architecture = message.architecture?.rawValue
            agent.operatingSystem = message.operatingSystem?.rawValue ?? agent.operatingSystem
            agent.hypervisors = message.effectiveHypervisors
            agent.networkCapability = message.networkCapability?.rawValue
            agent.hostInfo = message.hostInfo ?? agent.hostInfo
            agent.sandboxCapable = message.sandboxCapable ?? false
            // Re-read on every registration, like every other capability: a
            // guest-image rollback or a jailer that stopped resolving must be
            // able to take the flag back down, and the agent re-probes all
            // three inputs each time it reconnects.
            agent.sandboxNetworkingCapable = message.sandboxNetworkingCapable ?? false
            agent.tpmCapable = message.tpmCapable ?? false
            agent.resolverCapable = message.resolverCapable ?? false
            agent.dependencyObservations = dependencyObservations
            agent.dependencyObservationsReceivedAt = dependencyObservationsReceivedAt
            _ = agent.updateAvailableResources(message.resources)
            agent.lastHeartbeat = Date()
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
            guard let siteID else {
                throw Abort(.badRequest, reason: "Agent enrollment requires a site")
            }
            // Create new agent
            agent = Agent.from(registration: message, name: agentName, trustDomain: trustDomain)
            agent.dependencyObservations = dependencyObservations
            agent.dependencyObservationsReceivedAt = dependencyObservationsReceivedAt
            agent.$site.id = siteID
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
            if agent.id != nil {
                refusalReason = "agent organization is fixed by its required site"
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

        // A site with no designated network controller reconciles no topology
        // at all, so the first OVN-capable node to join one takes the job
        // (issue #743). Without this the common single-node deployment — new
        // org, its default site, one enrolled node — comes up with switches
        // authored by nobody and every VM parked on a logical switch that
        // never appears, with no API-visible symptom. An existing designation
        // is never displaced. The sync pushed right after this registration
        // carries the new controller its authoritative topology.
        //
        // Re-validation runs first: every condition the designation was made
        // under is a property of *this* registration, and an agent that came
        // back in user-mode or on a rolled-back binary would otherwise keep the
        // job while authoring nothing (issue #833). When it hands the job back,
        // an eligible peer claims it on its own next registration.
        let persistedSiteID = agent.$site.id
        await SiteNetworkAuthority.revalidateDesignation(
            agent: agent, siteID: persistedSiteID, on: db, logger: app.logger)
        await SiteNetworkAuthority.designateIfUnset(
            agent: agent, siteID: persistedSiteID, on: db, logger: app.logger)

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

        // Attach the UUID to the live socket so local routing (console and
        // exec streams) can resolve it without a database read. No-op when no
        // socket exists (tests).
        app.websocketManager.associate(agentKey: agentKey, agentId: agentUUID.uuidString)

        // Publish presence to the coordination store so every control-plane
        // process — not just the one holding this socket — can see the agent.
        await refreshAgentPresenceIfNeeded(agentKey: agentKey, force: true)

        Telemetry.agentConnected()
        Telemetry.recordAgentUp(agentName: Self.displayName(forKey: agentKey), up: true)
        for observation in dependencyObservations {
            Telemetry.recordDependency(
                agentName: agent.name,
                observation: observation,
                receivedAt: dependencyObservationsReceivedAt)
        }
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

        app.websocketManager.removeConnection(agentKey: agentKey)
        // The eventual socket close skips its cleanup once the connection is
        // gone (`removeConnection(ifCurrent:)` no longer matches), so console
        // and exec sessions must be torn down here for the graceful-unregister
        // path.
        app.consoleSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        app.sandboxExecSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        presenceRefreshedAt.removeValue(forKey: agentKey)
        await app.coordination.clearAgentPresence(agentKey: agentKey)

        Telemetry.agentDisconnected(reason: "unregister")
        Telemetry.recordAgentUp(agentName: Self.displayName(forKey: agentKey), up: false)
        Telemetry.recordDependenciesUnavailable(
            agentName: agent.name, observations: agent.dependencyObservations)
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

        if let agentUUID = UUID(uuidString: agentId),
            let agent = try? await Agent.find(agentUUID, on: app.db)
        {
            Telemetry.recordDependenciesUnavailable(
                agentName: agent.name, observations: agent.dependencyObservations)
        }

        app.websocketManager.removeConnection(agentKey: agentKey)
        // Same reasoning as `unregisterAgent`: the socket-close handler will
        // not run its cleanup once the connection entry is gone.
        app.consoleSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        app.sandboxExecSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        // Drop the cluster-visible claim that this agent is alive, so the
        // stale-agent sweep stops skipping it. This used to fall out of
        // clearing the socket-route key, which shared a write with presence;
        // with the route gone (STR-152) presence is cleared on its own.
        presenceRefreshedAt.removeValue(forKey: agentKey)
        await app.coordination.clearAgentPresence(agentKey: agentKey)

        app.logger.info(
            "Agent force unregistered",
            metadata: ["agentId": .string(agentId), "agentKey": .string(agentKey)])
    }

    /// Socket-close cleanup. Only reached when this socket was still the
    /// agent's current *local* connection — `removeConnection(ifCurrent:)` in
    /// the close handler already drops a delayed close superseded by a
    /// same-replica reconnect.
    ///
    /// This used to consult the `agent:{name}:replica` routing key and also
    /// skip the offline mark when the agent had reconnected to *another*
    /// replica. The key existed for the cross-replica RPC bridge and went with
    /// it (STR-152), so a close delayed past such a reconnect now writes
    /// `offline` under a live connection until the holding replica's next
    /// frame writes `.online` back — bounded by the agent's heartbeat interval,
    /// about 20 seconds.
    ///
    /// **That window is not cosmetic**, and it is worth being precise about the
    /// cost: `status == .online` is an admission gate, not just a badge.
    /// `SnapshotArtifactMutation.requireCaptureCapableAgent` refuses a capture
    /// with `409 Agent is offline`, and `selectVolumeAgent` and the scheduler's
    /// `filterEligibleAgents` both skip the host. So a capture aimed at that
    /// agent is *rejected* rather than delayed, and new placements route around
    /// a healthy node.
    ///
    /// Presence is deliberately not used as a stand-in. `agent:{name}:presence`
    /// is a single fleet-wide key with no owner attribution — this replica
    /// refreshed it within the last half-TTL too — so "presence is live" cannot
    /// distinguish another replica's claim from our own, and skipping the
    /// offline mark whenever it is live would leave a genuinely dead agent
    /// `online` for up to a full TTL on the single-replica deployments that are
    /// the common case. That inverts the failure into the more damaging
    /// direction: admitting placements onto a host that is gone, rather than
    /// refusing them onto one that is live. Closing the window properly needs a
    /// signal that says *which* connection is current, which is the directory
    /// this change deleted.
    func removeAgent(_ agentKey: String) async {
        presenceRefreshedAt.removeValue(forKey: agentKey)

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
                    Telemetry.recordDependenciesUnavailable(
                        agentName: agent.name, observations: agent.dependencyObservations)
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

        // The database row is the registry (issue #261), but the heartbeat
        // and observed report carry the same snapshot on the same cadence.
        // Persist only real resource/status changes or one heartbeat per half
        // TTL so identical pairs do not churn the row.
        if applyPeriodicAgentState(
            message.resources,
            dependencyObservations: message.dependencyObservations,
            to: agent)
        {
            try await agent.save(on: db)
        }

        // Refresh the agent's presence key so its liveness stays visible
        // cluster-wide, not just to the process holding this socket.
        await refreshAgentPresenceIfNeeded(agentKey: agentKey)

        app.logger.debug("Agent heartbeat updated", metadata: ["agentId": .string(message.agentId)])
    }

    /// Apply the mutable fields from a periodic agent report. A real state
    /// change always persists and refreshes `lastHeartbeat`; otherwise the
    /// timestamp advances at half the presence TTL.
    private func applyPeriodicAgentState(
        _ resources: AgentResources,
        dependencyObservations: [NodeDependencyObservation]?,
        to agent: Agent
    ) -> Bool {
        var changed = agent.updateAvailableResources(resources)
        let now = Date()
        if let dependencyObservations {
            let storedObservations = normalizedDependencyObservations(
                agent.dependencyObservations, agentName: agent.name)
            let incomingObservations = normalizedDependencyObservations(
                dependencyObservations, agentName: agent.name)
            let previous = Dictionary(uniqueKeysWithValues: storedObservations.map { ($0.id, $0) })
            if agent.dependencyObservations != incomingObservations {
                agent.dependencyObservations = incomingObservations
                changed = true
            }
            agent.dependencyObservationsReceivedAt = now
            for observation in incomingObservations {
                Telemetry.recordDependency(
                    agentName: agent.name,
                    observation: observation,
                    receivedAt: now)
                if previous[observation.id]?.functionalState != observation.functionalState
                    || previous[observation.id]?.reason?.code != observation.reason?.code
                {
                    app.logger.log(
                        level: observation.functionalState == .unhealthy ? .error : .info,
                        "Agent dependency state changed",
                        metadata: [
                            "agent": .string(agent.name),
                            "dependency": .string(observation.id.rawValue),
                            "state": .string(observation.functionalState.rawValue),
                            "reasonCode": .string(observation.reason?.code.rawValue ?? "none"),
                        ])
                }
            }
        }
        if agent.status != .online {
            agent.status = .online
            changed = true
        }

        let heartbeatDue =
            agent.lastHeartbeat.map {
                now.timeIntervalSince($0) >= Self.databaseHeartbeatRefreshInterval
            } ?? true
        if changed || heartbeatDue {
            agent.lastHeartbeat = now
            return true
        }
        return false
    }

    /// Canonicalize an agent-controlled wire array before it is indexed or
    /// persisted. A dependency ID names one registry module, so duplicate IDs
    /// are malformed; retaining the freshest sample keeps ingestion resilient
    /// without letting array order replace newer health with older health.
    private func normalizedDependencyObservations(
        _ observations: [NodeDependencyObservation],
        agentName: String
    ) -> [NodeDependencyObservation] {
        let normalized = Self.normalizedDependencyObservations(observations)
        guard normalized.count != observations.count else { return normalized }

        var seen = Set<NodeDependencyID>()
        let duplicateIDs = Set(
            observations.compactMap { observation in
                seen.insert(observation.id).inserted ? nil : observation.id.rawValue
            }
        ).sorted()
        app.logger.warning(
            "Agent reported duplicate dependency observations; retaining the freshest sample",
            metadata: [
                "agent": .string(agentName),
                "dependencyIds": .array(duplicateIDs.map { .string($0) }),
            ])
        return normalized
    }

    /// Pure test seam for the dependency-observation wire invariant.
    static func normalizedDependencyObservations(
        _ observations: [NodeDependencyObservation]
    ) -> [NodeDependencyObservation] {
        var orderedIDs: [NodeDependencyID] = []
        var byID: [NodeDependencyID: NodeDependencyObservation] = [:]
        for observation in observations {
            guard let current = byID[observation.id] else {
                orderedIDs.append(observation.id)
                byID[observation.id] = observation
                continue
            }
            if observation.checkedAt >= current.checkedAt {
                byID[observation.id] = observation
            }
        }
        return orderedIDs.compactMap { byID[$0] }
    }

    /// Refresh the agent's presence key at most once per half TTL. Failed
    /// attempts are deliberately not recorded so the next incoming frame
    /// retries instead of allowing a previously live key to expire.
    private func refreshAgentPresenceIfNeeded(agentKey: String, force: Bool = false) async {
        let now = ContinuousClock.now
        if !force, let lastRefresh = presenceRefreshedAt[agentKey],
            lastRefresh.duration(to: now) < Self.presenceRefreshInterval
        {
            return
        }

        if await app.coordination.recordAgentPresence(agentKey: agentKey) {
            presenceRefreshedAt[agentKey] = now
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

                    // Degrade workloads that missed their convergence deadline
                    // (STR-147). Lock-free — see `sweepStuckConvergence`.
                    await sweepStuckConvergence()

                    try self.checkTickPreconditions()

                    // Surface desired/observed divergence when no mutation is
                    // outstanding (STR-123). Each row carries its own
                    // compare-and-swap warning claim across replicas.
                    await sweepSteadyStateDivergence()

                    try self.checkTickPreconditions()

                    // Release volumes still naming a VM that no longer exists
                    // (STR-129).
                    await sweepStrandedVolumeAttachments()

                    try self.checkTickPreconditions()

                    // Reap workloads whose finalizers all cleared but whose row
                    // outlived the process that owed the removal (STR-144).
                    await sweepOrphanedTerminatingResources()

                    try self.checkTickPreconditions()

                    // Delete sandboxes past their TTL, and reap terminal
                    // sandbox records past the retention window (issue #424).
                    await sweepExpiredSandboxes()

                    try self.checkTickPreconditions()

                    // Delete snapshot artifacts past their retention deadline
                    // (STR-150) — the `ttlSecondsAfterFinished` answer durable
                    // artifact objects need and fire-and-forget RPCs did not.
                    await SnapshotRetentionSweep.run(app: app)

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

    /// Internal so tests can drive one monitor pass without waiting for the timer.
    func checkStaleAgents(dependencyMetricsFactory: (any MetricsFactory)? = nil) async {
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

            // Not gated on a sweep lock even though the state is shared: the
            // offline write is idempotent, and the presence check keeps
            // replicas from disagreeing — an agent heartbeating through any
            // replica keeps a live presence key and is skipped.
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

                agent.status = .offline
                Telemetry.recordDependenciesUnavailable(
                    agentName: agent.name,
                    observations: agent.dependencyObservations,
                    factory: dependencyMetricsFactory)
                try await agent.save(on: app.db)

                Telemetry.agentDisconnected(reason: "stale")
                Telemetry.recordAgentUp(agentName: agent.name, up: false)
                await WebhookEvents.emitAgentPresence(
                    agent: agent, connected: false, reason: "stale", on: app.db, logger: app.logger)
                app.logger.info(
                    "Agent heartbeat stale past threshold; marked offline",
                    metadata: ["agentName": .string(agent.name)])
                await warnIfSiteNetworkController(agent)
            }
        } catch {
            app.logger.error("Stale-agent sweep failed: \(error)")
        }
    }

    /// Raises the alarm when the node that just went quiet is some site's
    /// designated network controller.
    ///
    /// This is the highest-value signal in the site-authority area: nothing
    /// else in the site can author topology while it is gone, so *every* new
    /// networked workload there is about to be refused, and already-running
    /// ones keep running — which is exactly what makes the outage easy to miss
    /// (issue #833). Best effort: a failure here must not abort the sweep.
    private func warnIfSiteNetworkController(_ agent: Agent) async {
        guard let agentID = agent.id else { return }
        do {
            let controlled = try await Site.query(on: app.db)
                .filter(\.$networkControllerAgent.$id == agentID)
                .all()
            for site in controlled {
                Telemetry.recordSiteNetworkControllerUp(site: site.name, up: false)
                app.logger.warning(
                    "Site network controller went offline; nothing authors the site's network topology until it returns",
                    metadata: [
                        "agentName": .string(agent.name),
                        "site": .string(site.name),
                        "graceSeconds": .stringConvertible(
                            Int(SiteNetworkAuthority.controllerOfflineGrace)),
                    ])
            }
        } catch {
            app.logger.warning(
                "Failed to check whether the stale agent is a site's network controller",
                metadata: ["agentName": .string(agent.name), "error": .string("\(error)")])
        }
    }

    /// Marks a VM or sandbox `degraded` once its convergence deadline passes
    /// with the outstanding mutations still unconverged (ADR 0001 stage 4,
    /// STR-147).
    ///
    /// This is what the stuck-*operation* sweep was for lifecycle mutations,
    /// now that they keep no operation row: the deadline every accepted
    /// mutation stamps replaces the row's `created_at` plus its per-kind
    /// budget, and the resource's own `conditions.degraded` replaces the
    /// verdict.
    ///
    /// **Deliberately not a cluster singleton.** Marking degraded is idempotent
    /// (`recordFailure` no-ops once `failedGeneration == generation`) and
    /// commutative (every replica computes the same verdict from the same
    /// row), so two replicas sweeping the same resource cost one wasted write
    /// at worst — where the operation sweep genuinely needed the lock, because
    /// its verdict was a state transition two writers could disagree about.
    /// One less thing whose correctness depends on Valkey, which is the point
    /// of ADR 0001's multi-replica argument.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepStuckConvergence() async {
        guard !isShutDown, !app.didShutdown else { return }

        let db = app.db
        let now = Date()

        do {
            try await degradeOverdue(VM.self, now: now, on: db)
            try await degradeOverdue(Sandbox.self, now: now, on: db)
            // Volumes joined the same backstop in STR-148, replacing the
            // status-and-timestamp sweep that used to guess which transitional
            // status had been abandoned. Snapshot artifacts followed in
            // STR-150, replacing the RPC timeouts that used to decide a
            // capture's fate.
            try await degradeOverdue(Volume.self, now: now, on: db)
            try await degradeOverdue(VolumeSnapshot.self, now: now, on: db)
            try await degradeOverdue(VMSnapshot.self, now: now, on: db)
            try await degradeOverdue(SandboxSnapshot.self, now: now, on: db)
        } catch {
            app.logger.error("Stuck-convergence sweep failed: \(error)")
        }
    }

    /// Fixed grace before a resting desired/observed mismatch becomes
    /// operationally divergent. Kept longer than ordinary report jitter and
    /// short agent outages, while remaining alertable within one quarter-hour.
    static let steadyStateDivergenceGrace: TimeInterval = 15 * 60

    struct SteadyStateDivergenceCounts: Equatable, Sendable {
        var vms = 0
        var sandboxes = 0
        var newlyDetected = 0
    }

    /// Detect steady-state divergence for workloads with no convergence
    /// deadline. The metric is level-triggered; warning logs are edge-triggered
    /// by `divergence_detected_at`, claimed atomically so every replica may run
    /// this sweep without duplicating one episode's warning.
    @discardableResult
    func sweepSteadyStateDivergence(now: Date = Date()) async -> SteadyStateDivergenceCounts {
        guard !isShutDown, !app.didShutdown else { return SteadyStateDivergenceCounts() }
        guard let sql = app.db as? any SQLDatabase else {
            app.logger.error("Steady-state divergence sweep requires an SQL database")
            return SteadyStateDivergenceCounts()
        }

        let cutoff = now.addingTimeInterval(-Self.steadyStateDivergenceGrace)
        do {
            let vms = try await divergentVMRows(before: cutoff, on: sql)
            let sandboxes = try await divergentSandboxRows(before: cutoff, on: sql)
            var counts = SteadyStateDivergenceCounts(vms: vms.count, sandboxes: sandboxes.count)

            Telemetry.recordDivergedWorkloads(kind: "vm", count: counts.vms)
            Telemetry.recordDivergedWorkloads(kind: "sandbox", count: counts.sandboxes)

            for row in vms where try await claimVMDivergence(row.id, at: now, before: cutoff, on: sql) {
                counts.newlyDetected += 1
                logDivergence(row, kind: "vm")
            }
            for row in sandboxes
            where try await claimSandboxDivergence(row.id, at: now, before: cutoff, on: sql) {
                counts.newlyDetected += 1
                logDivergence(row, kind: "sandbox")
            }
            return counts
        } catch {
            app.logger.error("Steady-state divergence sweep failed: \(error)")
            return SteadyStateDivergenceCounts()
        }
    }

    private struct DivergedWorkloadRow: Decodable {
        let id: UUID
        let name: String
        let desiredStatus: String
        let status: String
        let generation: Int64
        let observedGeneration: Int64
        let lastError: String?

        enum CodingKeys: String, CodingKey {
            case id, name, status, generation
            case desiredStatus = "desired_status"
            case observedGeneration = "observed_generation"
            case lastError = "last_error"
        }
    }

    private struct DivergenceClaim: Decodable { let id: UUID }

    private func divergentVMRows(
        before cutoff: Date, on sql: any SQLDatabase
    ) async throws -> [DivergedWorkloadRow] {
        try await sql.raw(
            """
            SELECT id, name, desired_status, status, generation, observed_generation, last_error
            FROM vms
            WHERE convergence_deadline IS NULL
              AND desired_status <> 'Absent'
              AND observed_generation >= generation
              AND COALESCE(status_changed_at, created_at, updated_at) <= \(bind: cutoff)
              AND NOT (
                    (desired_status = 'Running' AND status = 'Running')
                 OR (desired_status = 'Paused' AND status = 'Paused')
                 OR (desired_status = 'Shutdown' AND status IN ('Shutdown', 'Created'))
              )
            """
        ).all(decoding: DivergedWorkloadRow.self)
    }

    private func divergentSandboxRows(
        before cutoff: Date, on sql: any SQLDatabase
    ) async throws -> [DivergedWorkloadRow] {
        try await sql.raw(
            """
            SELECT id, name, desired_status, status, generation, observed_generation, last_error
            FROM sandboxes
            WHERE convergence_deadline IS NULL
              AND desired_status <> 'Absent'
              AND observed_generation >= generation
              AND COALESCE(status_changed_at, created_at, updated_at) <= \(bind: cutoff)
              AND NOT (
                    (desired_status = 'Running' AND status IN ('Running', 'Exited'))
                 OR (desired_status = 'Stopped' AND status IN ('Stopped', 'Exited'))
              )
            """
        ).all(decoding: DivergedWorkloadRow.self)
    }

    private func claimVMDivergence(
        _ id: UUID, at now: Date, before cutoff: Date, on sql: any SQLDatabase
    ) async throws -> Bool {
        let rows = try await sql.raw(
            """
            UPDATE vms SET divergence_detected_at = \(bind: now)
            WHERE id = \(bind: id)
              AND divergence_detected_at IS NULL
              AND convergence_deadline IS NULL
              AND desired_status <> 'Absent'
              AND observed_generation >= generation
              AND COALESCE(status_changed_at, created_at, updated_at) <= \(bind: cutoff)
              AND NOT (
                    (desired_status = 'Running' AND status = 'Running')
                 OR (desired_status = 'Paused' AND status = 'Paused')
                 OR (desired_status = 'Shutdown' AND status IN ('Shutdown', 'Created'))
              )
            RETURNING id
            """
        ).all(decoding: DivergenceClaim.self)
        return !rows.isEmpty
    }

    private func claimSandboxDivergence(
        _ id: UUID, at now: Date, before cutoff: Date, on sql: any SQLDatabase
    ) async throws -> Bool {
        let rows = try await sql.raw(
            """
            UPDATE sandboxes SET divergence_detected_at = \(bind: now)
            WHERE id = \(bind: id)
              AND divergence_detected_at IS NULL
              AND convergence_deadline IS NULL
              AND desired_status <> 'Absent'
              AND observed_generation >= generation
              AND COALESCE(status_changed_at, created_at, updated_at) <= \(bind: cutoff)
              AND NOT (
                    (desired_status = 'Running' AND status IN ('Running', 'Exited'))
                 OR (desired_status = 'Stopped' AND status IN ('Stopped', 'Exited'))
              )
            RETURNING id
            """
        ).all(decoding: DivergenceClaim.self)
        return !rows.isEmpty
    }

    private func logDivergence(_ row: DivergedWorkloadRow, kind: String) {
        var metadata: Logger.Metadata = [
            "kind": .string(kind),
            "workloadId": .string(row.id.uuidString),
            "name": .string(row.name),
            "desiredStatus": .string(row.desiredStatus),
            "observedStatus": .string(row.status),
            "generation": .stringConvertible(row.generation),
            "observedGeneration": .stringConvertible(row.observedGeneration),
        ]
        if let lastError = row.lastError { metadata["lastError"] = .string(lastError) }
        app.logger.warning(
            "Workload remains divergent with no mutation outstanding",
            metadata: metadata)
    }

    /// One workload kind's overdue rows. The deadline is the only column the
    /// query filters on — no kind lookup, which is exactly what stamping a
    /// deadline instead of a `lastMutationKind` bought.
    private func degradeOverdue<R: ConvergingResource>(
        _ type: R.Type, now: Date, on db: any Database
    ) async throws {
        let overdue = try await R.overdueForConvergence(at: now, on: db)

        for resource in overdue {
            guard let id = resource.id else { continue }
            // Claim the timeout before doing anything with it. Clearing the
            // deadline is the claim, so of two replicas sweeping the same row
            // exactly one proceeds — which is what lets this run everywhere
            // without a lock while still emitting one completion webhook.
            switch try await resource.claimConvergenceTimeout(on: db) {
            case .claimed:
                break
            case .superseded(let actualGeneration):
                Telemetry.desiredStateWriteConflict(
                    resourceKind: R.operationResourceKind.rawValue, writer: "stuck_convergence")
                app.logger.warning(
                    "Dropped a convergence timeout after newer desired state superseded it",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(id.uuidString),
                        "expectedGeneration": .stringConvertible(resource.generation),
                        "actualGeneration": .stringConvertible(actualGeneration),
                    ])
                continue
            case .alreadyClaimed, .missing:
                continue
            }

            // The deadline is a backstop, not the verdict: a resource that
            // converged between the query and here (or whose deadline the
            // applier has not cleared yet) is left alone — the claim above has
            // already dropped the deadline, which is all that was owed. A
            // terminating resource never reports converged — it is on its way
            // out, not converging on anything — so a stuck delete falls through
            // and degrades, which is what a delete blocked on a finalizer
            // should look like.
            // Nothing to save: the claim already cleared the deadline in SQL,
            // and writing the whole row from a model read before the claim
            // would put this sweep's stale snapshot over a concurrent report.
            guard !resource.isConverged else { continue }

            // The mutation kind is read for one thing — whether a never-settled
            // `create` should escalate to `.error` — and comes from the audit
            // trail rather than a column on the resource, so overlapping
            // mutations cannot make it disagree with what was actually asked
            // for. A resource with no recorded mutation predates the trail;
            // `.boot` is the conservative stand-in, since it resolves nothing
            // a create would not.
            let mutation =
                try await ResourceEvent.latest(
                    .requested, resourceKind: R.operationResourceKind, resourceID: id, on: db
                )?.mutation ?? .boot

            let outcome = try await ResourceConvergence.recordFailure(
                resource, mutation: mutation,
                reason: "Timed out: the agent did not converge to generation "
                    + "\(resource.generation) before the deadline",
                telemetryReason: "stuck_convergence", on: db)
            if case .superseded(let actualGeneration) = outcome {
                app.logger.warning(
                    "Dropped a convergence timeout after newer desired state superseded it",
                    metadata: [
                        "resourceKind": .string(R.operationResourceKind.rawValue),
                        "resourceId": .string(id.uuidString),
                        "actualGeneration": .stringConvertible(actualGeneration),
                    ])
            }
            guard outcome == .recorded else { continue }

            app.logger.warning(
                "Resource did not converge before its deadline; marked degraded",
                metadata: [
                    "resourceKind": .string(R.operationResourceKind.rawValue),
                    "resourceId": .string(id.uuidString),
                    "mutation": .string(mutation.rawValue),
                    "targetGeneration": .stringConvertible(resource.generation),
                    "observedGeneration": .stringConvertible(resource.observedGeneration),
                ])
        }
    }

    /// Releases volumes left holding an attachment to a VM that no longer
    /// exists (STR-129).
    ///
    /// This was the third and last half of the stuck-operation sweep, and the
    /// only one that never had anything to do with operations. The other two —
    /// failing rows past their per-kind budget, and marking transitional VMs
    /// and sandboxes `.error` — went with the table in STR-152: a mutation's
    /// deadline and the resource's own `conditions.degraded` say both things
    /// now, and `sweepStuckConvergence` writes them without a cluster lock.
    ///
    /// The VM reap releases volumes inside the delete transaction, so this
    /// should never fire — it is the backstop for a replica still running an
    /// older build during a rolling upgrade, and for any future path that
    /// removes a VM without going through the reap.
    ///
    /// No age budget, unlike the convergence sweep: nothing is in flight that
    /// could still land, and until the columns are cleared the volume names a
    /// device on a VM that does not exist. The generation bump is what makes
    /// the agent act on it — a desired entry no newer than the last one applied
    /// is dropped, so clearing the columns alone would leave the disk plugged
    /// into a guest the control plane no longer describes.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepStrandedVolumeAttachments() async {
        // Never touch app.db (a fatal error, not a throw, after core
        // teardown) once shutdown has begun — this was the crashing frame of
        // the recurring "Core not configured" CI crash.
        guard !isShutDown, !app.didShutdown else { return }
        // Cluster-singleton: the repair is idempotent, but each pass bumps a
        // generation, so two replicas racing would churn the agent's sync for
        // nothing.
        guard await app.coordination.acquireSweepLock("stranded_attachments") else {
            app.logger.debug("Skipping stranded-attachment sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db

        do {
            // This mirrors the schema constraint column for column: the fields
            // describe one state, so they must agree.
            let strandedVolumes = try await Volume.query(on: db)
                .filter(\.$vm.$id == nil)
                .group(.or) { unresolved in
                    unresolved.filter(\.$deviceName != nil)
                    unresolved.filter(\.$bootOrder != nil)
                    unresolved.filter(\.$attachedAgentId != nil)
                    unresolved.filter(\.$readonly == true)
                }
                .all()

            for volume in strandedVolumes {
                guard let volumeID = volume.id else { continue }
                let repaired = try await db.transaction { tx -> Bool in
                    guard try await volume.lockAndRefresh(on: tx) else { return false }
                    guard volume.$vm.id == nil,
                        volume.deviceName != nil || volume.bootOrder != nil
                            || volume.attachedAgentId != nil || volume.readonly
                    else { return false }
                    let expectedGeneration = volume.generation
                    VolumeAttachmentService.clearAttachment(volume)
                    guard
                        case .applied = try await volume.advanceDesiredStateGeneration(
                            expectedGeneration: expectedGeneration, on: tx)
                    else { return false }
                    try await volume.save(on: tx)
                    return true
                }
                guard repaired else { continue }

                app.logger.warning(
                    "Volume left attachment fields set with no VM; released",
                    metadata: [
                        "volumeId": .string(volumeID.uuidString),
                        "generation": .string("\(volume.generation)"),
                    ])
            }
        } catch {
            app.logger.error("Stranded-attachment sweep failed: \(error)")
        }
    }

    /// How long a terminating workload may sit with every finalizer cleared
    /// before this sweep reaps it. Generous on purpose: the delete path's own
    /// reap follows its finalizer clear by milliseconds, so anything this old
    /// lost the process that owed it (crash, drain, OOM kill) rather than
    /// being slow.
    static let orphanedTerminatingBudgetSeconds: TimeInterval = 60

    /// Reaps workloads whose finalizers all cleared but whose row survived
    /// (STR-144). Clearing a token and removing the row are two commits; a
    /// crash between them leaves a terminating row with an empty list, which
    /// still holds quota and still appears in listings.
    ///
    /// Participants with a repeating trigger heal themselves — every
    /// observed-state report re-drives `agent.absent`. This is the backstop for
    /// the ones that do not: the offline/unplaced direct path is a one-shot
    /// background task, and the sandbox expiry sweep's deletions are unattended,
    /// so without this a drained replica could strand a row with nobody left to
    /// notice. It is also what lets a future participant be added without each
    /// one inventing its own retry.
    ///
    /// Internal rather than private so tests can drive a pass directly.
    func sweepOrphanedTerminatingResources() async {
        guard !isShutDown, !app.didShutdown else { return }
        // Cluster-singleton like the other sweeps: the reap claim would make
        // concurrent passes safe anyway, but there is no reason to pay for
        // every replica scanning.
        guard await app.coordination.acquireSweepLock("orphaned_terminating") else { return }

        let db = app.db
        let cutoff = Date().addingTimeInterval(-Self.orphanedTerminatingBudgetSeconds)

        do {
            // `finalizers` is filtered in Swift, not SQL: Fluent cannot express
            // array cardinality, and the scanned set is only workloads that
            // have been terminating for at least a minute — normally empty.
            let vms = try await VM.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(vms.filter { $0.finalizers.isEmpty }, kind: "VM", on: db)

            let sandboxes = try await Sandbox.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(
                sandboxes.filter { $0.finalizers.isEmpty }, kind: "sandbox", on: db)

            let volumes = try await Volume.query(on: db)
                .filter(\.$desiredStatus == .absent)
                .filterAged(before: cutoff, by: \.$updatedAt, fallingBackTo: \.$createdAt)
                .all()
            await reapOrphanedTerminating(
                volumes.filter { $0.finalizers.isEmpty }, kind: "volume", on: db)

            // Snapshot artifacts (STR-150). Their `agent.absent` trigger is the
            // same repeating observed-state report, but the retention sweep's
            // deletions are unattended in exactly the way the sandbox expiry
            // sweep's are, so they need the same backstop.
            //
            // No age cutoff here, unlike the three above, and it is not an
            // oversight: `finalizers.isEmpty` on a terminating row already
            // means nobody owes cleanup — either the token cleared, or none was
            // stamped because the artifact never reached an agent. The cutoff
            // exists to keep the workload scan cheap on a large table, and the
            // terminating set here is normally empty.
            try await reapOrphanedTerminatingSnapshots(
                VolumeSnapshot.self, kind: "volume snapshot", on: db)
            try await reapOrphanedTerminatingSnapshots(
                VMSnapshot.self, kind: "checkpoint", on: db)
            try await reapOrphanedTerminatingSnapshots(
                SandboxSnapshot.self, kind: "sandbox snapshot", on: db)
        } catch {
            app.logger.error("Orphaned-terminating sweep failed: \(error)")
        }
    }

    /// The snapshot-artifact half of the orphan sweep. Separate from the
    /// workload half only because `desired_status` is a different enum type per
    /// family, which Fluent's field projection cannot be abstracted over.
    private func reapOrphanedTerminatingSnapshots<A: SnapshotArtifactResource>(
        _ type: A.Type, kind: String, on db: any Database
    ) async throws {
        let terminating = try await A.terminating(on: db).filter { $0.finalizers.isEmpty }
        await reapOrphanedTerminating(terminating, kind: kind, on: db)
    }

    /// Drives one kind's orphans through the ordinary clear path — clearing an
    /// already-cleared token on an empty list reaps — so the sweep shares the
    /// reap claim and per-kind teardown instead of re-spelling either.
    private func reapOrphanedTerminating<R: FinalizableResource>(
        _ resources: [R], kind: String, on db: any Database
    ) async {
        for resource in resources {
            guard let id = resource.id else { continue }
            do {
                let outcome = try await ResourceFinalizerService.clear(
                    .agentAbsent, from: resource, on: db, app: app)
                guard case .reaped = outcome else { continue }
                app.logger.warning(
                    "Reaped a terminating \(kind) whose row outlived its last finalizer",
                    metadata: ["resourceId": .string(id.uuidString)])
            } catch {
                app.logger.error(
                    "Failed to reap orphaned terminating \(kind): \(error)",
                    metadata: ["resourceId": .string(id.uuidString)])
            }
        }
    }

    // The transitional-status backstop — VMs and sandboxes sitting in
    // `.starting`/`.stopping` past 120s with no pending operation, marked
    // `.error` — went with the operations table (STR-152). It predated
    // generations: with no `observedGeneration` to compare against, "stuck" had
    // to be inferred from a status and a clock, and the pending-operation query
    // existed only to stop the two backstops fighting. `sweepStuckConvergence`
    // says the same thing from the deadline every accepted mutation stamps, and
    // resolves through the same per-kind `resolveForStuckOperation`.

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
    /// /api/sandboxes/:id`: desired `.absent` plus its attribution event in one
    /// transaction, then either agent teardown (the row goes once a report
    /// confirms absence) or — with no agent to converge on — a direct record
    /// delete. Sharing the path is the point: quota release, reservation
    /// release, and the audit trail all come for free, and the `system` actor
    /// on the event makes the unattended deletion attributable.
    private func expireSandbox(_ sandbox: Sandbox, reason: SandboxExpiryReason, on db: Database) async {
        guard let sandboxID = sandbox.id else { return }

        var onlineAgentID: String?
        if let agentId = sandbox.hypervisorId, let agent = await getAgentInfo(agentId), agent.status == .online {
            onlineAgentID = agentId
        }

        // With no agent to converge on, the expiry owns the teardown itself;
        // otherwise `.stateSync` nudges the agent holding it.
        let strategy: ResourceMutation.Dispatch =
            onlineAgentID == nil
            ? .directResolution { @Sendable [app = self.app] db in
                try await SandboxController.performDirectDeletion(sandbox: sandbox, on: db, app: app)
            }
            : .stateSync

        do {
            let accepted = try await app.resourceMutation.accept(
                .delete, on: sandbox, actor: .system, dispatch: strategy, on: db, app: app
            ) { db in
                try await SandboxController.requireSnapshotLineageDeletable(
                    for: sandboxID, on: db)
                // Same stamp-then-mark order as the user-initiated delete: an
                // expiry that races a user's DELETE must not re-stamp a token
                // its participant already cleared.
                try await ResourceFinalizerService.stampForDeletion(sandbox, on: db)
                sandbox.setDesiredStatus(.absent)
            }

            app.logger.info(
                "Expiring sandbox",
                metadata: [
                    "sandboxId": .string(sandboxID.uuidString),
                    "reason": .string(reason.description),
                    "mutationId": .string(accepted.mutationID.uuidString),
                ])
        } catch {
            // The "operation already pending" `409` that used to defer an
            // expiry racing a user action is gone with the operation row
            // (STR-147), and is not missed: marking `.absent` is idempotent and
            // level-triggered, so an expiry landing on top of a user's own
            // delete converges on the same thing. What remains here is a real
            // failure — a snapshot lineage that refuses deletion, or a write
            // that did not commit — and the next tick recomputes both clocks,
            // so an expired sandbox is deferred rather than dropped.
            app.logger.debug(
                "Skipping sandbox expiry: \(error)",
                metadata: ["sandboxId": .string(sandboxID.uuidString)])
        }
    }

    // MARK: - Agent auto-update rollout (issue #434)

    /// How long an assigned agent has to either re-register at its target
    /// version or report a blocker before the sweep treats the silence as a
    /// failed update and halts the rollout. Generous on purpose: it spans the
    /// artifact download, the restart, and re-registration.
    static let autoUpdateHealthBudgetSeconds: TimeInterval = 600

    /// Advances the fleet's declarative agent updates one agent at a time
    /// (issue #434). Cluster-singleton via the sweep lock; all rollout state
    /// lives on the agent rows, so any replica can pick up where another
    /// stopped.
    ///
    /// Per tick, each *assigned* agent is classified — an operator's "update
    /// now" writes the same assignment (STR-145), so it is tracked, budgeted,
    /// and reported exactly like a rollout one, and an in-flight manual update
    /// holds the fleet rollout for the same reason a rollout assignment does:
    /// one agent restarts at a time.
    /// - **converged** — re-registered at the target: assignment cleared.
    /// - **stale** — a *rollout* assignment whose version the deployment target
    ///   has moved past: reset, including failures, so an old halt never blocks
    ///   a new target. Manual assignments are exempt — the operator named that
    ///   version (possibly a one-off build) deliberately.
    /// - **failed** — a recorded failure (agent-reported, or silence past the
    ///   health budget, recorded here). A *rollout* failure halts the fleet
    ///   until an operator intervenes or the target changes: the next agent
    ///   would most likely hit the same bad artifact. A *manual* one does not —
    ///   one operator action on one agent must not stop every other agent's
    ///   auto-update, especially since the manual assignment's own escapes
    ///   (converge, stale reset) are exactly what a terminal failure closes off.
    ///   Cancelling the assignment is what clears it.
    /// - **parked** — blocked past the health budget (e.g. running
    ///   Firecracker VMs): the assignment stays, level-triggered, so the
    ///   agent converges whenever its blocker clears — but advancement stops
    ///   waiting on it. Parked is marked by a nil `updateAttemptedAt`.
    /// - **waiting** — within budget: the rollout holds.
    ///
    /// Only when nothing is failed or waiting does the sweep assign the next
    /// eligible *enrolled* agent (deterministic name order), after proving the
    /// release actually publishes an artifact for that agent's platform.
    func sweepAgentAutoUpdates() async {
        guard !isShutDown, !app.didShutdown else { return }
        guard await app.coordination.acquireSweepLock("agent_auto_update") else {
            app.logger.debug("Skipping auto-update sweep; lock held by another control-plane instance")
            return
        }

        let db = app.db
        let now = Date()
        // Nil on a dev build with no configured target: no *rollout* can run,
        // but assignments an operator made by hand (which supply their own
        // artifact, precisely for builds a release does not serve) still need
        // their convergence bookkeeping, so classification runs regardless.
        let target = autoUpdateTarget
        let canonicalTarget = target.map(AgentVersionTarget.canonical)

        do {
            // Enrolled agents (candidates for the next assignment) plus anyone
            // already carrying one — an operator's manual update assigns the
            // same field without requiring enrollment (STR-145), and it needs
            // the same convergence bookkeeping.
            let candidates = try await Agent.query(on: db)
                .group(.or) { group in
                    group
                        .filter(\.$autoUpdate == true)
                        .filter(\.$updateDesiredVersion != nil)
                }
                .sort(\.$name)
                .all()

            var rolloutHalted = false
            var waitingOnAgent = false

            for agent in candidates {
                guard let assigned = agent.updateDesiredVersion else { continue }

                // The deployment target moved past this assignment
                // (mid-rollout upgrade): reset everything, including a
                // failure — the old target's halt must not block the new one.
                // Only for rollout assignments: a manual one names a version
                // the operator chose, which the deployment target has no
                // opinion about.
                guard
                    agent.updateAssignmentSource == .manual
                        || canonicalTarget == nil
                        || AgentVersionTarget.canonical(assigned) == canonicalTarget
                else {
                    agent.clearUpdateAssignment()
                    try await agent.save(on: db)
                    continue
                }

                // Converged: the agent re-registered at the target (or was
                // updated by hand, which counts just the same).
                if !AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: assigned) {
                    agent.clearUpdateAssignment()
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
                    // A *rollout* failure halts the fleet until an operator
                    // intervenes: the next agent would most likely hit the same
                    // bad artifact. A manual one does not. It is one operator's
                    // action on one agent — possibly not even an enrolled one —
                    // and letting it stop every other agent's auto-update means
                    // a single failed "update now" wedges the fleet with no
                    // automatic way out (the assignment is exempt from the
                    // stale reset by design, and the agent that would clear it
                    // by converging is the one that just died). Cancelling the
                    // assignment is the operator's escape; until then this
                    // agent simply holds its own failure.
                    if agent.updateAssignmentSource != .manual {
                        rolloutHalted = true
                    }
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
                    // update and never came back.
                    let manual = agent.updateAssignmentSource == .manual
                    agent.recordUpdateFailure(
                        "did not re-register at \(assigned) within \(Int(Self.autoUpdateHealthBudgetSeconds))s of assignment"
                    )
                    try await agent.save(on: db)
                    Telemetry.agentAutoUpdateFailed(reason: "health_budget")
                    app.logger.error(
                        manual
                            ? "Agent update failed: agent went silent past the health budget"
                            : "Agent auto-update failed: agent went silent past the health budget; rollout halted",
                        metadata: [
                            "agentName": .string(agent.name),
                            "targetVersion": .string(assigned),
                        ])
                    rolloutHalted = rolloutHalted || !manual
                } else {
                    waitingOnAgent = true
                }
            }

            guard !rolloutHalted && !waitingOnAgent else { return }
            // Bookkeeping is done; advancing the fleet needs a target version.
            guard let target else { return }

            // Nothing in flight and nothing failed: assign the next agent.
            // Eligibility mirrors the update endpoint's checks, minus the
            // hosted-workload guard — that precondition is evaluated live on
            // the agent, which is the only side that actually knows.
            let next = candidates.first { agent in
                agent.autoUpdate
                    && agent.updateDesiredVersion == nil
                    && AgentVersionTarget.updateAvailable(agentVersion: agent.version, target: target)
                    && agent.isOnline
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

            next.assignUpdate(version: target, source: .rollout, at: now)
            try await next.save(on: db)
            Telemetry.agentAutoUpdateAssigned()
            app.logger.notice(
                "Agent auto-update assigned",
                metadata: [
                    "agentName": .string(next.name),
                    "currentVersion": .string(next.version),
                    "targetVersion": .string(target),
                ])
            // Ring now for low latency; the agent's unconditional refetch is
            // the correctness backstop.
            await syncDesiredState(agentId: nextId.uuidString)
        } catch {
            app.logger.error("Agent auto-update sweep failed: \(error)")
        }
    }

    // MARK: - Desired-state sync (issues #260, #261)

    /// Signal a desired-state change for an agent from any replica.
    ///
    /// This rings the contentless broadcast doorbell (STR-146): the local half
    /// runs inline, and the same signal goes out on `agent:doorbell` so
    /// whichever *other* replica happens to hold the agent's parked poll can
    /// act on it. Nothing here consults a routing directory — that question is
    /// what the doorbell exists to not have to answer.
    ///
    /// Purely a latency optimization: the agent converges on its own
    /// unconditional re-fetch, doorbell or no doorbell.
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
            await ringDesiredStateDoorbell(agentId: controllerId)
        }
        await ringDesiredStateDoorbell(agentId: agentId)
    }

    /// The agent id of the site network controller responsible for the given
    /// agent's networks, or nil for unconfigured sites.
    /// Best-effort: on lookup failure the controller's own unconditional
    /// refetch still converges it.
    private func siteNetworkControllerID(forAgentId agentId: String) async -> String? {
        guard let agentUUID = UUID(uuidString: agentId) else { return nil }
        do {
            guard let agent = try await Agent.find(agentUUID, on: app.db),
                let site = try await Site.find(agent.$site.id, on: app.db)
            else { return nil }
            return site.$networkControllerAgent.id?.uuidString
        } catch {
            app.logger.debug("Site controller lookup failed: \(error)")
            return nil
        }
    }

    /// Ring the doorbell for one agent: act on it locally, then broadcast so
    /// every other replica gets the same chance.
    ///
    /// Both halves always run. The local half is not an optimization that
    /// makes the broadcast redundant — this replica may hold the poll — and
    /// the broadcast is not a substitute for the local half, because Valkey
    /// may be down. Ringing twice is free; the doorbell is contentless and
    /// every recipient re-derives the truth from Postgres.
    private func ringDesiredStateDoorbell(agentId: String) async {
        guard let agentKey = await agentKey(forId: agentId) else {
            app.logger.warning(
                "Cannot ring the desired-state doorbell for an unknown agent",
                metadata: ["agentId": .string(agentId)])
            return
        }
        await applyDoorbell(agentKey: agentKey)
        await app.replicaBridge.ringDoorbell(agentKey: agentKey)
    }

    /// The local half of a doorbell, shared by the in-process ring and the
    /// broadcast subscriber. Does whatever this replica can do about the agent
    /// and nothing else — which for most replicas, most of the time, is
    /// nothing at all. That is the design, not a degraded path: "at most one
    /// replica can act" is what removes the need for a routing directory.
    private func applyDoorbell(agentKey: String) async {
        guard agentKey != CoordinationService.doorbellAllAgents else {
            await applyFleetDoorbell()
            return
        }

        // Wake a parked long-poll, if this is where it happens to be parked.
        // An agent whose poll is parked elsewhere needs nothing from us: it
        // will fetch wherever it actually lives.
        await app.desiredStatePollRegistry.ring(agentKey: agentKey)
    }

    /// The local half of a fleet-wide doorbell: wake every poll parked here.
    private func applyFleetDoorbell() async {
        await app.desiredStatePollRegistry.ringAll()
    }

    /// Ring the fleet-wide doorbell: every agent's desired state may have
    /// changed. The entry point for mutations whose effect is not scoped to a
    /// placement — security groups, networks, site topology, floating IPs.
    ///
    /// Before STR-146 these callers reached only the agents socketed to the
    /// calling replica, so in a multi-replica deployment the rest waited out
    /// the forced periodic pass. Broadcasting fixes that as a side effect of
    /// being the only way to reach a parked poll on another replica.
    func syncDesiredStateToFleet() async {
        await applyFleetDoorbell()
        await app.replicaBridge.ringDoorbell(agentKey: CoordinationService.doorbellAllAgents)
    }

    /// Deliver a broadcast doorbell from another replica (the
    /// `ReplicaBridgeDelegate` hook). Identical to the local ring — the whole
    /// point of a contentless broadcast is that the recipient does not need to
    /// know where it came from.
    func deliverDoorbell(agentKey: String) async {
        await applyDoorbell(agentKey: agentKey)
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
        // scheduler's view fresh from whichever arrives without re-saving an
        // identical row a second time.
        var agentChanged = applyPeriodicAgentState(
            report.resources,
            dependencyObservations: nil,
            to: agent)
        let previousBlockedReason = agent.updateBlockedReason
        let previousFailureReason = agent.updateFailureReason
        applyReportedUpdateStatus(report.agentUpdateStatus, to: agent)
        if agent.updateBlockedReason != previousBlockedReason
            || agent.updateFailureReason != previousFailureReason
        {
            agentChanged = true
            agent.lastHeartbeat = Date()
        }
        if applyReportedTeardownRefusal(report.teardownRefusal, to: agent) {
            agentChanged = true
        }
        if applyReportedManifestStatus(report.manifestStatus, to: agent) {
            agentChanged = true
        }
        if agentChanged {
            do {
                try await agent.save(on: app.db)
            } catch {
                app.logger.warning(
                    "Failed to persist agent resources from observed-state report: \(error)",
                    metadata: ["agentId": .string(report.agentId)])
            }
        }

        // The report arrived over this process's socket: refresh presence
        // alongside, mirroring the heartbeat path.
        await refreshAgentPresenceIfNeeded(agentKey: agentKey)

        do {
            let outcome = try await app.observedStateApplier.apply(report)
            // Level-triggered, and recorded here because this is where the
            // agent's name is: the withheld-teardown counter only fires at the
            // transition, so on its own it can't answer whether a host is
            // still holding workloads the control plane failed to describe.
            for (reason, count) in outcome.heldByReason {
                Telemetry.workloadClaimsHeld(agentName: agent.name, reason: reason, count: count)
            }
            // A newly authorized teardown (STR-98) is worth a sync right away:
            // until the tombstone reaches the agent it keeps holding — and
            // re-reporting — a workload nothing describes.
            if outcome.authorizedTeardown {
                await syncDesiredState(agentId: report.agentId)
            }
        } catch {
            app.logger.error(
                "Failed to apply observed-state report: \(error)",
                metadata: ["agentId": .string(report.agentId)])
        }
    }

    /// Folds an agent's teardown refusal (STR-98 phase 2) into its row,
    /// mutating the in-memory model for the caller's save.
    ///
    /// A refusal means the agent declined to converge teardowns a sync
    /// authorized because they would have taken out too much of the host at
    /// once. That is a standing condition, not an event: it repeats on every
    /// sync until either the batch shrinks or an operator intervenes, so it
    /// lives on the row where the UI can show it rather than only in a log.
    ///
    /// The log line and the counter are deduped on `syncId`, because the
    /// refusal rides along on *every* observed report — heartbeats included —
    /// while the agent's guard stands. Logging per report would turn one stuck
    /// refusal into thousands of `error` lines a day, which is exactly how an
    /// error level stops meaning anything. Per refused sync is the honest
    /// count; the row keeps `teardownRefusedAt` fresh either way, so the UI
    /// still shows the condition as current.
    /// Returns whether the row actually changed, so a heartbeat carrying a
    /// refusal it has already recorded costs no write.
    private func applyReportedTeardownRefusal(
        _ refusal: ObservedTeardownRefusal?, to agent: Agent
    ) -> Bool {
        guard let refusal else {
            reportedTeardownRefusalSyncIds.removeValue(forKey: agent.name)
            guard agent.teardownRefusalReason != nil || agent.teardownRefusedAt != nil else {
                return false
            }
            agent.teardownRefusalReason = nil
            agent.teardownRefusedAt = nil
            return true
        }
        guard reportedTeardownRefusalSyncIds[agent.name] != refusal.syncId else {
            // Same refused sync, re-reported on a heartbeat. Already logged,
            // already counted, already on the row.
            return agent.teardownRefusalReason != refusal.reason
        }
        reportedTeardownRefusalSyncIds[agent.name] = refusal.syncId
        app.logger.error(
            "Agent refused a sync's workload teardowns",
            metadata: [
                "agentName": .string(agent.name),
                "syncId": .string(refusal.syncId),
                "requestedTeardowns": .stringConvertible(refusal.requestedTeardowns),
                "presentWorkloads": .stringConvertible(refusal.presentWorkloads),
                "reason": .string(refusal.reason),
            ])
        Telemetry.agentTeardownRefused()
        agent.teardownRefusalReason = refusal.reason
        agent.teardownRefusedAt = Date()
        return true
    }

    /// Folds an agent's self-reported manifest status (STR-138) into its row,
    /// mutating the in-memory model for the caller's save.
    ///
    /// The manifest is the agent's only memory of what it is running. When it
    /// cannot be read the agent quarantines itself — zero advertised capacity,
    /// no convergence — and that is a standing condition an operator has to
    /// resolve on the host, so it lives on the row where the UI shows it
    /// rather than in a log line on a node nobody is looking at.
    ///
    /// Returns whether the row actually changed, so the reports that re-assert
    /// an unchanged condition on every heartbeat cost no write. The gauge is
    /// recorded on every report, changed or not: it answers "is this still
    /// happening", which a transition-only signal cannot.
    private func applyReportedManifestStatus(
        _ status: ObservedManifestStatus?, to agent: Agent
    ) -> Bool {
        Telemetry.agentManifestUnreadable(
            agentName: agent.name, unreadable: status.map { !$0.inventoryComplete } ?? false)

        guard let status else {
            guard
                agent.manifestStatusReason != nil || agent.manifestStatusAt != nil
                    || agent.manifestInventoryComplete != nil
            else { return false }
            app.logger.notice(
                "Agent's workload manifest is healthy again",
                metadata: ["agentName": .string(agent.name)])
            agent.manifestStatusReason = nil
            agent.manifestStatusAt = nil
            agent.manifestInventoryComplete = nil
            return true
        }

        guard
            agent.manifestStatusReason != status.reason
                || agent.manifestInventoryComplete != status.inventoryComplete
        else {
            // Same condition, re-reported on a heartbeat: already logged,
            // already on the row.
            return false
        }
        app.logger.error(
            status.inventoryComplete
                ? "Agent is holding workloads its build cannot route"
                : "Agent cannot read its workload manifest; it is quarantined and placing nothing",
            metadata: [
                "agentName": .string(agent.name),
                "quarantinedEntries": .stringConvertible(status.quarantinedEntries),
                "reason": .string(status.reason),
            ])
        agent.manifestStatusReason = status.reason
        agent.manifestStatusAt = Date()
        agent.manifestInventoryComplete = status.inventoryComplete
        return true
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
            // Terminal for this artifact and process lifetime: record the real
            // error instead of waiting out the budget (and, for a rollout
            // assignment, halt on it).
            agent.updateBlockedReason = nil
            if agent.updateFailureReason != status.reason {
                agent.recordUpdateFailure(status.reason)
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
    /// placement, and rings the agent's desired-state doorbell. The pending
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
        let vmId = try vm.requireID().uuidString
        let imageArchitecture = image?.architecture
        let reservedAgentId = NIOLockedValueBox<String?>(nil)

        // Placement and API updates both take this row lock before deciding
        // from or saving the VM. The create request's `vm` is only the snapshot
        // captured before background dispatch: an immediate update may have
        // switched metadata off while this task was waiting to run. Reloading
        // under the lock makes that committed intent the scheduler input and
        // prevents the placement save from writing the captured value back.
        let agentId: String
        do {
            agentId = try await db.transaction { [self] tx in
                guard try await vm.lockAndRefresh(on: tx),
                    let currentVM = try await VM.find(vm.id, on: tx)
                else {
                    throw Abort(.notFound, reason: "VM no longer exists")
                }

                let currentVMID = try currentVM.requireID()
                let bootVolumes = try await Volume.query(on: tx)
                    .filter(\.$vm.$id == currentVMID)
                    .filter(\.$volumeType == .boot)
                    .filter(\.$desiredStatus == .present)
                    .with(\.$pool)
                    .all()
                guard bootVolumes.count == 1, let bootVolume = bootVolumes.first else {
                    throw Abort(
                        .internalServerError,
                        reason: "VM \(vmId) must have exactly one managed boot volume before placement")
                }
                let poolMembers = bootVolume.pool?.memberAgentIds ?? []
                let storageEligibleAgents = schedulableAgents.filter { agent in
                    poolMembers.isEmpty || poolMembers.contains(agent.id)
                }

                // A network pinned to a site exists only in that site's OVN
                // deployment, so it pins the VM's placement (issue #343).
                let requiredSiteID = try await pinnedSiteID(for: currentVM, on: tx)

                // Use the freshly locked row for every placement requirement,
                // including the v39 metadata opt-out gate. The reservation is
                // still atomic in the coordination store (issue #258).
                let selectedAgentId: String
                do {
                    selectedAgentId = try await app.scheduler.selectAndReserveAgent(
                        requirements: SchedulerService.placementRequirements(
                            for: currentVM, architecture: imageArchitecture, siteID: requiredSiteID),
                        vmId: vmId,
                        from: storageEligibleAgents,
                        coordination: app.coordination,
                        strategy: strategy,
                        vmName: currentVM.name
                    )
                } catch let error as SchedulerError {
                    app.logger.error("Scheduler failed to find suitable agent: \(error)")
                    // Preserve the scheduler's reason (unsupported hypervisor,
                    // arch mismatch, insufficient resources, ...) instead of
                    // collapsing every placement failure into a generic one.
                    throw AgentServiceError.schedulingFailed(error.description)
                }
                reservedAgentId.withLockedValue { $0 = selectedAgentId }

                try await self.requireNetworkAuthority(
                    forAgentId: selectedAgentId, workloadId: vmId,
                    consequence: "the VM's network would never be realized and it would never boot", on: tx)

                // Persist only from the current row. From here the VM is part
                // of the agent's desired state and every sync path carries it.
                currentVM.hypervisorId = selectedAgentId
                try await currentVM.save(on: tx)

                let bootVolumeID = try bootVolume.requireID()
                let existingReplicas = try await VolumeReplica.query(on: tx)
                    .filter(\.$volume.$id == bootVolumeID)
                    .all()
                guard existingReplicas.isEmpty else {
                    throw Abort(
                        .conflict,
                        reason: "Boot volume \(bootVolumeID) was already placed before VM \(vmId)")
                }
                bootVolume.attachedAgentId = selectedAgentId
                try await bootVolume.save(on: tx)
                try await VolumeReplica(
                    volumeID: bootVolumeID,
                    agentId: selectedAgentId,
                    state: .provisioning,
                    generation: bootVolume.generation
                ).save(on: tx)
                return selectedAgentId
            }
        } catch {
            // The placement never became desired state, so nothing will ever
            // account for the reservation — release it rather than pinning
            // capacity until the TTL.
            if let reservedAgentId = reservedAgentId.withLockedValue({ $0 }) {
                await app.coordination.releaseReservation(agentId: reservedAgentId, vmId: vmId)
            }
            throw error
        }

        // Keep the caller's instance coherent for call sites that inspect it
        // after this method; persistence above deliberately used the reload.
        vm.hypervisorId = agentId

        app.logger.info(
            "VM creation dispatched via desired-state doorbell",
            metadata: [
                "vmId": .string(vmId),
                "agentId": .string(agentId),
            ])

        await syncDesiredState(agentId: agentId)
    }

    /// Places a sandbox on a Firecracker-capable agent, persists the
    /// placement, and rings the agent's desired-state doorbell — the sandbox
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
    ///
    /// A sandbox that has a NIC adds three constraints the VM path derives
    /// separately (STR-103): the sandbox-networking capability, overlay
    /// networking, and — when its network is pinned to a site — that site. The
    /// first is refused rather than degraded, because the alternative is a
    /// sandbox that boots with no interface while the API keeps reporting the
    /// address IPAM reserved for it.
    func createSandbox(sandbox: Sandbox, db: Database) async throws {
        var schedulableAgents = await schedulableAgentsFromDatabase()
        let sandboxId = sandbox.id?.uuidString ?? ""

        // The NIC rows are written in the create transaction, before placement
        // runs, so they are authoritative here — the same guarantee the VM
        // path's `pinnedSiteID` relies on.
        let nic = try await sandbox.$networkInterfaces.get(on: db)
        let sandboxSiteID = try await pinnedSiteID(forNetworkIDs: nic.map(\.logicalNetworkID), on: db)

        var requiredArchitecture: CPUArchitecture?
        if let snapshotID = sandbox.restoredFromSnapshotId {
            guard let snapshot = try await SandboxSnapshot.find(snapshotID, on: db),
                snapshot.isReady
            else {
                throw AgentServiceError.schedulingFailed(
                    "the restore snapshot is unavailable or not ready")
            }
            guard
                snapshot.guestControlProtocolVersion
                    == SandboxGuestControlProtocol.currentVersion
            else {
                throw AgentServiceError.schedulingFailed(
                    "snapshot uses unsupported guest control protocol "
                        + "\(snapshot.guestControlProtocolVersion.map(String.init) ?? "missing"); "
                        + "version \(SandboxGuestControlProtocol.currentVersion) is required, so delete "
                        + "and recapture it after upgrading the sandbox guest image"
                )
            }

            // Candidates (issue #428): the snapshot's own agent restores from
            // local artifacts; once exported, any agent that satisfies the
            // recorded compatibility constraints (wire v13, same architecture,
            // same Firecracker version, CPU template or identical CPU model)
            // can stage the archive from object storage instead.
            //
            // A *networked* fork adds one more, and it applies to the pinned
            // agent too (STR-104): remapping the checkpointed network device
            // needs Firecracker 1.12+, which the capture path does not, so a
            // snapshot's own host can be unable to fork it. Filtering here is
            // what turns that into a scheduling failure naming the version
            // rather than a placement onto a host that refuses permanently.
            let forkNeedsNetworkRemap = !nic.isEmpty
            var candidates: [SchedulableAgent] = []
            var networkRemapBlocker: String?
            if let pinnedAgentID = snapshot.agentId,
                let pinned = schedulableAgents.first(where: { $0.id == pinnedAgentID })
            {
                var pinnedBlocker: String?
                if forkNeedsNetworkRemap, let pinnedUUID = UUID(uuidString: pinnedAgentID),
                    let pinnedRow = try await Agent.find(pinnedUUID, on: db)
                {
                    pinnedBlocker = SandboxSnapshotCompatibility.networkedForkBlocker(target: pinnedRow)
                }
                if let pinnedBlocker {
                    networkRemapBlocker = pinnedBlocker
                } else {
                    candidates.append(pinned)
                }
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
                                && (!forkNeedsNetworkRemap
                                    || SandboxSnapshotCompatibility.networkedForkBlocker(target: $0) == nil)
                        }.compactMap { $0.id?.uuidString })
                    candidates += schedulableAgents.filter { compatibleIDs.contains($0.id) }
                }
            }
            guard !candidates.isEmpty else {
                if let networkRemapBlocker, !snapshot.isExported {
                    throw AgentServiceError.schedulingFailed(networkRemapBlocker)
                }
                if snapshot.isExported {
                    throw AgentServiceError.schedulingFailed(
                        "no schedulable agent is compatible with the restore snapshot (need Firecracker \(SandboxSnapshotCompatibility.normalizedFirecrackerVersion(snapshot.firecrackerVersion) ?? "unknown") on \(snapshot.architecture ?? "unknown")\(forkNeedsNetworkRemap ? " — at least \(FirecrackerSnapshotFeatures.networkOverridesMinimumVersion) to remap the NIC" : ""), and a matching CPU template or identical CPU)"
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

        let agentId: String
        do {
            agentId = try await app.scheduler.selectAndReserveAgent(
                requirements: VMPlacementRequirements(
                    cpu: sandbox.cpus,
                    memory: sandbox.memory,
                    disk: 0,
                    hypervisorType: .firecracker,
                    architecture: requiredArchitecture,
                    // Unlike a VM's plain NIC, which user-mode/SLIRP satisfies
                    // with outbound NAT, a sandbox NIC has no user-mode form at
                    // all — so unlike the VM path, presence really does imply
                    // the overlay requirement.
                    requiresInterVMNetworking: !nic.isEmpty,
                    siteID: sandboxSiteID,
                    requiresSandboxRuntime: true,
                    requiresSandboxNetworking: !nic.isEmpty
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
            let placed = try await db.transaction { tx -> Bool in
                guard try await sandbox.lockAndRefresh(on: tx) else { return false }
                // A delete may commit while the create scheduler is choosing a
                // host. Absence is the one intent placement must never revive.
                guard sandbox.desiredStatus != .absent else { return false }
                try await self.requireNetworkAuthority(
                    forAgentId: agentId, workloadId: sandboxId,
                    consequence:
                        "the sandbox's network would never be realized and it would never start",
                    on: tx)

                // Persist only after refreshing under the row lock, so this
                // background placement cannot save its pre-scheduling snapshot
                // over a concurrent lifecycle mutation.
                sandbox.hypervisorId = agentId
                try await sandbox.save(on: tx)
                return true
            }
            guard placed else {
                await app.coordination.releaseReservation(agentId: agentId, vmId: sandboxId)
                return
            }

            app.logger.info(
                "Sandbox creation dispatched via desired-state doorbell",
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

    /// Refuses a placement the network path could never complete.
    ///
    /// The scheduler only asks whether a host has room. When it lands a
    /// workload on an OVN agent whose site designates no network controller,
    /// nothing will ever realize that workload's logical switch: the agent
    /// parks it indefinitely and the create operation hangs until the stuck
    /// sweep fails it with a timeout that names no cause (issue #743). Fail
    /// the placement instead, carrying the fix in the operation's error —
    /// releasing the reservation, as a dispatch failure does, since the
    /// placement never becomes desired state.
    ///
    /// The same refusal covers a site whose designated controller is offline
    /// past the grace window or came back unable to author topology (issue
    /// #833) — the workload would park on a switch nobody writes either way.
    ///
    /// Site-less agents (legacy self-authored NB) and non-overlay
    /// (user-mode/SLIRP) agents realize their networking without a site
    /// controller and are unaffected.
    private func requireNetworkAuthority(
        forAgentId agentId: String, workloadId: String, consequence: String, on db: Database
    ) async throws {
        guard let agentUUID = UUID(uuidString: agentId),
            let agent = try await Agent.find(agentUUID, on: db),
            agent.supportsInterVMNetworking
        else { return }
        let authority = try await SiteNetworkAuthority.resolve(forAgent: agent, on: db)
        guard
            let reason = SiteNetworkAuthority.refusalReason(
                authority, host: agent, consequence: consequence)
        else { return }
        await app.coordination.releaseReservation(agentId: agentId, vmId: workloadId)
        throw AgentServiceError.schedulingFailed(reason)
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
        return try await pinnedSiteID(forNetworkIDs: nics.map(\.logicalNetworkID), on: db)
    }

    /// The site a set of a workload's attached networks pins it to, or nil when
    /// none of them is site-pinned. Shared by the VM and sandbox paths (STR-103)
    /// — a sandbox carries at most one NIC, so the multi-site conflict can only
    /// arise for a VM, but the rule is a property of the networks either way.
    private func pinnedSiteID(forNetworkIDs ids: [UUID], on db: Database) async throws -> UUID? {
        let networkIDs = Set(ids)
        guard !networkIDs.isEmpty else { return nil }

        let networks = try await LogicalNetwork.query(on: db)
            .filter(\.$id ~~ Array(networkIDs))
            .all()
        let siteIDs = Set(networks.compactMap { $0.$site.id })
        guard siteIDs.count <= 1 else {
            throw AgentServiceError.schedulingFailed(
                "workload attaches networks pinned to different sites; no host can satisfy both")
        }
        return siteIDs.first
    }

    // `performVMOperationAwaitingResponse` went with `vm_reboot` at wire v34
    // (ADR 0001 stage 9, STR-151). It was the last VM-shaped correlated
    // request/response on a durable resource; what remains of this apparatus
    // serves console, exec and log streams, which stay imperative by design.

    // MARK: - Agent Selection

    /// The scheduler's view of the fleet, assembled from the shared registry:
    /// agent rows (resources refreshed by heartbeats through any replica) and
    /// per-agent VM counts, filtered to agents whose presence key is live.
    func schedulableAgentsFromDatabase() async -> [SchedulableAgent] {
        do {
            async let onlineAgents = Agent.query(on: app.db)
                .filter(\.$status == .online)
                .all()
            async let groupedCounts = runningVMCountsFromDatabase()
            let (agents, runningVMCounts) = try await (onlineAgents, groupedCounts)

            // Fail open on nil (store unavailable): the rows said online, and
            // refusing all placement would couple VM creation to Valkey harder
            // than issue #258's degradation policy allows.
            let presence = await app.coordination.agentPresence(
                agentKeys: agents.map(\.identity.key))
            let present =
                presence.map { states in
                    zip(agents, states).compactMap { agent, isPresent in
                        isPresent ? agent : nil
                    }
                } ?? agents

            return present.compactMap { agent in
                guard let agentId = agent.id?.uuidString else { return nil }
                return SchedulableAgent(
                    id: agentId,
                    name: agent.name,
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
                    supportsSandboxWorkloads: agent.sandboxCapable,
                    supportsSandboxNetworking: agent.effectiveSandboxNetworkingCapable,
                    supportsVTPM: agent.tpmCapable,
                    supportsVsock: agent.supportsVsock
                )
            }
        } catch {
            app.logger.error("Failed to load schedulable agents from database: \(error)")
            return []
        }
    }

    /// Count placed VMs per agent without hydrating every VM in the cluster.
    private func runningVMCountsFromDatabase() async throws -> [String: Int] {
        guard let sql = app.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "Scheduler placement requires an SQL database")
        }

        struct Row: Decodable {
            let hypervisor_id: String
            let count: Int
        }

        let rows = try await sql.raw(
            """
            SELECT hypervisor_id, COUNT(*) AS count
            FROM vms
            WHERE hypervisor_id IS NOT NULL
            GROUP BY hypervisor_id
            """
        ).all(decoding: Row.self)

        return Dictionary(uniqueKeysWithValues: rows.map { ($0.hypervisor_id, $0.count) })
    }

    // MARK: - Message Sending

    // There is no request/response path here any more (ADR 0001 stage 11,
    // STR-152). `sendMessageToAgentWithResponse` and the continuation
    // bookkeeping behind it — pending map, per-request timeout tasks,
    // disconnect cleanup, the `requestId` ownership check — served the
    // imperative verbs, and the last of those became desired state at wire v34.
    // Console and exec are streams with their own session managers and their
    // own `sessionId` correlation; nothing else ever asked an agent a question.

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

/// The delegate is `deliverDoorbell` alone, declared with the desired-state
/// sync code above. Its other half, `runLocalExchange`, went with the
/// cross-replica RPC bridge (STR-152).
extension AgentService: ReplicaBridgeDelegate {}

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
    /// issue #261 — the doorbell and RPC channel subscriptions must be
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
