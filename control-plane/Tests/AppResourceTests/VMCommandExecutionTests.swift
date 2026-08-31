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

    private actor SentFrames {
        private var values: [(MessageEnvelope, String)] = []

        func append(_ envelope: MessageEnvelope, agentKey: String) {
            values.append((envelope, agentKey))
        }

        func all() -> [(MessageEnvelope, String)] { values }
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
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            let command = ["/bin/sh", "-c", "printf test"]
            try await execution.create(command: command, on: app.db)
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
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(payload.command == command)
            #expect(payload.stdout?.count == VMCommandExecutionService.outputLimitBytes - 3)
            #expect(String(decoding: payload.stderr ?? Data(), as: UTF8.self) == "abc")
            #expect(payload.exitCode == 7)
            #expect(payload.truncated == true)

            let response = try await stored.operationResponse(on: app.db)
            #expect(response.result?.exitCode == 7)
            #expect(response.result?.truncated == true)

            let history = try await OperationFacade.history(
                resourceKind: .virtualMachine, resourceID: execution.vmID,
                limit: 100, on: app.db)
            #expect(history.count == 1)
            #expect(history[0].result == nil)
        }
    }

    @Test("a started command stays pending when stdin EOF delivery fails")
    func eofDeliveryFailureDoesNotFailStartedCommand() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in throw EOFDeliveryFailure() })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            let started = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(started.status == .pending)
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))

            let completed = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(completed.status == .succeeded)
        }
    }

    @Test("a transient start-classification failure retains frames and retries")
    func retriesStartedCommandClassification() async throws {
        try await withTestApp { app in
            let attempts = FailFirstAttempt()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforeClassifyStart: { try await attempts.run() },
                retryDelay: .milliseconds(10))
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/printf", "retained"], on: app.db)
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

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
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
                sendEnvelope: { _, _ in },
                beforePersistResult: { try await attempts.run() },
                retryDelay: .milliseconds(10))
            app.vmCommandExecutionService = service
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/printf", "done"], on: app.db)
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
                if try await VMCommandExecution.find(id, on: app.db)?.status == .succeeded {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "done")
            #expect(payload.exitCode == 0)
            #expect(await attempts.count() >= 2)
        }
    }

    @Test("an exit for a recorded command without a live capture completes it")
    func exitWithoutLiveCaptureCompletesRecordedCommand() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 23))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(stored.error == nil)
            #expect(payload.exitCode == 23)
        }
    }

    @Test("output for a recorded command without a live capture is retained")
    func outputWithoutLiveCaptureIsRetained() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/printf", "late"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("late".utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))

            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "late")
            #expect(payload.exitCode == 0)
        }
    }

    @Test("provisional classification cannot complete another agent's command")
    func provisionalCaptureDoesNotCrossAgentOwnership() async throws {
        try await withTestApp { app in
            let attempts = FailFirstAttempt()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforeClassifyStart: { try await attempts.run() })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()
            let wrongAgent = "spiffe://example.test/agent/node-2"

            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: wrongAgent,
                    stream: "stdout", data: Data("forged".utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: wrongAgent, exitCode: 0))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .pending)
            #expect(payload.stdout == nil)
            #expect(payload.exitCode == nil)
        }
    }

    @Test("a late exit corrects a command failed by the stuck sweep")
    func lateExitCorrectsSweptCommand() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/sleep", "600"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("before sweep".utf8)))
            await service.sweepStuck()

            let swept = try #require(try await VMCommandExecution.find(id, on: app.db))
            let sweptPayload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(swept.status == .failed)
            #expect(swept.error == "Command execution timed out")
            #expect(String(decoding: sweptPayload.stdout ?? Data(), as: UTF8.self) == "before sweep")
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(stored.error == nil)
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(payload.command == ["/usr/bin/sleep", "600"])
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "before sweep")
            #expect(payload.exitCode == 0)
        }
    }

    @Test("late output appends to partial bytes persisted by the stuck sweep")
    func lateOutputPreservesSweptPartialCapture() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/sleep", "600"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("before ".utf8)))
            await service.sweepStuck()

            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("after".utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "before after")
            #expect(payload.exitCode == 0)
            #expect(payload.truncated == true)
        }
    }

    @Test("a start rejection fails the command without waiting for the sweep")
    func closeBeforeStartedFailsImmediately() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/id"], on: app.db)
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

    @Test("an authoritative exit is acknowledged only after commit and on duplicate replay")
    func recordedExitAcknowledgesAfterPersistence() async throws {
        try await withTestApp { app in
            let attempts = FailFirstAttempt()
            let sent = SentFrames()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { envelope, agentKey in
                    await sent.append(envelope, agentKey: agentKey)
                },
                beforePersistResult: { try await attempts.run() })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/printf", "replayed"], on: app.db)
            let id = try execution.requireID()
            let state = GuestExecRecordedStateMessage(
                sessionId: id.uuidString,
                revision: 2,
                status: .exited,
                rawStdout: Data("replayed".utf8),
                rawStderr: Data("warning".utf8),
                exitCode: 9,
                truncated: false)

            #expect(await service.handleRecordedState(state, fromAgentKey: execution.agentKey))
            #expect(await sent.all().isEmpty)
            #expect(try await VMCommandExecution.find(id, on: app.db)?.status == .pending)

            #expect(await service.handleRecordedState(state, fromAgentKey: execution.agentKey))
            var frames = await sent.all()
            #expect(frames.count == 1)
            #expect(frames[0].1 == execution.agentKey)
            #expect(frames[0].0.type == .guestExecRecordedAck)
            let firstAck = try frames[0].0.decode(as: GuestExecRecordedAckMessage.self)
            #expect(firstAck.sessionId == id.uuidString)

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "replayed")
            #expect(String(decoding: payload.stderr ?? Data(), as: UTF8.self) == "warning")
            #expect(payload.exitCode == 9)

            // The agent may replay after the commit if the first ACK was lost.
            // Confirming the same-agent terminal row is enough to ACK again.
            #expect(await service.handleRecordedState(state, fromAgentKey: execution.agentKey))
            frames = await sent.all()
            #expect(frames.count == 2)
            #expect(frames.allSatisfy { $0.0.type == .guestExecRecordedAck })
        }
    }

    @Test("a running recorded snapshot replaces the replica-local capture")
    func runningRecordedStateReplacesCapture() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/printf", "snapshot"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("stale-local".utf8)))

            let running = GuestExecRecordedStateMessage(
                sessionId: id.uuidString,
                revision: 1,
                status: .running,
                rawStdout: Data("authoritative".utf8),
                rawStderr: Data(),
                truncated: false)
            #expect(await service.handleRecordedState(running, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("-tail".utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))

            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "authoritative-tail")
        }
    }

    @Test("a recorded close exposes authoritative partial output without an exit code")
    func recordedClosePersistsFailedPartialResult() async throws {
        try await withTestApp { app in
            let sent = SentFrames()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { envelope, agentKey in
                    await sent.append(envelope, agentKey: agentKey)
                })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/upgrade"], on: app.db)
            let id = try execution.requireID()

            let state = GuestExecRecordedStateMessage(
                sessionId: id.uuidString,
                revision: 3,
                status: .closed,
                rawStdout: Data("installed package-a\n".utf8),
                rawStderr: Data("connection lost\n".utf8),
                reason: "guest exec channel closed",
                truncated: false)
            #expect(await service.handleRecordedState(state, fromAgentKey: execution.agentKey))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .failed)
            #expect(stored.error == "guest exec channel closed")
            #expect(payload.exitCode == nil)
            #expect(payload.truncated == true)
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "installed package-a\n")
            #expect(String(decoding: payload.stderr ?? Data(), as: UTF8.self) == "connection lost\n")

            let response = try await stored.operationResponse(on: app.db)
            #expect(response.result?.stdout == "installed package-a\n")
            #expect(response.result?.stderr == "connection lost\n")
            #expect(response.result?.exitCode == nil)
            #expect(response.result?.truncated == true)
            #expect(await sent.all().map { $0.0.type } == [.guestExecRecordedAck])
        }
    }

    @Test("the deadline sweep persists local partial output before eviction")
    func deadlineSweepPersistsPartialCapture() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/sleep", "600"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data("partly done".utf8)))
            await service.sweepStuck()

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let response = try await stored.operationResponse(on: app.db)
            #expect(stored.status == .failed)
            #expect(response.result?.stdout == "partly done")
            #expect(response.result?.exitCode == nil)
            #expect(response.result?.truncated == true)
        }
    }

    @Test("a deadline sweep marks a persisted running snapshot as truncated")
    func deadlineSweepMarksPersistedRunningSnapshotTruncated() async throws {
        try await withTestApp { app in
            let snapshotService = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            let sweepService = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/sleep", "600"], on: app.db)
            let id = try execution.requireID()

            let running = GuestExecRecordedStateMessage(
                sessionId: id.uuidString,
                revision: 1,
                status: .running,
                rawStdout: Data("partly done".utf8),
                rawStderr: Data(),
                truncated: false)
            #expect(
                await snapshotService.handleRecordedState(
                    running, fromAgentKey: execution.agentKey))
            #expect(try await VMCommandPayload.find(id, on: app.db)?.truncated == false)

            await sweepService.sweepStuck()

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let response = try await stored.operationResponse(on: app.db)
            #expect(stored.status == .failed)
            #expect(response.result?.stdout == "partly done")
            #expect(response.result?.exitCode == nil)
            #expect(response.result?.truncated == true)
        }
    }

    @Test("a terminal snapshot from the wrong agent is discarded and acknowledged")
    func recordedStateCannotCompleteAnotherAgentExecution() async throws {
        try await withTestApp { app in
            let sent = SentFrames()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { envelope, agentKey in
                    await sent.append(envelope, agentKey: agentKey)
                })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()
            let wrongAgent = "spiffe://example.test/agent/node-2"
            let state = GuestExecRecordedStateMessage(
                sessionId: id.uuidString,
                revision: 1,
                status: .exited,
                rawStdout: Data("not authoritative".utf8),
                rawStderr: Data(),
                exitCode: 0,
                truncated: false)

            #expect(await service.handleRecordedState(state, fromAgentKey: wrongAgent))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .pending)
            #expect(payload.stdout == nil)
            let frames = await sent.all()
            #expect(frames.count == 1)
            #expect(frames[0].1 == wrongAgent)
            #expect(frames[0].0.type == .guestExecRecordedAck)
        }
    }

    @Test("a malformed terminal snapshot is failed durably before acknowledgement")
    func malformedTerminalStateDoesNotBlockReplayQueue() async throws {
        try await withTestApp { app in
            let attempts = FailFirstAttempt()
            let sent = SentFrames()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { envelope, agentKey in
                    await sent.append(envelope, agentKey: agentKey)
                },
                beforePersistResult: { try await attempts.run() })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()
            let malformed = GuestExecRecordedStateMessage(
                sessionId: id.uuidString,
                revision: 1,
                status: .exited,
                stdout: "not-base64!",
                stderr: "",
                exitCode: 0,
                truncated: false)

            #expect(
                await service.handleRecordedState(
                    malformed, fromAgentKey: execution.agentKey))
            #expect(await sent.all().isEmpty)
            #expect(try await VMCommandExecution.find(id, on: app.db)?.status == .pending)

            #expect(
                await service.handleRecordedState(
                    malformed, fromAgentKey: execution.agentKey))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .failed)
            #expect(
                stored.error
                    == "Recorded guest command reported a malformed terminal state; the command may have partially run"
            )
            #expect(payload.stdout == Data())
            #expect(payload.stderr == Data())
            #expect(payload.exitCode == nil)
            #expect(payload.truncated == true)
            let frames = await sent.all()
            #expect(frames.count == 1)
            #expect(frames[0].0.type == .guestExecRecordedAck)
            let ack = try frames[0].0.decode(as: GuestExecRecordedAckMessage.self)
            #expect(ack.sessionId == id.uuidString)
        }
    }

    @Test("a malformed running snapshot is closed so it cannot replay forever")
    func malformedRunningRecordedStateIsClosed() async throws {
        try await withTestApp { app in
            let sent = SentFrames()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { envelope, agentKey in
                    await sent.append(envelope, agentKey: agentKey)
                })
            app.vmCommandExecutionService = service
            let id = UUID()
            let agentKey = "spiffe://example.test/agent/node-1"
            let malformed = GuestExecRecordedStateMessage(
                sessionId: id.uuidString,
                revision: 1,
                status: .running,
                stdout: "not-base64!",
                stderr: "",
                truncated: false)

            #expect(await service.handleRecordedState(malformed, fromAgentKey: agentKey))

            let frames = await sent.all()
            #expect(frames.count == 1)
            #expect(frames[0].0.type == .guestExecClose)
            let close = try frames[0].0.decode(as: GuestExecCloseMessage.self)
            #expect(close.sessionId == id.uuidString)
            #expect(close.reason == "recorded command reported malformed running state")
        }
    }

    @Test("an unknown running snapshot is closed without an acknowledgement")
    func unknownRunningRecordedStateIsClosed() async throws {
        try await withTestApp { app in
            let sent = SentFrames()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { envelope, agentKey in
                    await sent.append(envelope, agentKey: agentKey)
                })
            app.vmCommandExecutionService = service
            let id = UUID()
            let agentKey = "spiffe://example.test/agent/node-1"
            let state = GuestExecRecordedStateMessage(
                sessionId: id.uuidString,
                revision: 1,
                status: .running,
                rawStdout: Data("still running".utf8),
                rawStderr: Data(),
                truncated: false)

            #expect(await service.handleRecordedState(state, fromAgentKey: agentKey))

            let frames = await sent.all()
            #expect(frames.count == 1)
            #expect(frames[0].0.type == .guestExecClose)
            let close = try frames[0].0.decode(as: GuestExecCloseMessage.self)
            #expect(close.sessionId == id.uuidString)
        }
    }
}
