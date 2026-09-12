import AppTestSupport
import Fluent
import Foundation
import SQLKit
import Testing

@testable import App

@Suite("Rebase legacy cluster-clock deadlines", .serialized)
struct RebaseLegacyClusterClockDeadlinesTests {
    @Test("legacy convergence and retention deadlines receive a database-clock runway")
    func deadlinesReceiveDatabaseClockRunway() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "legacy-clock-user",
                email: "legacy-clock@example.com",
                displayName: "Legacy Clock User")
            let organization = try await builder.createOrganization(name: "Legacy Clock Org")
            let project = try await builder.createProject(
                name: "Legacy Clock Project",
                description: "Legacy deadline repair",
                organization: organization)
            let vm = try await builder.createVM(name: "legacy-clock-vm", project: project)
            let snapshot = VMSnapshot(
                name: "legacy-clock-snapshot",
                vmID: try vm.requireID(),
                projectID: try project.requireID(),
                environment: vm.environment,
                agentId: nil,
                createdByID: try user.requireID())
            try await snapshot.save(on: app.db)

            let databaseNow = try await ClusterClock.read(on: app.db)
            let legacyCreatedAt = databaseNow.date.addingTimeInterval(-120)
            let legacyDeadline = databaseNow.date.addingTimeInterval(-60)
            let legacyExpiry = legacyCreatedAt.addingTimeInterval(3_600)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                UPDATE vms
                SET convergence_deadline = \(bind: legacyDeadline)
                WHERE id = \(bind: try vm.requireID())
                """
            ).run()
            try await sql.raw(
                """
                UPDATE vm_snapshots
                SET created_at = \(bind: legacyCreatedAt),
                    expires_at = \(bind: legacyExpiry),
                    convergence_deadline = \(bind: legacyDeadline)
                WHERE id = \(bind: try snapshot.requireID())
                """
            ).run()

            try await RebaseLegacyClusterClockDeadlines().prepare(on: app.db)

            let sampledAfterRepair = try await ClusterClock.read(on: app.db)
            let repairedVM = try #require(try await VM.find(vm.id, on: app.db))
            let repairedSnapshot = try #require(try await VMSnapshot.find(snapshot.id, on: app.db))
            let vmDeadline = try #require(repairedVM.convergenceDeadline)
            let snapshotDeadline = try #require(repairedSnapshot.convergenceDeadline)
            let snapshotExpiry = try #require(repairedSnapshot.expiresAt)

            #expect(vmDeadline.timeIntervalSince(sampledAfterRepair.date) > 1_790)
            #expect(snapshotDeadline.timeIntervalSince(sampledAfterRepair.date) > 1_790)
            #expect(snapshotExpiry.timeIntervalSince(sampledAfterRepair.date) > 3_590)
        }
    }

    @Test("unrecoverable legacy snapshot retention is disabled")
    func unrecoverableRetentionIsDisabled() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "malformed-clock-user",
                email: "malformed-clock@example.com",
                displayName: "Malformed Clock User")
            let organization = try await builder.createOrganization(name: "Malformed Clock Org")
            let project = try await builder.createProject(
                name: "Malformed Clock Project",
                description: "Malformed deadline repair",
                organization: organization)
            let vm = try await builder.createVM(name: "malformed-clock-vm", project: project)
            let snapshot = VMSnapshot(
                name: "malformed-clock-snapshot",
                vmID: try vm.requireID(),
                projectID: try project.requireID(),
                environment: vm.environment,
                agentId: nil,
                createdByID: try user.requireID())
            try await snapshot.save(on: app.db)

            let databaseNow = try await ClusterClock.read(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                UPDATE vm_snapshots
                SET created_at = NULL,
                    expires_at = \(bind: databaseNow.date.addingTimeInterval(60))
                WHERE id = \(bind: try snapshot.requireID())
                """
            ).run()

            try await RebaseLegacyClusterClockDeadlines().prepare(on: app.db)

            let repaired = try #require(try await VMSnapshot.find(snapshot.id, on: app.db))
            #expect(repaired.expiresAt == nil)
        }
    }
}
