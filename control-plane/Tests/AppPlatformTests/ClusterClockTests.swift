import Fluent
import Foundation
import MetricsTestKit
import Testing

import AppTestSupport
@testable import App

@Suite("Cluster clock", .serialized, .postgresFixture)
struct ClusterClockTests {
    @Test("reads advance inside an existing transaction")
    func readsAdvanceInsideTransaction() async throws {
        try await withTestApp { app in
            try await app.db.transaction { db in
                let first = try await ClusterClock.read(on: db)
                try await Task.sleep(for: .milliseconds(150))
                let second = try await ClusterClock.read(on: db)

                // PostgreSQL `now()` would return the transaction-start instant
                // for both reads. Acceptance clocks must observe elapsed lock
                // waits instead.
                #expect(second.date.timeIntervalSince(first.date) >= 0.1)
            }
        }
    }

    @Test("a fast replica clock cannot expire a database-clock convergence deadline")
    func fastReplicaClockDoesNotDegradeHealthyMutation() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization(name: "Clock Org")
            let project = try await builder.createProject(
                name: "Clock Project", description: "clock regression", organization: organization)
            let vm = try await builder.createVM(name: "clock-vm", project: project)

            let databaseNow = try await ClusterClock.read(on: app.db)
            vm.desiredStatus = .running
            vm.observedGeneration = 0
            vm.setStatus(.shutdown, at: databaseNow)
            vm.convergenceDeadline = databaseNow.date.addingTimeInterval(60)
            try await vm.save(on: app.db)

            // Simulate a replica whose wall clock is two minutes fast. The
            // returned instant remains PostgreSQL time; only its measured
            // offset reflects the bad local clock.
            let fastLocalTime = databaseNow.date.addingTimeInterval(120)
            let sampled = try await ClusterClock.read(
                on: app.db, localTime: { fastLocalTime })
            #expect(sampled.localClockOffsetSeconds < -119)

            await app.agentMaintenance.sweepStuckConvergence(at: sampled)

            let survivor = try #require(await VM.find(vm.id, on: app.db))
            #expect(survivor.conditions.degraded == nil)
            #expect(survivor.convergenceDeadline != nil)
        }
    }

    @Test("the signed database clock offset is exported")
    func clockOffsetGauge() throws {
        let metrics = TestMetrics()
        Telemetry.recordControlPlaneClockOffset(seconds: -12.5, factory: metrics)

        let gauge = try metrics.expectGauge("control_plane_clock_offset_seconds")
        #expect(gauge.lastValue == -12.5)
    }
}
