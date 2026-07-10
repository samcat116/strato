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

    /// System admin, or `manage_agents` on the org/OU scope a new site is
    /// being created under.
    private func requireManageAgents(_ req: Request, scope: OrganizationScope) async throws {
        let user = try requireUser(req)
        if user.isSystemAdmin { return }
        let ref = scope.spiceDBParentRef
        let allowed = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: "manage_agents",
            resource: ref.subjectType,
            resourceId: ref.subjectId.uuidString
        )
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have permission to manage sites for this organization")
        }
    }

    /// System admin, or the given permission on the site itself (resolved
    /// through `site#parent` in SpiceDB).
    private func requireSitePermission(_ req: Request, site: Site, permission: String) async throws {
        let user = try requireUser(req)
        if user.isSystemAdmin { return }
        let allowed = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: permission,
            resource: "site",
            resourceId: try site.requireID().uuidString
        )
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this site")
        }
    }

    /// System admin, or `manage` on the agent (via `agent#parent`). Site
    /// membership changes need this ON TOP of site#manage: with agents and
    /// sites delegated to different OUs of one org, a sibling-OU site admin
    /// shares the root org but must not move an agent SpiceDB wouldn't let
    /// them manage.
    private func requireAgentManage(_ req: Request, agent: Agent) async throws {
        let user = try requireUser(req)
        if user.isSystemAdmin { return }
        let allowed = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: "manage",
            resource: "agent",
            resourceId: try agent.requireID().uuidString
        )
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have 'manage' permission on this agent")
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

    func listSites(req: Request) async throws -> [SiteResponse] {
        let user = try requireUser(req)
        let sites = try await Site.query(on: req.db).sort(\.$name).all()

        let visible: [Site]
        if user.isSystemAdmin {
            visible = sites
        } else {
            var allowed: [Site] = []
            for site in sites {
                guard let siteId = site.id else { continue }
                let ok = try await req.spicedb.checkPermission(
                    subject: user.id!.uuidString,
                    permission: "view",
                    resource: "site",
                    resourceId: siteId.uuidString
                )
                if ok { allowed.append(site) }
            }
            visible = allowed
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

        let site = Site(name: name, description: create.description, organizationScope: scope)
        do {
            try await site.save(on: req.db)
        } catch {
            // Surface the unique-name violation as a client error, matching
            // the registration-token conflict behavior.
            throw Abort(.conflict, reason: "A site named '\(name)' already exists")
        }

        // Mirror ownership into SpiceDB so org admins can manage the site.
        let ref = scope.spiceDBParentRef
        try await req.spicedb.writeRelationship(
            entity: "site", entityId: try site.requireID().uuidString,
            relation: "parent",
            subject: ref.subjectType, subjectId: ref.subjectId.uuidString)

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
        }

        site.description = update.description
        site.$networkControllerAgent.id = update.networkControllerAgentId
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

        try await site.delete(on: req.db)

        // Drop the ownership tuple; best-effort — a leftover grants nothing
        // once the row is gone.
        if let ref = site.organizationScope?.spiceDBParentRef {
            try? await req.spicedb.deleteRelationship(
                entity: "site", entityId: siteId.uuidString,
                relation: "parent",
                subject: ref.subjectType, subjectId: ref.subjectId.uuidString)
        }
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

        // A site is one OVN deployment owned by one org; admitting a foreign
        // org's agent would mix tenants on a shared SDN.
        let siteOrg = try await site.rootOrganizationID(on: req.db)
        let agentOrg = try await agent.rootOrganizationID(on: req.db)
        guard siteOrg == agentOrg else {
            throw Abort(
                .conflict,
                reason: "Agent belongs to a different organization than this site")
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

        agent.$site.id = nil
        try await agent.save(on: req.db)
        await req.application.agentService.syncDesiredStateToAllAgents()
        return try AgentResponse(from: agent)
    }
}
