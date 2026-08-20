import Fluent
import Foundation
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

@Suite("Captured VM command execution", .serialized)
struct VMCommandExecutionTests {
    private struct TransientFailure: Error {}
    private struct EOFDeliveryFailure: Error {}

    private actor FailFirstAttempt {
        private var attempts = 0

        func run() throws {
            attempts += 1
            if attempts == 1 { throw TransientFailure() }
        }

        func count() -> Int { attempts }
    }

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
            let service = VMCommandExecutionService(
                app: app,
                persistence: app.vmCommandExecutionsPersistence,
                sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            let command = ["/bin/sh", "-c", "printf test"]
            try await execution.create(command: command, using: app.vmCommandExecutionsPersistence)
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

            let stored = try #require(
                try await VMCommandExecution.find(id, using: app.vmCommandExecutionsPersistence))
            let payload = try #require(
                try await VMCommandPayload.find(id, using: app.vmCommandExecutionsPersistence))
            #expect(stored.status == VMOperationStatus.succeeded.rawValue)
            #expect(payload.command == command)
            #expect(payload.stdout?.count == VMCommandExecutionService.outputLimitBytes - 3)
            #expect(String(decoding: payload.stderr ?? Data(), as: UTF8.self) == "abc")
            #expect(payload.exitCode == 7)
            #expect(payload.truncated == true)

            let response = try await stored.operationResponse(using: app.vmCommandExecutionsPersistence)
            #expect(response.result?.exitCode == 7)
            #expect(response.result?.truncated == true)

            let history = try await OperationFacade.history(
                resourceKind: .virtualMachine, resourceID: execution.vmID,
                limit: 100, vmCommands: app.vmCommandExecutionsPersistence, on: app.db)
            #expect(history.count == 1)
            #expect(history[0].result == nil)
        }
    }

    @Test("a started command stays pending when stdin EOF delivery fails")
    func eofDeliveryFailureDoesNotFailStartedCommand() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(
                app: app,
                persistence: app.vmCommandExecutionsPersistence,
                sendEnvelope: { _, _ in throw EOFDeliveryFailure() })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(
                command: ["/usr/bin/true"], using: app.vmCommandExecutionsPersistence)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            let started = try #require(
                try await VMCommandExecution.find(id, using: app.vmCommandExecutionsPersistence))
            #expect(started.status == VMOperationStatus.pending.rawValue)
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))

            let completed = try #require(
                try await VMCommandExecution.find(id, using: app.vmCommandExecutionsPersistence))
            #expect(completed.status == VMOperationStatus.succeeded.rawValue)
        }
    }

    @Test("a transient start-classification failure retains frames and retries")
    func retriesStartedCommandClassification() async throws {
        try await withTestApp { app in
            let attempts = FailFirstAttempt()
            let service = VMCommandExecutionService(
                app: app,
                persistence: app.vmCommandExecutionsPersistence,
                sendEnvelope: { _, _ in },
                beforeClassifyStart: { try await attempts.run() },
                retryDelay: .milliseconds(10))
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(
                command: ["/usr/bin/printf", "retained"],
                using: app.vmCommandExecutionsPersistence)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("retained".utf8)))

            for _ in 0..<100 {
                if await attempts.count() >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await attempts.count() >= 2)
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))

            let stored = try #require(
                try await VMCommandExecution.find(id, using: app.vmCommandExecutionsPersistence))
            let payload = try #require(
                try await VMCommandPayload.find(id, using: app.vmCommandExecutionsPersistence))
            #expect(stored.status == VMOperationStatus.succeeded.rawValue)
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "retained")
            #expect(payload.exitCode == 0)
        }
    }

    @Test("a completed command survives a transient persistence failure and timeout sweep")
    func retriesCompletedResultPersistence() async throws {
        try await withTestApp { app in
            let attempts = FailFirstAttempt()
            let service = VMCommandExecutionService(
                app: app,
                persistence: app.vmCommandExecutionsPersistence,
                sendEnvelope: { _, _ in },
                beforePersistResult: { try await attempts.run() },
                retryDelay: .milliseconds(10))
            app.vmCommandExecutionService = service
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(
                command: ["/usr/bin/printf", "done"],
                using: app.vmCommandExecutionsPersistence)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("done".utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))
            await service.sweepStuck()

            for _ in 0..<100 {
                if try await VMCommandExecution.find(
                    id, using: app.vmCommandExecutionsPersistence)?.status
                    == VMOperationStatus.succeeded.rawValue
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let stored = try #require(
                try await VMCommandExecution.find(id, using: app.vmCommandExecutionsPersistence))
            let payload = try #require(
                try await VMCommandPayload.find(id, using: app.vmCommandExecutionsPersistence))
            #expect(stored.status == VMOperationStatus.succeeded.rawValue)
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "done")
            #expect(payload.exitCode == 0)
            #expect(await attempts.count() >= 2)
        }
    }

    @Test("the stuck sweep atomically fails a command and rejects a late result")
    func stuckSweepWinsOverLateExit() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(
                app: app,
                persistence: app.vmCommandExecutionsPersistence,
                sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(
                command: ["/usr/bin/sleep", "600"],
                using: app.vmCommandExecutionsPersistence)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            await service.sweepStuck()
            #expect(
                !(await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0)))

            let stored = try #require(
                try await VMCommandExecution.find(id, using: app.vmCommandExecutionsPersistence))
            #expect(stored.status == VMOperationStatus.failed.rawValue)
            #expect(stored.error == "Command execution timed out")
            let payload = try #require(
                try await VMCommandPayload.find(id, using: app.vmCommandExecutionsPersistence))
            #expect(payload.command == ["/usr/bin/sleep", "600"])
            #expect(payload.stdout == nil)
            #expect(payload.exitCode == nil)
        }
    }

    @Test("a start rejection fails the command without waiting for the sweep")
    func closeBeforeStartedFailsImmediately() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(
                app: app,
                persistence: app.vmCommandExecutionsPersistence,
                sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(
                command: ["/usr/bin/id"], using: app.vmCommandExecutionsPersistence)
            let id = try execution.requireID()

            #expect(
                await service.handleClosed(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    reason: "guest agent unavailable"))

            let stored = try #require(
                try await VMCommandExecution.find(id, using: app.vmCommandExecutionsPersistence))
            #expect(stored.status == VMOperationStatus.failed.rawValue)
            #expect(stored.error == "guest agent unavailable")
        }
    }
}
