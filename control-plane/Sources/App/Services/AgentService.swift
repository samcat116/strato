import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent
import NIOCore
import NIOConcurrencyHelpers
import SQLKit
import Tracing
import Metrics

actor AgentService {
    let app: Application

    var heartbeatTask: Task<Void, Never>?

    /// Last successful presence refresh per local socket. The wire sends both a
    /// heartbeat and an observed report every 20 seconds; refreshing on every
    /// frame doubles Valkey traffic without extending liveness. Half the TTL
    /// leaves a full retry window after a failed write.
    var presenceRefreshedAt: [String: ContinuousClock.Instant] = [:]
    /// Route writes fail independently of presence writes. Keep their success
    /// timestamps separate so a missing cross-replica socket route retries on
    /// the next frame instead of waiting for the presence throttle window.
    var routeRefreshedAt: [String: ContinuousClock.Instant] = [:]
    static let presenceRefreshInterval: Duration =
        .seconds(Int64(CoordinationService.presenceTTLSeconds / 2))

    /// Keep the durable heartbeat comfortably inside the same 60-second
    /// liveness window while coalescing identical heartbeat/report pairs.
    static let databaseHeartbeatRefreshInterval =
        TimeInterval(CoordinationService.presenceTTLSeconds / 2)

    /// The last refused sync this replica has logged per agent (STR-98).
    /// A refusal rides on every observed report until the agent's guard
    /// clears, so without this one stuck refusal would log and count on every
    /// heartbeat instead of once per refused sync. Replica-local: after a
    /// restart the first report re-logs, which is the right side to err on.
    var reportedTeardownRefusalSyncIds: [String: String] = [:]

    /// The startup task that arms the replica pub/sub subscriptions. Tracked
    /// so `shutdown()` can wait for it — otherwise it can still be
    /// subscribing (touching `app` storage) while the application tears down.
    var startupTask: Task<Void, Never>?

    /// Interval between heartbeat-monitor ticks. Injectable so tests can
    /// exercise the loop (and its shutdown race) without waiting 30s.
    let heartbeatInterval: Duration

    /// Set at application shutdown. Guards against the init task arming the
    /// heartbeat monitor after `shutdown()` already ran.
    var isShutDown = false

    /// Overrides the startup-resolved agent target for the auto-update sweep.
    var autoUpdateTargetOverride: String?

    /// Tail of each agent's report-application chain. These are stored on the
    /// actor itself because extensions cannot add state; report ingestion lives
    /// in `AgentService+ObservedState.swift`.
    var reportTails: [String: (id: UInt64, task: Task<Void, Never>)] = [:]
    var nextReportTailId: UInt64 = 0

    func setAutoUpdateTargetForTesting(_ target: String?) {
        autoUpdateTargetOverride = target
    }

    /// The version auto-updating agents should converge on.
    var autoUpdateTarget: String? {
        autoUpdateTargetOverride
            ?? AgentVersionTarget.version(configuration: app.controlPlaneConfiguration)
    }

    init(app: Application, heartbeatInterval: Duration = .seconds(30)) {
        self.app = app
        self.heartbeatInterval = heartbeatInterval
        // Start heartbeat monitoring and the replica's pub/sub subscriptions
        // after initialization. The hop through an isolated method is
        // deliberate: a nonisolated init cannot store the task it spawns, and
        // both background tasks must be tracked so `shutdown()` can await
        // them.
        Task { await self.armBackgroundWork() }
    }

    /// Arm the tracked background tasks (heartbeat loop, replica pub/sub
    /// subscriptions). No-op if shutdown already ran.
    ///
    /// Also a no-op when the *application* has shut down: `agentService` is a
    /// lazy getter, so a stray late caller (a detached task from a request or
    /// socket handler running after `asyncShutdown` cleared storage) creates
    /// a fresh service on a dead app. `AgentServiceLifecycleHandler` has
    /// already run by then and nothing will ever shut this instance down, so
    /// an armed heartbeat's first tick touches `app.db` after core teardown
    /// and dies with Vapor's "Core not configured" fatal error — the
    /// recurring CI crash.
    func armBackgroundWork() {
        guard !isShutDown, !app.didShutdown else { return }
        startHeartbeatMonitoring()
        startupTask = Task {
            await self.app.replicaBridge.start(delegate: self)
        }
    }

    /// Cancel the heartbeat monitoring loop and wait for an in-flight tick to
    /// finish. Called from the application's shutdown lifecycle (see
    /// `AgentServiceLifecycleHandler`): the loop holds the `Application` and
    /// sweeps the database every tick, so a tick that touches `app.db` after
    /// shutdown hits Vapor's "Core not configured" fatal error — long-lived
    /// test processes crash exactly this way. Cancellation interrupts the
    /// loop's sleep immediately, but a tick body already past the sleep is
    /// mid-sweep; awaiting the task's completion keeps Vapor's core alive
    /// until it drains. The startup task (replica pub/sub subscriptions) is
    /// awaited for the same reason. Safe on the actor: it is reentrant at
    /// these suspensions, so the tick can still hop back on to finish.
    func shutdown() async {
        isShutDown = true
        // Close the bridge's subscription re-arm path before we stop driving
        // it; its subscription tasks drain with the Valkey pools.
        await app.replicaBridgeIfCreated?.shutdown()
        startupTask?.cancel()
        heartbeatTask?.cancel()
        if let startupTask {
            await startupTask.value
        }
        startupTask = nil
        // `isShutDown` was set before the await, so the startup task cannot
        // have armed the loop in the meantime — this reads the final value.
        if let heartbeatTask {
            await heartbeatTask.value
        }
        heartbeatTask = nil
    }
}

// MARK: - ReplicaBridgeDelegate

/// The delegate is `deliverDoorbell` alone, declared with the desired-state
/// sync code above. Its other half, `runLocalExchange`, went with the
/// cross-replica RPC bridge (STR-152).
extension AgentService: ReplicaBridgeDelegate {}

// MARK: - Application Extension

extension Application {
    private struct WebSocketManagerKey: StorageKey, LockKey {
        typealias Value = WebSocketManager
    }

    var websocketManager: WebSocketManager {
        get {
            lazyService(WebSocketManagerKey.self) { WebSocketManager() }
        }
        set {
            setStorageValue(WebSocketManagerKey.self, to: newValue)
        }
    }

    private struct AgentServiceKey: StorageKey, LockKey {
        typealias Value = AgentService
    }

    var agentService: AgentService {
        get {
            lazyService(AgentServiceKey.self) { AgentService(app: self) }
        }
        set {
            setStorageValue(AgentServiceKey.self, to: newValue)
        }
    }

    /// The `AgentService` if one has already been created, without lazily
    /// creating it. Shutdown must not instantiate the service (that would arm
    /// the very heartbeat task shutdown exists to cancel).
    var agentServiceIfCreated: AgentService? {
        storage[AgentServiceKey.self]
    }
}

/// Instantiates the agent service at boot; at shutdown, cancels its heartbeat
/// monitor and waits for the loop to exit so the periodic database sweep
/// never outlives the application (an in-flight tick touching `app.db` after
/// core teardown is the "Core not configured" CI crash).
struct AgentServiceLifecycleHandler: LifecycleHandler {
    /// Force creation at boot: the service's heartbeat/sweep loop and — since
    /// issue #261 — the doorbell and RPC channel subscriptions must be
    /// live even before the first request or agent connection would have
    /// created it lazily. Runs in `didBootAsync` so the Redis pools the
    /// subscriptions need already exist.
    func didBootAsync(_ application: Application) async throws {
        _ = application.agentService
    }

    func shutdownAsync(_ application: Application) async {
        await application.agentServiceIfCreated?.shutdown()
    }
}

extension Request {
    var agentService: AgentService {
        return application.agentService
    }
}

extension VMStatus {
    /// States that assert live agent presence: agents keep running, paused,
    /// and shut-down-but-not-deleted VMs in their managed set, so one of these
    /// missing from a heartbeat or observed-state report means the agent lost
    /// it. `.created` may be mid-create, and transitional/diagnostic states
    /// are owned by the sweep — absence in those states is expected.
    var assertsAgentPresence: Bool {
        self == .running || self == .paused || self == .shutdown
    }
}

extension SandboxStatus {
    /// Sandbox counterpart of `VMStatus.assertsAgentPresence`: running,
    /// stopped (rootfs materialized), and exited sandboxes live in the
    /// agent's managed set. Sandboxes have no `.created`-style pre-placement
    /// status, so callers must additionally skip never-confirmed rows
    /// (`observedGeneration == 0`) — a fresh sandbox's `.stopped` predates
    /// any agent involvement.
    var assertsAgentPresence: Bool {
        self == .running || self == .stopped || self == .exited
    }
}
