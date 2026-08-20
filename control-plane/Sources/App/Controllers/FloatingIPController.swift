import Fluent
import ControlPlanePostgres
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
    private let allocations: FloatingIPAllocationsPersistence?
    private let iam: IAMPersistence
    private let projects: ProjectsPersistence
    private let pools: FloatingIPPoolsPersistence
    private let sites: SitesPersistence

    init(
        allocations: FloatingIPAllocationsPersistence? = nil,
        iam: IAMPersistence,
        projects: ProjectsPersistence,
        pools: FloatingIPPoolsPersistence,
        sites: SitesPersistence
    ) {
        self.allocations = allocations
        self.iam = iam
        self.projects = projects
        self.pools = pools
        self.sites = sites
    }

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

    /// `agent:manage` on the org/OU scope a pool is being created under —
    /// the same trust level as site management: a pool decides which external
    /// addresses a site answers for.
    private func requireManageAgents(_ req: Request, scope: OrganizationScope) async throws {
        let allowed = try await req.can("agent:manage", on: scope.checkNode)
        guard allowed else {
            throw Abort(
                .forbidden, reason: "You don't have permission to manage floating IP pools for this organization")
        }
    }

    /// `manage` on the site being pinned (resolved through the site's parent
    /// scope). Pinning a pool occupies the site's address-overlap scope, so
    /// authorizing only the pool's own org/OU would let one tenant's admin
    /// claim (and block) another tenant's site.
    private func requireSiteManage(_ req: Request, site: SiteSnapshot) async throws {
        let allowed = try await req.can("site:manage", on: IAMNode(type: .site, id: site.id))
        guard allowed else {
            throw Abort(.forbidden, reason: "You don't have 'manage' permission on this site")
        }
    }

    /// The IAM action standing for pool `view`/`manage`: a pool's access *is*
    /// its owning scope's access (`view = parent->view_*`,
    /// `manage = parent->manage_*`), so the check evaluates on the owning
    /// org/folder node. The pool itself has no node in the IAM tree.
    private static func poolScopeCheck(_ scope: OrganizationScope, manage: Bool) -> (action: String, node: IAMNode) {
        switch scope {
        case .organization:
            return (manage ? "org:update" : "org:read", scope.checkNode)
        case .organizationalUnit:
            return (manage ? "folder:update" : "folder:read", scope.checkNode)
        }
    }

    /// The scope-level permission a pool operation stands for, through the
    /// evaluator.
    private func requirePoolPermission(
        _ req: Request,
        pool: FloatingIPPoolSnapshot,
        manage: Bool
    ) async throws {
        guard let scope = try OrganizationScope.from(
            organizationID: pool.organizationID,
            organizationalUnitID: pool.organizationalUnitID,
            required: false
        ) else {
            // Rows predating scoping belong to no organization: nothing to
            // evaluate against, so only system admins may touch them
            // (defensive deny, mirroring scopeless quotas; the gate marks
            // the decision for the middleware's handler assertion).
            _ = try await req.requireSystemAdmin("This floating IP pool has no owning organization")
            return
        }
        let check = Self.poolScopeCheck(scope, manage: manage)
        guard try await req.can(check.action, on: check.node) else {
            throw Abort(
                .forbidden,
                reason: "You don't have '\(manage ? "manage" : "view")' permission on this floating IP pool")
        }
    }

    private func findPool(_ req: Request) async throws -> FloatingIPPoolSnapshot {
        guard let poolId = req.parameters.get("poolId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid pool ID")
        }
        guard let pool = try await pools.pool(id: poolId) else {
            throw Abort(.notFound, reason: "Floating IP pool not found")
        }
        return pool
    }

    /// GET /api/floating-ip-pools
    /// Query params: limit/offset (optional) — select the page.
    @Sendable
    func listPools(req: Request) async throws -> PagedResponse<FloatingIPPoolResponse> {
        let paging = try ListPaging.decode(from: req)
        let pools = try await visiblePools(req: req)
        return paging.page(pools)
    }

    /// Every pool the caller may read, by name, ready for slicing.
    func visiblePools(req: Request) async throws -> [FloatingIPPoolResponse] {
        _ = try req.auth.require(User.self)
        let poolRows = try await pools.allPools()

        // One filter for everyone: a scoped pool is an evaluator check on its
        // org/OU, which the tier-1 `platform-system-admin` policy answers for
        // admins — so an admin's full view is a logged, guardrail-bound
        // decision rather than a skipped check. A scopeless pool has no node
        // and stays system-admin only, as in `requirePoolPermission`.
        //
        // Which read action a pool stands for depends on the kind of scope
        // owning it (`org:read` vs `folder:read`), so the page costs one
        // batched decision per action (#687) instead of one evaluation per
        // pool. Unioning the two verdict sets is unambiguous because the node
        // type determines the action: an Organization node is only ever asked
        // `org:read`, a folder node only ever `folder:read`.
        var nodesByAction: [String: [IAMNode]] = [:]
        for pool in poolRows {
            guard let scope = try OrganizationScope.from(
                organizationID: pool.organizationID,
                organizationalUnitID: pool.organizationalUnitID,
                required: false
            ) else { continue }
            let check = Self.poolScopeCheck(scope, manage: false)
            nodesByAction[check.action, default: []].append(check.node)
        }
        var readable: Set<IAMNode> = []
        // Sorted so the decision log records the two batches in a stable order.
        for (action, nodes) in nodesByAction.sorted(by: { $0.key < $1.key }) {
            readable.formUnion(try await req.canFilter(action, on: nodes))
        }
        let visible = try poolRows.filter { pool in
            guard let scope = try OrganizationScope.from(
                organizationID: pool.organizationID,
                organizationalUnitID: pool.organizationalUnitID,
                required: false
            ) else {
                return req.allowsScopelessPlatformRow(action: "floatingip:list")
            }
            return readable.contains(Self.poolScopeCheck(scope, manage: false).node)
        }

        return visible.map { FloatingIPPoolResponse(from: $0) }
    }

    /// POST /api/floating-ip-pools
    @Sendable
    func createPool(req: Request) async throws -> FloatingIPPoolResponse {
        let create = try req.content.decodeValidated(CreateFloatingIPPoolRequest.self)

        guard
            let scope = try OrganizationScope.from(
                organizationID: create.organizationId, organizationalUnitID: create.organizationalUnitId)
        else {
            throw Abort(.badRequest, reason: "Either organizationId or organizationalUnitId is required")
        }
        try await requireManageAgents(req, scope: scope)

        let (cidr, gateway) = try Self.validatePoolAddressing(cidr: create.cidr, gateway: create.gateway)

        let siteId = create.siteId
        guard let site = try await sites.site(id: siteId) else {
            throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
        }
        try await requireSiteManage(req, site: site)

        switch try await pools.create(FloatingIPPoolWrite(
            name: create.name,
            cidr: cidr,
            gateway: gateway,
            siteID: siteId,
            organizationID: scope.organizationID,
            organizationalUnitID: scope.organizationalUnitID
        )) {
        case .created(let pool):
            return FloatingIPPoolResponse(from: pool)
        case .siteNotFound:
            throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
        case .scopeNotFound:
            switch scope {
            case .organization(let id):
                throw Abort(.badRequest, reason: "Organization \(id) does not exist")
            case .organizationalUnit(let id):
                throw Abort(.badRequest, reason: "Folder \(id) does not exist")
            }
        case .overlaps(let name, let existingCIDR):
            throw Abort(
                .conflict,
                reason: "Pool CIDR \(cidr) overlaps pool '\(name)' (\(existingCIDR)) in the same scope"
            )
        case .duplicateName:
            throw Abort(
                .conflict,
                reason: "A floating IP pool named '\(create.name)' already exists in this organization scope")
        }
    }

    /// GET /api/floating-ip-pools/:poolId
    @Sendable
    func getPool(req: Request) async throws -> FloatingIPPoolResponse {
        let pool = try await findPool(req)
        try await requirePoolPermission(req, pool: pool, manage: false)
        return FloatingIPPoolResponse(from: pool)
    }

    /// PUT /api/floating-ip-pools/:poolId — full-replace of the mutable
    /// fields (gateway, site pin), matching sites' PUT semantics. The CIDR is
    /// immutable: allocated addresses were carved from it.
    @Sendable
    func updatePool(req: Request) async throws -> FloatingIPPoolResponse {
        let pool = try await findPool(req)
        try await requirePoolPermission(req, pool: pool, manage: true)
        let update = try req.content.decode(UpdateFloatingIPPoolRequest.self)

        var canonicalGateway: String?
        if let gateway = update.gateway {
            (_, canonicalGateway) = try Self.validatePoolAddressing(cidr: pool.cidr, gateway: gateway)
        }
        let siteId = update.siteId
        if siteId != pool.siteID {
            guard let site = try await sites.site(id: siteId) else {
                throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
            }
            try await requireSiteManage(req, site: site)
        }
        // Moving the pool between sites (or unpinning it) changes which pools
        // it can conflict with — re-check at the new scope. And it must not
        // strand live attachments: the site constraint is only enforced at
        // attach time, so a move would leave the old site advertising
        // addresses from a pool that now claims to answer elsewhere.
        switch try await pools.update(id: pool.id, gateway: canonicalGateway, siteID: siteId) {
        case .updated(let pool):
            return FloatingIPPoolResponse(from: pool)
        case .notFound:
            throw Abort(.notFound, reason: "Floating IP pool not found")
        case .siteNotFound:
            throw Abort(.badRequest, reason: "Site \(siteId) does not exist")
        case .gatewayAlreadyAllocated:
            throw Abort(
                .conflict,
                reason: "Gateway \(canonicalGateway!) is already allocated as a floating IP; release it first"
            )
        case .hasAttachedAddresses(let count):
            throw Abort(
                .conflict,
                reason: "Pool has \(count) attached floating IP(s); detach them before changing the pool's site"
            )
        case .overlaps(let name, let existingCIDR):
            throw Abort(
                .conflict,
                reason: "Pool CIDR \(pool.cidr) overlaps pool '\(name)' (\(existingCIDR)) in the same scope"
            )
        }
    }

    /// DELETE /api/floating-ip-pools/:poolId
    @Sendable
    func deletePool(req: Request) async throws -> HTTPStatus {
        let pool = try await findPool(req)
        try await requirePoolPermission(req, pool: pool, manage: true)
        switch try await pools.deleteIfEmpty(id: pool.id) {
        case .deleted:
            return .noContent
        case .notFound:
            throw Abort(.notFound, reason: "Floating IP pool not found")
        case .hasAllocatedAddresses(let count):
            throw Abort(.conflict, reason: "Pool has \(count) allocated address(es); release them first")
        }
    }

    // MARK: - Floating IPs (project resources, network-style authz)

    /// GET /api/floating-ips
    /// Query params: project_id (optional),
    /// limit/offset (optional) — select the page.
    @Sendable
    func listFloatingIPs(req: Request) async throws -> PagedResponse<FloatingIPResponse> {
        let paging = try ListPaging.decode(from: req)
        let floatingIPs = try await visibleFloatingIPs(req: req)
        return paging.page(floatingIPs)
    }

    /// Every floating IP the caller may read, newest first, ready for slicing.
    func visibleFloatingIPs(req: Request) async throws -> [FloatingIPResponse] {
        _ = try req.auth.require(User.self)
        let requestedProjectId = req.query[String.self, at: "project_id"].flatMap(UUID.init(uuidString:))
        guard let allocations else {
            throw Abort(
                .internalServerError,
                reason: "Floating-IP allocation persistence is not configured"
            )
        }

        // Project scoping runs for every caller. An admin holds no per-project
        // bindings, but every project their rows land in is still put to the
        // evaluator and the tier-1 `platform-system-admin` policy answers yes —
        // so an admin still sees every project's floating IPs, by a decision
        // that is logged and that a guardrail can narrow.
        var visibility: ProjectVisibility?
        let rows: [FloatingIPAllocationSnapshot]
        if let requestedProjectId {
            let hasAccess = try await req.can(
                "project:read", on: IAMNode(type: .project, id: requestedProjectId))
            guard hasAccess else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }
            rows = try await allocations.allocations(projectIDs: [requestedProjectId])
        } else {
            // Narrow to the projects the caller could reach, then let the
            // evaluator decide the ones that carry rows (`ProjectVisibility`).
            let resolved = try await ProjectVisibility.resolve(on: req, using: iam, projects: projects)
            guard !resolved.reachesNoProject else { return [] }
            if let candidates = resolved.candidateProjectIDs {
                rows = try await allocations.allocations(projectIDs: candidates)
            } else {
                rows = try await allocations.allAllocations()
            }
            visibility = resolved
        }
        var floatingIPs = rows
        if let visibility {
            floatingIPs = try await visibility.readableRows(
                floatingIPs, projectID: { $0.projectID }, on: req)
        }
        return try floatingIPs.map { try FloatingIPResponse(from: $0) }
    }

    /// POST /api/floating-ips — allocate the lowest free address in a pool.
    @Sendable
    func allocateFloatingIP(req: Request) async throws -> FloatingIPResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decode(CreateFloatingIPRequest.self)

        let project = try await req.authorizedProjectForCreate(
            requested: request.projectId,
            action: "floatingip:create", resourceKind: "floating IPs", verb: "allocate")
        let projectId = try project.requireID()

        guard let pool = try await pools.pool(id: request.poolId) else {
            throw Abort(.badRequest, reason: "Floating IP pool \(request.poolId) does not exist")
        }
        // The pool serves its owning scope only, exactly as a site serves its
        // scope's projects: a sibling OU's project must not drain addresses
        // delegated elsewhere.
        guard let poolScope = try OrganizationScope.from(
                organizationID: pool.organizationID,
                organizationalUnitID: pool.organizationalUnitID,
                required: false
            ),
            try await Self.scopeContains(poolScope, project: project, on: req.db)
        else {
            throw Abort(.conflict, reason: "Pool '\(pool.name)' does not serve this project's organization scope")
        }

        guard let allocations else {
            throw Abort(
                .internalServerError,
                reason: "Floating-IP allocation persistence is not configured"
            )
        }
        let creatorID = user.id!
        let floatingIP: FloatingIPAllocationSnapshot
        do {
            floatingIP = try await allocations.allocate(
                fromPoolID: pool.id,
                toProjectID: projectId,
                createdByID: creatorID
            )
            Telemetry.ipamAllocated(family: "ipv4")
        } catch let error as FloatingIPAllocationError {
            switch error {
            case .poolExhausted(let poolName, let cidr):
                Telemetry.ipamAllocationFailed(family: "ipv4", reason: "pool_exhausted")
                throw Abort(
                    .conflict,
                    reason: "No free IP addresses left in network \(poolName) (\(cidr))"
                )
            case .poolNotFound:
                throw Abort(
                    .badRequest,
                    reason: "Floating IP pool \(request.poolId) does not exist"
                )
            case .invalidSubnet:
                Telemetry.ipamAllocationFailed(family: "ipv4", reason: "invalid_subnet")
                throw error
            case .invalidGateway:
                Telemetry.ipamAllocationFailed(family: "ipv4", reason: "invalid_gateway")
                throw error
            case .unexpectedRowCount:
                throw error
            }
        }

        req.logger.info(
            "Floating IP allocated",
            metadata: [
                "floatingIpId": .string(floatingIP.id.uuidString),
                "address": .string(floatingIP.address),
                "pool": .string(pool.name),
            ])
        return try FloatingIPResponse(from: floatingIP)
    }

    /// GET /api/floating-ips/:floatingIpId
    @Sendable
    func getFloatingIP(req: Request) async throws -> FloatingIPResponse {
        let floatingIP = try await fetchNativeFloatingIPWithAction(
            req: req,
            action: "floatingip:read"
        )
        return try FloatingIPResponse(from: floatingIP)
    }

    /// DELETE /api/floating-ips/:floatingIpId — release the address back to
    /// the pool. Refused while attached: releasing a live address would tear
    /// down its NAT as a side effect; detaching first makes that explicit.
    @Sendable
    func releaseFloatingIP(req: Request) async throws -> HTTPStatus {
        let floatingIP = try await fetchNativeFloatingIPWithAction(
            req: req,
            action: "floatingip:release"
        )
        guard let allocations else {
            throw Abort(
                .internalServerError,
                reason: "Floating-IP allocation persistence is not configured"
            )
        }
        switch try await allocations.releaseIfDetached(id: floatingIP.id) {
        case .released:
            return .noContent
        case .notFound:
            throw Abort(.notFound, reason: "Floating IP not found")
        case .attached:
            throw Abort(.conflict, reason: "Floating IP is attached; detach it first")
        }
    }

    /// POST /api/floating-ips/:floatingIpId/attach
    @Sendable
    func attachFloatingIP(req: Request) async throws -> FloatingIPResponse {
        let floatingIP = try await fetchNativeFloatingIPWithAction(
            req: req, action: "floatingip:attach")
        let request = try req.content.decode(AttachFloatingIPRequest.self)

        guard (request.vmId != nil) != (request.loadBalancerId != nil) else {
            throw Abort(
                .badRequest,
                reason: "Specify exactly one attachment target: vmId or loadBalancerId")
        }
        if let loadBalancerID = request.loadBalancerId {
            guard request.interfaceId == nil else {
                throw Abort(.badRequest, reason: "interfaceId is only valid with vmId")
            }
            return try await attach(
                floatingIP: floatingIP, toLoadBalancer: loadBalancerID, req: req)
        }
        guard let vmID = request.vmId else {
            throw Abort(.badRequest, reason: "vmId is required for a VM attachment")
        }

        // Owning the floating IP is not enough: attaching changes the *VM's*
        // inbound exposure and outbound SNAT, so the caller needs update on
        // the VM too (the volume-attach rule). An unreachable VM is answered as
        // absent whether it is missing or merely forbidden — see `reachableVM`
        // (issue #881).
        let vm = try await req.reachableVM(vmID, action: "vm:update")
        // After the VM check, never before: a containment refusal handed to a
        // caller who can't touch the VM would tell them it exists in another
        // project (issue #777).
        try ProjectContainment.require(
            "VM", in: vm.projectID,
            sameProjectAs: "the floating IP", in: floatingIP.projectID)

        let interfaces = try await LegacyInterfaceAddressStore.loading(
            LegacyVMNetworkInterfaceStore.interfaces(vmID: vmID, on: req.db),
            on: req.db)
        let interface: VMNetworkInterface
        if let interfaceId = request.interfaceId {
            guard let match = interfaces.first(where: { $0.id == interfaceId }) else {
                throw Abort(.badRequest, reason: "Interface \(interfaceId) does not belong to VM \(vmID)")
            }
            interface = match
        } else {
            guard let first = interfaces.first else {
                throw Abort(.conflict, reason: "VM has no network interfaces")
            }
            interface = first
        }
        let interfaceId = try interface.requireID()

        if floatingIP.loadBalancerID != nil {
            throw Abort(.conflict, reason: "Floating IP is already attached; detach it first")
        }
        if let currentId = floatingIP.interfaceID {
            guard currentId == interfaceId else {
                throw Abort(.conflict, reason: "Floating IP is already attached; detach it first")
            }
            return try FloatingIPResponse(from: floatingIP)
        }

        // The NAT rule needs the NIC's fixed IPv4 as its logical IP, and a
        // router with an uplink to live on — so the NIC's network must have
        // egress (`externalAccess`); an isolated network's router deliberately
        // has no uplink to NAT through.
        guard interface.ipv4Address != nil else {
            throw Abort(.conflict, reason: "Interface has no IPv4 address to NAT to")
        }
        guard let network = try await LogicalNetwork.find(interface.logicalNetworkID, on: req.db) else {
            throw Abort(.conflict, reason: "Interface's network no longer exists")
        }
        guard network.externalAccess else {
            throw Abort(
                .conflict,
                reason: "Network '\(network.name)' has no external access; floating IPs need an egress network")
        }
        // A site-pinned pool only answers for its own site's OVN deployment.
        guard let pool = try await pools.pool(id: floatingIP.poolID) else {
            throw Abort(.conflict, reason: "Floating IP pool no longer exists")
        }
        if network.siteID != pool.siteID {
            throw Abort(
                .conflict,
                reason: "Pool '\(pool.name)' is pinned to a different site than network '\(network.name)'")
        }
        // Refuse *unplaced* VMs outright: an attach accepted now has no
        // realizing agent to carry the NAT rule, and the API would report an
        // attached address nothing backs.
        _ = try await Self.requireNATRealizingAgent(
            for: vm,
            offlineGrace: req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
            on: req.db)
        guard let allocations else {
            throw Abort(
                .internalServerError,
                reason: "Floating-IP allocation persistence is not configured")
        }
        let attached: FloatingIPAllocationSnapshot
        switch try await allocations.attach(
            id: floatingIP.id,
            to: .interface(id: interfaceId, networkID: try network.requireID()))
        {
        case .attached(let snapshot), .unchanged(let snapshot):
            attached = snapshot
        case .notFound:
            throw Abort(.notFound, reason: "Floating IP not found")
        case .alreadyAttached:
            throw Abort(.conflict, reason: "Floating IP is already attached; detach it first")
        case .targetInUse:
            throw Abort(.conflict, reason: "Interface already has a floating IP attached")
        case .networkNotFound:
            throw Abort(.notFound, reason: "Network no longer exists")
        }

        // Ring the fleet for the new NAT desired state (the site's controller
        // realizes it); a lost doorbell is caught by unconditional refetches.
        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "Floating IP attached",
            metadata: [
                "floatingIpId": .string(floatingIP.id.uuidString),
                "address": .string(attached.address),
                "vmId": .string(vmID.uuidString),
                "interfaceId": .string(interfaceId.uuidString),
            ])
        return try FloatingIPResponse(from: attached)
    }

    /// POST /api/floating-ips/:floatingIpId/detach
    @Sendable
    func detachFloatingIP(req: Request) async throws -> FloatingIPResponse {
        let floatingIP = try await fetchNativeFloatingIPWithAction(
            req: req, action: "floatingip:detach")
        guard floatingIP.interfaceID != nil || floatingIP.loadBalancerID != nil else {
            return try FloatingIPResponse(from: floatingIP)
        }
        guard let allocations else {
            throw Abort(
                .internalServerError,
                reason: "Floating-IP allocation persistence is not configured")
        }
        let detached: FloatingIPAllocationSnapshot
        switch try await allocations.detach(id: floatingIP.id) {
        case .attached(let snapshot), .unchanged(let snapshot):
            detached = snapshot
        case .notFound:
            throw Abort(.notFound, reason: "Floating IP not found")
        case .networkNotFound:
            throw Abort(.notFound, reason: "Network no longer exists")
        case .alreadyAttached, .targetInUse:
            throw Abort(.internalServerError, reason: "Floating IP detach failed")
        }

        await req.application.agentService.syncDesiredStateToFleet()

        req.logger.info(
            "Floating IP detached",
            metadata: [
                "floatingIpId": .string(floatingIP.id.uuidString),
                "address": .string(detached.address),
            ])
        return try FloatingIPResponse(from: detached)
    }

    // MARK: - Helpers

    private func attach(
        floatingIP: FloatingIPAllocationSnapshot,
        toLoadBalancer loadBalancerID: UUID,
        req: Request
    ) async throws -> FloatingIPResponse {
        let loadBalancer = try await req.authorizedLoadBalancer(
            loadBalancerID, action: "loadbalancer:update")
        try ProjectContainment.require(
            "Load balancer", in: loadBalancer.projectID,
            sameProjectAs: "the floating IP", in: floatingIP.projectID)

        if floatingIP.interfaceID != nil {
            throw Abort(.conflict, reason: "Floating IP is already attached; detach it first")
        }
        if let currentID = floatingIP.loadBalancerID {
            guard currentID == loadBalancerID else {
                throw Abort(.conflict, reason: "Floating IP is already attached; detach it first")
            }
            return try FloatingIPResponse(from: floatingIP)
        }

        guard
            let network = try await LogicalNetwork.find(
                loadBalancer.logicalNetworkID, on: req.db)
        else {
            throw Abort(.conflict, reason: "Load balancer's network no longer exists")
        }
        guard network.externalAccess else {
            throw Abort(
                .conflict,
                reason: "Network '\(network.name)' has no external access; floating IPs need an egress network")
        }
        guard let pool = try await pools.pool(id: floatingIP.poolID) else {
            throw Abort(.conflict, reason: "Floating IP pool no longer exists")
        }
        guard network.siteID == pool.siteID else {
            throw Abort(
                .conflict,
                reason: "Pool '\(pool.name)' is pinned to a different site than network '\(network.name)'")
        }
        guard let site = try await LegacySiteStore.site(id: network.siteID, on: req.db) else {
            throw Abort(.conflict, reason: "Load balancer's network site no longer exists")
        }
        if let refusal = SiteNetworkAuthority.refusal(
            try await SiteNetworkAuthority.resolve(
                forSite: site,
                offlineGrace: req.controlPlaneConfiguration.double(.siteControllerOfflineGraceSeconds),
                on: req.db),
            consequence: "nothing would realize the load balancer's external address")
        {
            throw refusal
        }

        guard let allocations else {
            throw Abort(
                .internalServerError,
                reason: "Floating-IP allocation persistence is not configured")
        }
        let attached: FloatingIPAllocationSnapshot
        switch try await allocations.attach(
            id: floatingIP.id,
            to: .loadBalancer(id: loadBalancerID, networkID: try network.requireID()))
        {
        case .attached(let snapshot), .unchanged(let snapshot):
            attached = snapshot
        case .notFound:
            throw Abort(.notFound, reason: "Floating IP not found")
        case .alreadyAttached:
            throw Abort(.conflict, reason: "Floating IP is already attached; detach it first")
        case .targetInUse:
            throw Abort(.conflict, reason: "Load balancer already has a floating IP attached")
        case .networkNotFound:
            throw Abort(.notFound, reason: "Network no longer exists")
        }

        await req.application.agentService.syncDesiredStateToFleet()
        return try FloatingIPResponse(from: attached)
    }

    /// Whether a pool's owning scope contains a project (same containment rule
    /// as sites serving projects).
    static func scopeContains(_ scope: OrganizationScope, project: Project, on db: Database) async throws -> Bool {
        let projectScope: OrganizationScope
        if let orgID = project.organizationID {
            projectScope = .organization(orgID)
        } else if let ouID = project.organizationalUnitID {
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
        cidr: String,
        siteId: UUID?,
        excluding poolId: UUID?,
        using pools: FloatingIPPoolsPersistence
    ) async throws {
        let others = try await pools.allPools()
        for other in others where other.id != poolId {
            if let siteId, siteId != other.siteID { continue }
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

    /// The site's network controller whose reconciler would realize NAT for
    /// the VM. Throws 409 in every state where
    /// *nothing* would realize the NAT rule, so an attach can never persist
    /// an address the sync path won't back:
    /// - the VM is unplaced (the scheduler has no floating-IP capability
    ///   requirement, so a later placement could land on a too-old agent);
    /// - the site has no designated network controller (assembly then sends
    ///   *no* agent the network state);
    /// - the site's controller is offline past the grace window, or came back
    ///   unable to author topology (issue #833).
    static func requireNATRealizingAgent(
        for vm: VM,
        offlineGrace: TimeInterval = SiteNetworkAuthority.controllerOfflineGrace,
        on db: Database
    ) async throws -> Agent {
        guard let hypervisorId = vm.hypervisorId,
            let agentUUID = UUID(uuidString: hypervisorId),
            let agent = try await Agent.find(agentUUID, on: db)
        else {
            throw Abort(
                .conflict,
                reason: "VM is not placed on an agent yet; attach the floating IP after it is scheduled")
        }
        let authority = try await SiteNetworkAuthority.resolve(
            forAgent: agent, offlineGrace: offlineGrace, on: db)
        if let refusal = SiteNetworkAuthority.refusal(
            authority, host: agent, consequence: "nothing would realize the NAT rule")
        {
            throw refusal
        }
        switch authority {
        case .controller(let controller):
            return controller
        case .controllerUnavailable(_, let controller, _):
            // Only reachable through `refusal`'s host exemption — the hosting
            // agent *is* the unavailable controller, and it is still the agent
            // that realizes this NAT once it comes back.
            return controller
        case .unassigned(let site):
            // Already refused above — restated rather than force-unwrapped so
            // the switch stays exhaustive without a fatal path.
            throw SiteNetworkAuthority.missingControllerAbort(
                site: site, consequence: "nothing would realize the NAT rule")
        }
    }

    private func fetchNativeFloatingIPWithAction(
        req: Request,
        action: String
    ) async throws -> FloatingIPAllocationSnapshot {
        guard let floatingIPID = req.parameters.get("floatingIpId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid floating IP ID")
        }
        guard let allocations else {
            throw Abort(
                .internalServerError,
                reason: "Floating-IP allocation persistence is not configured"
            )
        }
        guard let floatingIP = try await allocations.allocation(id: floatingIPID) else {
            throw Abort(.notFound, reason: "Floating IP not found")
        }
        guard try await req.can(action, on: IAMNode(type: .floatingIP, id: floatingIPID)) else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this floating IP")
        }
        return floatingIP
    }

}
