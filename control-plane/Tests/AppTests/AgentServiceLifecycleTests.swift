import Testing
import Vapor
import Fluent
import VaporTesting
@testable import App

/// Regression test for the "Core not configured" crash: `AgentService` starts a
/// detached heartbeat/reconciliation loop that polls `app.db` every 30s. Without a
/// shutdown hook the loop outlives the app and faults when the timer next fires after
/// teardown — harmless as a production process exits, but a crash in the test suite,
/// where CI runs long enough for the timer to fire mid-run against a shut-down app.
@Suite("AgentService lifecycle", .serialized)
final class AgentServiceLifecycleTests {

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
}
