import Foundation
import Synchronization
import Testing
import Vapor
@testable import App

private actor MaintenanceTickBarrier {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func tick() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Guest exec renewal lifecycle", .timeLimit(.minutes(1)))
struct GuestExecSessionMaintenanceLifecycleTests {
    @Test("The lifecycle handler arms at boot and cancels before application teardown")
    func handlerTracksLoop() async throws {
        let app = try await Application.make(.testing)
        let handler = GuestExecSessionMaintenanceLifecycleHandler()
        #expect(app.guestExecSessionMaintenanceIfCreated == nil)
        try await handler.didBootAsync(app)
        let loop = try #require(app.guestExecSessionMaintenanceIfCreated)
        #expect(await loop.isActive)
        await handler.shutdownAsync(app)
        #expect(await !loop.isActive)
        try await app.asyncShutdown()
    }

    @Test("Shutdown joins an in-flight renewal and refuses to restart")
    func shutdownJoinsTick() async throws {
        let app = try await Application.make(.testing)
        let barrier = MaintenanceTickBarrier()
        let loop = GuestExecSessionMaintenanceLoop(
            app: app, interval: .milliseconds(1), maintain: { await barrier.tick() })
        await loop.start()
        while await !barrier.started { await Task.yield() }
        let stopped = Mutex(false)
        let shutdown = Task {
            await loop.shutdown(); stopped.withLock { $0 = true }
        }
        while await !loop.isShutDown { await Task.yield() }
        #expect(!stopped.withLock { $0 })
        await barrier.release()
        await shutdown.value
        #expect(await !loop.isActive)
        await loop.start()
        #expect(await !loop.isActive)
        try await app.asyncShutdown()
    }

    @Test("A renewal loop created after application shutdown remains disarmed")
    func postShutdownStaysDisarmed() async throws {
        let app = try await Application.make(.testing)
        try await app.asyncShutdown()
        let calls = Mutex(0)
        let loop = GuestExecSessionMaintenanceLoop(
            app: app, interval: .milliseconds(1), maintain: { calls.withLock { $0 += 1 } })
        await loop.start()
        #expect(await !loop.isActive)
        #expect(calls.withLock { $0 } == 0)
        await loop.shutdown()
    }
}
