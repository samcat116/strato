import Fluent
import Foundation
import MetricsTestKit
import Testing

import AppTestSupport
@testable import App

@Suite("Cluster clock", .serialized)
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

    @Test("durable clock interfaces cannot regain Date defaults")
    func noReplicaClockDefaultsInDurableInterfaces() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let files = [
            "Models/ResourceConditions.swift",
            "Models/Sandbox.swift",
            "Models/SnapshotArtifact.swift",
            "Services/AgentMaintenanceLoop.swift",
            "Services/ResourceMutation.swift",
            "Services/WorkloadObservedMerge.swift",
            "Services/Sweeps/AgentAutoUpdateSweep.swift",
            "Services/Sweeps/OrphanedTerminatingSweep.swift",
            "Services/VMCommandExecutionService.swift",
            "Services/Sweeps/SandboxExpirySweep.swift",
            "Services/Sweeps/StrandedVolumeAttachmentSweep.swift",
            "Services/SnapshotRetentionSweep.swift",
        ]
        let forbidden = [
            "from now: Date = Date()",
            "at now: Date = Date()",
            "at date: Date = Date()",
            "receivedAt: Date = Date()",
            "sweepStuck(now: Date",
            "overdueForConvergence(at now: Date",
            "expired(at now: Date",
            "let now = Date()",
            "resourceTelemetryReceivedAt = Date()",
        ]

        for file in files {
            let source = try String(
                contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for pattern in forbidden {
                #expect(!source.contains(pattern), "\(file) contains forbidden durable clock pattern \(pattern)")
            }
        }

        let agentSource = try String(
            contentsOf: sources.appendingPathComponent("Models/Agent.swift"), encoding: .utf8)
        #expect(!agentSource.contains("receivedAt: Date = Date()"))
        #expect(!agentSource.contains("Date().timeIntervalSince(lastHeartbeat)"))
        #expect(!agentSource.contains("var isOnline: Bool"))
        #expect(!agentSource.contains("func dependencyAllows(_ capability: NodeCapability, at now: Date"))
        #expect(!agentSource.contains("var supportedHypervisors:"))
        #expect(!agentSource.contains("var supportsInterVMNetworking:"))
        #expect(!agentSource.contains("var effectiveSandboxNetworkingCapable:"))
        #expect(!agentSource.contains("var effectiveResolverCapable:"))
        #expect(
            !agentSource.contains(
                "func supportsSnapshotArtifact(_ kind: SnapshotArtifactKind) -> Bool"))

        for file in [
            "Controllers/StorageDeviceController.swift",
            "Services/SiteNetworkAuthority.swift",
        ] {
            let source = try String(
                contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            #expect(!source.contains("now: Date = Date()"))
        }

        let clusterClockSource = try String(
            contentsOf: sources.appendingPathComponent("Services/ClusterClock.swift"),
            encoding: .utf8)
        #expect(clusterClockSource.contains("SELECT clock_timestamp() AS database_time"))
        #expect(!clusterClockSource.contains("SELECT now() AS database_time"))
    }
}
