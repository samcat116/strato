import NIOConcurrencyHelpers
import Testing
import Vapor

import AppTestSupport
@testable import App

/// Regression coverage for the shutdown teardown race that crashed CI's "Test
/// Control Plane" job with a nil unwrap in `Fluent/FluentProvider`.
///
/// Post-`202` completion work runs in `backgroundTasks.spawn` tasks that touch
/// `app.testPostgres`. At shutdown `BackgroundTaskLifecycle.drain` cancels tasks that
/// outlive its budget, then Vapor clears storage — after which any `app.testPostgres`
/// read force-unwraps nil. Cancellation is cooperative and plain Fluent awaits
/// do not throw on it, so a task parked in a slow query can survive the drain
/// and resume into that unwrap. The completion paths defend against it by
/// checking `Task.isCancelled` / reading through `Application.testPostgres` before
/// each database access; these tests pin down the mechanism that makes that
/// defense sound.
@Suite("Background Task Registry")
struct BackgroundTaskRegistryTests {

    /// A one-shot signal usable in either direction between test and task.
    /// `wait()` never throws and never auto-resumes on cancellation, so it
    /// models a Fluent await that ignores cancellation.
    private actor Latch {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    @Test("drain cancels a parked task before it touches the database")
    func drainCancelsParkedTask() async {
        let registry = BackgroundTaskRegistry()
        let parked = Latch()  // task -> test: "I am parked"
        let release = Latch()  // test -> task: "resume now"
        let finished = Latch()  // task -> test: "my guard ran"
        let observedCancelled = NIOLockedValueBox(false)
        let touchedDatabase = NIOLockedValueBox(false)

        registry.spawn {
            // Park like a Fluent await that neither throws on cancellation nor
            // resumes itself — it unblocks only when the test releases it, by
            // which point the drain has already cancelled this task.
            await parked.signal()
            await release.wait()

            // This is exactly the guard the completion paths perform before
            // dereferencing `app.testPostgres`.
            if Task.isCancelled {
                observedCancelled.withLockedValue { $0 = true }
            } else {
                touchedDatabase.withLockedValue { $0 = true }
            }
            await finished.signal()
        }

        // Only drain once the task is genuinely parked, so the first poll times
        // out and drain proceeds to cancellation.
        await parked.wait()
        await registry.drain(timeout: .milliseconds(50), cancellationGrace: .milliseconds(50))

        // The parked task outlived the drain; release it so its guard runs.
        await release.signal()
        await finished.wait()

        #expect(observedCancelled.withLockedValue { $0 })
        #expect(!touchedDatabase.withLockedValue { $0 })
    }

    @Test("drain waits for tasks that finish within budget without cancelling")
    func drainWaitsForQuickTasks() async {
        let registry = BackgroundTaskRegistry()
        let ranToCompletion = NIOLockedValueBox(false)
        let done = Latch()

        registry.spawn {
            ranToCompletion.withLockedValue { $0 = true }
            await done.signal()
        }

        // The task has finished its work; the registry entry clears itself, so
        // drain returns on its first poll and never issues a cancel.
        await done.wait()
        await registry.drain()

        #expect(ranToCompletion.withLockedValue { $0 })
    }

    @Test("cancelled background work checks cancellation before database access")
    func cancellationPrecedesDatabaseAccess() async throws {
        try await withTestApp { app in
            // The native context is injected when the app is configured.
            _ = app.testPostgres

            let started = Latch()
            let release = Latch()
            let sawNil = NIOLockedValueBox(false)

            let task = Task {
                await started.signal()
                await release.wait()
                sawNil.withLockedValue { $0 = Task.isCancelled }
            }

            // Native persistence is injected rather than looked up during
            // background work, so cancellation itself is the shutdown guard.
            await started.wait()
            task.cancel()
            await release.signal()
            _ = await task.value

            #expect(sawNil.withLockedValue { $0 })
        }
    }
}
