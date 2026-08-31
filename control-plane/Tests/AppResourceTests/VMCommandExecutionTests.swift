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
    private struct ClassificationUnavailable: Error {}

    private actor FailFirstAttempt {
        private var attempts = 0

        func run() throws {
            attempts += 1
            if attempts == 1 { throw TransientFailure() }
        }

        func count() -> Int { attempts }
    }

    private actor ClassificationFailureBudget {
        private var remaining: Int

        init(_ remaining: Int) {
            self.remaining = remaining
        }

        func run() throws {
            guard remaining > 0 else { return }
            remaining -= 1
            throw ClassificationUnavailable()
        }
    }

    private actor SuspendedCloseDelivery {
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func suspend() async {
            started = true
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func waitUntilStarted() async {
            while !started {
                await Task.yield()
            }
        }

        func release() {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private func execution(
        agentKey: String = "spiffe://example.test/agent/node-1",
        deadline: Date = Date().addingTimeInterval(60)
    ) -> VMCommandExecution {
        VMCommandExecution(
            vmID: UUID(), actorID: UUID(), agentKey: agentKey, deadline: deadline)
    }

    private func auditEvents(
        ofType type: String,
        on app: Application
    ) async throws -> [AuditEvent] {
        await app.audit.flush()
        return try await AuditEvent.query(on: app.db)
            .filter(\.$eventType == type)
            .sort(\.$createdAt)
            .all()
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

            let completion = try #require(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).first)
            #expect(completion.resourceType == "vms")
            #expect(completion.resourceID == execution.vmID.uuidString)
            #expect(completion.metadata?["argv"] == "[\"/bin/sh\",\"-c\",\"printf test\"]")
            #expect(completion.metadata?["outcome"] == "exited")
            #expect(completion.metadata?["exitCode"] == "7")

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

    @Test("a timeout sweep compacts an exit whose persistence is still retrying")
    func retriesCompletedResultPersistence() async throws {
        try await withTestApp { app in
            let attempts = FailFirstAttempt()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforePersistResult: { try await attempts.run() },
                retryDelay: .milliseconds(100))
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
            let timedOut = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(timedOut.status == .failed)
            #expect(timedOut.error == "Command execution timed out")
            #expect(timedOut.timedOutBySweeper)

            for _ in 0..<200 {
                if try await VMCommandExecution.find(id, on: app.db)?.status == .succeeded {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(payload.stdout?.isEmpty == true)
            #expect(payload.exitCode == 0)
            #expect(payload.truncated == true)
            #expect(await attempts.count() >= 2)
        }
    }

    @Test("a duplicate close cannot replace an exit whose persistence is retrying")
    func duplicateCloseCannotReplacePendingExit() async throws {
        try await withTestApp { app in
            let attempts = FailFirstAttempt()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforePersistResult: { try await attempts.run() },
                retryDelay: .milliseconds(100))
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 23))
            #expect(
                await service.handleClosed(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    reason: "duplicate terminal frame"))

            let pending = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(pending.status == .pending)
            #expect(pending.error == nil)
            #expect(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).isEmpty)

            for _ in 0..<100 {
                if try await VMCommandExecution.find(id, on: app.db)?.status == .succeeded {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(payload.exitCode == 23)
            let events = try await self.auditEvents(
                ofType: "vm.command.completed", on: app)
            #expect(events.count == 1)
            #expect(events.first?.metadata?["outcome"] == "exited")
            #expect(events.first?.metadata?["exitCode"] == "23")
        }
    }

    @Test("a timeout sheds captured output and a late owner exit corrects it once")
    func lateExitCorrectsSweptTimeout() async throws {
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
                    stream: "stdout", data: Data("late result".utf8)))
            await service.sweepStuck()

            let timedOut = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(timedOut.status == .failed)
            #expect(timedOut.error == "Command execution timed out")
            let timeoutEvents = try await self.auditEvents(
                ofType: "vm.command.completed", on: app)
            #expect(timeoutEvents.count == 1)
            #expect(timeoutEvents.first?.metadata?["outcome"] == "timed_out")
            #expect(
                !(await service.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    stream: "stdout",
                    data: Data("must be discarded".utf8))))
            #expect(
                !(await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: "spiffe://example.test/agent/impostor",
                    exitCode: 99)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey, exitCode: 0))
            #expect(
                !(await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0)))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(stored.error == nil)
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(payload.command == ["/usr/bin/sleep", "600"])
            #expect(payload.stdout?.isEmpty == true)
            #expect(payload.stderr?.isEmpty == true)
            #expect(payload.exitCode == 0)
            #expect(payload.truncated == true)
            let completionEvents = try await self.auditEvents(
                ofType: "vm.command.completed", on: app)
            #expect(completionEvents.count == 2)
            #expect(completionEvents.last?.metadata?["outcome"] == "exited")
            #expect(completionEvents.last?.metadata?["correctsOutcome"] == "timed_out")
        }
    }

    @Test("migration backfill preserves late correction for pre-marker timeout rows")
    func migrationBackfillPreservesLegacyTimeoutCorrection() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/sleep", "600"], on: app.db)
            let id = try execution.requireID()
            execution.status = .failed
            execution.error = AddVMGuestExecutionAudit.historicalTimeoutReason
            execution.completedAt = Date()
            execution.timedOutBySweeper = false
            try await execution.update(on: app.db)

            try await AddVMGuestExecutionAudit.backfillLegacyTimeouts(on: app.db)
            let backfilled = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(backfilled.timedOutBySweeper)
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))

            let corrected = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(corrected.status == .succeeded)
            #expect(payload.stdout?.isEmpty == true)
            #expect(payload.truncated == true)
            let events = try await self.auditEvents(ofType: "vm.command.completed", on: app)
            #expect(events.count == 1)
            #expect(events.first?.metadata?["outcome"] == "exited")
            #expect(events.first?.metadata?["correctsOutcome"] == "timed_out")
        }
    }

    @Test("a timeout fact is appended before a close send can provoke its correction")
    func timeoutFactPrecedesCorrectionDuringSuspendedCloseSend() async throws {
        try await withTestApp { app in
            let delivery = SuspendedCloseDelivery()
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { envelope, _ in
                    if envelope.type == .guestExecClose {
                        await delivery.suspend()
                    }
                })
            app.vmCommandExecutionService = service
            let timeoutAt = Date()
            let execution = execution(deadline: timeoutAt.addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            let sweep = Task { await service.sweepStuck(now: timeoutAt) }
            await delivery.waitUntilStarted()

            let timeoutEvents = try await self.auditEvents(
                ofType: "vm.command.completed", on: app)
            #expect(timeoutEvents.count == 1)
            #expect(timeoutEvents.first?.metadata?["outcome"] == "timed_out")

            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))
            let orderedEvents = try await self.auditEvents(
                ofType: "vm.command.completed", on: app)
            #expect(orderedEvents.count == 2)
            #expect(orderedEvents[0].metadata?["outcome"] == "timed_out")
            #expect(orderedEvents[1].metadata?["outcome"] == "exited")
            #expect(orderedEvents[1].metadata?["correctsOutcome"] == "timed_out")

            await delivery.release()
            await sweep.value
        }
    }

    @Test("durable timestamps sort a paused timeout before its earlier-recorded correction")
    func durableTimestampsPreserveCrossReplicaCorrectionOrder() async throws {
        try await withTestApp { app in
            let pause = SuspendedCloseDelivery()
            let owner = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            let timeoutReplica = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                afterTimeoutCommitBeforeAudit: { await pause.suspend() })
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await owner.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            let timeoutSweep = Task { await timeoutReplica.sweepStuck() }
            await pause.waitUntilStarted()

            #expect(
                await owner.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))
            let correctionFirst = try await self.auditEvents(
                ofType: "vm.command.completed", on: app)
            #expect(correctionFirst.count == 1)
            #expect(correctionFirst.first?.metadata?["outcome"] == "exited")
            #expect(correctionFirst.first?.metadata?["correctsOutcome"] == "timed_out")

            await pause.release()
            await timeoutSweep.value
            let causallySorted = try await self.auditEvents(
                ofType: "vm.command.completed", on: app)
            #expect(causallySorted.count == 2)
            #expect(causallySorted[0].metadata?["outcome"] == "timed_out")
            #expect(causallySorted[1].metadata?["outcome"] == "exited")
            let timeoutTimestamp = try #require(causallySorted[0].createdAt)
            let correctionTimestamp = try #require(causallySorted[1].createdAt)
            #expect(timeoutTimestamp < correctionTimestamp)
        }
    }

    @Test("an owning-agent start after the timeout claim can still correct it")
    func lateStartAndExitCorrectSweptTimeout() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            await service.sweepStuck()
            let timedOut = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(timedOut.status == .failed)

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey))
            #expect(
                !(await service.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    stream: "stdout",
                    data: Data("not retained after timeout".utf8))))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))

            let corrected = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(corrected.status == .succeeded)
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(payload.stdout?.isEmpty == true)
            #expect(payload.truncated == true)
            let events = try await self.auditEvents(ofType: "vm.command.completed", on: app)
            #expect(events.count == 2)
            #expect(events[0].metadata?["outcome"] == "timed_out")
            #expect(events[1].metadata?["outcome"] == "exited")
            #expect(events[1].metadata?["correctsOutcome"] == "timed_out")
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
            let completion = try #require(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).first)
            #expect(completion.metadata?["outcome"] == "failed")
            #expect(completion.metadata?["reason"] == "guest agent unavailable")
        }
    }

    @Test("stored failure reasons are bounded by Unicode scalars")
    func failureReasonUsesScalarBound() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/false"], on: app.db)
            let id = try execution.requireID()
            let combiningGrapheme = "e\u{301}"
            let oversizedReason = String(
                repeating: combiningGrapheme,
                count: Validate.textLength)

            #expect(
                await service.handleClosed(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    reason: oversizedReason))

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let storedReason = try #require(stored.error)
            #expect(stored.status == .failed)
            #expect(Validate.length(storedReason) == Validate.textLength)
            #expect(
                storedReason
                    == String(
                        repeating: combiningGrapheme,
                        count: Validate.textLength / 2))
        }
    }

    @Test("an arbitrarily late exit remains correctable without retaining captured output")
    func arbitrarilyLateTimeoutCorrectionUsesDurableState() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let timeoutAt = Date()
            let execution = execution(deadline: timeoutAt.addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/sleep", "600"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            await service.sweepStuck(now: timeoutAt)
            await service.sweepStuck(
                now: timeoutAt.addingTimeInterval(365 * 24 * 60 * 60))

            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))
            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(stored.error == nil)
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(payload.stdout?.isEmpty == true)
            #expect(payload.truncated == true)
            let completionEvents = try await self.auditEvents(
                ofType: "vm.command.completed", on: app)
            #expect(completionEvents.count == 2)
            #expect(completionEvents[0].metadata?["outcome"] == "timed_out")
            #expect(completionEvents[1].metadata?["outcome"] == "exited")
            #expect(completionEvents[1].metadata?["correctsOutcome"] == "timed_out")
        }
    }

    @Test("a process-restart-shaped late exit corrects a durable timeout")
    func noCaptureLateExitCorrectsAfterServiceReplacement() async throws {
        try await withTestApp { app in
            let initial = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = initial
            let execution = execution(deadline: Date().addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            await initial.sweepStuck()
            let restarted = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = restarted
            #expect(
                await restarted.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 17))

            let corrected = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(corrected.status == .succeeded)
            #expect(payload.exitCode == 17)
            #expect(payload.stdout?.isEmpty == true)
            #expect(payload.truncated == true)
            let events = try await self.auditEvents(ofType: "vm.command.completed", on: app)
            #expect(events.count == 2)
            #expect(events[0].metadata?["outcome"] == "timed_out")
            #expect(events[1].metadata?["outcome"] == "exited")
            #expect(events[1].metadata?["correctsOutcome"] == "timed_out")
        }
    }

    @Test("a local sweep sheds an expired provisional capture after a remote timeout claim")
    func localSweepShedsCaptureWhenRemoteReplicaClaimedTimeout() async throws {
        try await withTestApp { app in
            let timeoutAt = Date()
            let local = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforeClassifyStart: { throw ClassificationUnavailable() },
                retryDelay: .seconds(30))
            let execution = execution(deadline: timeoutAt.addingTimeInterval(-1))
            try await execution.create(command: ["/usr/bin/printf", "discarded"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await local.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await local.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    stream: "stdout",
                    data: Data("local capture".utf8)))

            let remote = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            await remote.sweepStuck(now: timeoutAt)
            #expect(
                await local.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    stream: "stdout",
                    data: Data("still local".utf8)))

            await local.sweepStuck(
                now: timeoutAt.addingTimeInterval(
                    VMCommandExecutionService.completionBudget + 1))
            #expect(
                !(await local.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    stream: "stdout",
                    data: Data("must not be retained".utf8))))
            #expect(
                await local.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))

            let corrected = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(corrected.status == .succeeded)
            #expect(payload.stdout?.isEmpty == true)
            #expect(payload.truncated == true)
            let events = try await self.auditEvents(ofType: "vm.command.completed", on: app)
            #expect(events.count == 2)
            #expect(events[0].metadata?["outcome"] == "timed_out")
            #expect(events[1].metadata?["outcome"] == "exited")
            #expect(events[1].metadata?["correctsOutcome"] == "timed_out")
        }
    }

    @Test("database outage capture and retry state is bounded under forged UUID load")
    func databaseOutageStateIsBounded() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforeClassifyStart: { throw ClassificationUnavailable() },
                beforePersistResult: { throw ClassificationUnavailable() },
                retryDelay: .seconds(30))
            let agent = "spiffe://example.test/agent/forged-source"
            let overflow = 20
            let ids = (0..<(VMCommandExecutionService.maxBufferedExecutions + overflow)).map {
                _ in UUID()
            }

            for id in ids {
                #expect(
                    await service.handleStarted(
                        sessionId: id.uuidString,
                        fromAgentKey: agent))
            }
            var stats = await service.bufferStats()
            #expect(stats.states == VMCommandExecutionService.maxBufferedExecutions)
            #expect(stats.discardedStates == overflow)
            #expect(stats.stateShedTotal == overflow)

            let fullChunk = Data(repeating: 65, count: VMCommandExecutionService.outputLimitBytes)
            let outputAttempts =
                VMCommandExecutionService.aggregateOutputLimitBytes
                / VMCommandExecutionService.outputLimitBytes + 1
            for id in ids.prefix(outputAttempts) {
                #expect(
                    await service.handleOutput(
                        sessionId: id.uuidString,
                        fromAgentKey: agent,
                        stream: "stdout",
                        data: fullChunk))
            }
            stats = await service.bufferStats()
            #expect(stats.capturedBytes == VMCommandExecutionService.aggregateOutputLimitBytes)
            #expect(stats.outputShedTotal == 1)

            for id in ids.suffix(overflow) {
                #expect(
                    await service.handleExit(
                        sessionId: id.uuidString,
                        fromAgentKey: agent,
                        exitCode: 0))
            }
            stats = await service.bufferStats()
            #expect(stats.states == VMCommandExecutionService.maxBufferedExecutions)
            #expect(stats.discardedStates == 0)
            #expect(stats.stateShedTotal == overflow * 2)
        }
    }

    @Test("capacity-shed output is discarded without terminating the durable command")
    func capacityShedOutputRemainsOwnedByCommandService() async throws {
        try await withTestApp { app in
            let classificationFailures = ClassificationFailureBudget(
                VMCommandExecutionService.maxBufferedExecutions)
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforeClassifyStart: { try await classificationFailures.run() },
                retryDelay: .seconds(30))
            app.vmCommandExecutionService = service
            let agent = "spiffe://example.test/agent/node-1"
            for _ in 0..<VMCommandExecutionService.maxBufferedExecutions {
                #expect(
                    await service.handleStarted(
                        sessionId: UUID().uuidString,
                        fromAgentKey: agent))
            }

            let execution = execution(agentKey: agent)
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()
            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: agent))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: agent,
                    stream: "stdout",
                    data: Data("discarded under pressure".utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: agent,
                    exitCode: 0))

            let completed = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(completed.status == .succeeded)
            #expect(payload.stdout?.isEmpty == true)
            #expect(payload.truncated == true)
            let events = try await self.auditEvents(ofType: "vm.command.completed", on: app)
            #expect(events.count == 1)
            #expect(events.first?.metadata?["outcome"] == "exited")
        }
    }

    @Test("a wrong-agent provisional capture cannot poison the owning agent's frames")
    func wrongAgentCannotCompleteProvisionalCapture() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforeClassifyStart: { throw ClassificationUnavailable() },
                retryDelay: .seconds(30))
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/id"], on: app.db)
            let id = try execution.requireID()
            let impostor = "spiffe://example.test/agent/impostor"

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: impostor))

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    stream: "stdout",
                    data: Data("owner result".utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))
            let completed = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(completed.status == .succeeded)
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(String(decoding: payload.stdout ?? Data(), as: UTF8.self) == "owner result")
            #expect(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).count == 1)

            #expect(
                await service.handleExit(
                    sessionId: id.uuidString, fromAgentKey: impostor, exitCode: 99))
            #expect(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).count == 1)
        }
    }

    @Test("a provisional capture cannot let the wrong agent forge a closure")
    func wrongAgentCannotFailProvisionalCapture() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(
                app: app,
                sendEnvelope: { _, _ in },
                beforeClassifyStart: { throw ClassificationUnavailable() },
                retryDelay: .seconds(30))
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/id"], on: app.db)
            let id = try execution.requireID()
            let impostor = "spiffe://example.test/agent/impostor"

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: impostor))
            #expect(
                await service.handleClosed(
                    sessionId: id.uuidString,
                    fromAgentKey: impostor,
                    reason: "forged closure"))

            let stillPending = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(stillPending.status == .pending)
            #expect(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).isEmpty)

            #expect(
                await service.handleClosed(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    reason: "guest refused command"))
            let failed = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(failed.status == .failed)
            #expect(failed.error == "guest refused command")
            #expect(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).count == 1)
        }
    }

    @Test("an agent failure reason that looks like a timeout cannot forge a correction")
    func timeoutLookingAgentFailureIsNotCorrectable() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/false"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleClosed(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    reason: VMCommandExecutionService.timeoutReason))
            let failed = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(failed.status == .failed)
            #expect(failed.error == VMCommandExecutionService.timeoutReason)
            #expect(!failed.timedOutBySweeper)

            #expect(
                !(await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey)))
            #expect(
                !(await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0)))

            let stillFailed = try #require(try await VMCommandExecution.find(id, on: app.db))
            #expect(stillFailed.status == .failed)
            #expect(!stillFailed.timedOutBySweeper)
            let events = try await self.auditEvents(ofType: "vm.command.completed", on: app)
            #expect(events.count == 1)
            #expect(events.first?.metadata?["outcome"] == "failed")
            #expect(events.first?.metadata?["correctsOutcome"] == nil)
        }
    }

    @Test("duplicate terminal frames append one completion fact")
    func duplicateTerminalFramesDoNotDuplicateAudit() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))
            #expect(
                !(await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0)))
            #expect(
                !(await service.handleClosed(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    reason: "duplicate terminal frame")))

            let events = try await self.auditEvents(ofType: "vm.command.completed", on: app)
            #expect(events.count == 1)
            #expect(events.first?.metadata?["outcome"] == "exited")
        }
    }

    @Test("captured output never enters completion audit metadata")
    func capturedOutputIsExcludedFromAuditMetadata() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/printf", "safe argv"], on: app.db)
            let id = try execution.requireID()
            let stdoutSentinel = "STR84_STDOUT_MUST_NOT_BE_AUDITED"
            let stderrSentinel = "STR84_STDERR_MUST_NOT_BE_AUDITED"

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    stream: "stdout",
                    data: Data(stdoutSentinel.utf8)))
            #expect(
                await service.handleOutput(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    stream: "stderr",
                    data: Data(stderrSentinel.utf8)))
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))

            let event = try #require(
                try await self.auditEvents(ofType: "vm.command.completed", on: app).first)
            let values = try #require(event.metadata).values
            #expect(!values.contains(stdoutSentinel))
            #expect(!values.contains(stderrSentinel))
        }
    }

    @Test("audit persistence failure cannot roll back command completion")
    func auditPersistenceFailureIsFailOpen() async throws {
        try await withTestApp { app in
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            app.vmCommandExecutionService = service
            let execution = execution()
            try await execution.create(command: ["/usr/bin/true"], on: app.db)
            let id = try execution.requireID()

            #expect(
                await service.handleStarted(
                    sessionId: id.uuidString, fromAgentKey: execution.agentKey))
            try await app.db.schema(AuditEvent.schema).delete()
            #expect(
                await service.handleExit(
                    sessionId: id.uuidString,
                    fromAgentKey: execution.agentKey,
                    exitCode: 0))
            await app.audit.flush()

            let stored = try #require(try await VMCommandExecution.find(id, on: app.db))
            let payload = try #require(try await VMCommandPayload.find(id, on: app.db))
            #expect(stored.status == .succeeded)
            #expect(payload.exitCode == 0)
        }
    }
}
