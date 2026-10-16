import AppTestSupport
import Fluent
import FluentPostgresDriver
import NIOPosix
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("VM placement retry", .serialized, .postgresFixture)
struct VMPlacementRetryTests {
    private func failedVM(
        _ app: Application, _ builder: TestDataBuilder, _ fixture: ProjectFixture
    ) async throws -> (VM, Volume, VMNetworkInterface) {
        let image = try await builder.createImage(
            name: "retry-image", project: fixture.project, uploadedBy: fixture.user)
        let vm = try await builder.createVM(name: "retry-vm", project: fixture.project)
        vm.$sourceImage.id = try image.requireID()
        vm.generation = 1
        vm.failedGeneration = 1
        vm.lastError = "placement failed"
        vm.setStatus(.error)
        try await vm.save(on: app.db)
        let boot = try await attachBootVolume(to: vm, on: nil, using: app.db)
        boot.observedGeneration = 0
        try await boot.save(on: app.db)
        let network = try await builder.createNetwork(name: "retry-net", project: fixture.project)
        let nic = try await builder.attachNIC(to: vm, network: network, macAddress: "02:00:00:00:00:59")
        return (vm, boot, nic)
    }

    private func agent(_ app: Application, _ builder: TestDataBuilder) async throws -> String {
        let id = try await builder.registerAgent(on: app, named: "retry-agent", operatingSystem: .linux)
        let row = try #require(try await Agent.find(UUID(uuidString: id), on: app.db))
        let site = try await row.$site.get(on: app.db)
        site.$networkControllerAgent.id = try row.requireID()
        try await site.save(on: app.db)
        return id
    }

    private func retry(
        _ app: Application, vmID: UUID, token: String, key: String? = nil
    ) async throws -> (HTTPStatus, AcceptedMutation<VMDetailResponse>?) {
        var status = HTTPStatus.internalServerError
        var accepted: AcceptedMutation<VMDetailResponse>?
        try await app.test(.POST, "/api/vms/\(vmID)/retry-placement") { request in
            request.headers.bearerAuthorization = BearerAuthorization(token: token)
            if let key { request.headers.replaceOrAdd(name: "Idempotency-Key", value: key) }
        } afterResponse: { response in
            status = response.status
            if status == .accepted { accepted = try response.content.decode(AcceptedMutation<VMDetailResponse>.self) }
        }
        return (status, accepted)
    }

    @Test("Retry and replay reuse the existing VM, boot disk, NIC and reservation")
    func retryReusesResources() async throws {
        try await withProjectApp(prefix: "placementretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, nic) = try await failedVM(app, builder, fixture)
            let host = try await agent(app, builder)
            let id = try vm.requireID()
            let key = UUID().uuidString
            let (status, first) = try await retry(app, vmID: id, token: fixture.token, key: key)
            #expect(status == .accepted)
            let accepted = try #require(first)
            #expect(accepted.targetGeneration == 2)
            #expect(accepted.resource.conditions.degraded?.sinceGeneration != accepted.targetGeneration)
            let placed: VM = try await pollUntil {
                guard let row = try await VM.find(id, on: app.db), row.hypervisorId != nil else { return nil }
                return row
            }
            #expect(placed.hypervisorId == host)
            #expect(placed.desiredStatus == .shutdown)
            let (replayStatus, replay) = try await retry(app, vmID: id, token: fixture.token, key: key)
            #expect(replayStatus == .accepted)
            #expect(replay?.mutationId == accepted.mutationId)
            #expect(replay?.targetGeneration == accepted.targetGeneration)
            #expect(try await VM.query(on: app.db).count() == 1)
            let boots = try await Volume.query(on: app.db).filter(\.$vm.$id == id).all()
            #expect(boots.map(\.id) == [boot.id])
            #expect(boots.first?.attachedAgentId == host)
            let interfaces = try await VMNetworkInterface.query(on: app.db).filter(\.$vm.$id == id).all()
            #expect(interfaces.map(\.id) == [nic.id])
            #expect(try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count() == 1)
            #expect(try await ResourceEvent.query(on: app.db).filter(\.$resourceID == id).count() == 1)
            let reserved = await app.coordination.activeReservations(agentIds: [host])
            #expect(reserved[host]?.cpuMicroUnits == Int64(vm.cpu) * 1_000_000)
        }
    }

    @Test("Concurrent retries record and dispatch one attempt", arguments: [false, true])
    func concurrentRetries(sameKey: Bool) async throws {
        try await withProjectApp(prefix: "concurrentretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            _ = try await agent(app, builder)
            let id = try vm.requireID()
            let key = UUID().uuidString
            // Hold placement until both HTTP acceptances have resolved. This
            // tests racing delivery, independent of scheduler timing.
            try await AdvisoryLock.withSessionLock(
                .object(.vmPlacement, id: id), on: app.db, timeout: .seconds(3),
                pollInterval: .milliseconds(10), logger: app.logger
            ) { _ in
                async let a = retry(app, vmID: id, token: fixture.token, key: sameKey ? key : nil)
                async let b = retry(app, vmID: id, token: fixture.token, key: sameKey ? key : nil)
                let (first, second) = try await (a, b)
                if sameKey {
                    #expect(first.0 == .accepted && second.0 == .accepted)
                    #expect(first.1?.mutationId == second.1?.mutationId)
                } else {
                    #expect([first.0, second.0].filter { $0 == .accepted }.count == 1)
                    #expect([first.0, second.0].filter { $0 == .conflict }.count == 1)
                }
            }
            let _: String = try await pollUntil { try await VM.find(id, on: app.db)?.hypervisorId }
            #expect(try await VM.find(id, on: app.db)?.generation == 2)
            #expect(try await ResourceEvent.query(on: app.db).filter(\.$resourceID == id).count() == 1)
            #expect(try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count() == 1)
        }
    }

    @Test(
        "Retry refuses ambiguous or ineligible state without recording an attempt",
        arguments: ["placed", "pending", "missing-boot", "replica", "terminating"])
    func refusesUnsafeState(state: String) async throws {
        try await withProjectApp(prefix: "invalidretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            switch state {
            case "placed": vm.hypervisorId = UUID().uuidString
            case "pending": vm.failedGeneration = nil
            case "missing-boot": try await boot.delete(on: app.db)
            case "replica":
                try await placeVolume(boot, on: UUID().uuidString, using: app.db)
            default: vm.setFixtureDesiredStatus(.absent)
            }
            try await vm.save(on: app.db)
            let id = try vm.requireID()
            let before = vm.generation
            let response = try await retry(app, vmID: id, token: fixture.token)
            #expect(response.0 == .conflict)
            #expect(try await VM.find(id, on: app.db)?.generation == before)
            #expect(try await ResourceEvent.query(on: app.db).filter(\.$resourceID == id).count() == 0)
        }
    }

    @Test("Read-only credentials cannot trigger placement")
    func readOnlyRefused() async throws {
        try await withProjectApp(prefix: "readonlyretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, _, _) = try await failedVM(app, builder, fixture)
            let key = try await fixture.user.generateAPIKey(on: app.db, restriction: .readOnly)
            let response = try await retry(app, vmID: vm.requireID(), token: key)
            #expect(response.0 == .forbidden)
            #expect(try await VM.find(vm.id, on: app.db)?.generation == 1)
            #expect(try await ResourceEvent.query(on: app.db).count() == 0)
        }
    }

    @Test("A viewer cannot retry placement")
    func viewerRefused() async throws {
        try await withProjectApp(prefix: "viewerretry", role: "viewer") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, _, _) = try await failedVM(app, builder, fixture)
            let response = try await retry(app, vmID: vm.requireID(), token: fixture.token)
            #expect(response.0 == .forbidden)
            #expect(try await VM.find(vm.id, on: app.db)?.generation == 1)
            #expect(try await ResourceEvent.query(on: app.db).count() == 0)
        }
    }

    @Test("A failed retry can retry again without replacing its resources")
    func schedulingFailureCanRetry() async throws {
        try await withProjectApp(prefix: "failedretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, nic) = try await failedVM(app, builder, fixture)
            let id = try vm.requireID()
            // No agent exists: the first retry must degrade, not invent a host.
            let first = try await retry(app, vmID: id, token: fixture.token)
            #expect(first.0 == .accepted)
            let _: Int64 = try await pollUntil {
                guard let row = try await VM.find(id, on: app.db), row.failedGeneration == 2 else { return nil }
                return row.failedGeneration
            }
            let host = try await agent(app, builder)
            let second = try await retry(app, vmID: id, token: fixture.token)
            #expect(second.0 == .accepted)
            #expect(second.1?.targetGeneration == 3)
            let placed: String = try await pollUntil { try await VM.find(id, on: app.db)?.hypervisorId }
            #expect(placed == host)
            #expect(try await Volume.find(boot.id, on: app.db)?.$vm.id == id)
            #expect(try await VMNetworkInterface.find(nic.id, on: app.db) != nil)
            #expect(try await Volume.query(on: app.db).count() == 1)
            #expect(try await ResourceEvent.query(on: app.db).filter(\.$resourceID == id).count() == 2)
        }
    }

    @Test("Placement reuses its pinned connection with a one-connection pool")
    func placementWithOneConnection() async throws {
        let database = try await PostgresTestDatabases.shared.createDatabaseForTest()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let app = try await Application.make(.testing, .shared(group))
        app.databases.use(
            .postgres(
                configuration: PostgresTestDatabases.configuration(database: database),
                maxConnectionsPerEventLoop: 1, connectionPoolTimeout: .milliseconds(250)),
            as: .psql)
        app.storage[TestDatabaseNameKey.self] = database
        app.logger.logLevel = .warning
        do {
            try await configure(app)
            let builder = TestDataBuilder(db: app.db)
            let fixture = try await builder.createAuthenticatedProject(prefix: "oneconnectionplacement")
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            let host = try await agent(app, builder)
            try await app.workloadPlacement.createVM(vm: vm, db: app.db, expectedGeneration: vm.generation)
            #expect(try await VM.find(vm.id, on: app.db)?.hypervisorId == host)
            #expect(try await Volume.find(boot.id, on: app.db)?.attachedAgentId == host)
        } catch {
            try? await app.shutdownForTesting()
            try? await group.shutdownGracefully()
            throw error
        }
        try await app.shutdownForTesting()
        try await group.shutdownGracefully()
    }

    @Test("Replica placement races retain one boot replica and the winner's reservation")
    func replicaPlacementRace() async throws {
        try await withProjectApp(prefix: "replicarace") { app, builder, fixture in
            app.logger.logLevel = .warning
            let database = try #require(app.storage[TestDatabaseNameKey.self])
            let other = try await Application.makeForTesting(database: database, owningDatabase: false)
            do {
                try await configure(other)
                other.logger.logLevel = .warning
                let store = InMemoryCoordinationStore()
                app.coordination = CoordinationService(store: store, logger: app.logger)
                other.coordination = CoordinationService(store: store, logger: other.logger)
                let (vm, boot, _) = try await failedVM(app, builder, fixture)
                let host = try await agent(app, builder)
                let counterpart = try #require(try await VM.find(vm.id, on: other.db))
                async let a: Void = app.workloadPlacement.createVM(vm: vm, db: app.db, expectedGeneration: 1)
                async let b: Void = other.workloadPlacement.createVM(
                    vm: counterpart, db: other.db, expectedGeneration: 1)
                _ = try await (a, b)
                #expect(try await VM.find(vm.id, on: app.db)?.hypervisorId == host)
                #expect(
                    try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count() == 1)
                let reserved = await app.coordination.activeReservations(agentIds: [host])
                #expect(reserved[host]?.cpuMicroUnits == Int64(vm.cpu) * 1_000_000)
            } catch {
                try? await other.asyncShutdown()
                throw error
            }
            try await other.asyncShutdown()
        }
    }

    @Test("A superseded retry cannot assign a host or provision a boot replica")
    func supersededRetryDoesNotPlace() async throws {
        try await withProjectApp(prefix: "staleretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            let host = try await agent(app, builder)
            let id = try vm.requireID()
            try await AdvisoryLock.withSessionLock(
                .object(.vmPlacement, id: id), on: app.db, timeout: .seconds(3),
                pollInterval: .milliseconds(10), logger: app.logger
            ) { _ in
                let response = try await retry(app, vmID: id, token: fixture.token)
                #expect(response.0 == .accepted)
                let newer = try #require(try await VM.find(id, on: app.db))
                newer.setFixtureDesiredStatus(.absent)
                try await newer.save(on: app.db)
            }
            // A serialized service call drains the earlier background attempt.
            let newer = try #require(try await VM.find(id, on: app.db))
            try await app.workloadPlacement.createVM(vm: newer, db: app.db, expectedGeneration: 2)
            #expect(try await VM.find(id, on: app.db)?.hypervisorId == nil)
            #expect(try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count() == 0)
            let reserved = await app.coordination.activeReservations(agentIds: [host])
            #expect((reserved[host]?.cpuMicroUnits ?? 0) == 0)
        }
    }

    @Test("Failure after host selection rolls back placement and releases its reservation", arguments: [false, true])
    func placementFailureRollsBack(productionTimeouts: Bool) async throws {
        try await withProjectApp(prefix: "rollbackretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            let host = try await agent(app, builder)
            // Simulate an ambiguous pre-existing physical placement. The
            // service checks this after writing hypervisorId, so rollback is
            // what keeps the VM unplaced rather than partially committing it.
            try await placeVolume(boot, on: host, using: app.db)
            if productionTimeouts {
                let database = try #require(app.storage[TestDatabaseNameKey.self])
                app.databases.use(
                    try DatabaseStatementTimeout(milliseconds: 5_000).applying(
                        to: .postgres(
                            configuration: PostgresTestDatabases.configuration(database: database),
                            maxConnectionsPerEventLoop: 1)), as: .psql)
            }
            await #expect(throws: Abort.self) {
                try await app.workloadPlacement.createVM(vm: vm, db: app.db, expectedGeneration: 1)
            }
            #expect(try await VM.find(vm.id, on: app.db)?.hypervisorId == nil)
            #expect(try await Volume.find(boot.id, on: app.db)?.attachedAgentId == nil)
            #expect(try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count() == 1)
            let reserved = await app.coordination.activeReservations(agentIds: [host])
            #expect((reserved[host]?.cpuMicroUnits ?? 0) == 0)
        }
    }
}
