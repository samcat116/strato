import Fluent
import NIOConcurrencyHelpers
import Vapor

/// Tracks fire-and-forget background work (async VM-operation completion,
/// desired-state dispatch) so shutdown can wait for in-flight tasks instead of
/// tearing the database out from under them.
///
/// Async VM endpoints return 202 and continue in detached tasks that use
/// `app.db`. If the application shuts down while one is mid-flight, the task
/// can touch Fluent after its pools closed, lazily creating a connection pool
/// that nothing ever shuts down (an assertion failure in debug builds, a
/// leaked connection in release). Registering the work here lets
/// `BackgroundTaskLifecycle` drain it — bounded by a timeout — before Fluent
/// tears down.
final class BackgroundTaskRegistry: Sendable {
    private let tasks = NIOLockedValueBox<[UUID: Task<Void, Never>]>([:])

    /// Start `operation` as a tracked background task. The entry removes
    /// itself on completion; insertion holds the lock while the task is
    /// created, so the removal (which needs the same lock) cannot lose the
    /// race against it.
    func spawn(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        tasks.withLockedValue { dict in
            let task = Task {
                await operation()
                self.tasks.withLockedValue { $0[id] = nil }
            }
            dict[id] = task
        }
    }

    /// Wait for tracked tasks to finish, giving up after `timeout` (a task
    /// stuck on a multi-minute agent-response budget must not stall
    /// shutdown). Tasks that outlive the timeout are cancelled and given
    /// `cancellationGrace` to unwind, so a long agent-response wait gets cut
    /// short instead of touching the database after Fluent tears down.
    ///
    /// Cancellation is cooperative, and plain Fluent awaits (`.find`, `.save`,
    /// `completeIfPending`) do *not* throw on cancellation — so a task parked
    /// in a slow query on an overloaded host can survive `cancel` +
    /// `cancellationGrace` and resume after storage is gone, where the next
    /// `app.db` read force-unwraps nil (`Fluent/FluentProvider.swift`). The
    /// completion paths defend against that by reading the database through
    /// ``Application/liveDB`` and re-checking `Task.isCancelled` before each
    /// access, so a drained task returns cleanly instead of crashing.
    ///
    /// Polls rather than awaiting task handles so a hung task cannot pin the
    /// drain past its deadline.
    func drain(
        timeout: Duration = .seconds(2),
        cancellationGrace: Duration = .seconds(1)
    ) async {
        if await pollUntilEmpty(for: timeout) { return }
        for task in tasks.withLockedValue({ Array($0.values) }) {
            task.cancel()
        }
        _ = await pollUntilEmpty(for: cancellationGrace)
    }

    private func pollUntilEmpty(for timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if tasks.withLockedValue({ $0.isEmpty }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return tasks.withLockedValue { $0.isEmpty }
    }
}

extension Application {
    private struct BackgroundTaskRegistryKey: StorageKey {
        typealias Value = BackgroundTaskRegistry
    }

    /// The registry is created in `configure()` before any route can spawn
    /// work; the assertion guards against storage-ordering regressions.
    var backgroundTasks: BackgroundTaskRegistry {
        guard let registry = storage[BackgroundTaskRegistryKey.self] else {
            fatalError("BackgroundTaskRegistry not configured. Configure it in configure().")
        }
        return registry
    }

    func setUpBackgroundTaskRegistry() {
        storage[BackgroundTaskRegistryKey.self] = BackgroundTaskRegistry()
        lifecycle.use(BackgroundTaskLifecycle())
    }

    /// Fluent's default database, or `nil` when the current background task has
    /// been cancelled by shutdown's drain.
    ///
    /// After `BackgroundTaskLifecycle` cancels a task that outlived the drain,
    /// Vapor clears application storage, and any later read of `app.db`
    /// force-unwraps nil (`Fluent/FluentProvider.swift`), crashing the whole
    /// process. Post-`202` completion paths capture this once before their
    /// first database access and reuse the handle: a `nil` here means
    /// "cancelled — bail", and a task already parked in a
    /// non-cancellation-throwing Fluent await resolves to a harmless thrown
    /// error on the captured handle rather than a fatal unwrap.
    ///
    /// The check is sound because `Task.isCancelled` can be true here only
    /// because `drain` issued the cancel, and `drain` issues it *before* it
    /// returns — so before Vapor clears storage. A non-nil return therefore
    /// guarantees storage is still live.
    var liveDB: (any Database)? {
        Task.isCancelled ? nil : self.db
    }
}

/// Drains tracked background work during shutdown. Vapor runs lifecycle
/// handlers before it clears application storage (where Fluent closes its
/// connection pools), so in-flight tasks get to finish their database writes
/// while the pools are still alive.
struct BackgroundTaskLifecycle: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        // Tests should prefer waiting over racing: a generous budget lets
        // in-flight completion tasks finish their writes before the pool
        // closes, so the full-suite run doesn't provoke the teardown race at
        // all. Production keeps the bounded default so a task stuck on a
        // multi-minute agent-response wait cannot stall shutdown.
        if application.environment == .testing {
            await application.backgroundTasks.drain(
                timeout: .seconds(10), cancellationGrace: .seconds(2))
        } else {
            await application.backgroundTasks.drain()
        }
    }
}
