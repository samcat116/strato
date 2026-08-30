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

actor AgentService {
    private let app: Application
    nonisolated let maintenance: AgentMaintenanceLoop
    nonisolated let placement: WorkloadPlacementService

    /// Last successful presence refresh per local socket. The wire sends both a
    /// heartbeat and an observed report every 20 seconds; refreshing on every
    /// frame doubles Valkey traffic without extending liveness. Half the TTL
    /// leaves a full retry window after a failed write.
    private var presenceRefreshedAt: [String: ContinuousClock.Instant] = [:]
    /// Route writes fail independently of presence writes. Keep their success
    /// timestamps separate so a missing cross-replica socket route retries on
    /// the next frame instead of waiting for the presence throttle window.
    private var routeRefreshedAt: [String: ContinuousClock.Instant] = [:]
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
    private var reportTails: [String: (id: UInt64, task: Task<Void, Never>)] = [:]
    private var nextReportTailId: UInt64 = 0

    /// The startup task that arms the replica pub/sub subscriptions. Tracked
    /// so `shutdown()` can wait for it — otherwise it can still be
    /// subscribing (touching `app` storage) while the application tears down.
    private var startupTask: Task<Void, Never>?

    /// Set at application shutdown. Guards against the init task arming the
    /// heartbeat monitor after `shutdown()` already ran.
    private var isShutDown = false

    init(app: Application, heartbeatInterval: Duration = .seconds(30)) {
        self.app = app
        self.maintenance = AgentMaintenanceLoop(app: app, interval: heartbeatInterval)
        self.placement = WorkloadPlacementService(app: app)
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
    private func armBackgroundWork() async {
        guard !isShutDown, !app.didShutdown else { return }
        await maintenance.start()
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
        await maintenance.shutdown()
        if let startupTask {
            await startupTask.value
        }
        startupTask = nil
    }

    // MARK: - Agent Registration

    /// Registers an agent after resolving its durable organization scope and site.
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
        var previousDependencyObservations: [NodeDependencyObservation] = []

        // Find existing agent or create new one
        let agent: Agent
        if let existingAgent = try await Agent.query(on: db)
            .filter(\.$trustDomain == trustDomain)
            .filter(\.$name == agentName)
            .first()
        {
            // Update existing agent
            agent = existingAgent
            previousDependencyObservations = existingAgent.dependencyObservations
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
            agent.metadataServiceCapable = message.metadataServiceCapable ?? false
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
            agent = Agent.from(
                registration: message, name: agentName, siteID: siteID, trustDomain: trustDomain)
            agent.dependencyObservations = dependencyObservations
            agent.dependencyObservationsReceivedAt = dependencyObservationsReceivedAt
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

        // Record that the node completed its first registration. Bootstrap
        // redemption already erased the token hash atomically before minting
        // the node credential, so this informational save cannot reopen the
        // credential even if it fails. The enrollment row remains as the
        // durable scope record.
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
        Telemetry.recordRemovedDependenciesUnavailable(
            agentName: agent.name,
            previousObservations: previousDependencyObservations,
            currentObservations: dependencyObservations)
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
        // and attached exec sessions must be torn down here for the
        // graceful-unregister path. Captured commands remain pending because a
        // terminal frame may already be in flight; their deadline is the safe
        // failure backstop.
        app.consoleSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        app.guestExecSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        presenceRefreshedAt.removeValue(forKey: agentKey)
        routeRefreshedAt.removeValue(forKey: agentKey)
        await app.coordination.clearAgentPresence(agentKey: agentKey)
        await app.replicaBridge.clearRoute(agentKey: agentKey)

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
        // not run its interactive-session cleanup once the connection entry is
        // gone. Captured commands keep waiting for a terminal frame or their
        // deadline.
        app.consoleSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        app.guestExecSessionManager.closeAllSessions(forAgent: agentKey, reason: "agent unregistered")
        // Drop both cluster-visible claims immediately. The route clear is a
        // compare-and-delete, so it cannot remove a successor connection.
        presenceRefreshedAt.removeValue(forKey: agentKey)
        routeRefreshedAt.removeValue(forKey: agentKey)
        await app.coordination.clearAgentPresence(agentKey: agentKey)
        await app.replicaBridge.clearRoute(agentKey: agentKey)

        app.logger.info(
            "Agent force unregistered",
            metadata: ["agentId": .string(agentId), "agentKey": .string(agentKey)])
    }

    /// Socket-close cleanup. Only reached when this socket was still the
    /// agent's current *local* connection — `removeConnection(ifCurrent:)` in
    /// the close handler already drops a delayed close superseded by a
    /// same-replica reconnect.
    ///
    /// The delivery-only route restored for captured commands identifies the
    /// socket-holding replica, but it is not durable liveness truth. A close
    /// delayed past a reconnect on another replica can therefore still write
    /// `offline` under a live connection until the holder's next frame writes
    /// `.online` back — bounded by the agent's heartbeat interval, about 20
    /// seconds. Compare-and-delete does ensure this cleanup cannot erase the
    /// successor replica's route.
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
    /// signal that says *which connection generation* is current; a replica id
    /// alone is intentionally not treated as that authority.
    func removeAgent(_ agentKey: String) async {
        // For the same reason, do not fail captured commands from this close.
        // A terminal frame may belong to a successor connection; the durable
        // command deadline handles executions that are truly abandoned.
        presenceRefreshedAt.removeValue(forKey: agentKey)
        routeRefreshedAt.removeValue(forKey: agentKey)
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

    /// Refresh the agent's presence and local-socket route at most once per
    /// half TTL. Their success timestamps are independent: either failed write
    /// retries on the next incoming frame even when the other one landed.
    private func refreshAgentPresenceIfNeeded(agentKey: String, force: Bool = false) async {
        let now = ContinuousClock.now
        let presenceDue =
            force
            || presenceRefreshedAt[agentKey].map {
                $0.duration(to: now) >= Self.presenceRefreshInterval
            } ?? true
        let routeDue =
            force
            || routeRefreshedAt[agentKey].map {
                $0.duration(to: now) >= Self.presenceRefreshInterval
            } ?? true

        if presenceDue, await app.coordination.recordAgentPresence(agentKey: agentKey) {
            presenceRefreshedAt[agentKey] = now
        }

        if routeDue, app.websocketManager.getConnection(agentKey: agentKey) != nil,
            await app.replicaBridge.recordRoute(agentKey: agentKey)
        {
            routeRefreshedAt[agentKey] = now
        }
    }

}

extension AgentService {
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

    func deliverAgentEnvelope(_ envelope: MessageEnvelope, agentKey: String) async throws {
        guard let websocket = app.websocketManager.getConnection(agentKey: agentKey) else {
            throw ReplicaMessageBridge.DeliveryError.agentNotConnected(agentKey)
        }
        websocket.send(try WireProtocol.makeEncoder().encode(envelope))
    }

    // MARK: - Observed-state reports (issue #260)

    /// Tail of the per-agent report-application chain (keyed by agent name)
    /// plus the id that identifies it, so a finished chain link only retires
    /// its own bookkeeping.
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

        // Storage inventory has its own completeness contract and transaction.
        // A malformed or unavailable disk snapshot must not prevent valid VM,
        // sandbox, volume, or network observations in this report from applying.
        if let storageDevices = report.storageDevices {
            do {
                try await StorageDeviceInventoryReconciler(application: app).apply(
                    storageDevices,
                    for: agent,
                    receivedAt: Date())
            } catch {
                app.logger.error(
                    "Failed to apply storage-device inventory: \(error)",
                    metadata: ["agentId": .string(report.agentId)])
            }
        }

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
            if outcome.authorizedTeardown || outcome.desiredStateChanged {
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

}

extension AgentService {

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

    var agentMaintenance: AgentMaintenanceLoop {
        agentService.maintenance
    }

    var workloadPlacement: WorkloadPlacementService {
        agentService.placement
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
