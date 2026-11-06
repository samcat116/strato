import Fluent
import SQLKit
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

@Suite("Load Balancer Observations", .serialized, .postgresFixture)
struct LoadBalancerObservationTests {
    private struct Fixture: Sendable {
        let controller: Agent
        let worker: Agent
        let remoteController: Agent
        let site: Site
        let loadBalancer: LoadBalancer
        let backend: LoadBalancerBackend
        let otherBackend: LoadBalancerBackend
    }

    private func withFixture(
        _ test: (Application, Fixture) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "LB observation org")
            let project = try await builder.createProject(
                name: "LB observation project", description: "observations", organization: organization)
            let site = Site(name: "lb-site", organizationScope: .organization(try organization.requireID()))
            let remoteSite = Site(name: "remote-site", organizationScope: .organization(try organization.requireID()))
            try await site.save(on: app.db)
            try await remoteSite.save(on: app.db)
            let controller = try await builder.createAgent(named: "controller", siteID: site.requireID())
            let worker = try await builder.createAgent(named: "worker", siteID: site.requireID())
            let remoteController = try await builder.createAgent(named: "remote", siteID: remoteSite.requireID())
            site.$networkControllerAgent.id = try controller.requireID()
            remoteSite.$networkControllerAgent.id = try remoteController.requireID()
            try await site.save(on: app.db)
            try await remoteSite.save(on: app.db)
            let network = LogicalNetwork(
                name: "lb-network", subnet: "10.10.0.0/24", gateway: "10.10.0.1",
                projectID: try project.requireID(), siteID: try site.requireID())
            try await network.save(on: app.db)
            let loadBalancer = LoadBalancer(
                name: "api", projectID: try project.requireID(), logicalNetworkID: try network.requireID(),
                vip: "10.10.0.10", protocolName: .tcp)
            let other = LoadBalancer(
                name: "other", projectID: try project.requireID(), logicalNetworkID: try network.requireID(),
                vip: "10.10.0.11", protocolName: .tcp)
            try await loadBalancer.save(on: app.db)
            try await other.save(on: app.db)
            let backend = LoadBalancerBackend(loadBalancerID: try loadBalancer.requireID(), address: "10.10.0.20")
            let otherBackend = LoadBalancerBackend(loadBalancerID: try other.requireID(), address: "10.10.0.21")
            try await backend.save(on: app.db)
            try await otherBackend.save(on: app.db)
            try await test(
                app,
                Fixture(
                    controller: controller, worker: worker, remoteController: remoteController,
                    site: site, loadBalancer: loadBalancer, backend: backend, otherBackend: otherBackend))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func observation(
        _ fixture: Fixture, generation: Int64 = 1, status: ObservedLoadBalancerStatus = .active
    ) throws -> ObservedLoadBalancerState {
        ObservedLoadBalancerState(
            id: try fixture.loadBalancer.requireID(), observedGeneration: generation, status: status,
            lastError: status == .error ? "reported failure" : nil,
            backends: [
                ObservedLoadBalancerBackend(
                    id: try fixture.backend.requireID(), healthStatus: .offline,
                    lastCheckedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                // An authorized LB report still cannot change another LB's backend.
                ObservedLoadBalancerBackend(id: try fixture.otherBackend.requireID(), healthStatus: .online),
                ObservedLoadBalancerBackend(id: UUID(), healthStatus: .error),
            ])
    }

    @Test(
        "Only the designated controller can report its load balancers",
        arguments: ["worker", "remote", "missing", "invalid"])
    func rejectsUnauthorizedReporter(_ reporter: String) async throws {
        try await withFixture { app, fixture in
            let agentID =
                switch reporter {
                case "worker": try fixture.worker.requireID().uuidString
                case "remote": try fixture.remoteController.requireID().uuidString
                case "missing": UUID().uuidString
                default: "not-an-agent-id"
                }
            for status: ObservedLoadBalancerStatus in [.active, .error] {
                try await ObservedStateApplier(app: app).applyObservedLoadBalancers(
                    [observation(fixture, status: status)], reportedBy: agentID, on: app.db)
            }
            let row = try #require(try await LoadBalancer.find(fixture.loadBalancer.requireID(), on: app.db))
            #expect(row.observedGeneration == 0)
            #expect(row.observedState == .pending)
            #expect(row.lastError == nil)
            let backend = try #require(try await LoadBalancerBackend.find(fixture.backend.requireID(), on: app.db))
            #expect(backend.healthStatus == .unknown)
            #expect(backend.lastHealthCheckAt == nil)
        }
    }

    @Test("A demoted controller's stale report cannot change convergence or health")
    func rejectsDemotedController() async throws {
        try await withFixture { app, fixture in
            fixture.site.$networkControllerAgent.id = try fixture.worker.requireID()
            try await fixture.site.save(on: app.db)
            try await ObservedStateApplier(app: app).applyObservedLoadBalancers(
                [observation(fixture, status: .error)], reportedBy: fixture.controller.requireID().uuidString,
                on: app.db)
            let row = try #require(try await LoadBalancer.find(fixture.loadBalancer.requireID(), on: app.db))
            #expect(row.observedGeneration == 0)
            #expect(row.observedState == .pending)
            #expect(row.lastError == nil)
            let backend = try #require(try await LoadBalancerBackend.find(fixture.backend.requireID(), on: app.db))
            #expect(backend.healthStatus == .unknown)
        }
    }

    @Test("The full report routes controller identity and updates only the matching backend")
    func appliesAuthorizedReport() async throws {
        try await withFixture { app, fixture in
            let report = ObservedStateReport(
                agentId: try fixture.controller.requireID().uuidString, vms: [],
                resources: fixture.controller.resources, loadBalancers: [try observation(fixture)])
            try await ObservedStateApplier(app: app).apply(report, at: ClusterClock.read(on: app.db))
            let row = try #require(try await LoadBalancer.find(fixture.loadBalancer.requireID(), on: app.db))
            #expect(row.observedGeneration == 1)
            #expect(row.observedState == .active)
            #expect(row.lastError == nil)
            let backend = try #require(try await LoadBalancerBackend.find(fixture.backend.requireID(), on: app.db))
            #expect(backend.healthStatus == .offline)
            #expect(backend.lastHealthCheckAt == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(backend.address == "10.10.0.20")
            let other = try #require(try await LoadBalancerBackend.find(fixture.otherBackend.requireID(), on: app.db))
            #expect(other.healthStatus == .unknown)
            #expect(other.lastHealthCheckAt == nil)
        }
    }

    @Test(
        "Generation guards reject older and future observations without changing health",
        arguments: [Int64(0), Int64(2)])
    func rejectsInvalidGeneration(_ generation: Int64) async throws {
        try await withFixture { app, fixture in
            fixture.loadBalancer.observedGeneration = 1
            fixture.loadBalancer.observedState = .active
            try await fixture.loadBalancer.save(on: app.db)
            try await ObservedStateApplier(app: app).applyObservedLoadBalancers(
                [observation(fixture, generation: generation, status: .error)],
                reportedBy: fixture.controller.requireID().uuidString, on: app.db)
            let row = try #require(try await LoadBalancer.find(fixture.loadBalancer.requireID(), on: app.db))
            #expect(row.generation == 1)
            #expect(row.observedGeneration == 1)
            #expect(row.observedState == .active)
            #expect(row.lastError == nil)
            let backend = try #require(try await LoadBalancerBackend.find(fixture.backend.requireID(), on: app.db))
            #expect(backend.healthStatus == .unknown)
        }
    }

    @Test(
        "A queued report rechecks desired state, convergence and authority after waiting",
        arguments: ["mutation", "demotion", "newer-observation"])
    func preservesConcurrentMutation(_ change: String) async throws {
        try await withFixture { app, fixture in
            let database = try #require(app.storage[TestDatabaseNameKey.self])
            let observer = try await Application.makeForTesting(database: database, owningDatabase: false)
            let pending = PendingObservation()
            do {
                let observerSQL = try #require(observer.db as? any SQLDatabase)
                let id = try fixture.loadBalancer.requireID()
                let report = try observation(fixture)
                let controllerID = try fixture.controller.requireID().uuidString
                try await observer.db.transaction { db in
                    let row = try #require(try await LoadBalancer.lockAndFetch(id, on: db))
                    // Same persistence path as the update endpoint: save intent, then advance
                    // generation in SQL while retaining the parent row lock.
                    row.name = "updated-api"
                    row.protocolName = .udp
                    row.healthCheck = LoadBalancerHealthCheckConfig(
                        enabled: true, intervalSeconds: 12, timeoutSeconds: 4,
                        successThreshold: 2, failureThreshold: 5)
                    if change == "newer-observation" {
                        row.observedGeneration = 2
                        row.observedState = .active
                    }
                    try await row.save(on: db)
                    try await DesiredStateGenerationWriter.advanceOrThrow(
                        schema: LoadBalancer.schema, id: id, resource: "Load balancer", on: db)
                    let task = Task {
                        try await ObservedStateApplier(app: app).applyObservedLoadBalancers(
                            [report], reportedBy: controllerID, on: app.db)
                    }
                    await pending.store(task)
                    try await waitForBlockedWriter(table: "load_balancers", on: observerSQL)
                    if change == "demotion" {
                        fixture.site.$networkControllerAgent.id = try fixture.worker.requireID()
                        try await fixture.site.save(on: observer.db)
                    }
                }
                try await pending.finish()
                let row = try #require(try await LoadBalancer.find(id, on: app.db))
                #expect(row.name == "updated-api")
                #expect(row.protocolName == .udp)
                #expect(row.healthCheck.enabled)
                #expect(row.healthCheck.intervalSeconds == 12)
                #expect(row.healthCheck.timeoutSeconds == 4)
                #expect(row.healthCheck.successThreshold == 2)
                #expect(row.healthCheck.failureThreshold == 5)
                #expect(row.generation == 2)
                let expectedObserved: Int64 =
                    switch change {
                    case "newer-observation": 2
                    case "demotion": 0
                    default: 1
                    }
                #expect(row.observedGeneration == expectedObserved)
                let backend = try #require(try await LoadBalancerBackend.find(fixture.backend.requireID(), on: app.db))
                #expect(backend.healthStatus == (change == "mutation" ? .offline : .unknown))
            } catch {
                // The transaction has unwound before awaiting the worker, so a
                // failed assertion cannot strand a task on our own row lock.
                await pending.cancelAndDrain()
                try await observer.shutdownForTesting()
                throw error
            }
            try await observer.shutdownForTesting()
        }
    }

    @Test("Backend health writes preserve a racing edit or deletion", arguments: [false, true])
    func preservesConcurrentBackendMutation(delete: Bool) async throws {
        try await withFixture { app, fixture in
            let database = try #require(app.storage[TestDatabaseNameKey.self])
            let observer = try await Application.makeForTesting(database: database, owningDatabase: false)
            let pending = PendingObservation()
            do {
                let observerSQL = try #require(observer.db as? any SQLDatabase)
                let backendID = try fixture.backend.requireID()
                let report = try observation(fixture)
                let controllerID = try fixture.controller.requireID().uuidString
                try await observer.db.transaction { db in
                    let sql = try #require(db as? any SQLDatabase)
                    // Stand in for a backend-owning writer independent of the
                    // LB API. The report may not save a stale address or insert
                    // a backend again after this transaction deletes it.
                    if delete {
                        try await sql.raw(
                            "DELETE FROM load_balancer_backends WHERE id = \(bind: backendID)"
                        ).run()
                    } else {
                        try await sql.raw(
                            "UPDATE load_balancer_backends SET address = '10.10.0.99' WHERE id = \(bind: backendID)"
                        ).run()
                    }
                    let task = Task {
                        try await ObservedStateApplier(app: app).applyObservedLoadBalancers(
                            [report], reportedBy: controllerID, on: app.db)
                    }
                    await pending.store(task)
                    try await waitForBlockedWriter(table: "load_balancer_backends", on: observerSQL)
                }
                try await pending.finish()
                let backend = try await LoadBalancerBackend.find(backendID, on: app.db)
                if delete {
                    #expect(backend == nil)
                } else {
                    let backend = try #require(backend)
                    #expect(backend.address == "10.10.0.99")
                    #expect(backend.healthStatus == .offline)
                    #expect(backend.lastHealthCheckAt == Date(timeIntervalSince1970: 1_700_000_000))
                }
            } catch {
                await pending.cancelAndDrain()
                try await observer.shutdownForTesting()
                throw error
            }
            try await observer.shutdownForTesting()
        }
    }

    private func waitForBlockedWriter(table: String, on sql: any SQLDatabase) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while true {
            let waiting =
                try await sql.raw(
                    """
                    SELECT COUNT(*)::int AS count FROM pg_stat_activity
                    WHERE datname = current_database() AND wait_event_type = 'Lock'
                      AND query ILIKE \(bind: "%\(table)%")
                    """
                ).first(decodingColumn: "count", as: Int.self) ?? 0
            if waiting > 0 { return }
            guard ContinuousClock.now < deadline else {
                throw Abort(.internalServerError, reason: "Observation did not reach the \(table) row lock")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}

private actor PendingObservation {
    private var task: Task<Void, any Error>?
    func store(_ task: Task<Void, any Error>) { self.task = task }
    func finish() async throws { try await task?.value }
    func cancelAndDrain() async {
        task?.cancel()
        _ = await task?.result
    }
}
