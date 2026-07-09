import Fluent
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
    /// changes which node authors a site's whole SDN. System admins only.
    private func requireSystemAdmin(_ req: Request) throws {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "System admin access required")
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
        try requireSystemAdmin(req)
        let sites = try await Site.query(on: req.db).sort(\.$name).all()
        return try sites.map { try SiteResponse(from: $0) }
    }

    func getSite(req: Request) async throws -> SiteResponse {
        try requireSystemAdmin(req)
        return try SiteResponse(from: try await findSite(req))
    }

    func createSite(req: Request) async throws -> SiteResponse {
        try requireSystemAdmin(req)
        let create = try req.content.decode(CreateSiteRequest.self)

        let name = create.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else {
            throw Abort(.badRequest, reason: "Site name must be 1-100 characters")
        }

        let site = Site(name: name, description: create.description)
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
        try requireSystemAdmin(req)
        let site = try await findSite(req)
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
        try requireSystemAdmin(req)
        let site = try await findSite(req)
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
        return .noContent
    }

    func assignAgent(req: Request) async throws -> AgentResponse {
        try requireSystemAdmin(req)
        let site = try await findSite(req)
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db) else {
            throw Abort(.notFound, reason: "Agent not found")
        }
        let targetSiteId = try site.requireID()

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
        try requireSystemAdmin(req)
        let site = try await findSite(req)
        let siteId = try site.requireID()
        guard let agentId = req.parameters.get("agentId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid agent ID")
        }
        guard let agent = try await Agent.find(agentId, on: req.db), agent.$site.id == siteId else {
            throw Abort(.notFound, reason: "Agent not found in this site")
        }

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
