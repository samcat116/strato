import ControlPlanePostgres
import StratoShared
import Vapor

/// Sites (availability zones) group agents that share one OVN deployment, so
/// a logical network pinned to a site can span its nodes (issue #343).
struct SiteController: RouteCollection {
    private let sites: SitesPersistence
    private let agents: AgentsPersistence
    private let hierarchy: HierarchyPersistence

    init(
        sites: SitesPersistence,
        agents: AgentsPersistence,
        hierarchy: HierarchyPersistence
    ) {
        self.sites = sites
        self.agents = agents
        self.hierarchy = hierarchy
    }

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
    }

    // MARK: - Authorization
    //
    // Site topology is infrastructure, same trust level as agent management:
    // moving an agent between sites or re-pointing the network controller
    // changes which node authors a site's whole SDN. Delegated to the owning
    // org (manage_agents / site#manage); system admins retain full access.

    /// `agent:manage` on the org/OU scope a new site is being created under
    /// (system admins pass through the evaluator's tier-1 policy).
    private func requireManageAgents(_ req: Request, scope: OrganizationScope) async throws {
        let allowed = try await req.can("agent:manage", on: scope.checkNode)
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have permission to manage sites for this organization")
        }
    }

    /// The given canonical action on the site itself (resolved through the site's
    /// parent scope in the IAM tree).
    private func requireSiteAction(_ req: Request, site: SiteSnapshot, action: String) async throws {
        let allowed = try await req.can(action, on: IAMNode(type: .site, id: site.id))
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this site")
        }
    }

    /// `manage` on the agent (resolved through the agent's parent scope). Site
    /// membership changes need this ON TOP of site#manage: with agents and
    /// sites delegated to different OUs of one org, a sibling-OU site admin
    /// shares the root org but must not move an agent the evaluator wouldn't
    /// let them manage.
    private func requireAgentManage(_ req: Request, agentID: UUID) async throws {
        let allowed = try await req.can("agent:manage", on: IAMNode(type: .agent, id: agentID))
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have 'manage' permission on this agent")
        }
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

    private func findSite(_ req: Request) async throws -> SiteSnapshot {
        guard let siteId = req.parameters.get("siteId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid site ID")
        }
        guard let site = try await sites.site(id: siteId) else {
            throw Abort(.notFound, reason: "Site not found")
        }
        return site
    }

    /// GET /api/sites
    /// Query params: organization_id (optional) — narrows to one org's hierarchy;
    /// limit/offset (optional) — select the page.
    func listSites(req: Request) async throws -> PagedResponse<SiteResponse> {
        let paging = try ListPaging.decode(from: req)
        let sites = try await visibleSites(req: req)
        return paging.page(sites)
    }

    /// Every site the caller may read, by name, ready for slicing.
    func visibleSites(req: Request) async throws -> [SiteResponse] {
        _ = try req.auth.require(User.self)
        let orgFilter = try await OrganizationAccessService.organizationListFilter(
            on: req,
            using: hierarchy
        )
        let siteRows: [SiteSnapshot]
        if let orgFilter {
            siteRows = try await sites.sites(
                organizationID: orgFilter.organizationID,
                organizationalUnitIDs: orgFilter.organizationalUnitIDs
            )
        } else {
            siteRows = try await sites.allSites()
        }

        // Every caller is filtered the same way, admins included: the
        // `platform-system-admin` tier-1 policy is what lets them see the whole
        // fleet, so their view is a decision the evaluator made — logged, and
        // narrowable by a tier-2 guardrail — rather than a check they skipped.
        // The org filter above narrows the query first, so an admin who asks
        // for one org's sites does not get every org's back.
        // One batched decision for the page (#687) rather than a full
        // evaluation per site.
        let readable = try await req.canFilter(
            "site:read",
            on: siteRows.map { IAMNode(type: .site, id: $0.id) }
        )
        return try siteRows
            .filter { readable.contains(IAMNode(type: .site, id: $0.id)) }
            .map { try SiteResponse(from: $0) }
    }

    func getSite(req: Request) async throws -> SiteResponse {
        let site = try await findSite(req)
        try await requireSiteAction(req, site: site, action: "site:read")
        return try SiteResponse(from: site)
    }

    func createSite(req: Request) async throws -> SiteResponse {
        let create = try req.content.decodeValidated(CreateSiteRequest.self)

        guard
            let scope = try OrganizationScope.from(
                organizationID: create.organizationId, organizationalUnitID: create.organizationalUnitId)
        else {
            throw Abort(.badRequest, reason: "Either organizationId or organizationalUnitId is required")
        }
        try await requireManageAgents(req, scope: scope)

        let labels = Self.normalizedLabels(create.labels)
        try Self.validateMetadata(
            latitude: create.latitude, longitude: create.longitude,
            locationLabel: create.locationLabel, regionCode: create.regionCode, labels: labels)

        let result = try await sites.create(SiteWrite(
            name: create.name,
            description: create.description,
            status: (create.status ?? .active).rawValue,
            latitude: create.latitude,
            longitude: create.longitude,
            locationLabel: Self.normalized(create.locationLabel),
            regionCode: Self.normalized(create.regionCode),
            labels: labels ?? [:],
            organizationID: scope.organizationID,
            organizationalUnitID: scope.organizationalUnitID
        ))
        switch result {
        case .created(let site):
            return try SiteResponse(from: site)
        case .scopeNotFound:
            switch scope {
            case .organization(let id):
                throw Abort(.badRequest, reason: "Organization \(id) does not exist")
            case .organizationalUnit(let id):
                throw Abort(.badRequest, reason: "Folder \(id) does not exist")
            }
        case .duplicateName:
            throw Abort(.conflict, reason: "A site named '\(create.name)' already exists")
        }
    }

    func updateSite(req: Request) async throws -> SiteResponse {
        let site = try await findSite(req)
        try await requireSiteAction(req, site: site, action: "site:manage")
        let update = try req.content.decodeValidated(UpdateSiteRequest.self)

        let labels = Self.normalizedLabels(update.labels)
        try Self.validateMetadata(
            latitude: update.latitude, longitude: update.longitude,
            locationLabel: update.locationLabel, regionCode: update.regionCode, labels: labels)

        let result = try await sites.update(
            id: site.id,
            with: SiteUpdate(
                description: update.description,
                networkControllerAgentID: update.networkControllerAgentId,
                status: update.status?.rawValue,
                latitude: update.latitude,
                longitude: update.longitude,
                locationLabel: Self.normalized(update.locationLabel),
                regionCode: Self.normalized(update.regionCode),
                labels: labels ?? [:]
            )
        )
        let updated: SiteSnapshot
        switch result {
        case .updated(let site):
            updated = site
        case .notFound:
            throw Abort(.notFound, reason: "Site not found")
        case .controllerNotFound(let id):
            throw Abort(.badRequest, reason: "Agent \(id) does not exist")
        case .controllerOutsideSite(let name):
            throw Abort(
                .badRequest,
                reason: "Agent '\(name)' is not a member of this site; assign it to the site first"
            )
        case .controllerCannotAuthor(let name):
            throw Abort(
                .badRequest,
                reason:
                    "Agent '\(name)' has no overlay (OVN) networking capability and cannot author site topology"
            )
        }

        // Topology authority may have moved: the old controller must stop
        // reconciling (and gets networksAuthoritative=false on its next sync)
        // before/as the new one starts. Level-triggered syncs make the
        // handover safe in either order.
        await req.application.agentService.syncDesiredStateToFleet()

        return try SiteResponse(from: updated)
    }

    func deleteSite(req: Request) async throws -> HTTPStatus {
        let site = try await findSite(req)
        try await requireSiteAction(req, site: site, action: "site:manage")
        switch try await sites.deleteIfEmpty(id: site.id) {
        case .deleted:
            return .noContent
        case .notFound:
            throw Abort(.notFound, reason: "Site not found")
        case .hasAgents(let count):
            throw Abort(.conflict, reason: "Site has \(count) agent(s); remove them first")
        case .hasNetworks(let count):
            throw Abort(.conflict, reason: "Site has \(count) network(s) pinned to it; delete them first")
        case .hasFloatingIPPools(let count):
            throw Abort(
                .conflict,
                reason: "Site has \(count) floating IP pool(s) pinned to it; move or delete them first"
            )
        }
    }

    func assignAgent(req: Request) async throws -> AgentResponse {
        let site = try await findSite(req)
        try await requireSiteAction(req, site: site, action: "site:manage")
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard try await agents.agent(id: agentId) != nil else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        try await requireAgentManage(req, agentID: agentId)

        let assigned: AgentSnapshot
        switch try await sites.assignAgent(id: agentId, toSite: site.id) {
        case .assigned(let agent, let newlyDesignatedSiteName):
            assigned = agent
            if let siteName = newlyDesignatedSiteName {
                req.logger.notice(
                    "Designated the site's network controller automatically (it had none)",
                    metadata: [
                        "agentName": .string(agent.name),
                        "agentId": .string(agent.id.uuidString),
                        "site": .string(siteName),
                    ]
                )
                Telemetry.recordSiteNetworkControllerUp(site: siteName, up: true)
            }
        case .siteNotFound:
            throw Abort(.notFound, reason: "Site not found")
        case .agentNotFound:
            throw Abort(.notFound, reason: "Agent not found")
        case .outsideScope:
            throw Abort(
                .conflict,
                reason: "Agent is not owned by this site's organization scope; reassign the agent first"
            )
        case .controlsAnotherSite:
            throw Abort(
                .conflict,
                reason:
                    "Agent is another site's network controller; designate a replacement controller there first"
            )
        case .hostsVirtualMachines(let count):
            throw Abort(
                .conflict,
                reason: "Agent hosts \(count) VM(s); migrate or delete them before changing its site"
            )
        case .hostsSandboxes(let count):
            throw Abort(
                .conflict,
                reason: "Agent hosts \(count) sandbox(es); delete them before changing its site"
            )
        }

        await req.application.agentService.syncDesiredStateToFleet()
        return try AgentResponse(
            from: assigned,
            targetVersion: AgentVersionTarget.version(configuration: req.controlPlaneConfiguration))
    }

}
