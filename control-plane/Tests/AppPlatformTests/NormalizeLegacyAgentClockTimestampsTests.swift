import Fluent
import Foundation
import Testing

import AppTestSupport
@testable import App

@Suite("Normalize legacy agent clock timestamps", .serialized)
struct NormalizeLegacyAgentClockTimestampsTests {
    @Test("future legacy receipt timestamps fail closed")
    func futureTimestampsFailClosed() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Legacy Clock Org")
            let databaseNow = try await ClusterClock.read(on: app.db)
            let past = databaseNow.date.addingTimeInterval(-30)
            let future = databaseNow.date.addingTimeInterval(120)

            let legacy = try await builder.createAgent(
                named: "legacy-future-clock",
                dependencyObservationsReceivedAt: future,
                lastHeartbeat: future,
                organizationScope: .organization(try organization.requireID()))
            legacy.resourceTelemetryReceivedAt = future
            try await legacy.save(on: app.db)

            let unaffected = try await builder.createAgent(
                named: "legacy-correct-clock",
                dependencyObservationsReceivedAt: past,
                lastHeartbeat: past,
                organizationScope: .organization(try organization.requireID()))
            try await NormalizeLegacyAgentClockTimestamps().prepare(on: app.db)

            let sampledAfterRepair = try await ClusterClock.read(on: app.db)
            let repaired = try #require(try await Agent.find(legacy.id, on: app.db))
            let unchanged = try #require(try await Agent.find(unaffected.id, on: app.db))

            let repairedHeartbeat = try #require(repaired.lastHeartbeat)
            let repairedDependencies = try #require(repaired.dependencyObservationsReceivedAt)
            let repairedTelemetry = try #require(repaired.resourceTelemetryReceivedAt)
            #expect(sampledAfterRepair.date.timeIntervalSince(repairedHeartbeat) >= 60)
            #expect(sampledAfterRepair.date.timeIntervalSince(repairedDependencies) >= 60)
            #expect(repairedTelemetry <= sampledAfterRepair.date)
            #expect(!repaired.isOnline(at: sampledAfterRepair))
            #expect(unchanged.lastHeartbeat == past)
            #expect(unchanged.dependencyObservationsReceivedAt == past)
            #expect(unchanged.resourceTelemetryReceivedAt == nil)
        }
    }
}
