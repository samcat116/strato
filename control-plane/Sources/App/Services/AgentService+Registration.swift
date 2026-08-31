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

/// Owns agent enrollment, connection identity, heartbeat ingestion, and presence refresh.
extension AgentService {
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
                        "strato.agent.name": .string(agentName),
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
                    metadata: ["strato.agent.identity": .string(agentKey)])
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
                    metadata: ["strato.agent.identity": .string(agentKey), "requestedSite": .string(siteID.uuidString)])
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
                    metadata: ["strato.agent.identity": .string(agentKey), "error": .string("\(error)")])
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
                "strato.agent.id": .string(agentUUID.uuidString),
                "strato.agent.identity": .string(agentKey),
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
    func agentId(forKey agentKey: String) async -> String? {
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
    func agentKey(forId agentId: String) async -> String? {
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
                "Unregister for unknown agent; ignoring",
                metadata: ["strato.agent.claimed.id": .string(agentId)])
            return
        }

        guard agent.identity.key == connectionAgentKey else {
            app.logger.warning(
                "Unregister claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "strato.agent.claimed.id": .string(agentId),
                    "strato.agent.claimed.identity": .string(agent.identity.key),
                    "strato.agent.connection.identity": .string(connectionAgentKey),
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
        await app.guestExecSessionManager.closeAllSessions(
            forAgent: agentKey, reason: "agent unregistered")
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
        app.logger.info("Agent unregistered", metadata: ["strato.agent.id": .string(agentId)])
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
                "Cannot force unregister: agent not found by identity key",
                metadata: ["strato.agent.identity": .string(agentKey)])
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
        await app.guestExecSessionManager.closeAllSessions(
            forAgent: agentKey, reason: "agent unregistered")
        // Drop both cluster-visible claims immediately. The route clear is a
        // compare-and-delete, so it cannot remove a successor connection.
        presenceRefreshedAt.removeValue(forKey: agentKey)
        routeRefreshedAt.removeValue(forKey: agentKey)
        await app.coordination.clearAgentPresence(agentKey: agentKey)
        await app.replicaBridge.clearRoute(agentKey: agentKey)

        app.logger.info(
            "Agent force unregistered",
            metadata: ["strato.agent.id": .string(agentId), "strato.agent.identity": .string(agentKey)])
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
            app.logger.warning(
                "Received heartbeat from unknown agent",
                metadata: ["strato.agent.claimed.id": .string(message.agentId)])
            return
        }

        guard agent.identity.key == agentKey else {
            app.logger.warning(
                "Heartbeat claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "strato.agent.claimed.id": .string(message.agentId),
                    "strato.agent.claimed.identity": .string(agent.identity.key),
                    "strato.agent.connection.identity": .string(agentKey),
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

        app.logger.debug("Agent heartbeat updated", metadata: ["strato.agent.id": .string(message.agentId)])
    }

    /// Apply the mutable fields from a periodic agent report. A real state
    /// change always persists and refreshes `lastHeartbeat`; otherwise the
    /// timestamp advances at half the presence TTL.
    func applyPeriodicAgentState(
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
                            "strato.agent.name": .string(agent.name),
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
    func normalizedDependencyObservations(
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
                "strato.agent.name": .string(agentName),
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
    func refreshAgentPresenceIfNeeded(agentKey: String, force: Bool = false) async {
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
