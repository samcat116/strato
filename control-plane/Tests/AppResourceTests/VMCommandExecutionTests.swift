import Fluent
import Foundation
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

@Suite("Captured VM command execution", .serialized)
struct VMCommandExecutionTests {
    private func execution(
        agentKey: String = "spiffe://example.test/agent/node-1",
        deadline: Date = Date().addingTimeInterval(60)
    ) -> VMCommandExecution {
        VMCommandExecution(
            vmID: UUID(), actorID: UUID(), agentKey: agentKey, deadline: deadline)
    }

    @Test("stdout and stderr are capped together and persisted off the operation row")
    func capturesBoundedOutputInSideTable() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            let stdout = Data(repeating: 65, count: VMCommandExecutionService.outputLimitBytes - 3)
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: stdout))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stderr", data: Data("abcdef".utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 7))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let output = try #require(try await VMCommandOutput.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(output.stdout.count == VMCommandExecutionService.outputLimitBytes - 3)
            #expect(String(decoding: output.stderr, as: UTF8.self) == "abc")
            #expect(output.exitCode == 7)
            #expect(output.truncated)

            let response = try await stored.operationResponse(on: app.db)
            #expect(response.result?.exitCode == 7)
            #expect(response.result?.truncated == true)
        }
    }

    @Test("the stuck sweep atomically fails a command and rejects a late result")
    func stuckSweepWinsOverLateExit() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            await service.sweepStuck()
            #expect(
                !(await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0)))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(stored.status == .failed)
            #expect(stored.error == "Command execution timed out")
            #expect(try await VMCommandOutput.find(id, on: app.db) == nil)
        }
    }

    @Test("a start rejection fails the command without waiting for the sweep")
    func closeBeforeStartedFailsImmediately() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleClosed(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    reason: "guest agent unavailable"))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(stored.status == .failed)
            #expect(stored.error == "guest agent unavailable")
        }
    }
}
