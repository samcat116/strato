import AppTestSupport
import Fluent
import FluentPostgresDriver
import NIOPosix
import NIOConcurrencyHelpers
import PostgresNIO
import SQLKit
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
        boot.$sourceImage.id = vm.$sourceImage.id
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
        arguments: ["placed", "pending", "outstanding", "missing-boot", "replica", "terminating"])
    func refusesUnsafeState(state: String) async throws {
        try await withProjectApp(prefix: "invalidretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            switch state {
            case "placed": vm.hypervisorId = UUID().uuidString
            case "pending": vm.failedGeneration = nil
            case "outstanding":
                vm.generation = 2
                vm.convergenceDeadline = Date().addingTimeInterval(60)
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

    @Test("Metadata edits after a failed create preserve placement retry", arguments: [false, true])
    func metadataEditPreservesRetry(sshKeys: Bool) async throws {
        try await withProjectApp(prefix: "metadataretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, nic) = try await failedVM(app, builder, fixture)
            let host = try await agent(app, builder)
            let id = try vm.requireID()
            let publicKey =
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f retry@test"
            try await app.test(.PATCH, "/api/vms/\(id)") { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try request.content.encode(
                    PatchVMMetadataRequest(
                        tags: sshKeys ? nil : ["purpose": "retry"], sshAuthorizedKeys: sshKeys ? [publicKey] : nil))
            } afterResponse: { response in
                #expect(response.status == .ok)
            }
            let edited = try #require(try await VM.find(id, on: app.db))
            #expect(edited.generation == 2 && edited.failedGeneration == 1)
            let response = try await retry(app, vmID: id, token: fixture.token)
            #expect(response.0 == .accepted)
            #expect(response.1?.targetGeneration == 3)
            // A failed acceptance is already an adequate regression signal;
            // don't add a polling timeout to the original guard's refusal.
            guard response.0 == .accepted else { return }
            let placed: String = try await pollUntil { try await VM.find(id, on: app.db)?.hypervisorId }
            #expect(placed == host)
            #expect(try await Volume.find(boot.id, on: app.db)?.$vm.id == id)
            #expect(try await VMNetworkInterface.find(nic.id, on: app.db) != nil)
            let recovered = try #require(try await VM.find(id, on: app.db))
            if sshKeys {
                #expect(recovered.effectiveSSHAuthorizedKeys == [publicKey])
            } else {
                #expect(recovered.tags == ["purpose": "retry"])
            }
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

    @Test("Metadata edits after acceptance settle queued placement", arguments: [false, true], [false, true])
    func metadataWhileRetryQueued(sshKeys: Bool, schedulingFails: Bool) async throws {
        try await withProjectApp(prefix: "queuedmetadataretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            let host = schedulingFails ? nil : try await agent(app, builder)
            let id = try vm.requireID()
            let publicKey =
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f queued@test"
            try await AdvisoryLock.withSessionLock(
                .object(.vmPlacement, id: id), on: app.db, timeout: .seconds(3),
                pollInterval: .milliseconds(10), logger: app.logger
            ) { _ in
                let response = try await retry(app, vmID: id, token: fixture.token)
                #expect(response.0 == .accepted)
                try await app.test(.PATCH, "/api/vms/\(id)") { request in
                    request.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try request.content.encode(
                        PatchVMMetadataRequest(
                            tags: sshKeys ? nil : ["purpose": "queued-retry"],
                            sshAuthorizedKeys: sshKeys ? [publicKey] : nil))
                } afterResponse: { response in
                    #expect(response.status == .ok)
                }
            }
            if schedulingFails {
                let _: Int64 = try await pollUntil(attempts: 40) {
                    guard let row = try await VM.find(id, on: app.db), row.failedGeneration == 3 else { return nil }
                    return row.failedGeneration
                }
            } else {
                let placed: String = try await pollUntil(attempts: 40) {
                    try await VM.find(id, on: app.db)?.hypervisorId
                }
                #expect(placed == host)
            }
            let current = try #require(try await VM.find(id, on: app.db))
            #expect(current.generation == 3)
            if schedulingFails {
                #expect(current.convergenceDeadline == nil)
                #expect(current.hypervisorId == nil)
                let next = try await retry(app, vmID: id, token: fixture.token)
                #expect(next.0 == .accepted)
            }
            if sshKeys {
                #expect(current.effectiveSSHAuthorizedKeys == [publicKey])
            } else {
                #expect(current.tags == ["purpose": "queued-retry"])
            }
            #expect(
                try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count()
                    == (schedulingFails ? 0 : 1))
            #expect(
                try await ResourceEvent.query(on: app.db).filter(\.$resourceID == id).count()
                    == (schedulingFails ? 2 : 1))
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

    @Test("Retry renews the existing boot volume's generation and budget", arguments: [false, true])
    func bootVolumeBudgetIsRenewed(previouslyFailed: Bool) async throws {
        try await withProjectApp(prefix: "bootbudgetretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            let host = try await agent(app, builder)
            let id = try vm.requireID()
            let instant = try await ClusterClock.read(on: app.db)
            if previouslyFailed {
                boot.status = .error
                boot.failedGeneration = boot.generation
                boot.lastError = "Original boot volume deadline expired"
                boot.convergenceDeadline = nil
            } else {
                boot.convergenceDeadline = instant.date.addingTimeInterval(1)
            }
            try await boot.save(on: app.db)
            let stale = try #require(try await Volume.find(boot.id, on: app.db))
            let key = UUID().uuidString
            let response = try await retry(app, vmID: id, token: fixture.token, key: key)
            #expect(response.0 == .accepted)
            let _: String = try await pollUntil { try await VM.find(id, on: app.db)?.hypervisorId }
            let renewed = try #require(try await Volume.find(boot.id, on: app.db))
            let budget = OperationResourceKind.volume.completionBudgetSeconds(for: .create)
            #expect(renewed.generation == stale.generation + 1)
            #expect(renewed.failedGeneration != renewed.generation)
            #expect(renewed.convergenceDeadline.map { $0 >= instant.date.addingTimeInterval(budget) } == true)
            let desired = try await app.desiredStateAssembler.desiredVolumes(agentId: host, on: app.db)
            let entry = try #require(desired.first { $0.volumeId == boot.id })
            #expect(entry.generation == renewed.generation)
            #expect(entry.desiredStatus == .present)
            #expect(entry.source != nil)
            let replay = try await retry(app, vmID: id, token: fixture.token, key: key)
            #expect(replay.1?.mutationId == response.1?.mutationId)
            let afterReplay = try #require(try await Volume.find(boot.id, on: app.db))
            #expect(afterReplay.generation == renewed.generation)
            #expect(afterReplay.convergenceDeadline == renewed.convergenceDeadline)
            #expect(try await ResourceEvent.query(on: app.db).filter(\.$resourceID == id).count() == 1)
            guard renewed.generation != stale.generation else { return }
            // A sweep selected before the acceptance cannot fail the renewed
            // boot attempt after acquiring its row lock.
            let outcome = try await ResourceConvergence.recordExpiredDeadline(
                stale, mutation: .create,
                at: .testing(instant.date.addingTimeInterval(2)),
                timeoutReason: "Stale original boot deadline", on: app.db)
            #expect(outcome == .superseded(actualGeneration: renewed.generation))
            let current = try #require(try await Volume.find(boot.id, on: app.db))
            #expect(current.convergenceDeadline == renewed.convergenceDeadline)
            #expect(current.failedGeneration == renewed.failedGeneration)
        }
    }

    @Test("The acceptance lock preserves metadata but fences a newly failed attempt", arguments: [false, true])
    func changesBeforeAcceptanceLock(newFailure: Bool) async throws {
        try await withProjectApp(prefix: "prelockretry") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            let host = try await agent(app, builder)
            let id = try vm.requireID()
            let request = try await app.db.transaction { tx in
                #expect(try await vm.lockAndRefresh(on: tx))
                let request = Task { try await retry(app, vmID: id, token: fixture.token) }
                let sql = try #require(app.db as? any SQLDatabase)
                let _: Bool = try await pollUntil(attempts: 100) {
                    let blocked = try await sql.raw(
                        """
                        SELECT EXISTS (
                            SELECT 1 FROM pg_stat_activity
                            WHERE datname = current_database() AND pid <> pg_backend_pid()
                              AND wait_event_type = 'Lock' AND query ILIKE '%vms%'
                        ) AS blocked
                        """
                    ).first(decodingColumn: "blocked", as: Bool.self)
                    return blocked == true ? true : nil
                }
                vm.generation += 1
                vm.tags = ["purpose": "before-acceptance-lock"]
                if newFailure { vm.failedGeneration = vm.generation }
                try await vm.save(on: tx)
                return request
            }
            let response = try await request.value
            if newFailure {
                #expect(response.0 == .conflict)
                #expect(try await ResourceEvent.query(on: app.db).filter(\.$resourceID == id).count() == 0)
                #expect(
                    try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count() == 0)
            } else {
                #expect(response.0 == .accepted)
                #expect(response.1?.targetGeneration == 3)
                let placed: String = try await pollUntil { try await VM.find(id, on: app.db)?.hypervisorId }
                #expect(placed == host)
            }
            #expect(try await VM.find(id, on: app.db)?.tags == ["purpose": "before-acceptance-lock"])
        }
    }

    @Test(
        "A retry deadline fences stale placement before and after planning",
        arguments: ["expired", "swept", "new-attempt"])
    func stalePlacementCannotCommit(change: String) async throws {
        try await withProjectApp(prefix: "staleplacement") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            let id = try vm.requireID()
            let gate = DispatchFailureGate()
            let calls = NIOLockedValueBox(0)
            let store = CoordinationFixtureStore(beforeReserve: {
                let first = calls.withLockedValue { count in
                    count += 1
                    return count == 1
                }
                if first && change != "expired" { await gate.wait() }
            })
            app.coordination = CoordinationService(store: store, logger: app.logger)
            let host = try await agent(app, builder)
            vm.generation = 2
            vm.convergenceDeadline = Date().addingTimeInterval(change == "expired" ? -1 : 600)
            try await vm.save(on: app.db)
            let deadline = try #require(try await VM.find(id, on: app.db)?.convergenceDeadline)
            let worker = Task {
                try await app.workloadPlacement.createVM(vm: vm, db: app.db, attemptDeadline: deadline)
            }
            if change != "expired" {
                await gate.waitUntilEntered()
                let current = try #require(try await VM.find(id, on: app.db))
                let outcome = try await ResourceConvergence.recordExpiredDeadline(
                    current, mutation: .create, at: .testing(deadline.addingTimeInterval(1)),
                    timeoutReason: "Retry expired during planning", on: app.db)
                #expect(outcome == .recorded)
                let failed = try #require(try await VM.find(id, on: app.db))
                #expect(failed.generation == 2)
                #expect(failed.failedGeneration == 2)
                if change == "new-attempt" {
                    let next = try await retry(app, vmID: id, token: fixture.token)
                    #expect(next.0 == .accepted)
                }
                await gate.release()
            }
            await #expect(throws: Abort.self) { try await worker.value }
            await app.backgroundTasks.drain(timeout: .seconds(10))
            let current = try #require(try await VM.find(id, on: app.db))
            let replicas = try await VolumeReplica.query(on: app.db)
                .filter(\.$volume.$id == boot.requireID()).all()
            let reservations = await app.coordination.activeReservations(agentIds: [host])
            if change == "new-attempt" {
                #expect(current.hypervisorId == host)
                #expect(replicas.count == 1)
                let renewed = try #require(try await Volume.find(boot.id, on: app.db))
                #expect(replicas.first?.generation == renewed.generation)
                #expect(reservations[host]?.cpuMicroUnits == Int64(vm.cpu) * 1_000_000)
            } else {
                #expect(current.hypervisorId == nil)
                #expect(replicas.isEmpty)
                #expect((reservations[host]?.cpuMicroUnits ?? 0) == 0)
            }
        }
    }

    @Test(
        "Placement failures settle metadata edits but fence superseding work",
        arguments: ["metadata", "new-attempt", "delete", "placed"])
    func failureAfterSnapshot(change: String) async throws {
        try await withProjectApp(prefix: "failureaftersnapshot") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, _, _) = try await failedVM(app, builder, fixture)
            let id = try vm.requireID()
            let gate = DispatchFailureGate()
            let mutation = ResourceMutation(agentDispatch: FakeAgentDispatch(), logger: app.logger)
            let accepted = try await mutation.accept(
                .create, on: vm, actor: .user(try fixture.user.requireID()),
                dispatch: .placement { db in
                    // Capture the same snapshot and attempt deadline as the
                    // endpoint before a suspended planning query fails.
                    let snapshot = try #require(try await VM.find(id, on: db))
                    let deadline = try #require(snapshot.convergenceDeadline)
                    await gate.wait()
                    throw ResourceMutation.PlacementFailure(deadline: deadline, reason: "No eligible agent")
                }, on: app.db, app: app
            ) { _ in }
            await gate.waitUntilEntered()
            let changed = try #require(try await VM.find(id, on: app.db))
            changed.generation += 1
            changed.tags = ["purpose": "post-snapshot-edit"]
            if change == "new-attempt" {
                changed.convergenceDeadline = changed.convergenceDeadline?.addingTimeInterval(60)
            } else if change == "delete" {
                changed.setFixtureDesiredStatus(.absent)
            } else if change == "placed" {
                changed.hypervisorId = UUID().uuidString
            }
            try await changed.save(on: app.db)
            await gate.release()
            await app.backgroundTasks.drain(timeout: .seconds(10))
            let current = try #require(try await VM.find(id, on: app.db))
            #expect(current.generation == changed.generation)
            if change == "metadata" {
                #expect(current.failedGeneration == 3)
                #expect(current.convergenceDeadline == nil)
                #expect(current.tags == ["purpose": "post-snapshot-edit"])
                try await app.test(.GET, "/api/operations/\(accepted.mutationID)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                } afterResponse: { response in
                    let operation = try response.content.decode(OperationResponse.self)
                    #expect(operation.status == .failed)
                    #expect(operation.error == "No eligible agent")
                }
                #expect(try await retry(app, vmID: id, token: fixture.token).0 == .accepted)
            } else {
                #expect(current.failedGeneration == 1)
                #expect(current.convergenceDeadline == changed.convergenceDeadline)
            }
        }
    }

    @Test("Committed placement survives session-lock cleanup failure", arguments: [false, true], [false, true])
    func committedPlacementSurvivesCleanupFailure(connectionCloses: Bool, productionTimeouts: Bool) async throws {
        try await withProjectApp(prefix: "placementcleanup") { app, builder, fixture in
            app.logger.logLevel = .warning
            let (vm, boot, _) = try await failedVM(app, builder, fixture)
            let host = try await agent(app, builder)
            let id = try vm.requireID()
            let key = AdvisoryLockKey.object(.vmPlacement, id: id)
            let placementDB: any Database
            if productionTimeouts {
                let database = try #require(app.storage[TestDatabaseNameKey.self])
                let databaseID = DatabaseID(string: "cleanup-production")
                app.databases.use(
                    try DatabaseStatementTimeout(milliseconds: 5_000).applying(
                        to: .postgres(
                            configuration: PostgresTestDatabases.configuration(database: database),
                            maxConnectionsPerEventLoop: 1)), as: databaseID, isDefault: false)
                placementDB = app.db(databaseID)
            } else {
                placementDB = app.db
            }
            let dispatch = FakeAgentDispatch()
            let mutation = ResourceMutation(agentDispatch: dispatch, logger: app.logger)
            _ = try await mutation.accept(
                .create, on: vm, actor: .user(try fixture.user.requireID()),
                dispatch: .placement { _ in
                    let placed = try await AdvisoryLock.withSessionLock(
                        key, on: placementDB, timeout: .seconds(3), pollInterval: .milliseconds(10),
                        logger: app.logger, preserveCompletedValueOnReleaseFailure: true
                    ) { connection in
                        // The nested service lock is reentrant on this session.
                        // Commit real placement before injecting cleanup failure.
                        try await app.workloadPlacement.createVM(vm: vm, db: connection)
                        if connectionCloses {
                            let postgres = try #require(connection as? any PostgresDatabase)
                            try await postgres.withConnection { $0.close() }.get()
                        } else {
                            #expect(try await AdvisoryLock.releaseSessionLockForTesting(key, on: connection))
                        }
                        return host
                    }
                    await dispatch.syncDesiredState(agentId: placed)
                }, on: app.db, app: app
            ) { _ in vm.setDesiredStatus(.running) }
            let delivered: String = try await pollUntil {
                await dispatch.syncedAgentIds.first
            }
            #expect(delivered == host)
            let current = try #require(try await VM.find(id, on: app.db))
            #expect(current.hypervisorId == host)
            #expect(current.desiredStatus == .running)
            #expect(current.failedGeneration != current.generation)
            #expect(current.convergenceDeadline != nil)
            #expect(try await Volume.find(boot.id, on: app.db)?.attachedAgentId == host)
            #expect(try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count() == 1)
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
            try await app.workloadPlacement.createVM(vm: vm, db: app.db)
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
                async let a: Void = app.workloadPlacement.createVM(vm: vm, db: app.db)
                async let b: Void = other.workloadPlacement.createVM(
                    vm: counterpart, db: other.db)
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

    @Test("Deletion cancels queued placement without assigning a host or provisioning a boot replica")
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
            try await app.workloadPlacement.createVM(vm: newer, db: app.db)
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
            let placementDB: any Database
            if productionTimeouts {
                let database = try #require(app.storage[TestDatabaseNameKey.self])
                let id = DatabaseID(string: "placement-production")
                app.databases.use(
                    try DatabaseStatementTimeout(milliseconds: 5_000).applying(
                        to: .postgres(
                            configuration: PostgresTestDatabases.configuration(database: database),
                            maxConnectionsPerEventLoop: 1)), as: id, isDefault: false)
                placementDB = app.db(id)
                let sql = try #require(placementDB as? any SQLDatabase)
                let timeout = try await sql.raw("SELECT current_setting('statement_timeout') AS value")
                    .first(decodingColumn: "value", as: String.self)
                #expect(timeout == "5s")
            } else {
                placementDB = app.db
            }
            await #expect(throws: Abort.self) {
                try await app.workloadPlacement.createVM(vm: vm, db: placementDB)
            }
            #expect(try await VM.find(vm.id, on: app.db)?.hypervisorId == nil)
            #expect(try await Volume.find(boot.id, on: app.db)?.attachedAgentId == nil)
            #expect(try await VolumeReplica.query(on: app.db).filter(\.$volume.$id == boot.requireID()).count() == 1)
            let reserved = await app.coordination.activeReservations(agentIds: [host])
            #expect((reserved[host]?.cpuMicroUnits ?? 0) == 0)
        }
    }
}
