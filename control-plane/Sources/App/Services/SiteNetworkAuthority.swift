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
    }

    static func resolve(forAgent agent: Agent, on db: any Database) async throws -> Authority {
        guard let siteID = agent.$site.id, let site = try await Site.find(siteID, on: db) else {
            return .selfAuthored(agent)
        }
        guard let controllerID = site.$networkControllerAgent.id,
            let controller = try await Agent.find(controllerID, on: db)
        else {
            return .unassigned(site)
        }
        return .controller(controller)
    }

    /// Whether the sync path would actually honor `agent` as a topology
    /// author — the same two conditions `SiteController.updateSite` enforces on
    /// an explicit designation. A pre-v4 agent is kept on legacy per-node
    /// scoping by assembly, and a non-overlay (user-mode/SLIRP) agent has no
    /// OVN network service to reconcile with; either way the site's networks
    /// would still be realized nowhere.
    static func canAuthorTopology(_ agent: Agent) -> Bool {
        WireProtocol.supportsSiteAuthority(agent.wireProtocolVersion ?? 0)
            && agent.supportsInterVMNetworking
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
}
