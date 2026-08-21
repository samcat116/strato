import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native VM command persistence", .serialized)
struct VMCommandExecutionsPersistenceTests {
    @Test("create keeps status and cold payload separate")
    func createAndLookup() async throws {
        try await withVMCommandDatabase { commands in
            let vmID = UUID()
            let actorID = UUID()
            let created = try await commands.create(
                vmID: vmID,
                actorType: "user",
                actorID: actorID,
                agentKey: "spiffe://example.test/agent/node-1",
                deadline: Date().addingTimeInterval(60),
                command: ["/usr/bin/printf", "hello"])

            #expect(created.vmID == vmID)
            #expect(created.actorID == actorID)
            #expect(created.status == "pending")
            #expect(created.createdAt != nil)
            #expect(try await commands.execution(id: created.id) == created)
            #expect(
                try await commands.pendingExecution(
                    id: created.id, agentKey: created.agentKey) == created)
            #expect(try await commands.history(vmID: vmID, limit: 20) == [created])
            #expect(try await commands.count() == 1)

            let payload = try #require(try await commands.payload(executionID: created.id))
            #expect(payload.command == ["/usr/bin/printf", "hello"])
            #expect(payload.stdout == nil)
        }
    }

    @Test("completion atomically records status and bounded output")
    func completion() async throws {
        try await withVMCommandDatabase { commands in
            let created = try await commands.create(
                vmID: UUID(),
                actorType: "user",
                actorID: UUID(),
                agentKey: "agent-key",
                deadline: Date().addingTimeInterval(60),
                command: ["/usr/bin/id"])

            #expect(
                try await commands.complete(
                    id: created.id,
                    stdout: Data("uid=0\n".utf8),
                    stderr: Data(),
                    exitCode: 0,
                    truncated: false))
            #expect(try await commands.execution(id: created.id)?.status == "succeeded")
            let payload = try #require(try await commands.payload(executionID: created.id))
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "uid=0\n")
            #expect(payload.exitCode == 0)
            #expect(payload.truncated == false)
        }
    }

    @Test("timeout and explicit failure only claim pending commands")
    func failureClaims() async throws {
        try await withVMCommandDatabase { commands in
            let expired = try await commands.create(
                vmID: UUID(),
                actorType: "user",
                actorID: UUID(),
                agentKey: "expired-agent",
                deadline: Date().addingTimeInterval(-1),
                command: ["/usr/bin/sleep", "60"])
            let dispatched = try await commands.create(
                vmID: UUID(),
                actorType: "user",
                actorID: UUID(),
                agentKey: "dispatch-agent",
                deadline: Date().addingTimeInterval(60),
                command: ["/usr/bin/true"])

            #expect(try await commands.fail(id: dispatched.id, reason: "dispatch failed"))
            #expect(!(try await commands.fail(id: dispatched.id, reason: "again")))
            #expect(try await commands.execution(id: dispatched.id)?.error == "dispatch failed")

            #expect(
                try await commands.failTimedOut(now: Date())
                    == [TimedOutVMCommandSnapshot(id: expired.id, agentKey: "expired-agent")])
            #expect(try await commands.execution(id: expired.id)?.status == "failed")
        }
    }

    private func withVMCommandDatabase(
        _ test: (VMCommandExecutionsPersistence) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase { database in
            _ = try await database.withSession(operation: "test.vm_commands.schema") { session in
                try await session.command(
                    """
                    CREATE TABLE vm_command_executions (
                        id UUID PRIMARY KEY,
                        vm_id UUID NOT NULL,
                        actor_type TEXT NOT NULL CHECK (actor_type = 'user'),
                        actor_id UUID NOT NULL,
                        agent_key TEXT NOT NULL,
                        status TEXT NOT NULL CHECK (status IN ('pending', 'succeeded', 'failed')),
                        error TEXT,
                        deadline TIMESTAMPTZ NOT NULL,
                        created_at TIMESTAMPTZ,
                        completed_at TIMESTAMPTZ
                    )
                    """,
                    operation: "test.vm_commands.schema.executions")
                try await session.command(
                    """
                    CREATE TABLE vm_command_payloads (
                        execution_id UUID PRIMARY KEY REFERENCES vm_command_executions(id) ON DELETE CASCADE,
                        command TEXT[] NOT NULL,
                        stdout BYTEA,
                        stderr BYTEA,
                        exit_code BIGINT,
                        truncated BOOLEAN
                    )
                    """,
                    operation: "test.vm_commands.schema.payloads")
            }
            try await test(ControlPlanePersistence(database: database).vmCommandExecutions)
        }
    }
}
