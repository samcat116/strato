import Fluent
import Foundation
import Testing
import Vapor

import AppTestSupport
@testable import App

@Suite("VM guest execution audit", .serialized)
struct VMGuestExecutionAuditTests {
    private func events(
        _ type: AuditEventType,
        on database: any Database
    ) async throws -> [AuditEvent] {
        try await AuditEvent.query(on: database)
            .filter(\.$eventType == type.rawValue)
            .sort(\.$createdAt, .ascending)
            .all()
    }

    @Test("command facts use canonical fields and append a timeout correction")
    func commandFactsUseCanonicalContract() async throws {
        try await withTestApp { app in
            let vmID = UUID()
            let organizationID = UUID()
            let userID = UUID()
            let apiKeyID = UUID()
            let context = VMGuestExecutionAuditContext(
                vmID: vmID,
                organizationID: organizationID,
                userID: userID,
                username: "audit-user",
                apiKeyID: apiKeyID,
                sourceIP: "192.0.2.10",
                adminBypass: true,
                correlationID: UUID().uuidString,
                argv: ["/usr/bin/printf", "%s", "hello world"])

            await app.audit.recordFailOpen(
                VMGuestExecutionAudit.makeCommandRequestedRecord(context))
            await app.audit.recordFailOpen(
                VMGuestExecutionAudit.makeCommandCompletedRecord(
                    context,
                    outcome: .timedOut,
                    reason: "  command\nexecution\ttimed out  "))
            await app.audit.recordFailOpen(
                VMGuestExecutionAudit.makeCommandCompletedRecord(
                    context,
                    outcome: .exited,
                    exitCode: 7,
                    correctsOutcome: .timedOut))
            await app.audit.flush()

            let requested = try #require(
                try await self.events(.vmCommandRequested, on: app.db).first)
            #expect(requested.userID == userID)
            #expect(requested.username == "audit-user")
            #expect(requested.apiKeyID == apiKeyID)
            #expect(requested.organizationID == organizationID)
            #expect(requested.method == "POST")
            #expect(requested.path == "/api/vms/\(vmID.uuidString)/actions/run")
            #expect(requested.status == 202)
            #expect(requested.resourceType == "vms")
            #expect(requested.resourceID == vmID.uuidString)
            #expect(requested.action == "vm:runCommand")
            #expect(requested.sourceIP == "192.0.2.10")
            #expect(requested.adminBypass)
            #expect(requested.metadata?["outcome"] == "accepted")
            #expect(requested.metadata?["phase"] == "requested")

            let requestedArgv = try #require(requested.metadata?["argv"]?.data(using: .utf8))
            #expect(
                try JSONDecoder().decode([String].self, from: requestedArgv)
                    == ["/usr/bin/printf", "%s", "hello world"])

            let completions = try await self.events(.vmCommandCompleted, on: app.db)
            #expect(completions.count == 2)
            #expect(completions[0].status == nil)
            #expect(completions[0].metadata?["outcome"] == "timed_out")
            #expect(completions[0].metadata?["reason"] == "command execution timed out")
            #expect(completions[1].metadata?["outcome"] == "exited")
            #expect(completions[1].metadata?["exitCode"] == "7")
            #expect(completions[1].metadata?["correctsOutcome"] == "timed_out")

            let forbiddenKeys: Set<String> = [
                "env", "environment", "workingDir", "stdin", "stdout", "stderr", "output", "frame",
            ]
            for event in [requested] + completions {
                #expect(forbiddenKeys.isDisjoint(with: Set(event.metadata?.keys.map { $0 } ?? [])))
            }
        }
    }

    @Test("exec facts retain exact argv, bound reasons, and use the approved outcome vocabulary")
    func execFactsRetainArgvAndBoundReasons() async throws {
        try await withTestApp { app in
            let argv = ["/bin/sh", "-c", String(repeating: "x", count: 70_000)]
            let context = VMGuestExecutionAuditContext(
                vmID: UUID(),
                correlationID: UUID().uuidString,
                argv: argv)
            let longReason = Array(repeating: "guest disconnected", count: 200).joined(separator: "\n")

            await app.audit.recordFailOpen(
                VMGuestExecutionAudit.makeExecRequestedRecord(context))
            await app.audit.recordFailOpen(
                VMGuestExecutionAudit.makeExecStartedRecord(context))
            await app.audit.recordFailOpen(
                VMGuestExecutionAudit.makeExecEndedRecord(
                    context,
                    outcome: .disconnected,
                    reason: longReason))
            await app.audit.flush()

            let requested = try #require(try await self.events(.vmExecRequested, on: app.db).first)
            #expect(requested.metadata?["outcome"] == "accepted")
            let requestedArgv = try #require(requested.metadata?["argv"]?.data(using: .utf8))
            #expect(try JSONDecoder().decode([String].self, from: requestedArgv) == argv)

            let started = try #require(try await self.events(.vmExecStarted, on: app.db).first)
            #expect(started.metadata?["outcome"] == "started")
            #expect(started.metadata?["phase"] == "started")

            let ended = try #require(try await self.events(.vmExecEnded, on: app.db).first)
            #expect(ended.metadata?["outcome"] == "disconnected")
            #expect(ended.metadata?["phase"] == "ended")
            #expect(ended.metadata?["reason"]?.count == VMGuestExecutionAudit.maxReasonCharacters)
            #expect(ended.metadata?["reason"]?.contains("\n") == false)

            let combiningReason = "e" + String(repeating: "\u{0301}", count: 10_000)
            #expect(combiningReason.count == 1)
            let combiningRecord = VMGuestExecutionAudit.makeExecEndedRecord(
                context,
                outcome: .refused,
                reason: combiningReason)
            let boundedCombiningReason = try #require(combiningRecord.metadata?["reason"])
            #expect(
                Validate.length(boundedCombiningReason)
                    == VMGuestExecutionAudit.maxReasonCharacters)
        }
    }

    @Test("request context snapshots actor, credential, and VM root organization")
    func requestContextSnapshotsAttribution() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "context-user", email: "context@example.com")
            let organization = try await builder.createOrganization(name: "Context Org")
            try await builder.addUserToOrganization(
                user: user, organization: organization, role: "admin")
            let project = try await builder.createProject(
                name: "Context Project", description: "Audit context test project",
                organization: organization)
            _ = try await user.generateAPIKey(on: app.db)
            let apiKey = try #require(try await APIKey.query(on: app.db).first())

            let request = Request(
                application: app,
                method: .POST,
                url: URI(path: "/api/vms/context/exec"),
                on: app.eventLoopGroup.next())
            request.auth.login(user)
            request.apiKey = apiKey

            let vmID = UUID()
            _ = try await IAMResourceTree.resolve(
                IAMNode(type: .project, id: try project.requireID()),
                cache: request.iamCache,
                on: app.db)
            let correlationID = UUID().uuidString
            let context = VMGuestExecutionAudit.makeContext(
                vmID: vmID,
                projectID: try project.requireID(),
                correlationID: correlationID,
                argv: ["/usr/bin/id"],
                on: request)

            #expect(context.vmID == vmID)
            #expect(context.organizationID == organization.id)
            #expect(context.userID == user.id)
            #expect(context.username == "context-user")
            #expect(context.apiKeyID == apiKey.id)
            #expect(context.adminBypass == false)
            #expect(context.correlationID == correlationID)
            #expect(context.argv == ["/usr/bin/id"])
        }
    }

    @Test("durable command attribution survives a reload")
    func durableCommandAttributionSurvivesReload() async throws {
        try await withTestApp { app in
            let execution = VMCommandExecution(
                vmID: UUID(),
                actorID: UUID(),
                agentKey: "spiffe://example.test/agent/audit",
                deadline: Date().addingTimeInterval(60),
                actorUsername: "durable-user",
                apiKeyID: UUID(),
                organizationID: UUID(),
                sourceIP: "198.51.100.7",
                adminBypass: true)
            try await execution.create(command: ["/usr/bin/true"], on: app.db)

            let stored = try #require(
                try await VMCommandExecution.find(execution.requireID(), on: app.db))
            #expect(stored.actorUsername == execution.actorUsername)
            #expect(stored.apiKeyID == execution.apiKeyID)
            #expect(stored.organizationID == execution.organizationID)
            #expect(stored.sourceIP == "198.51.100.7")
            #expect(stored.adminBypass)
        }
    }
}
