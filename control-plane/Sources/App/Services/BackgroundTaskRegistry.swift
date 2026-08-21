import NIOConcurrencyHelpers
import Vapor

/// Tracks fire-and-forget background work (async VM-operation completion,
/// desired-state dispatch) so shutdown can wait for in-flight tasks instead of
/// tearing the database out from under them.
///
/// Async VM endpoints return 202 and continue in detached tasks that retain a
/// scoped database context. Registering the work here lets
/// `BackgroundTaskLifecycle` drain it before the native pool shuts down.
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
    /// short instead of outliving the native database pool.
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
        setStorageValue(BackgroundTaskRegistryKey.self, to: BackgroundTaskRegistry())
        lifecycle.use(BackgroundTaskLifecycle())
    }

}

/// Drains tracked background work during shutdown. Vapor runs lifecycle
/// handlers before the native PostgreSQL lifecycle closes its pool, so
/// in-flight tasks get to finish their database writes while it is live.
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
