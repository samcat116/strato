import Fluent
import StratoShared
import Vapor

/// Who authors a workload's OVN topology — the one rule the placement, start,
/// and floating-IP preconditions read, plus the auto-designation that keeps a
/// fresh single-node site from having no answer at all.
///
/// A site's switches, routers and port groups are written by exactly one agent
/// (see `Site`). While no controller is designated, `DesiredStateAssembler`
/// hands *every* agent in the site an empty, non-authoritative network list:
/// the topology is authored nowhere, and workloads park indefinitely on a
/// logical switch that never appears. That state used to be invisible from the
/// API — a `202` whose operation simply never completed (issue #743) — so:
///
/// * `designateIfUnset` makes the first eligible member of a controller-less
///   site its controller, which is the whole post-enrollment step for the
///   overwhelmingly common single-node site;
/// * `resolve` + `missingControllerAbort` turn what remains (a site whose only
///   members can't author topology, or a designation an operator cleared) into
///   a loud, actionable error at the API instead of a silent stall.
///
/// A *standing* designation reaches the same dead end without ever being null,
/// which is the far likelier production failure (issue #833): the controller is
/// an ordinary hypervisor node that can crash, reboot or be drained, and it
/// re-registers on every reconnect — possibly in user-mode or on a rolled-back
/// binary that no longer clears the bar it was designated under. So `resolve`
/// also reports `.controllerUnavailable`, and `refusal` is the one place that
/// decides what a precondition does about it.
enum SiteNetworkAuthority {

    /// Where topology for workloads placed on a given agent gets realized.
    enum Authority {
        /// Site-less agent: the legacy single-node model, in which the agent
        /// is always authoritative over its own private northbound DB.
        case selfAuthored(Agent)
        /// The agent's site designates this controller — possibly the agent
        /// itself.
        case controller(Agent)
        /// The agent belongs to a site that designates no controller, so
        /// nothing authors the networks its workloads need.
        case unassigned(Site)
        /// The site designates a controller that cannot author topology right
        /// now, so its peers' workloads park exactly as they would with no
        /// designation at all — but the operator action is different (bring
        /// this node back, or designate a replacement), which is why this is
        /// its own case rather than folded into `.unassigned`.
        case controllerUnavailable(site: Site, controller: Agent, fault: ControllerFault)
    }

    /// Why a standing designation cannot author topology.
    enum ControllerFault: Equatable, Sendable {
        /// No heartbeat for longer than `controllerOfflineGrace`. `staleFor` is
        /// nil for an agent that has never heartbeated at all.
        case offline(staleFor: TimeInterval?)
        /// Re-registered below `WireProtocol.siteAuthorityMinimumVersion`, so
        /// assembly drops it to legacy per-node scoping and it writes its own
        /// local NB while its peers wait on the shared one.
        case protocolTooOld(Int)
        /// Re-registered in user-mode (SLIRP): no OVN service to reconcile
        /// with at all.
        case noOverlayNetworking

        /// The clause naming what is wrong, shared by the refusal wording and
        /// the health surface so an operator reads the same sentence in the
        /// 409 and on the site page. Completes "controller 'node-2' …".
        var phrase: String {
            switch self {
            case .offline(let staleFor):
                guard let staleFor else { return "is offline (it has never sent a heartbeat)" }
                return "is offline (no heartbeat for \(SiteNetworkAuthority.compactAge(staleFor)))"
            case .protocolTooOld(let version):
                return """
                    re-registered on wire protocol v\(version), too old for site topology authority \
                    (v\(WireProtocol.siteAuthorityMinimumVersion)+ required)
                    """
            case .noOverlayNetworking:
                return "re-registered without overlay (OVN) networking capability"
            }
        }

        /// The operator action that clears this fault, minus the "designate a
        /// replacement" half every refusal also offers.
        var primaryRemedy: String {
            switch self {
            case .offline: return "Bring it back online"
            case .protocolTooOld: return "Roll it forward"
            case .noOverlayNetworking: return "Restore its OVN networking configuration"
            }
        }
    }

    /// How long a designated controller may be unreachable before topology-
    /// dependent work is refused outright rather than accepted and left to
    /// converge.
    ///
    /// Deliberately longer than the 60s liveness window `Agent.isOnline` and
    /// the stale-agent sweep use: a node reboot must keep degrading to the
    /// existing 202-and-converge behavior instead of becoming a wall of 409s.
    /// A capability regression gets no grace at all — it is a durable property
    /// of the agent's current registration, not a transient.
    static let controllerOfflineGrace: TimeInterval =
        Environment.get("SITE_CONTROLLER_OFFLINE_GRACE_SECONDS").flatMap(TimeInterval.init) ?? 300

    /// Mirrors `DesiredStateAssembler.networkAssemblyScope`, including the
    /// order of its two escapes: a site-less agent *and* a pre-v4 sited agent
    /// both come back `.selfAuthored`, because assembly keeps the pre-v4 agent
    /// on legacy per-node scoping (`authoritative: true`, its own networks,
    /// its own floating IPs) whether or not the site has a controller — its
    /// binary predates `ovn_northbound`, so it writes its own local NB. Its
    /// workloads are realized and do boot in a controller-less site, and every
    /// precondition built on this must agree, or it would reject placements
    /// and boots that assembly would have carried through.
    static func resolve(forAgent agent: Agent, on db: any Database) async throws -> Authority {
        guard let siteID = agent.$site.id, let site = try await Site.find(siteID, on: db) else {
            return .selfAuthored(agent)
        }
        guard WireProtocol.supportsSiteAuthority(agent.wireProtocolVersion ?? 0) else {
            return .selfAuthored(agent)
        }
        return try await resolve(forSite: site, on: db)
    }

    /// The authority for a site as such, for callers with no host agent in
    /// hand (pinning a network to a site). Never returns `.selfAuthored` —
    /// that case is a property of the *agent*, not the site.
    static func resolve(forSite site: Site, on db: any Database) async throws -> Authority {
        guard let controllerID = site.$networkControllerAgent.id,
            let controller = try await Agent.find(controllerID, on: db)
        else {
            // Includes a designation left dangling at a deleted agent row: the
            // column carries no FK, and "points at nobody" is `.unassigned`.
            return .unassigned(site)
        }
        guard let fault = controllerFault(controller) else {
            return .controller(controller)
        }
        return .controllerUnavailable(site: site, controller: controller, fault: fault)
    }

    /// Why a standing designation can't author topology right now, or nil while
    /// it can.
    ///
    /// Capability first, and without grace: unlike a reboot, an agent that came
    /// back in user-mode or on an old binary will never converge on its own.
    /// Liveness is judged on heartbeat age rather than the `status` column —
    /// a row the stale sweep hasn't reached yet still reads `.online`, and this
    /// threshold is in any case stricter than `statusBasedOnHeartbeat`.
    static func controllerFault(_ controller: Agent, now: Date = Date()) -> ControllerFault? {
        if let capability = capabilityFault(controller) { return capability }
        guard let lastHeartbeat = controller.lastHeartbeat else { return .offline(staleFor: nil) }
        let staleFor = now.timeIntervalSince(lastHeartbeat)
        guard staleFor > controllerOfflineGrace else { return nil }
        return .offline(staleFor: staleFor)
    }

    /// A compact, log-and-error-message-friendly duration ("45s", "7m", "3h").
    static func compactAge(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded()))s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded()))m" }
        return "\(Int((seconds / 3600).rounded()))h"
    }

    /// Whether the sync path would actually honor `agent` as a topology
    /// author — the same two conditions `SiteController.updateSite` enforces on
    /// an explicit designation. A pre-v4 agent is kept on legacy per-node
    /// scoping by assembly, and a non-overlay (user-mode/SLIRP) agent has no
    /// OVN network service to reconcile with; either way the site's networks
    /// would still be realized nowhere.
    static func canAuthorTopology(_ agent: Agent) -> Bool {
        capabilityFault(agent) == nil
    }

    /// `canAuthorTopology` as a fault, so the designation bar is written once
    /// and the refusal can still name which half of it the agent fails.
    private static func capabilityFault(_ agent: Agent) -> ControllerFault? {
        let version = agent.wireProtocolVersion ?? 0
        guard WireProtocol.supportsSiteAuthority(version) else { return .protocolTooOld(version) }
        guard agent.supportsInterVMNetworking else { return .noOverlayNetworking }
        return nil
    }

    /// The wording every "nothing would realize this" precondition shares, so
    /// they read alike and all name the one call that fixes them.
    /// `consequence` completes the sentence "… has no network controller, so".
    static func missingControllerReason(site: Site, consequence: String) -> String {
        let path = site.id.map { "/api/sites/\($0.uuidString)" } ?? "/api/sites/{siteId}"
        return """
            Site '\(site.name)' has no network controller, so \(consequence). \
            Designate one of the site's OVN-capable agents with \
            PUT \(path) {"networkControllerAgentId": "<agentId>"}
            """
    }

    /// `missingControllerReason` as the 409 a synchronous API path throws.
    static func missingControllerAbort(site: Site, consequence: String) -> Abort {
        Abort(.conflict, reason: missingControllerReason(site: site, consequence: consequence))
    }

    /// `missingControllerReason`'s twin for a designation that exists but can't
    /// author. Same `consequence` clause, so a call site words both states with
    /// one string, and the same contract of naming the exact fix — here two of
    /// them, because bringing the controller back and designating a replacement
    /// are both valid answers.
    static func unavailableControllerReason(
        site: Site, controller: Agent, fault: ControllerFault, consequence: String
    ) -> String {
        let path = site.id.map { "/api/sites/\($0.uuidString)" } ?? "/api/sites/{siteId}"
        return """
            Site '\(site.name)' network controller '\(controller.name)' \(fault.phrase), \
            so \(consequence). \(fault.primaryRemedy), or designate another of the site's \
            OVN-capable agents with PUT \(path) {"networkControllerAgentId": "<agentId>"}
            """
    }

    /// Why `authority` cannot carry `consequence`, or nil when it can — the one
    /// entry point every precondition calls.
    ///
    /// Folding both "nothing would realize this" states into a single call is
    /// what keeps the five preconditions in step: adding a state means changing
    /// this switch, not finding every `if case` that quietly ignores it.
    ///
    /// `host` is the agent the work is placed on, where there is one. A
    /// `.controllerUnavailable` whose controller *is* that host is **not**
    /// refused: in a single-node site the workload and its topology author
    /// share a fate, the node being down is already visible as agent status,
    /// and refusing would break the declarative contract that desired state may
    /// be set while a node reboots. The cross-node stall this exists for — a
    /// healthy peer that can never get its switch — is unaffected.
    static func refusalReason(_ authority: Authority, host: Agent? = nil, consequence: String) -> String? {
        switch authority {
        case .selfAuthored, .controller:
            return nil
        case .unassigned(let site):
            return missingControllerReason(site: site, consequence: consequence)
        case .controllerUnavailable(let site, let controller, let fault):
            if let hostID = host?.id, controller.id == hostID { return nil }
            return unavailableControllerReason(
                site: site, controller: controller, fault: fault, consequence: consequence)
        }
    }

    /// `refusalReason` as the 409 a synchronous API path throws, or nil when
    /// the authority can carry the work.
    static func refusal(_ authority: Authority, host: Agent? = nil, consequence: String) -> Abort? {
        refusalReason(authority, host: host, consequence: consequence)
            .map { Abort(.conflict, reason: $0) }
    }

    /// What `SiteResponse` publishes about a site's designated controller.
    struct ControllerHealth: Sendable {
        /// The controller's heartbeat-derived status; nil when the site
        /// designates none.
        let status: AgentStatus?
        /// Why the designation cannot author topology; nil while it can.
        let issue: String?
    }

    /// The controller-health view for a site, given its (already loaded)
    /// controller row.
    ///
    /// `status` reports the outage the moment the heartbeat lapses, with no
    /// grace — an operator should see a controller go quiet *before* the API
    /// starts refusing work, not at the same time. `issue` is the gate: it is
    /// non-nil exactly when `resolve` would report `.controllerUnavailable`.
    static func controllerHealth(controller: Agent?) -> ControllerHealth {
        guard let controller else { return ControllerHealth(status: nil, issue: nil) }
        let fault = controllerFault(controller)
        return ControllerHealth(
            status: controller.statusBasedOnHeartbeat,
            issue: fault.map { "Network controller '\(controller.name)' \($0.phrase)" })
    }

    /// Makes `agent` the network controller of the site it belongs to when
    /// that site designates none.
    ///
    /// Called wherever an agent joins a site (registration and the sites API's
    /// assign endpoint), which makes the single-node case — one org, its
    /// default site, one enrolled node — self-configuring: the operator would
    /// otherwise have to discover an undocumented `PUT /api/sites/{id}` from
    /// agent logs after their VMs silently failed to boot.
    ///
    /// Only claims a designation that is *unset*: an existing controller is
    /// never displaced, so a second node joining a site changes nothing. The
    /// converse — an operator who deliberately cleared the designation and then
    /// restarts an agent — re-designates, which is the right trade when the
    /// cleared state has no working behavior to preserve.
    ///
    /// Deliberately skips the sites API's floating-IP protocol gate: that gate
    /// protects NAT rules a *working* controller is realizing, and a
    /// controller-less site cannot have an attached floating IP in the first
    /// place (attaching one requires a controller — see
    /// `FloatingIPController.requireNATRealizingAgent`).
    ///
    /// Best effort: a failure here leaves the site exactly as it was (no
    /// controller), which is the pre-existing behavior, so it must never fail
    /// the registration or assignment that triggered it.
    @discardableResult
    static func designateIfUnset(
        agent: Agent, siteID: UUID, on db: any Database, logger: Logger
    ) async -> Bool {
        guard let agentID = agent.id, canAuthorTopology(agent) else { return false }
        do {
            // A conditional update rather than read-modify-write: replicas can
            // be admitting members of the same controller-less site
            // concurrently, and the first one must win rather than the last.
            try await Site.query(on: db)
                .filter(\.$id == siteID)
                .filter(
                    .path(Site.path(for: \.$networkControllerAgent.$id), schema: Site.schema),
                    .equal, .null
                )
                .set(\.$networkControllerAgent.$id, to: agentID)
                .update()

            // Read back: the update is silent about whether it matched, and
            // only the agent that actually won should be announced as the new
            // topology author.
            guard let site = try await Site.find(siteID, on: db),
                site.$networkControllerAgent.id == agentID
            else {
                return false
            }
            logger.notice(
                "Designated the site's network controller automatically (it had none)",
                metadata: [
                    "agentName": .string(agent.name),
                    "agentId": .string(agentID.uuidString),
                    "site": .string(site.name),
                ])
            Telemetry.recordSiteNetworkControllerUp(site: site.name, up: true)
            return true
        } catch {
            logger.warning(
                "Failed to auto-designate a network controller for the site",
                metadata: [
                    "agentName": .string(agent.name),
                    "siteId": .string(siteID.uuidString),
                    "error": .string("\(error)"),
                ])
            return false
        }
    }

    /// Re-applies the designation bar to a *standing* controller at
    /// registration, and reports the site's controller health either way.
    ///
    /// Every condition `SiteController.updateSite` enforces is a property of
    /// the agent's current registration, and agents re-register on every
    /// reconnect. A controller that comes back in user-mode, or on a
    /// rolled-back pre-v4 binary, keeps the job while authoring nothing: its
    /// peers still get `networks: [], authoritative: false` and park forever
    /// (issue #833). Nothing else re-checks this — `designateIfUnset` only
    /// looks at designations that are *unset*.
    ///
    /// Hands the job back only when the site has another eligible member.
    /// Clearing an irreplaceable designation would trade one silent failure for
    /// another: `designateIfUnset` would have nothing to pick, and the refusal
    /// would stop naming the node the operator actually has to fix.
    ///
    /// Returns whether the designation was cleared. Best effort like
    /// `designateIfUnset`: it must never fail the registration that ran it.
    @discardableResult
    static func revalidateDesignation(
        agent: Agent, siteID: UUID, on db: any Database, logger: Logger
    ) async -> Bool {
        guard let agentID = agent.id else { return false }
        do {
            guard let site = try await Site.find(siteID, on: db),
                site.$networkControllerAgent.id == agentID
            else {
                return false
            }
            guard let fault = capabilityFault(agent) else {
                // A healthy controller re-registering is the signal that clears
                // the alert the stale sweep raised when it went away.
                Telemetry.recordSiteNetworkControllerUp(site: site.name, up: true)
                return false
            }

            let eligiblePeers = try await Agent.query(on: db)
                .filter(\.$site.$id == siteID)
                .filter(\.$id != agentID)
                .all()
                .filter(canAuthorTopology)

            Telemetry.recordSiteNetworkControllerUp(site: site.name, up: false)
            logger.warning(
                "Site network controller re-registered unable to author topology",
                metadata: [
                    "agentName": .string(agent.name),
                    "agentId": .string(agentID.uuidString),
                    "site": .string(site.name),
                    "fault": .string(fault.phrase),
                    "eligiblePeers": .stringConvertible(eligiblePeers.count),
                ])
            guard !eligiblePeers.isEmpty else { return false }

            // Conditional on still being the designated controller, so a
            // replacement another replica designated concurrently survives.
            try await Site.query(on: db)
                .filter(\.$id == siteID)
                .filter(\.$networkControllerAgent.$id == agentID)
                .set(\.$networkControllerAgent.$id, to: nil)
                .update()
            logger.warning(
                "Cleared the site's network controller designation; an eligible member takes it on its next registration",
                metadata: [
                    "agentName": .string(agent.name),
                    "site": .string(site.name),
                ])
            return true
        } catch {
            logger.warning(
                "Failed to re-validate the site's network controller designation",
                metadata: [
                    "agentName": .string(agent.name),
                    "siteId": .string(siteID.uuidString),
                    "error": .string("\(error)"),
                ])
            return false
        }
    }
}
