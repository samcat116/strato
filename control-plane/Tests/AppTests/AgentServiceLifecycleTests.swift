import Testing
import Vapor
import Fluent
import StratoShared
import VaporTesting
@testable import App

/// Regression test for the "Core not configured" crash: `AgentService` starts a
/// detached heartbeat/reconciliation loop that polls `app.db` every 30s. Without a
/// shutdown hook the loop outlives the app and faults when the timer next fires after
/// teardown — harmless as a production process exits, but a crash in the test suite,
/// where CI runs long enough for the timer to fire mid-run against a shut-down app.
@Suite("AgentService lifecycle", .serialized)
final class AgentServiceLifecycleTests {

    @Test("heartbeat monitor durably marks stale agents offline")
    func heartbeatMonitorMarksStaleAgentsOffline() async throws {
        try await withTestApp { app in
            let agent = Agent(
                name: "stale-agent",
                hostname: "stale-agent.example",
                version: "1.0.0",
                capabilities: ["qemu"],
                status: .online,
                resources: AgentResources(
                    totalCPU: 8,
                    availableCPU: 8,
                    totalMemory: 16_000_000_000,
                    availableMemory: 16_000_000_000,
                    totalDisk: 100_000_000_000,
                    availableDisk: 100_000_000_000),
                lastHeartbeat: Date().addingTimeInterval(-120))
            try await agent.save(on: app.db)

            await app.agentService.checkStaleAgents()

            let persisted = try #require(try await Agent.find(agent.id, on: app.db))
            #expect(persisted.status == .offline)
        }
    }

    @Test("app shutdown cancels the AgentService heartbeat loop")
    func shutdownCancelsHeartbeat() async throws {
        let app = try await Application.makeForTesting()
        // Assigned once the DB is up (AgentService.init touches `app.db`); held so the
        // actor can be inspected after the app is torn down.
        let service: AgentService

        do {
            try await configure(app)
            try await app.autoMigrate()

            service = app.agentService

            // The loop is armed from AgentService.init's detached task; give it a
            // moment to run so the assertion isn't racing initialization.
            for _ in 0..<50 where await !service.isHeartbeatActive {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await service.isHeartbeatActive)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        // asyncShutdown runs the registered AgentServiceLifecycleHandler, which must
        // cancel the loop before `app.core` is torn down.
        try await app.shutdownForTesting()

        #expect(await !service.isHeartbeatActive)
    }

    /// Cancellation alone is not enough: a tick that already woke from its sleep
    /// keeps sweeping the database after `cancel()`, and if the application tears
    /// down underneath it, `app.db` faults with "Core not configured" (the CI
    /// crash in `checkStaleAgents`). `shutdown()` must therefore *await* the
    /// loop's exit. A millisecond interval keeps a tick in flight essentially
    /// always, so shutting down here races the loop body rather than the sleep —
    /// without the await, this test crashes the process at teardown.
    @Test("shutdown waits for an in-flight heartbeat tick before app teardown")
    func shutdownAwaitsInFlightTick() async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let service = AgentService(app: app, heartbeatInterval: .milliseconds(1))

            // Let the startup task arm the loop and run a few ticks so shutdown
            // lands mid-tick, not before the first one.
            for _ in 0..<50 where await !service.isHeartbeatActive {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await service.isHeartbeatActive)
            try await Task.sleep(for: .milliseconds(50))

            // Must not return until the loop has fully exited.
            await service.shutdown()
            #expect(await !service.isHeartbeatActive)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        // If shutdown() returned with the tick still running, this teardown
        // clears app storage under it and the process fatal-errors.
        try await app.shutdownForTesting()
    }

    /// The lifecycle handler only shuts down the service instance that exists
    /// at shutdown time. `Application.agentService` is a lazy getter, so a
    /// stray late caller — a detached request/socket task running after
    /// `asyncShutdown` cleared storage — creates a *fresh* service on the dead
    /// app that nothing will ever shut down. Its heartbeat must refuse to arm:
    /// an armed tick touching `app.db` after core teardown is the recurring
    /// "Core not configured" CI crash.
    @Test("a service created after app shutdown never arms its heartbeat")
    func postShutdownServiceStaysDisarmed() async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()

        // Simulate the stray late caller. A millisecond interval means an
        // armed loop would tick (and crash the process) within the wait below.
        let resurrected = AgentService(app: app, heartbeatInterval: .milliseconds(1))

        // Give the init's arming task ample time to run; the guard must have
        // kept the loop disarmed.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !resurrected.isHeartbeatActive)
    }
}
