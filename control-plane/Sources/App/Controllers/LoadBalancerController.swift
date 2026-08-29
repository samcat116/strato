import Fluent
import SQLKit
import Vapor

/// Project-scoped native OVN L4 load balancers (STR-28). The resource and its
/// membership are synchronous database mutations; the level-triggered fleet
/// sync is the retryable delivery mechanism, so no ResourceOperation is needed.
struct LoadBalancerController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let loadBalancers = routes.grouped("api", "load-balancers").grouped(User.guardMiddleware())
        loadBalancers.get(use: list)
        loadBalancers.post(use: create)
        loadBalancers.get(":loadBalancerId", use: get)
        loadBalancers.put(":loadBalancerId", use: update)
        loadBalancers.delete(":loadBalancerId", use: delete)

        loadBalancers.get(":loadBalancerId", "listeners", use: listListeners)
        loadBalancers.post(":loadBalancerId", "listeners", use: createListener)
        loadBalancers.put(":loadBalancerId", "listeners", ":listenerId", use: updateListener)
        loadBalancers.delete(":loadBalancerId", "listeners", ":listenerId", use: deleteListener)

        loadBalancers.get(":loadBalancerId", "backends", use: listBackends)
        loadBalancers.post(":loadBalancerId", "backends", use: createBackend)
        loadBalancers.delete(":loadBalancerId", "backends", ":backendId", use: deleteBackend)
    }

    // MARK: - CRUD

    @Sendable
    func list(req: Request) async throws -> PagedResponse<LoadBalancerResponse> {
        _ = try req.auth.require(User.self)
        let paging = try ListPaging.decode(from: req)
        let requestedProjectId = req.query[String.self, at: "project_id"].flatMap(UUID.init(uuidString:))

        var query = LoadBalancer.query(on: req.db)
            .with(\.$logicalNetwork)
            .sort(\.$name)
            .sort(\.$id)
        var visibility: ProjectVisibility?
        if let requestedProjectId {
            guard try await req.can("project:read", on: IAMNode(type: .project, id: requestedProjectId)) else {
                throw Abort(.forbidden, reason: "You don't have access to this project")
            }
            query = query.filter(\.$project.$id == requestedProjectId)
        } else {
            let resolved = try await ProjectVisibility.resolve(on: req)
            guard !resolved.reachesNoProject else { return paging.page([]) }
            if let candidates = resolved.candidateProjectIDs {
                query = query.filter(\.$project.$id ~~ candidates)
            }
            visibility = resolved
        }

        var rows = try await query.all()
        if let visibility {
            rows = try await visibility.readableRows(rows, projectID: { $0.$project.id }, on: req)
        }
        var responses: [LoadBalancerResponse] = []
        for row in rows {
            responses.append(try await response(for: row, on: req.db))
        }
        return paging.page(responses)
    }

    @Sendable
    func create(req: Request) async throws -> LoadBalancerResponse {
        let user = try req.auth.require(User.self)
        let request = try req.content.decodeValidated(CreateLoadBalancerRequest.self)
        let name = request.name
        let healthCheck = request.healthCheck ?? .disabled
        try healthCheck.validate()

        let project = try await req.authorizedProjectForCreate(
            requested: request.projectId,
            action: "loadbalancer:create",
            resourceKind: "load balancers")
        let projectID = try project.requireID()
        let network = try await LogicalNetworkService.resolveForWorkloadCreate(
            requestedID: request.logicalNetworkId,
            requestedName: nil,
            projectID: projectID,
            on: req.db)

        let creatorID = try user.requireID()
        let loadBalancer: LoadBalancer
        do {
            loadBalancer = try await req.db.transaction { db in
                try await QuotaEnforcementService.reserveLoadBalancer(for: project, on: db)
                let allocation = try await IPAMService.allocateIP(for: network, on: db)
                let row = LoadBalancer(
                    name: name,
                    projectID: projectID,
                    logicalNetworkID: try network.requireID(),
                    vip: allocation.ipAddress,
                    protocolName: request.protocol,
                    healthCheck: healthCheck,
                    createdByID: creatorID)
                try await row.save(on: db)
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: creatorID,
                    role: .admin,
                    nodeType: .loadBalancer,
                    nodeID: try row.requireID(),
                    createdBy: creatorID,
                    on: db)
                return row
            }
        } catch let error as IPAMService.IPAMError {
            throw Abort(.conflict, reason: error.localizedDescription)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "A load balancer named '\(name)' already exists in this project")
        }

        await req.application.agentService.syncDesiredStateToFleet()
        return try await response(for: loadBalancer, on: req.db)
    }

    @Sendable
    func get(req: Request) async throws -> LoadBalancerResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:read")
        return try await response(for: loadBalancer, on: req.db)
    }

    @Sendable
    func update(req: Request) async throws -> LoadBalancerResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let request = try req.content.decodeValidated(UpdateLoadBalancerRequest.self)
        let id = try loadBalancer.requireID()

        if request.name == nil, request.protocol == nil, request.healthCheck == nil {
            return try await response(for: loadBalancer, on: req.db)
        }
        let name = request.name
        try request.healthCheck?.validate()

        do {
            try await req.db.transaction { db in
                let current = try await Self.locked(id, on: db)
                if let name { current.name = name }
                if let protocolName = request.protocol { current.protocolName = protocolName }
                if let healthCheck = request.healthCheck { current.healthCheck = healthCheck }
                current.observedState = .pending
                current.lastError = nil
                try await current.save(on: db)
                try await Self.bumpGeneration(of: id, on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(
                .conflict, reason: "A load balancer named '\(name ?? loadBalancer.name)' already exists in this project"
            )
        }
        await req.application.agentService.syncDesiredStateToFleet()
        guard let refreshed = try await LoadBalancer.find(id, on: req.db) else { throw Abort(.notFound) }
        return try await response(for: refreshed, on: req.db)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let loadBalancer = try await find(req, action: "loadbalancer:delete")
        let id = try loadBalancer.requireID()
        let networkID = loadBalancer.$logicalNetwork.id
        try await req.db.transaction { db in
            // FloatingIP.load_balancer_id is SET NULL: deleting the load
            // balancer withdraws external exposure without releasing the
            // project's reserved floating address.
            try await loadBalancer.delete(on: db)
            // The LB and its cascading floating-IP detach both disappear from
            // this network's authoritative desired state. Advance the network
            // ordering key in the same transaction so an older payload cannot
            // recreate either OVN row after this deletion commits.
            try await DesiredStateGenerationWriter.advanceOrThrow(
                schema: LogicalNetwork.schema, id: networkID, resource: "Network", on: db)
            try await RoleBindingService.revokeAll(nodeType: .loadBalancer, nodeID: id, on: db)
            try await QuotaEnforcementService.release(for: loadBalancer, on: db)
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Listeners

    @Sendable
    func listListeners(req: Request) async throws -> [LoadBalancerListenerResponse] {
        let loadBalancer = try await find(req, action: "loadbalancer:read")
        return try await LoadBalancerListener.query(on: req.db)
            .filter(\.$loadBalancer.$id == loadBalancer.requireID())
            .sort(\.$port)
            .all()
            .map(LoadBalancerListenerResponse.init(from:))
    }

    @Sendable
    func createListener(req: Request) async throws -> LoadBalancerListenerResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let request = try req.content.decode(CreateLoadBalancerListenerRequest.self)
        try Self.validatePort(request.port, name: "Listener")
        try Self.validatePort(request.backendPort, name: "Backend")
        let loadBalancerID = try loadBalancer.requireID()
        let listener = LoadBalancerListener(
            loadBalancerID: loadBalancerID, port: request.port, backendPort: request.backendPort)
        do {
            try await req.db.transaction { db in
                try await listener.save(on: db)
                try await Self.markPendingAndBump(loadBalancerID, on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "Listener port \(request.port) already exists on this load balancer")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return try LoadBalancerListenerResponse(from: listener)
    }

    @Sendable
    func updateListener(req: Request) async throws -> LoadBalancerListenerResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let request = try req.content.decode(UpdateLoadBalancerListenerRequest.self)
        try Self.validatePort(request.port, name: "Listener")
        try Self.validatePort(request.backendPort, name: "Backend")
        let loadBalancerID = try loadBalancer.requireID()
        let listener = try await findListener(req, loadBalancerID: loadBalancerID)
        do {
            try await req.db.transaction { db in
                listener.port = request.port
                listener.backendPort = request.backendPort
                try await listener.save(on: db)
                try await Self.markPendingAndBump(loadBalancerID, on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "Listener port \(request.port) already exists on this load balancer")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return try LoadBalancerListenerResponse(from: listener)
    }

    @Sendable
    func deleteListener(req: Request) async throws -> HTTPStatus {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let loadBalancerID = try loadBalancer.requireID()
        let listener = try await findListener(req, loadBalancerID: loadBalancerID)
        try await req.db.transaction { db in
            try await listener.delete(on: db)
            try await Self.markPendingAndBump(loadBalancerID, on: db)
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Backends

    @Sendable
    func listBackends(req: Request) async throws -> [LoadBalancerBackendResponse] {
        let loadBalancer = try await find(req, action: "loadbalancer:read")
        return try await backendResponses(loadBalancerID: loadBalancer.requireID(), on: req.db)
    }

    @Sendable
    func createBackend(req: Request) async throws -> LoadBalancerBackendResponse {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let request = try req.content.decode(CreateLoadBalancerBackendRequest.self)
        let loadBalancerID = try loadBalancer.requireID()
        let target = try await resolveBackend(request, for: loadBalancer, on: req)
        let backend = LoadBalancerBackend(
            loadBalancerID: loadBalancerID,
            interfaceID: target.interface?.id,
            address: target.address)
        do {
            try await req.db.transaction { db in
                try await backend.save(on: db)
                try await Self.markPendingAndBump(loadBalancerID, on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "This backend is already attached to the load balancer")
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return try LoadBalancerBackendResponse(from: backend, interface: target.interface)
    }

    @Sendable
    func deleteBackend(req: Request) async throws -> HTTPStatus {
        let loadBalancer = try await find(req, action: "loadbalancer:update")
        let loadBalancerID = try loadBalancer.requireID()
        guard let backendID = req.parameters.get("backendId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid backend ID")
        }
        guard
            let backend = try await LoadBalancerBackend.query(on: req.db)
                .filter(\.$id == backendID)
                .filter(\.$loadBalancer.$id == loadBalancerID)
                .first()
        else { throw Abort(.notFound, reason: "Backend not found on this load balancer") }
        try await req.db.transaction { db in
            try await backend.delete(on: db)
            try await Self.markPendingAndBump(loadBalancerID, on: db)
        }
        await req.application.agentService.syncDesiredStateToFleet()
        return .noContent
    }

    // MARK: - Helpers

    private func find(_ req: Request, action: String) async throws -> LoadBalancer {
        guard let id = req.parameters.get("loadBalancerId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid load balancer ID")
        }
        return try await req.authorizedLoadBalancer(id, action: action)
    }

    private func findListener(_ req: Request, loadBalancerID: UUID) async throws -> LoadBalancerListener {
        guard let listenerID = req.parameters.get("listenerId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid listener ID")
        }
        guard
            let listener = try await LoadBalancerListener.query(on: req.db)
                .filter(\.$id == listenerID)
                .filter(\.$loadBalancer.$id == loadBalancerID)
                .first()
        else { throw Abort(.notFound, reason: "Listener not found on this load balancer") }
        return listener
    }

    private struct ResolvedBackend {
        let interface: VMNetworkInterface?
        let address: String?
    }

    private func resolveBackend(
        _ request: CreateLoadBalancerBackendRequest,
        for loadBalancer: LoadBalancer,
        on req: Request
    ) async throws -> ResolvedBackend {
        let namesVM = request.vmId != nil || request.nicIndex != nil
        if namesVM == (request.ipAddress != nil) {
            throw Abort(.badRequest, reason: "Specify either vmId with nicIndex, or ipAddress")
        }
        if let address = request.ipAddress {
            guard let parsed = IPAMService.parseIPv4(address) else {
                throw Abort(.badRequest, reason: "Backend IP address is not valid IPv4")
            }
            return ResolvedBackend(interface: nil, address: IPAMService.formatIPv4(parsed))
        }
        guard let vmID = request.vmId, let nicIndex = request.nicIndex, nicIndex >= 0 else {
            throw Abort(.badRequest, reason: "vmId and a non-negative nicIndex are required together")
        }
        let vm = try await req.reachableVM(vmID, action: "vm:update")
        try ProjectContainment.require(
            "VM", in: vm.$project.id,
            sameProjectAs: "the load balancer", in: loadBalancer.$project.id)
        guard
            let interface = try await VMNetworkInterface.query(on: req.db)
                .filter(\.$vm.$id == vmID)
                .filter(\.$orderIndex == nicIndex)
                .with(\.$addresses)
                .first()
        else { throw Abort(.notFound, reason: "VM interface at nicIndex \(nicIndex) not found") }
        guard interface.ipv4Address != nil else {
            throw Abort(.conflict, reason: "Backend interface has no IPv4 address")
        }
        guard
            let loadBalancerNetwork = try await LogicalNetwork.find(
                loadBalancer.$logicalNetwork.id, on: req.db),
            let backendNetwork = try await LogicalNetwork.find(
                interface.$logicalNetwork.id, on: req.db)
        else {
            throw Abort(.conflict, reason: "Load balancer or backend network no longer exists")
        }
        guard loadBalancerNetwork.$site.id == backendNetwork.$site.id else {
            throw Abort(
                .conflict,
                reason:
                    "Backend interface network '\(backendNetwork.name)' is pinned to a different site than load balancer network '\(loadBalancerNetwork.name)'"
            )
        }
        return ResolvedBackend(interface: interface, address: nil)
    }

    private func response(for loadBalancer: LoadBalancer, on db: Database) async throws -> LoadBalancerResponse {
        if loadBalancer.$logicalNetwork.value == nil {
            try await loadBalancer.$logicalNetwork.load(on: db)
        }
        let listeners = try await LoadBalancerListener.query(on: db)
            .filter(\.$loadBalancer.$id == loadBalancer.requireID())
            .sort(\.$port)
            .all()
        let backends = try await loadedBackends(loadBalancerID: loadBalancer.requireID(), on: db)
        return try LoadBalancerResponse(from: loadBalancer, listeners: listeners, backends: backends)
    }

    private func backendResponses(loadBalancerID: UUID, on db: Database) async throws
        -> [LoadBalancerBackendResponse]
    {
        try await loadedBackends(loadBalancerID: loadBalancerID, on: db).map {
            try LoadBalancerBackendResponse(from: $0.0, interface: $0.1)
        }
    }

    private func loadedBackends(loadBalancerID: UUID, on db: Database) async throws
        -> [(LoadBalancerBackend, VMNetworkInterface?)]
    {
        let backends = try await LoadBalancerBackend.query(on: db)
            .filter(\.$loadBalancer.$id == loadBalancerID)
            .sort(\.$createdAt)
            .sort(\.$id)
            .all()
        var result: [(LoadBalancerBackend, VMNetworkInterface?)] = []
        for backend in backends {
            let interface: VMNetworkInterface?
            if let interfaceID = backend.$interface.id {
                interface = try await VMNetworkInterface.query(on: db)
                    .filter(\.$id == interfaceID)
                    .with(\.$addresses)
                    .first()
            } else {
                interface = nil
            }
            result.append((backend, interface))
        }
        return result
    }

    private static func validatePort(_ port: Int, name: String) throws {
        guard (1...65_535).contains(port) else {
            throw Abort(.badRequest, reason: "\(name) port must be 1-65535")
        }
    }

    private static func locked(_ id: UUID, on db: Database) async throws -> LoadBalancer {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Load balancer updates require an SQL database")
        }
        _ = try await sql.raw("SELECT id FROM load_balancers WHERE id = \(bind: id) FOR UPDATE").all()
        guard let row = try await LoadBalancer.find(id, on: db) else {
            throw Abort(.notFound, reason: "Load balancer no longer exists")
        }
        return row
    }

    private static func markPendingAndBump(_ id: UUID, on db: Database) async throws {
        let row = try await locked(id, on: db)
        row.observedState = .pending
        row.lastError = nil
        try await row.save(on: db)
        try await bumpGeneration(of: id, on: db)
    }

    private static func bumpGeneration(of id: UUID, on db: Database) async throws {
        try await DesiredStateGenerationWriter.advanceOrThrow(
            schema: LoadBalancer.schema, id: id, resource: "Load balancer", on: db)
    }
}
