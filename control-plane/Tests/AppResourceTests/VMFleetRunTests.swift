import Fluent
import Foundation
import StratoShared
import Testing
import Vapor
import AppTestSupport
@testable import App

@Suite("Fleet run durability and bounds", .serialized, .postgresFixture)
struct VMFleetRunTests {
    private actor Deliveries {
        var ids: [String] = []
        func record(_ message: GuestExecStartMessage) { ids.append(message.sessionId) }
        func count() -> Int { ids.count }
    }

    private func queuedFleet(count: Int, on app: Application) async throws -> VMFleetRun {
        var entries: [VMFleetEntry] = []
        for _ in 0..<count {
            let execution = VMCommandExecution(
                vmID: UUID(), actorID: UUID(), agentKey: "test-agent",
                deadline: Date().addingTimeInterval(7200))
            try await app.db.transaction { db in try await execution.create(command: ["/usr/bin/id"], on: db) }
            entries.append(VMFleetEntry(vmID: execution.vmID, state: "queued", operationID: try execution.requireID()))
        }
        let fleet = VMFleetRun(
            actorID: UUID(), apiKeyID: nil, command: ["/usr/bin/id"], entries: entries,
            deadline: Date().addingTimeInterval(7200))
        fleet.confirmed = true
        try await fleet.create(on: app.db)
        return fleet
    }

    @Test("Malformed or broad selectors never widen resolution")
    func selectorsFailClosed() throws {
        for selector in [
            "", "environment=production", "tag:role=web", "project=bad", "all=true", "ids=", "ids=bad",
            "project=\(UUID()),project=\(UUID())", "project=\(UUID()),", "ids=\(UUID()),environment=prod",
        ] {
            #expect(throws: Abort.self) { try VMFleetSelector(selector) }
        }
        let id = UUID()
        #expect(throws: Abort.self) { try VMFleetSelector("ids=\(id);\(id)") }
        let parsed = try VMFleetSelector("project=\(id),environment=prod,tag:role=web")
        #expect(parsed.projectID == id)
        #expect(parsed.environment == "prod")
        #expect(parsed.tag?.0 == "role")
        #expect(parsed.tag?.1 == "web")
    }

    @Test("Concurrent workers cap active children and repeated advances do not replay")
    func concurrentClaimsAndSlots() async throws {
        try await withTestApp { app in
            let fleet = try await queuedFleet(count: 12, on: app)
            let id = try fleet.requireID()
            let deliveries = Deliveries()
            async let first: Void = VMFleetRunDispatcher.advance(
                id: id, app: app, deliver: { message, _ in await deliveries.record(message) })
            async let second: Void = VMFleetRunDispatcher.advance(
                id: id, app: app, deliver: { message, _ in await deliveries.record(message) })
            _ = try await (first, second)
            #expect(await deliveries.count() == 8)
            try await VMFleetRunDispatcher.advance(
                id: id, app: app, deliver: { message, _ in await deliveries.record(message) })
            #expect(await deliveries.count() == 8)
            let stored = try #require(try await VMFleetRun.find(id, on: app.db))
            let active = try #require(stored.entries.first { $0.state == "dispatched" }?.operationID)
            await app.vmCommandExecutionService.markDispatchFailed(id: active, reason: "Injected failure")
            try await VMFleetRunDispatcher.advance(
                id: id, app: app, deliver: { message, _ in await deliveries.record(message) })
            #expect(await deliveries.count() == 9)
        }
    }

    @Test(
        "Interrupted or uncertain delivery stays claimed and never replays after a worker restart",
        arguments: [true, false])
    func interruptionDoesNotReplay(uncertain: Bool) async throws {
        try await withTestApp { app in
            let fleet = try await queuedFleet(count: 2, on: app)
            let id = try fleet.requireID()
            try await VMFleetRunDispatcher.advance(
                id: id, app: app,
                deliver: { _, _ in
                    if uncertain { throw ReplicaMessageBridge.DeliveryError.timedOut }
                    throw CancellationError()
                })
            let deliveries = Deliveries()
            try await VMFleetRunDispatcher.advance(
                id: id, app: app, deliver: { message, _ in await deliveries.record(message) })
            #expect(await deliveries.count() == 0)
            let stored = try #require(try await VMFleetRun.find(id, on: app.db))
            #expect(stored.entries.allSatisfy { $0.state == "dispatched" })
            #expect(try await VMCommandExecution.query(on: app.db).filter(\.$status == .pending).count() == 2)
        }
    }

    @Test("Expired queue becomes collected failures without any dispatch")
    func expiredQueueFailsClosed() async throws {
        try await withTestApp { app in
            let fleet = try await queuedFleet(count: 3, on: app)
            fleet.deadline = Date.distantPast
            try await fleet.save(on: app.db)
            let deliveries = Deliveries()
            try await VMFleetRunDispatcher.advance(
                id: fleet.requireID(), app: app, deliver: { message, _ in await deliveries.record(message) })
            #expect(await deliveries.count() == 0)
            let stored = try #require(try await VMFleetRun.find(fleet.requireID(), on: app.db))
            #expect(stored.entries.allSatisfy { $0.state == "skipped" })
            let response = try await VMFleetRunController().response(stored, on: app.db)
            #expect(response.complete)
            #expect(response.operations.count == 3)
            #expect(response.operations.allSatisfy { $0.status == .failed && $0.result?.exitCode == nil })
        }
    }
    @Test("Fleet polls collect exit codes with bounded excerpts while child output remains intact")
    func boundedCollectedOutput() async throws {
        try await withTestApp { app in
            let fleet = try await queuedFleet(count: 1, on: app)
            let executionID = try #require(fleet.entries.first?.operationID)
            let execution = try #require(try await VMCommandExecution.find(executionID, on: app.db))
            let service = VMCommandExecutionService(app: app, sendEnvelope: { _, _ in })
            #expect(await service.handleStarted(sessionId: executionID.uuidString, fromAgentKey: execution.agentKey))
            #expect(
                await service.handleOutput(
                    sessionId: executionID.uuidString, fromAgentKey: execution.agentKey,
                    stream: "stdout", data: Data(repeating: 65, count: 5000)))
            #expect(
                await service.handleExit(
                    sessionId: executionID.uuidString, fromAgentKey: execution.agentKey, exitCode: 7))
            fleet.entries[0].state = "dispatched"
            try await fleet.save(on: app.db)
            let result = try await VMFleetRunController().response(fleet, on: app.db)
            #expect(result.complete)
            #expect(result.operations.first?.result?.stdout.utf8.count == 4096)
            #expect(result.operations.first?.result?.exitCode == 7)
            #expect(result.operations.first?.result?.truncated == true)
            let stored = try #require(try await VMCommandExecution.find(executionID, on: app.db))
            let child = try await stored.operationResponse(on: app.db)
            #expect(child.result?.stdout.utf8.count == 5000)
            #expect(child.result?.truncated == false)
        }
    }

}
