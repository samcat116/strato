import AppTestSupport
import Fluent
import SQLKit
import StratoShared
import Testing
import Vapor

@testable import App

/// Hold admission until PostgreSQL observes both handlers waiting. Releasing
/// the transaction then exercises their authoritative reads after a commit.
@Suite("Overlap admission races", .serialized, .postgresFixture)
struct OverlapAdmissionRaceTests {
    enum Pair: String, CaseIterable, Sendable {
        case createCreate, createUpdate, updateUpdate
    }

    private func withFixture(
        _ body: (Application, User, Organization, Project, Site) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting(maxConnectionsPerEventLoop: 8)
        do {
            try await configure(app)
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(isSystemAdmin: true)
            let org = try await builder.createOrganization()
            user.currentOrganizationId = try org.requireID()
            try await user.save(on: app.db)
            let project = try await builder.createProject(name: "admission", description: "race", organization: org)
            let site = Site(name: "admission", organizationScope: .organization(try org.requireID()))
            try await site.save(on: app.db)
            try await body(app, user, org, project, site)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func request<Body: Content>(
        app: Application, user: User, body: Body, parameter: (String, UUID)? = nil
    ) throws -> Request {
        let req = Request(application: app, on: app.eventLoopGroup.any())
        req.auth.login(user)
        if let (name, id) = parameter { req.parameters.set(name, to: id.uuidString) }
        try req.content.encode(body)
        return req
    }

    private func status(_ operation: @Sendable () async throws -> Void) async throws -> HTTPStatus {
        do {
            try await operation()
            return .ok
        } catch let error as Abort {
            return error.status
        }
    }

    private func waitForWaiters(_ count: Int, key: AdvisoryLockKey, on db: any Database) async throws -> Bool {
        let sql = try #require(db as? any SQLDatabase)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            let waiting = try await sql.raw(
                """
                SELECT count(*)::int AS waiting FROM pg_locks
                WHERE locktype = 'advisory' AND NOT granted AND objsubid = 2
                  AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
                  AND classid::bigint = \(bind: Int64(key.namespace.rawValue))
                  AND objid::bigint = \(bind: Int64(UInt32(bitPattern: key.objectDigest)))
                """
            ).first(decodingColumn: "waiting", as: Int.self)
            if waiting == count { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func race(
        app: Application, key: AdvisoryLockKey,
        first: @escaping @Sendable () async throws -> HTTPStatus,
        second: @escaping @Sendable () async throws -> HTTPStatus,
        whileHeld: (@Sendable () async throws -> Void)? = nil
    ) async throws -> [HTTPStatus] {
        let (tasks, reachedAdmission) = try await app.db.transaction { held in
            try await AdvisoryLock.acquireTransactionLock(key, on: held)
            let tasks = [Task { try await first() }, Task { try await second() }]
            let reached = try await waitForWaiters(2, key: key, on: app.db)
            if let whileHeld { try await whileHeld() }
            return (tasks, reached)
        }
        // Await completion even if the waiter observation failed, so no task
        // can escape the fixture lifetime. No arbitrary release delay is used.
        let completed = await [tasks[0].result, tasks[1].result]
        #expect(reachedAdmission, "Both handlers must reach the shared admission lock before release")
        return try completed.map { try $0.get() }
    }

    @Test(
        "Subnet admission serializes create/create, create/update and update/update",
        arguments: Pair.allCases, [(false, false), (false, true), (true, false), (true, true)])
    func subnetRaces(pair: Pair, configuration: (Bool, Bool)) async throws {
        let (ipv6, conflicting) = configuration
        try await withFixture { app, user, _, project, site in
            let projectID = try project.requireID()
            let siteID = try site.requireID()
            @Sendable func operation(index: Int, update: Bool) async throws -> HTTPStatus {
                let subnet = "10.\(conflicting && !ipv6 ? 42 : 42 + index).0.0/24"
                let subnet6 = ipv6 ? "fd42:\(conflicting ? 1 : index + 1)::/64" : nil
                if update {
                    let network = try await TestDataBuilder(db: app.db).createNetwork(
                        name: "existing-\(index)", project: project, subnet: "10.\(90 + index).0.0/24",
                        gateway: "10.\(90 + index).0.1", site: site)
                    network.resolverEnabled = false
                    try await network.save(on: app.db)
                    let req = try request(
                        app: app, user: user,
                        body: UpdateNetworkRequest(
                            subnet: subnet, gateway: subnet.replacingOccurrences(of: "0.0/24", with: "0.1"),
                            subnet6: subnet6, ipv6Enabled: ipv6),
                        parameter: ("networkId", try network.requireID()))
                    return try await status { _ = try await NetworkController().updateNetwork(req: req) }
                }
                let req = try request(
                    app: app, user: user,
                    body: CreateNetworkRequest(
                        name: "created-\(index)", subnet: subnet, subnet6: subnet6,
                        ipv6Enabled: ipv6, projectId: projectID, resolverEnabled: false, siteId: siteID))
                return try await status { _ = try await NetworkController().createNetwork(req: req) }
            }
            let results = try await race(
                app: app, key: .object(.projectNetwork, id: projectID),
                first: { try await operation(index: 0, update: pair == .updateUpdate) },
                second: { try await operation(index: 1, update: pair != .createCreate) })
            #expect(results.filter { $0 == .ok }.count == (conflicting ? 1 : 2))
            #expect(results.filter { $0 == .conflict }.count == (conflicting ? 1 : 0))
            let networks = try await LogicalNetwork.query(on: app.db).filter(\.$project.$id == projectID).all()
            for (index, network) in networks.enumerated() {
                for other in networks.dropFirst(index + 1) {
                    #expect(!NetworkController.subnetsOverlap(network.subnet, other.subnet))
                    if let a = network.subnet6, let b = other.subnet6 {
                        #expect(!NetworkController.subnetsOverlap(a, b))
                    }
                }
            }
        }
    }

    @Test("Site pool admission serializes all create and update pairs", arguments: Pair.allCases, [false, true])
    func poolRaces(pair: Pair, conflicting: Bool) async throws {
        try await withFixture { app, user, org, _, site in
            let siteID = try site.requireID()
            let orgID = try org.requireID()
            @Sendable func operation(index: Int, update: Bool) async throws -> HTTPStatus {
                let cidr = "198.\(conflicting ? 18 : 18 + index).0.0/24"
                if update {
                    let source = Site(name: "source-\(index)", organizationScope: .organization(orgID))
                    try await source.save(on: app.db)
                    let pool = FloatingIPPool(
                        name: "moving-\(index)", cidr: cidr, siteID: try source.requireID(),
                        organizationScope: .organization(orgID))
                    try await pool.save(on: app.db)
                    let req = try request(
                        app: app, user: user, body: UpdateFloatingIPPoolRequest(gateway: nil, siteId: siteID),
                        parameter: ("poolId", try pool.requireID()))
                    return try await status { _ = try await FloatingIPController().updatePool(req: req) }
                }
                let req = try request(
                    app: app, user: user,
                    body: CreateFloatingIPPoolRequest(
                        name: "pool-\(index)", cidr: cidr, gateway: nil,
                        siteId: siteID, organizationId: orgID, organizationalUnitId: nil))
                return try await status { _ = try await FloatingIPController().createPool(req: req) }
            }
            let results = try await race(
                app: app, key: .object(.floatingIPSiteAdmission, id: siteID),
                first: { try await operation(index: 0, update: pair == .updateUpdate) },
                second: { try await operation(index: 1, update: pair != .createCreate) })
            #expect(results.filter { $0 == .ok }.count == (conflicting ? 1 : 2))
            #expect(results.filter { $0 == .conflict }.count == (conflicting ? 1 : 0))
            let pools = try await FloatingIPPool.query(on: app.db).filter(\.$site.$id == siteID).all()
            #expect(pools.count == (conflicting ? 1 : 2))
        }
    }

    @Test("Load balancer deletion takes admission before row locks held by network updates")
    func loadBalancerDeletionAndNetworkUpdate() async throws {
        try await withFixture { app, user, _, project, site in
            let projectID = try project.requireID()
            let network = try await TestDataBuilder(db: app.db).createNetwork(
                name: "load-balancer-network", project: project, subnet: "10.42.0.0/24", gateway: "10.42.0.1",
                site: site)
            network.resolverEnabled = false
            try await network.save(on: app.db)
            let networkID = try network.requireID()
            let initialGeneration = network.generation
            let loadBalancer = LoadBalancer(
                name: "deleting", projectID: projectID, logicalNetworkID: networkID,
                vip: "10.42.0.10", protocolName: .tcp)
            try await loadBalancer.save(on: app.db)
            let loadBalancerID = try loadBalancer.requireID()
            let updateRequest = try request(
                app: app, user: user, body: UpdateNetworkRequest(metadataEnabled: false),
                parameter: ("networkId", networkID))
            let deleteRequest = try request(
                app: app, user: user, body: UpdateNetworkRequest(),
                parameter: ("loadBalancerId", loadBalancerID))
            let key = AdvisoryLockKey.object(.projectNetwork, id: projectID)
            let (tasks, observed) = try await app.db.transaction { held in
                try await AdvisoryLock.acquireTransactionLock(key, on: held)
                let update = Task {
                    try await status { _ = try await NetworkController().updateNetwork(req: updateRequest) }
                }
                // Queue the network update first. Before the fix, deletion then
                // held the network row while waiting behind it for admission:
                // releasing admission forced a project/row deadlock cycle.
                let firstWaiting = try await waitForWaiters(1, key: key, on: app.db)
                let delete = Task { try await LoadBalancerController().delete(req: deleteRequest) }
                let bothWaiting = try await waitForWaiters(2, key: key, on: app.db)
                return ([update, delete], firstWaiting && bothWaiting)
            }
            let completed = await [tasks[0].result, tasks[1].result]
            #expect(observed, "Update must wait for admission before deletion enters the queue")
            let results = try completed.map { try $0.get() }
            #expect(results == [.ok, .noContent])
            let current = try #require(try await LogicalNetwork.find(networkID, on: app.db))
            #expect(!current.metadataEnabled)
            #expect(current.generation == initialGeneration + 2)
            #expect(try await LoadBalancer.find(loadBalancerID, on: app.db) == nil)
        }
    }

    @Test("Independent projects and sites proceed while admission is held", arguments: [false, true])
    func independentScopes(pools: Bool) async throws {
        try await withFixture { app, user, org, project, site in
            let orgID = try org.requireID()
            let otherSite = Site(name: "other", organizationScope: .organization(orgID))
            try await otherSite.save(on: app.db)
            let otherProject = try await TestDataBuilder(db: app.db).createProject(
                name: "other", description: "other", organization: org)
            let blockedID = pools ? try site.requireID() : try project.requireID()
            let key = AdvisoryLockKey.object(pools ? .floatingIPSiteAdmission : .projectNetwork, id: blockedID)
            @Sendable func create(index: Int, independent: Bool) async throws -> HTTPStatus {
                if pools {
                    let req = try request(
                        app: app, user: user,
                        body: CreateFloatingIPPoolRequest(
                            name: "pool-\(index)", cidr: "198.18.\(index).0/24", gateway: nil,
                            siteId: independent ? otherSite.requireID() : site.requireID(), organizationId: orgID,
                            organizationalUnitId: nil))
                    return try await status { _ = try await FloatingIPController().createPool(req: req) }
                }
                let req = try request(
                    app: app, user: user,
                    body: CreateNetworkRequest(
                        name: "network-\(index)", subnet: "10.42.\(index).0/24", ipv6Enabled: false,
                        projectId: independent ? otherProject.requireID() : project.requireID(), resolverEnabled: false,
                        siteId: site.requireID()))
                return try await status { _ = try await NetworkController().createNetwork(req: req) }
            }
            let results = try await race(
                app: app, key: key,
                first: { try await create(index: 0, independent: false) },
                second: { try await create(index: 1, independent: false) },
                whileHeld: {
                    #expect(try await create(index: 2, independent: true) == .ok)
                    if pools {
                        // Even identical UUID digests cannot alias allocation.
                        try await app.db.transaction { db in
                            try await AdvisoryLock.acquireTransactionLock(
                                .object(.floatingIPPool, id: blockedID), on: db)
                        }
                    }
                })
            #expect(results == [.ok, .ok])
        }
    }
}
