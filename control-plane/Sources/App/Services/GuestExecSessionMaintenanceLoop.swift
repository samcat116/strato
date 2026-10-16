import Vapor

/// Keeps socket-owned leases alive independently of agent reconciliation. The
/// timer uses monotonic deadlines so a pass does not add its runtime to the
/// interval. Shutdown joins the task before application/database teardown.
actor GuestExecSessionMaintenanceLoop {
    private let app: Application
    private let interval: Duration
    private let maintain: @Sendable () async -> Void
    private var task: Task<Void, Never>?
    private(set) var isShutDown = false

    init(
        app: Application,
        interval: Duration = .seconds(10),
        maintain: (@Sendable () async -> Void)? = nil
    ) {
        self.app = app
        self.interval = interval
        self.maintain = maintain ?? { await app.guestExecSessionManager.maintainSessions() }
    }

    var isActive: Bool { task != nil }

    func start() {
        guard !isShutDown, !app.didShutdown, task == nil else { return }
        task = Task {
            let clock = ContinuousClock()
            var deadline = clock.now.advanced(by: interval)
            while !Task.isCancelled, !isShutDown, !app.didShutdown {
                do { try await clock.sleep(until: deadline) } catch { return }
                guard !Task.isCancelled, !isShutDown, !app.didShutdown else { return }
                await maintain()
                deadline = max(deadline.advanced(by: interval), clock.now)
            }
        }
    }

    func shutdown() async {
        isShutDown = true
        task?.cancel()
        if let task { await task.value }
        task = nil
    }
}

extension Application {
    private struct GuestExecSessionMaintenanceKey: StorageKey, LockKey {
        typealias Value = GuestExecSessionMaintenanceLoop
    }

    var guestExecSessionMaintenance: GuestExecSessionMaintenanceLoop {
        lazyService(GuestExecSessionMaintenanceKey.self) { GuestExecSessionMaintenanceLoop(app: self) }
    }

    var guestExecSessionMaintenanceIfCreated: GuestExecSessionMaintenanceLoop? {
        storage[GuestExecSessionMaintenanceKey.self]
    }
}

struct GuestExecSessionMaintenanceLifecycleHandler: LifecycleHandler {
    func didBootAsync(_ application: Application) async throws {
        await application.guestExecSessionMaintenance.start()
    }

    func shutdownAsync(_ application: Application) async {
        await application.guestExecSessionMaintenanceIfCreated?.shutdown()
    }
}
