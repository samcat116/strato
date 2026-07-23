import Fluent
import StratoShared
import Vapor

/// Sites (availability zones) group agents that share one OVN deployment, so
/// a logical network pinned to a site can span its nodes (issue #343).
struct SiteController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let sites = routes.grouped("api", "sites")
        sites.get(use: listSites)
        sites.post(use: createSite)
        sites.get(":siteId", use: getSite)
        sites.put(":siteId", use: updateSite)
        sites.delete(":siteId", use: deleteSite)
        // Membership for agents that already exist; new nodes join via the
        // registration token's `siteId` instead.
        sites.post(":siteId", "agents", ":agentId", use: assignAgent)
        sites.delete(":siteId", "agents", ":agentId", use: removeAgent)
    }

    /// Site topology is infrastructure, same trust level as agent management:
    /// moving an agent between sites or re-pointing the network controller
    /// changes which node authors a site's whole SDN. Delegated to the owning
    /// org (manage_agents / site#manage); system admins retain full access.
    private func requireUser(_ req: Request) throws -> User {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        return user
    }

    /// The (resourceType, id) pair naming the scope's owning node for
    /// permission checks against the IAM hierarchy.

    /// `manage_agents` on the org/OU scope a new site is being created under
    /// (system admins pass through the evaluator's tier-1 policy).
    private func requireManageAgents(_ req: Request, scope: OrganizationScope) async throws {
        let resource = scope.checkResource
        let allowed = try await req.can("manage_agents", on: resource.type, id: resource.id.uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have permission to manage sites for this organization")
        }
    }

    /// The given permission on the site itself (resolved through the site's
    /// parent scope in the IAM tree).
    private func requireSitePermission(_ req: Request, site: Site, permission: String) async throws {
        let allowed = try await req.can(permission, on: "site", id: try site.requireID().uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this site")
        }
    }

    /// `manage` on the agent (resolved through the agent's parent scope). Site
    /// membership changes need this ON TOP of site#manage: with agents and
    /// sites delegated to different OUs of one org, a sibling-OU site admin
    /// shares the root org but must not move an agent the evaluator wouldn't
    /// let them manage.
    private func requireAgentManage(_ req: Request, agent: Agent) async throws {
        let allowed = try await req.can("manage", on: "agent", id: try agent.requireID().uuidString)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have 'manage' permission on this agent")
        }
    }

    /// How many floating IPs are attached to NICs of VMs hosted in the site —
    /// the set whose NAT rules the site's controller realizes.
    static func attachedFloatingIPCount(inSite site: Site, on db: Database) async throws -> Int {
        let siteAgentIDs = try await Agent.query(on: db)
            .filter(\.$site.$id == site.requireID())
            .all()
            .compactMap { $0.id?.uuidString }
        guard !siteAgentIDs.isEmpty else { return 0 }
        let siteVMIDs = try await VM.query(on: db)
            .filter(\.$hypervisorId ~~ siteAgentIDs)
            .all()
            .compactMap(\.id)
        guard !siteVMIDs.isEmpty else { return 0 }
        let nicIDs = Set(
            try await VMNetworkInterface.query(on: db)
                .filter(\.$vm.$id ~~ siteVMIDs)
                .all()
                .compactMap(\.id))
        guard !nicIDs.isEmpty else { return 0 }
        return try await FloatingIP.query(on: db)
            .all()
            .filter { floatingIP in floatingIP.$interface.id.map(nicIDs.contains) ?? false }
            .count
    }

    /// Trim a free-text metadata string, mapping blank input to nil so a
    /// whitespace-only value never masquerades as "set".
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Trim label keys and values so a stored key never carries surrounding
    /// whitespace (consistent with how `locationLabel`/`regionCode` normalize).
    /// A key that trims to empty is left empty here and rejected by validation.
    private static func normalizedLabels(_ labels: [String: String]?) -> [String: String]? {
        guard let labels else { return nil }
        var out: [String: String] = [:]
        for (key, value) in labels {
            out[key.trimmingCharacters(in: .whitespacesAndNewlines)] =
                value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    /// Validates the descriptive metadata shared by create and update. Cheap,
    /// range-and-length only — location is advisory, so the bar is "not
    /// obviously garbage", not canonical correctness.
    private static func validateMetadata(
        latitude: Double?, longitude: Double?, locationLabel: String?, regionCode: String?,
        labels: [String: String]?
    ) throws {
        // Coordinates are only meaningful as a pair.
        guard (latitude == nil) == (longitude == nil) else {
            throw Abort(.badRequest, reason: "latitude and longitude must be provided together")
        }
        if let latitude, !(-90...90).contains(latitude) {
            throw Abort(.badRequest, reason: "latitude must be between -90 and 90")
        }
        if let longitude, !(-180...180).contains(longitude) {
            throw Abort(.badRequest, reason: "longitude must be between -180 and 180")
        }
        if let label = normalized(locationLabel), label.count > 200 {
            throw Abort(.badRequest, reason: "locationLabel must be 200 characters or fewer")
        }
        if let region = normalized(regionCode), region.count > 64 {
            throw Abort(.badRequest, reason: "regionCode must be 64 characters or fewer")
        }
        if let labels {
            guard labels.count <= 64 else {
                throw Abort(.badRequest, reason: "A site may have at most 64 labels")
            }
            for (key, value) in labels {
                guard !key.isEmpty, key.count <= 128 else {
                    throw Abort(.badRequest, reason: "Label keys must be 1-128 characters")
                }
                guard value.count <= 256 else {
                    throw Abort(.badRequest, reason: "Label value for '\(key)' must be 256 characters or fewer")
                }
            }
        }
    }

    private func findSite(_ req: Request) async throws -> Site {
        guard let siteId = req.parameters.get("siteId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid site ID")
        }
        guard let site = try await Site.find(siteId, on: req.db) else {
            throw Abort(.notFound, reason: "Site not found")
        }
        return site
    }

    /// GET /api/sites
    /// Query params: organization_id (optional) — narrows to one org's hierarchy.
    func listSites(req: Request) async throws -> [SiteResponse] {
        _ = try requireUser(req)
        let orgFilter = try await OrganizationAccessService.organizationListFilter(on: req)

        var query = Site.query(on: req.db).sort(\.$name)
        if let orgFilter {
            query = query.group(.or) { group in
                group.filter(\.$organization.$id == orgFilter.organizationID)
                if !orgFilter.organizationalUnitIDs.isEmpty {
                    group.filter(\.$organizationalUnit.$id ~~ orgFilter.organizationalUnitIDs)
                }
            }
        }
        let sites = try await query.all()

        // Every caller is filtered the same way, admins included: the
        // `platform-system-admin` tier-1 policy is what lets them see the whole
        // fleet, so their view is a decision the evaluator made — logged, and
        // narrowable by a tier-2 guardrail — rather than a check they skipped.
        // The org filter above narrows the query first, so an admin who asks
        // for one org's sites does not get every org's back.
        var visible: [Site] = []
        for site in sites {
            guard let siteId = site.id else { continue }
            let ok = try await req.can("view", on: "site", id: siteId.uuidString)
            if ok { visible.append(site) }
        }
        return try visible.map { try SiteResponse(from: $0) }
    }

    func getSite(req: Request) async throws -> SiteResponse {
        let site = try await findSite(req)
        try await requireSitePermission(req, site: site, permission: "view")
        return try SiteResponse(from: site)
    }

    func createSite(req: Request) async throws -> SiteResponse {
        let create = try req.content.decode(CreateSiteRequest.self)

        guard
            let scope = try OrganizationScope.from(
                organizationID: create.organizationId, organizationalUnitID: create.organizationalUnitId)
        else {
            throw Abort(.badRequest, reason: "Either organizationId or organizationalUnitId is required")
        }
        try await scope.validateExists(on: req.db)
        try await requireManageAgents(req, scope: scope)

        let name = create.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else {
            throw Abort(.badRequest, reason: "Site name must be 1-100 characters")
        }

        let labels = Self.normalizedLabels(create.labels)
        try Self.validateMetadata(
            latitude: create.latitude, longitude: create.longitude,
            locationLabel: create.locationLabel, regionCode: create.regionCode, labels: labels)

        let site = Site(
            name: name,
            description: create.description,
            status: create.status ?? .active,
            latitude: create.latitude,
            longitude: create.longitude,
            locationLabel: Self.normalized(create.locationLabel),
            regionCode: Self.normalized(create.regionCode),
            labels: labels ?? [:],
            organizationScope: scope)
        do {
            try await site.save(on: req.db)
        } catch {
            // Surface the unique-name violation as a client error, matching
            // the registration-token conflict behavior.
            throw Abort(.conflict, reason: "A site named '\(name)' already exists")
        }

        return try SiteResponse(from: site)
    }

    func updateSite(req: Request) async throws -> SiteResponse {
        let site = try await findSite(req)
        try await requireSitePermission(req, site: site, permission: "manage")
        let update = try req.content.decode(UpdateSiteRequest.self)

        if let controllerId = update.networkControllerAgentId {
            guard let agent = try await Agent.find(controllerId, on: req.db) else {
                throw Abort(.badRequest, reason: "Agent \(controllerId) does not exist")
            }
            // The controller authors the site's shared NB over its local
            // socket; an agent outside the site is connected to some other
            // (or no) OVN deployment and would silently reconcile nothing.
            guard agent.$site.id == site.id else {
                throw Abort(
                    .badRequest,
                    reason: "Agent '\(agent.name)' is not a member of this site; assign it to the site first")
            }
            // A designation the sync path won't honor is a silent outage:
            // a pre-v4 agent is kept on legacy per-node scoping by assembly,
            // and a non-overlay (user-mode/SLIRP) agent has no OVN network
            // service to reconcile with — either way peers stay
            // non-authoritative and the site's networks are realized nowhere.
            guard WireProtocol.supportsSiteAuthority(agent.wireProtocolVersion ?? 0) else {
                throw Abort(
                    .badRequest,
                    reason:
                        "Agent '\(agent.name)' registered with a protocol too old for site topology authority; upgrade it first"
                )
            }
            guard agent.supportsInterVMNetworking else {
                throw Abort(
                    .badRequest,
                    reason:
                        "Agent '\(agent.name)' has no overlay (OVN) networking capability and cannot author site topology"
                )
            }
            // A pre-v12 controller would decode syncs but ignore their
            // `floatingIPs`, so every attached floating IP in the site would
            // silently lose its NAT while the API kept reporting it attached
            // (issue #344). Gate the designation, not just the attach path.
            if !WireProtocol.supportsFloatingIPs(agent.wireProtocolVersion ?? 0) {
                let attached = try await Self.attachedFloatingIPCount(inSite: site, on: req.db)
                guard attached == 0 else {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Agent '\(agent.name)' registered with a protocol too old for floating IPs, and this site has \(attached) attached floating IP(s); upgrade the agent or detach them first"
                    )
                }
            }
        }

        let labels = Self.normalizedLabels(update.labels)
        try Self.validateMetadata(
            latitude: update.latitude, longitude: update.longitude,
            locationLabel: update.locationLabel, regionCode: update.regionCode, labels: labels)

        site.description = update.description
        site.$networkControllerAgent.id = update.networkControllerAgentId
        // Full-replace for descriptive fields; `status` is the exception — an
        // omitted status leaves the current lifecycle untouched (see
        // `UpdateSiteRequest`).
        if let status = update.status { site.status = status }
        site.latitude = update.latitude
        site.longitude = update.longitude
        site.locationLabel = Self.normalized(update.locationLabel)
        site.regionCode = Self.normalized(update.regionCode)
        site.labels = labels ?? [:]
        try await site.save(on: req.db)

        // Topology authority may have moved: the old controller must stop
        // reconciling (and gets networksAuthoritative=false on its next sync)
        // before/as the new one starts. Level-triggered syncs make the
        // handover safe in either order.
        await req.application.agentService.syncDesiredStateToAllAgents()

        return try SiteResponse(from: site)
    }

    func deleteSite(req: Request) async throws -> HTTPStatus {
        let site = try await findSite(req)
        try await requireSitePermission(req, site: site, permission: "manage")
        let siteId = try site.requireID()

        // Refuse while anything references the site: a cascade would silently
        // flip agents back to the legacy per-node model and unpin networks
        // that VMs were placed against.
        let agentCount = try await Agent.query(on: req.db).filter(\.$site.$id == siteId).count()
        guard agentCount == 0 else {
            throw Abort(.conflict, reason: "Site has \(agentCount) agent(s); remove them first")
        }
        let networkCount = try await LogicalNetwork.query(on: req.db).filter(\.$site.$id == siteId).count()
        guard networkCount == 0 else {
            throw Abort(.conflict, reason: "Site has \(networkCount) network(s) pinned to it; delete them first")
        }
        // The FK would silently SET NULL the pin, turning a site-scoped pool
        // into an unpinned one — a scope change that bypasses the pool-overlap
        // validation (an unpinned pool conflicts with *every* site's pools).
        let poolCount = try await FloatingIPPool.query(on: req.db).filter(\.$site.$id == siteId).count()
        guard poolCount == 0 else {
            throw Abort(
                .conflict,
                reason: "Site has \(poolCount) floating IP pool(s) pinned to it; move or delete them first")
        }

        try await site.delete(on: req.db)
        return .noContent
    }

    func assignAgent(req: Request) async throws -> AgentResponse {
        let site = try await findSite(req)
        try await requireSitePermission(req, site: site, permission: "manage")
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        try await requireAgentManage(req, agent: agent)
        let targetSiteId = try site.requireID()

        // A site is one OVN deployment owned by one scope; its members must
        // live within that scope. Root-org equality is not enough: an OU-B
        // site admitting a sibling OU-A agent would run OU-B's site-pinned
        // VMs on capacity managed through OU-A. Rescope the agent first.
        guard let siteScope = site.organizationScope,
            let agentScope = agent.organizationScope,
            try await siteScope.contains(agentScope, on: req.db)
        else {
            throw Abort(
                .conflict,
                reason: "Agent is not owned by this site's organization scope; reassign the agent first")
        }

        // A move is a removal from the old site too, so it must honor the same
        // invariant as removeAgent: never orphan a site's topology authority.
        // Overwriting site_id while another site still designates this agent as
        // its network controller would leave that site pointing at a
        // non-member, silently stopping reconciliation of all its networks.
        let orphanedControllerships = try await Site.query(on: req.db)
            .filter(\.$networkControllerAgent.$id == agentId)
            .filter(\.$id != targetSiteId)
            .count()
        guard orphanedControllerships == 0 else {
            throw Abort(
                .conflict,
                reason:
                    "Agent is another site's network controller; designate a replacement controller there first")
        }

        // Changing site while the agent hosts VMs is the same hazard the
        // removal path guards: the old site's controller scopes its networks
        // by current membership, so networks referenced only by this agent's
        // still-running VMs would drop out of the old shared NB. (A site-less
        // agent's VMs live in its private local NB, which the new site's
        // shared deployment won't contain either.) Require a drain first.
        if agent.$site.id != targetSiteId {
            let hostedVMs = try await VM.query(on: req.db)
                .filter(\.$hypervisorId == agentId.uuidString)
                .count()
            guard hostedVMs == 0 else {
                throw Abort(
                    .conflict,
                    reason: "Agent hosts \(hostedVMs) VM(s); migrate or delete them before changing its site")
            }
            let hostedSandboxes = try await Sandbox.query(on: req.db)
                .filter(\.$hypervisorId == agentId.uuidString)
                .count()
            guard hostedSandboxes == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Agent hosts \(hostedSandboxes) sandbox(es); delete them before changing its site")
            }
        }

        agent.$site.id = targetSiteId
        try await agent.save(on: req.db)
        await req.application.agentService.syncDesiredStateToAllAgents()
        return try AgentResponse(from: agent)
    }

    func removeAgent(req: Request) async throws -> AgentResponse {
        let site = try await findSite(req)
        try await requireSitePermission(req, site: site, permission: "manage")
        let siteId = try site.requireID()
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db), agent.$site.id == siteId else {
            throw Abort(.notFound, reason: "Agent not found in this site")
        }
        try await requireAgentManage(req, agent: agent)

        // Never orphan a site's topology authority by pulling its controller:
        // reconciliation would silently stop for every network in the site.
        if site.$networkControllerAgent.id == agentId {
            throw Abort(
                .conflict,
                reason: "Agent is this site's network controller; designate another controller first")
        }
        // A removed agent may still host VMs whose networks are pinned to the
        // site; those VMs would keep running but their networks would no
        // longer be reconciled anywhere the scheduler agrees with.
        let hostedVMs = try await VM.query(on: req.db).filter(\.$hypervisorId == agentId.uuidString).count()
        guard hostedVMs == 0 else {
            throw Abort(.conflict, reason: "Agent hosts \(hostedVMs) VM(s); migrate or delete them first")
        }
        let hostedSandboxes = try await Sandbox.query(on: req.db)
            .filter(\.$hypervisorId == agentId.uuidString)
            .count()
        guard hostedSandboxes == 0 else {
            throw Abort(.conflict, reason: "Agent hosts \(hostedSandboxes) sandbox(es); delete them first")
        }

        agent.$site.id = nil
        try await agent.save(on: req.db)
        await req.application.agentService.syncDesiredStateToAllAgents()
        return try AgentResponse(from: agent)
    }
}
