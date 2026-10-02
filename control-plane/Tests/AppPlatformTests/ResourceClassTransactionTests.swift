import AppTestSupport
import Fluent
import SQLKit
import PostgresNIO
import StratoShared
import Testing
import Vapor
@testable import App

@Suite("Resource class transactions", .serialized)
struct ResourceClassTransactionTests {
    private func fixture(_ app: Application) async throws -> (Site, VM) {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "Class transactions")
        let project = try await builder.createProject(
            name: "Class project", description: "Atomic admission fixture", organization: org)
        let site = Site(name: "Class site", organizationScope: .organization(try org.requireID()))
        try await site.save(on: app.db)
        let vm = try await builder.createVM(name: "class-workload", project: project)
        vm.cpu = 1
        vm.memory = 1024
        vm.resourceClass = try site.resourceClasses()[1]
        vm.admittedReservation = .init(
            cpus: 1, memory: .init(guestBytes: 1024, backendOverheadBytes: 64),
            policy: try #require(vm.resourceClass).policy)
        try await vm.save(on: app.db)
        return (site, vm)
    }

    @Test func concurrentGrowthKeepsPriorPricingAndEachGeneration() async throws {
        try await withTestApp { app in
            let (site, vm) = try await fixture(app)
            let original = try #require(vm.resourceClass)
            site.burstableResourceClass = try .init(
                classID: original.classID, siteID: original.siteID, revision: 2,
                policy: .init(kind: .burstable, cpuAllocationRatio: 8, memoryAllocationRatio: 4, memoryHighPercent: 70))
            try await site.save(on: app.db)
            let id = try vm.requireID()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        try await app.db.transaction { tx in
                            let row = try #require(try await VM.find(id, on: tx))
                            #expect(try await row.lockAndRefresh(on: tx))
                            let nextCPU = row.cpu + 1
                            let nextMemory = row.memory + 64
                            let admission = try #require(
                                try await WorkloadResourceClassService.growth(
                                    row.resourceClass,
                                    admitted: row.admittedReservation, currentCPUs: row.cpu,
                                    currentMemory: .init(guestBytes: row.memory, backendOverheadBytes: 64),
                                    cpus: nextCPU,
                                    memory: .init(guestBytes: nextMemory, backendOverheadBytes: 64), on: tx))
                            row.cpu = nextCPU
                            row.memory = nextMemory
                            row.resourceClass = admission.snapshot
                            row.admittedReservation = admission.reservation
                            #expect(
                                try await row.advanceDesiredStateGeneration(expectedGeneration: row.generation, on: tx)
                                    != .missing)
                            try await row.save(on: tx)
                        }
                    }
                }
                try await group.waitForAll()
            }
            let persisted = try #require(try await VM.find(id, on: app.db))
            #expect(persisted.cpu == 11 && persisted.memory == 1664 && persisted.generation == 10)
            #expect(persisted.resourceClass?.revision == 2)
            #expect(persisted.admittedReservation?.cpuMicroUnits == 1_500_000)
            #expect(persisted.admittedReservation?.discountedGuestBytes == 1184)
            #expect(persisted.admittedReservation?.backendOverheadBytes == 64)
            #expect(throws: Abort.self) {
                try WorkloadResourceClassService.requireGrowthAvailable(vm: persisted, cpu: 12, memory: 1664)
            }
        }
    }

    @Test func failedTransactionRollsBackSnapshotLedgerSizingAndGeneration() async throws {
        try await withTestApp { app in
            let (site, vm) = try await fixture(app)
            let original = try #require(vm.resourceClass)
            let ledger = try #require(vm.admittedReservation)
            site.burstableResourceClass = try .init(
                classID: original.classID, siteID: original.siteID, revision: 2, policy: .burstable)
            try await site.save(on: app.db)
            let id = try vm.requireID()
            do {
                try await app.db.transaction { tx in
                    let row = try #require(try await VM.find(id, on: tx))
                    #expect(try await row.lockAndRefresh(on: tx))
                    let plan = try #require(
                        try await WorkloadResourceClassService.placement(
                            row.resourceClass, cpus: 8,
                            memory: .init(guestBytes: 8192, backendOverheadBytes: 64), on: tx))
                    row.resourceClass = plan.snapshot
                    row.admittedReservation = plan.reservation
                    row.cpu = 8
                    row.memory = 8192
                    _ = try await row.advanceDesiredStateGeneration(expectedGeneration: row.generation, on: tx)
                    try await row.save(on: tx)
                    throw Abort(.conflict, reason: "Fixture rollback")
                }
            } catch let error as Abort { #expect(error.status == .conflict) }
            let row = try #require(try await VM.find(id, on: app.db))
            #expect(row.resourceClass == original && row.admittedReservation == ledger)
            #expect(row.cpu == 1 && row.memory == 1024 && row.generation == 0)
        }
    }

    @Test func catalogEditCannotCrossAnAdmissionTransaction() async throws {
        try await withTestApp { app in
            let (site, vm) = try await fixture(app)
            let original = try #require(vm.resourceClass)
            let next = try WorkloadResourceClassSnapshot(
                classID: original.classID, siteID: original.siteID, revision: 2, policy: .burstable)
            site.burstableResourceClass = next
            try await app.db.transaction { tx in
                let pinned = try await WorkloadResourceClassService.currentPolicy(original, on: tx)
                #expect(pinned == original)
                let writer = Task { () -> String? in
                    do {
                        try await app.db.transaction { other in
                            let sql = try #require(other as? any SQLDatabase)
                            try await sql.raw("SET LOCAL lock_timeout = '100ms'").run()
                            try await site.save(on: other)
                        }
                        return nil
                    } catch { return (error as? PSQLError)?.serverInfo?[.sqlState] }
                }
                #expect(await writer.value == "55P03")
                let retained = try await WorkloadResourceClassService.currentPolicy(original, on: tx)
                #expect(retained == original)
            }
            try await site.save(on: app.db)
            let fresh = try await app.db.transaction { tx in
                try await WorkloadResourceClassService.placement(
                    original, cpus: 1, memory: .sandbox(memoryBytes: 1024), on: tx)
            }
            #expect(fresh?.snapshot == next)
            #expect(vm.resourceClass == original)
        }
    }

    @Test func missingLedgerCannotInferAndRepriceHistoricalBurstableGrant() async throws {
        try await withTestApp { app in
            let (_, vm) = try await fixture(app)
            do {
                _ = try await app.db.transaction { tx in
                    try await WorkloadResourceClassService.growth(
                        vm.resourceClass, admitted: nil, currentCPUs: vm.cpu,
                        currentMemory: .init(guestBytes: vm.memory, backendOverheadBytes: 64), cpus: 2,
                        memory: .init(guestBytes: vm.memory, backendOverheadBytes: 64), on: tx)
                }
                Issue.record("A missing burstable commitment must not be inferred")
            } catch let error as Abort { #expect(error.status == .conflict) }
        }
    }

    @Test func unchangedAndShrinkingGrantDoesNotReadTheNewCatalog() async throws {
        try await withTestApp { app in
            let (site, vm) = try await fixture(app)
            try await site.delete(on: app.db)
            let plan = try await app.db.transaction { tx in
                try await WorkloadResourceClassService.growth(
                    vm.resourceClass, admitted: vm.admittedReservation,
                    currentCPUs: vm.cpu, currentMemory: .init(guestBytes: vm.memory, backendOverheadBytes: 64),
                    cpus: 1, memory: .init(guestBytes: 512, backendOverheadBytes: 64), on: tx)
            }
            #expect(plan == nil)
            #expect(vm.admittedReservation?.cpuMicroUnits == 250_000)
        }
    }
}
