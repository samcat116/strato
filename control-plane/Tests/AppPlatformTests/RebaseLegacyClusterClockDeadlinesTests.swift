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

    @Test("legacy active fixed windows restart from one database instant")
    func activeFixedWindowsRestartFromDatabaseTime() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "legacy-window-user",
                email: "legacy-window@example.com",
                displayName: "Legacy Window User")
            let organization = try await builder.createOrganization(name: "Legacy Window Org")
            let project = try await builder.createProject(
                name: "Legacy Window Project",
                description: "Legacy active window repair",
                organization: organization)
            let vm = try await builder.createVM(name: "legacy-window-vm", project: project)
            let sandbox = try await builder.createSandbox(
                name: "legacy-window-sandbox", project: project)
            sandbox.ttlSeconds = 900
            try await sandbox.save(on: app.db)

            let agent = try await builder.createAgent(
                named: "legacy-window-agent",
                organizationScope: .organization(try organization.requireID()))
            agent.updateDesiredVersion = "2.0.0"
            agent.updateAssignmentSource = .rollout

            let sampledBeforeRepair = try await ClusterClock.read(on: app.db)
            let legacyStamp = sampledBeforeRepair.date.addingTimeInterval(-7_200)
            agent.updateAttemptedAt = legacyStamp
            try await agent.save(on: app.db)

            let execution = VMCommandExecution(
                vmID: try vm.requireID(),
                actorID: try user.requireID(),
                agentKey: "spiffe://strato.local/agent/legacy-window-agent",
                deadline: legacyStamp)
            try await execution.save(on: app.db)

            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw(
                """
                UPDATE sandboxes
                SET created_at = \(bind: legacyStamp)
                WHERE id = \(bind: try sandbox.requireID())
                """
            ).run()

            try await RebaseLegacyClusterClockDeadlines().prepare(on: app.db)

            let sampledAfterRepair = try await ClusterClock.read(on: app.db)
            let repairedSandbox = try #require(try await Sandbox.find(sandbox.id, on: app.db))
            let repairedAgent = try #require(try await Agent.find(agent.id, on: app.db))
            let repairedExecution = try #require(
                try await VMCommandExecution.find(execution.id, on: app.db))
            let sandboxCreatedAt = try #require(repairedSandbox.createdAt)
            let sandboxExpiry = try #require(repairedSandbox.expiresAt)
            let updateAttemptedAt = try #require(repairedAgent.updateAttemptedAt)

            #expect(abs(sandboxCreatedAt.timeIntervalSince(sampledAfterRepair.date)) < 10)
            #expect(sandboxExpiry.timeIntervalSince(sampledAfterRepair.date) > 890)
            #expect(repairedExecution.deadline.timeIntervalSince(sampledAfterRepair.date) > 290)
            #expect(abs(updateAttemptedAt.timeIntervalSince(sampledAfterRepair.date)) < 10)
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
