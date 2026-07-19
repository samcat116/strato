import Fluent
import StratoShared
import Vapor

/// Floating IPs (issue #344): external address pools plus per-address
/// allocations attached to VM NICs. An attached floating IP is pushed to the
/// site's network-controller agent on the desired-state sync and realized as
/// an OVN `dnat_and_snat` rule on the NIC's network router.
///
/// Pools are infrastructure (scoped like sites: org-or-OU owner, optional
/// site pin); allocations are project resources (scoped like networks).
struct FloatingIPController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let pools = routes.grouped("api", "floating-ip-pools").grouped(User.guardMiddleware())
        pools.get(use: listPools)
        pools.post(use: createPool)
        pools.get(":poolId", use: getPool)
        pools.put(":poolId", use: updatePool)
        pools.delete(":poolId", use: deletePool)

        let floatingIPs = routes.grouped("api", "floating-ips").grouped(User.guardMiddleware())
        floatingIPs.get(use: listFloatingIPs)
        floatingIPs.post(use: allocateFloatingIP)
        floatingIPs.get(":floatingIpId", use: getFloatingIP)
        floatingIPs.delete(":floatingIpId", use: releaseFloatingIP)
        floatingIPs.post(":floatingIpId", "attach", use: attachFloatingIP)
        floatingIPs.post(":floatingIpId", "detach", use: detachFloatingIP)
    }

    // MARK: - Pools (infrastructure, site-style authz)

    /// System admin, or `manage_agents` on the org/OU scope a pool is being
    /// created under — the same trust level as site management: a pool decides
    /// which external addresses a site answers for.
    private func requireManageAgents(_ req: Request, scope: OrganizationScope) async throws {
        let user = try req.auth.require(User.self)
        if user.isSystemAdmin { return }
        let ref = scope.spiceDBParentRef
        let allowed = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: "manage_agents",
            resource: ref.subjectType,
            resourceId: ref.subjectId.uuidString
        )
        guard allowed else {
            throw Abort(
                .forbidden, reason: "You don't have permission to manage floating IP pools for this organization")
        }
    }

    /// System admin, or the given permission on the pool itself (resolved
    /// through `floating_ip_pool#parent` in SpiceDB).
    private func requirePoolPermission(_ req: Request, pool: FloatingIPPool, permission: String) async throws {
        let user = try req.auth.require(User.self)
        if user.isSystemAdmin { return }
        let allowed = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: permission,
            resource: "floating_ip_pool",
            resourceId: try pool.requireID().uuidString
        )
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this floating IP pool")
        }
    }

    private func findPool(_ req: Request) async throws -> FloatingIPPool {
        guard let poolId = req.parameters.get("poolId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid pool ID")
        }
        guard let pool = try await FloatingIPPool.find(poolId, on: req.db) else {
            throw Abort(.notFound, reason: "Floating IP pool not found")
        }
        return pool
    }

    /// GET /api/floating-ip-pools
    @Sendable
    func listPools(req: Request) async throws -> [FloatingIPPoolResponse] {
        let user = try req.auth.require(User.self)
        let pools = try await FloatingIPPool.query(on: req.db).sort(\.$name).all()

        var visible: [FloatingIPPool] = []
        if user.isSystemAdmin {
            visible = pools
        } else {
            for pool in pools {
                guard let poolId = pool.id else { continue }
                let ok = try await req.spicedb.checkPermission(
                    subject: user.id!.uuidString,
                    permission: "view",
                    resource: "floating_ip_pool",
                    resourceId: poolId.uuidString
                )
                if ok { visible.append(pool) }
            }
        }

        var responses: [FloatingIPPoolResponse] = []
        for pool in visible {
            let count = try await FloatingIP.query(on: req.db)
                .filter(\.$pool.$id == pool.requireID())
                .count()
            responses.append(try FloatingIPPoolResponse(from: pool, allocatedCount: count))
        }
        return responses
    }

    /// POST /api/floating-ip-pools
    @Sendable
    func createPool(req: Request) async throws -> FloatingIPPoolResponse {
        let create = try req.content.decode(CreateFloatingIPPoolRequest.self)

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
            throw Abort(.badRequest, reason: "Pool name must be 1-100 characters")
        }
        let (cidr, gateway) = try Self.validatePoolAddressing(cidr: create.cidr, gateway: create.gateway)

        if let siteId = create.siteId {
            guard try await Site.find(siteId, on: req.db) != nil else {
                throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
            }
        }
        try await Self.assertNoPoolOverlap(cidr: cidr, siteId: create.siteId, excluding: nil, on: req.db)

        let pool = FloatingIPPool(
            name: name, cidr: cidr, gateway: gateway, siteID: create.siteId, organizationScope: scope)
        do {
            try await pool.save(on: req.db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A floating IP pool named '\(name)' already exists")
        }

        // Mirror ownership into SpiceDB so org admins can manage the pool.
        let ref = scope.spiceDBParentRef
        try await req.spicedb.writeRelationship(
            entity: "floating_ip_pool", entityId: try pool.requireID().uuidString,
            relation: "parent",
            subject: ref.subjectType, subjectId: ref.subjectId.uuidString)

        return try FloatingIPPoolResponse(from: pool, allocatedCount: 0)
    }

    /// GET /api/floating-ip-pools/:poolId
    @Sendable
    func getPool(req: Request) async throws -> FloatingIPPoolResponse {
        let pool = try await findPool(req)
        try await requirePoolPermission(req, pool: pool, permission: "view")
        let count = try await FloatingIP.query(on: req.db)
            .filter(\.$pool.$id == pool.requireID())
            .count()
        return try FloatingIPPoolResponse(from: pool, allocatedCount: count)
    }

    /// PUT /api/floating-ip-pools/:poolId — full-replace of the mutable
    /// fields (gateway, site pin), matching sites' PUT semantics. The CIDR is
    /// immutable: allocated addresses were carved from it.
    @Sendable
    func updatePool(req: Request) async throws -> FloatingIPPoolResponse {
        let pool = try await findPool(req)
        try await requirePoolPermission(req, pool: pool, permission: "manage")
        let update = try req.content.decode(UpdateFloatingIPPoolRequest.self)

        var canonicalGateway: String?
        if let gateway = update.gateway {
            (_, canonicalGateway) = try Self.validatePoolAddressing(cidr: pool.cidr, gateway: gateway)
            // The gateway is excluded from *future* allocation only, so a new
            // gateway that matches an already-allocated address would collide
            // with a live, possibly NAT'd floating IP.
            let collisions = try await FloatingIP.query(on: req.db)
                .filter(\.$pool.$id == pool.requireID())
                .filter(\.$address == canonicalGateway!)
                .count()
            guard collisions == 0 else {
                throw Abort(
                    .conflict,
                    reason: "Gateway \(canonicalGateway!) is already allocated as a floating IP; release it first")
            }
        }
        if let siteId = update.siteId {
            guard try await Site.find(siteId, on: req.db) != nil else {
                throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
            }
        }
        // Moving the pool between sites (or unpinning it) changes which pools
        // it can conflict with — re-check at the new scope. And it must not
        // strand live attachments: the site constraint is only enforced at
        // attach time, so a move would leave the old site advertising
        // addresses from a pool that now claims to answer elsewhere.
        if update.siteId != pool.$site.id {
            let attached = try await FloatingIP.query(on: req.db)
                .filter(\.$pool.$id == pool.requireID())
                .all()
                .filter { $0.$interface.id != nil }
                .count
            guard attached == 0 else {
                throw Abort(
                    .conflict,
                    reason:
                        "Pool has \(attached) attached floating IP(s); detach them before changing the pool's site"
                )
            }
            try await Self.assertNoPoolOverlap(
                cidr: pool.cidr, siteId: update.siteId, excluding: pool.id, on: req.db)
        }

        pool.gateway = canonicalGateway
        pool.$site.id = update.siteId
        try await pool.save(on: req.db)

        let count = try await FloatingIP.query(on: req.db)
            .filter(\.$pool.$id == pool.requireID())
            .count()
        return try FloatingIPPoolResponse(from: pool, allocatedCount: count)
    }

    /// DELETE /api/floating-ip-pools/:poolId
    @Sendable
    func deletePool(req: Request) async throws -> HTTPStatus {
        let pool = try await findPool(req)
        try await requirePoolPermission(req, pool: pool, permission: "manage")
        let poolId = try pool.requireID()

        let allocated = try await FloatingIP.query(on: req.db)
            .filter(\.$pool.$id == poolId)
            .count()
        guard allocated == 0 else {
            throw Abort(.conflict, reason: "Pool has \(allocated) allocated address(es); release them first")
        }

        try await pool.delete(on: req.db)

        // Drop the ownership tuple; best-effort — a leftover grants nothing
        // once the row is gone.
        if let ref = pool.organizationScope?.spiceDBParentRef {
            try? await req.spicedb.deleteRelationship(
                entity: "floating_ip_pool", entityId: poolId.uuidString,
                relation: "parent",
                subject: ref.subjectType, subjectId: ref.subjectId.uuidString)
        }
        return .noContent
    }

    // MARK: - Floating IPs (project resources, network-style authz)

    /// GET /api/floating-ips
    /// Query params: project_id (optional)
    @Sendable
    func listFloatingIPs(req: Request) async throws -> [FloatingIPResponse] {
        let user = try req.auth.require(User.self)

        let projectScope: [UUID]
        if let projectIdString = req.query[String.self, at: "project_id"],
            let projectId = UUID(uuidString: projectIdString)
        {
            let hasAccess = try await req.spicedb.checkPermission(
                subject: user.id!.uuidString,
                permission: "view_project",
                resource: "project",
                resourceId: projectId.uuidString
            )
            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }
            projectScope = [projectId]
        } else {
            projectScope = try await getAccessibleProjects(for: user, on: req)
        }

        let floatingIPs = try await FloatingIP.query(on: req.db)
            .filter(\.$project.$id ~~ projectScope)
            .with(\.$interface) { $0.with(\.$addresses) }
            .sort(\.$createdAt, .descending)
            .all()
        return try floatingIPs.map { try FloatingIPResponse(from: $0, interface: $0.interface) }
    }

    /// POST /api/floating-ips — allocate the lowest free address in a pool.
    @Sendable
    func allocateFloatingIP(req: Request) async throws -> FloatingIPResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decode(CreateFloatingIPRequest.self)

        // Same project resolution as networks/volumes.
        let projectId: UUID
        if let requestProjectId = request.projectId {
            projectId = requestProjectId
        } else if let currentOrgId = user.currentOrganizationId {
            guard
                let defaultProject = try await Project.query(on: req.db)
                    .filter(\.$organization.$id == currentOrgId)
                    .first()
            else {
                throw Abort(.badRequest, reason: "No project specified and no default project found")
            }
            projectId = defaultProject.id!
        } else {
            throw Abort(.badRequest, reason: "No project specified and user has no current organization")
        }

        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: "create_floating_ip",
            resource: "project",
            resourceId: projectId.uuidString
        )
        guard hasPermission else {
            throw Abort(.forbidden, reason: "You don't have permission to allocate floating IPs in this project")
        }

        guard let pool = try await FloatingIPPool.find(request.poolId, on: req.db) else {
            throw Abort(.badRequest, reason: "Floating IP pool \(request.poolId) does not exist")
        }
        // The pool serves its owning scope only, exactly as a site serves its
        // scope's projects: a sibling OU's project must not drain addresses
        // delegated elsewhere.
        guard let project = try await Project.find(projectId, on: req.db) else {
            throw Abort(.badRequest, reason: "Project \(projectId) does not exist")
        }
        guard let poolScope = pool.organizationScope,
            try await Self.scopeContains(poolScope, project: project, on: req.db)
        else {
            throw Abort(.conflict, reason: "Pool '\(pool.name)' does not serve this project's organization scope")
        }

        let creatorID = user.id!
        let floatingIP: FloatingIP
        do {
            floatingIP = try await req.db.transaction { db -> FloatingIP in
                let address = try await IPAMService.allocateFloatingIP(for: pool, on: db)
                let row = FloatingIP(
                    poolID: try pool.requireID(),
                    address: address,
                    projectID: projectId,
                    createdByID: creatorID)
                try await row.save(on: db)
                // IAM dual-write (issue #477), mirroring network create.
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: creatorID,
                    role: .admin,
                    nodeType: .floatingIP,
                    nodeID: row.id!,
                    createdBy: creatorID,
                    on: db
                )
                return row
            }
        } catch let error as IPAMService.IPAMError {
            throw Abort(.conflict, reason: error.localizedDescription)
        }

        try await req.spicedb.writeRelationship(
            entity: "floating_ip", entityId: floatingIP.id!.uuidString,
            relation: "owner",
            subject: "user", subjectId: creatorID.uuidString)
        try await req.spicedb.writeRelationship(
            entity: "floating_ip", entityId: floatingIP.id!.uuidString,
            relation: "project",
            subject: "project", subjectId: projectId.uuidString)

        req.logger.info(
            "Floating IP allocated",
            metadata: [
                "floatingIpId": .string(floatingIP.id!.uuidString),
                "address": .string(floatingIP.address),
                "pool": .string(pool.name),
            ])
        return try FloatingIPResponse(from: floatingIP)
    }

    /// GET /api/floating-ips/:floatingIpId
    @Sendable
    func getFloatingIP(req: Request) async throws -> FloatingIPResponse {
        let floatingIP = try await fetchFloatingIPWithPermission(req: req, permission: "read")
        let interface = try await loadedInterface(of: floatingIP, on: req.db)
        return try FloatingIPResponse(from: floatingIP, interface: interface)
    }

    /// DELETE /api/floating-ips/:floatingIpId — release the address back to
    /// the pool. Refused while attached: releasing a live address would tear
    /// down its NAT as a side effect; detaching first makes that explicit.
    @Sendable
    func releaseFloatingIP(req: Request) async throws -> HTTPStatus {
        let floatingIP = try await fetchFloatingIPWithPermission(req: req, permission: "delete")
        guard floatingIP.$interface.id == nil else {
            throw Abort(.conflict, reason: "Floating IP is attached; detach it first")
        }
        let floatingIpId = try floatingIP.requireID()

        if let createdById = floatingIP.$createdBy.id {
            try await req.spicedb.deleteRelationship(
                entity: "floating_ip", entityId: floatingIpId.uuidString,
                relation: "owner",
                subject: "user", subjectId: createdById.uuidString)
        }
        try await req.spicedb.deleteRelationship(
            entity: "floating_ip", entityId: floatingIpId.uuidString,
            relation: "project",
            subject: "project", subjectId: floatingIP.$project.id.uuidString)

        try await req.db.transaction { db in
            try await floatingIP.delete(on: db)
            try await RoleBindingService.revokeAll(nodeType: .floatingIP, nodeID: floatingIpId, on: db)
        }
        return .noContent
    }

    /// POST /api/floating-ips/:floatingIpId/attach
    @Sendable
    func attachFloatingIP(req: Request) async throws -> FloatingIPResponse {
        let floatingIP = try await fetchFloatingIPWithPermission(req: req, permission: "update")
        let request = try req.content.decode(AttachFloatingIPRequest.self)

        guard let vm = try await VM.find(request.vmId, on: req.db) else {
            throw Abort(.badRequest, reason: "VM \(request.vmId) does not exist")
        }
        guard vm.$project.id == floatingIP.$project.id else {
            throw Abort(.conflict, reason: "VM belongs to a different project than the floating IP")
        }

        let interfaces = try await VMNetworkInterface.query(on: req.db)
            .filter(\.$vm.$id == request.vmId)
            .with(\.$addresses)
            .sort(\.$orderIndex)
            .all()
        let interface: VMNetworkInterface
        if let interfaceId = request.interfaceId {
            guard let match = interfaces.first(where: { $0.id == interfaceId }) else {
                throw Abort(.badRequest, reason: "Interface \(interfaceId) does not belong to VM \(request.vmId)")
            }
            interface = match
        } else {
            guard let first = interfaces.first else {
                throw Abort(.conflict, reason: "VM has no network interfaces")
            }
            interface = first
        }
        let interfaceId = try interface.requireID()

        if let currentId = floatingIP.$interface.id {
            guard currentId == interfaceId else {
                throw Abort(.conflict, reason: "Floating IP is already attached; detach it first")
            }
            return try FloatingIPResponse(from: floatingIP, interface: interface)
        }

        // The NAT rule needs the NIC's fixed IPv4 as its logical IP, and a
        // router with an uplink to live on — so the NIC's network must have
        // egress (`externalAccess`); an isolated network's router deliberately
        // has no uplink to NAT through.
        guard interface.ipv4Address != nil else {
            throw Abort(.conflict, reason: "Interface has no IPv4 address to NAT to")
        }
        guard
            let network = try await LogicalNetwork.query(on: req.db)
                .filter(\.$name == interface.network)
                .first()
        else {
            throw Abort(.conflict, reason: "Interface's network '\(interface.network)' no longer exists")
        }
        guard network.externalAccess else {
            throw Abort(
                .conflict,
                reason: "Network '\(network.name)' has no external access; floating IPs need an egress network")
        }
        // A site-pinned pool only answers for its own site's OVN deployment.
        let pool = try await floatingIP.$pool.get(on: req.db)
        if let poolSiteId = pool.$site.id {
            guard network.$site.id == poolSiteId else {
                throw Abort(
                    .conflict,
                    reason: "Pool '\(pool.name)' is pinned to a different site than network '\(network.name)'")
            }
        }
        // One floating IP per NIC: two rules would fight over the NIC's
        // outbound SNAT. This read is the friendly-error fast path; the
        // partial unique index on interface_id is the authority — two
        // concurrent attaches can both pass this check, and the second one's
        // save then fails the constraint (caught below).
        let existingOnNIC = try await FloatingIP.query(on: req.db)
            .filter(\.$interface.$id == interfaceId)
            .count()
        guard existingOnNIC == 0 else {
            throw Abort(.conflict, reason: "Interface already has a floating IP attached")
        }

        floatingIP.$interface.id = interfaceId
        // Bump the network generation so a replayed pre-attach sync can't
        // resurrect the old NAT state on the agent.
        network.generation += 1
        do {
            try await req.db.transaction { db in
                try await floatingIP.save(on: db)
                try await network.save(on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "Interface already has a floating IP attached")
        }

        // Push the new NAT desired state to the fleet (the site's controller
        // realizes it); a lost nudge is caught by the periodic sync.
        await req.application.agentService.syncDesiredStateToAllAgents()

        req.logger.info(
            "Floating IP attached",
            metadata: [
                "floatingIpId": .string(floatingIP.id!.uuidString),
                "address": .string(floatingIP.address),
                "vmId": .string(request.vmId.uuidString),
                "interfaceId": .string(interfaceId.uuidString),
            ])
        return try FloatingIPResponse(from: floatingIP, interface: interface)
    }

    /// POST /api/floating-ips/:floatingIpId/detach
    @Sendable
    func detachFloatingIP(req: Request) async throws -> FloatingIPResponse {
        let floatingIP = try await fetchFloatingIPWithPermission(req: req, permission: "update")
        guard floatingIP.$interface.id != nil else {
            return try FloatingIPResponse(from: floatingIP)
        }
        let interface = try await loadedInterface(of: floatingIP, on: req.db)

        floatingIP.$interface.id = nil
        // Bump the (former) network's generation for the same replay-safety
        // reason as attach; the NAT rule drops out of the desired state and
        // the agent tears it down.
        let network = try await LogicalNetwork.query(on: req.db)
            .filter(\.$name == interface?.network ?? "")
            .first()
        network?.generation += 1
        try await req.db.transaction { db in
            try await floatingIP.save(on: db)
            try await network?.save(on: db)
        }

        await req.application.agentService.syncDesiredStateToAllAgents()

        req.logger.info(
            "Floating IP detached",
            metadata: [
                "floatingIpId": .string(floatingIP.id!.uuidString),
                "address": .string(floatingIP.address),
            ])
        return try FloatingIPResponse(from: floatingIP)
    }

    // MARK: - Helpers

    /// Whether a pool's owning scope contains a project (same containment rule
    /// as sites serving projects).
    static func scopeContains(_ scope: OrganizationScope, project: Project, on db: Database) async throws -> Bool {
        let projectScope: OrganizationScope
        if let orgID = project.$organization.id {
            projectScope = .organization(orgID)
        } else if let ouID = project.$organizationalUnit.id {
            projectScope = .organizationalUnit(ouID)
        } else {
            return false
        }
        return try await scope.contains(projectScope, on: db)
    }

    /// Rejects a pool CIDR that overlaps another pool's within the same
    /// answering scope. Allocation only deduplicates within one pool, so two
    /// overlapping pools that one OVN deployment answers for could both hand
    /// out the same external address. Pools pinned to *different* sites are
    /// separate fabrics and may overlap; a site-pinned pool conflicts with
    /// same-site and unpinned pools, and an unpinned pool conflicts with
    /// everything.
    static func assertNoPoolOverlap(
        cidr: String, siteId: UUID?, excluding poolId: UUID?, on db: Database
    ) async throws {
        let others = try await FloatingIPPool.query(on: db).all()
        for other in others where other.id != poolId {
            if let siteId, let otherSiteId = other.$site.id, siteId != otherSiteId { continue }
            if NetworkController.subnetsOverlap(cidr, other.cidr) {
                throw Abort(
                    .conflict,
                    reason: "Pool CIDR \(cidr) overlaps pool '\(other.name)' (\(other.cidr)) in the same scope")
            }
        }
    }

    /// Validates the pool CIDR (allocatable prefix range) and that the
    /// optional gateway is a valid address inside it. Returns canonical forms.
    static func validatePoolAddressing(cidr: String, gateway: String?) throws -> (String, String?) {
        guard let parsed = IPv4CIDR(cidr),
            IPAMService.allocatablePrefixRange.contains(parsed.prefix)
        else {
            throw Abort(
                .badRequest,
                reason:
                    "Pool CIDR must be IPv4 with a /\(IPAMService.allocatablePrefixRange.lowerBound)–/\(IPAMService.allocatablePrefixRange.upperBound) prefix"
            )
        }
        let canonical = "\(parsed.networkAddress)/\(parsed.prefix)"
        guard let gateway else { return (canonical, nil) }
        guard let gatewayIP = IPv4Address(gateway), parsed.contains(gatewayIP) else {
            throw Abort(.badRequest, reason: "Pool gateway must be an IPv4 address inside \(canonical)")
        }
        return (canonical, gatewayIP.description)
    }

    private func fetchFloatingIPWithPermission(req: Request, permission: String) async throws -> FloatingIP {
        let user = try req.auth.require(User.self)
        guard let floatingIpId = req.parameters.get("floatingIpId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid floating IP ID")
        }
        guard let floatingIP = try await FloatingIP.find(floatingIpId, on: req.db) else {
            throw Abort(.notFound, reason: "Floating IP not found")
        }
        let allowed = try await req.spicedb.checkPermission(
            subject: user.id!.uuidString,
            permission: permission,
            resource: "floating_ip",
            resourceId: floatingIpId.uuidString
        )
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have '\(permission)' permission on this floating IP")
        }
        return floatingIP
    }

    /// The floating IP's attached interface with addresses eager-loaded, nil
    /// while unattached.
    private func loadedInterface(of floatingIP: FloatingIP, on db: Database) async throws -> VMNetworkInterface? {
        guard let interfaceId = floatingIP.$interface.id else { return nil }
        return try await VMNetworkInterface.query(on: db)
            .filter(\.$id == interfaceId)
            .with(\.$addresses)
            .first()
    }

    /// Get all project IDs the user has access to (same shape as networks).
    private func getAccessibleProjects(for user: User, on req: Request) async throws -> [UUID] {
        let allProjects = try await Project.query(on: req.db).all()
        var accessibleProjectIds: [UUID] = []
        for project in allProjects {
            let hasAccess = try await req.spicedb.checkPermission(
                subject: user.id!.uuidString,
                permission: "view_project",
                resource: "project",
                resourceId: project.id!.uuidString
            )
            if hasAccess {
                accessibleProjectIds.append(project.id!)
            }
        }
        return accessibleProjectIds
    }
}
