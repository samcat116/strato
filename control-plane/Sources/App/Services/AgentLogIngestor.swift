import Foundation
import Synchronization
import StratoShared
import Vapor

/// A log line an agent reports on behalf of one of the resources it hosts,
/// admissible only once the reporting agent is confirmed to own that resource.
protocol AgentLoggedResourceMessage: Sendable {
    /// Resource kind as it reads in the drop warning ("sandbox", "VM").
    static var resourceKind: String { get }
    /// The resource whose ownership is checked before the line is pushed.
    var owningResourceID: String { get }
    var retainedLogBytes: Int { get }
}

extension SandboxLogMessage: AgentLoggedResourceMessage {
    static var resourceKind: String { "sandbox" }
    var owningResourceID: String { sandboxId }
    var retainedLogBytes: Int { requestId.utf8.count + sandboxId.utf8.count + stream.utf8.count + message.utf8.count }
}

extension VMLogMessage: AgentLoggedResourceMessage {
    static var resourceKind: String { "vm" }
    var owningResourceID: String { vmId }
    var retainedLogBytes: Int {
        requestId.utf8.count + vmId.utf8.count + message.utf8.count + (operation?.utf8.count ?? 0)
    }
}

/// Both resource ingestors share one outage log budget for the replica.
private enum WorkloadLogOutageReporter {
    private static let nextReport = Mutex<ContinuousClock.Instant?>(nil)

    static func report(_ error: any Error, logger: Logger) {
        let report = nextReport.withLock { next in
            let now = ContinuousClock.now
            if let next, next > now { return false }
            next = now.advanced(by: .seconds(30))
            return true
        }
        if report { logger.error("Loki workload log delivery failed; shedding until next probe: \(error)") }
    }
}

/// Lossy, bounded telemetry. One worker checks uncached ownership and pushes
/// batches in FIFO order; neither database nor Loki latency blocks the socket.
final class AgentLogIngestor<Message: AgentLoggedResourceMessage>: Sendable {
    typealias OwnershipCheck = @Sendable (_ resourceId: String, _ agentKey: String) async -> Bool
    typealias Push = @Sendable (_ messages: [Message]) async throws -> Void
    static var ownershipTTL: TimeInterval { 30 }

    struct Entry: Sendable {
        let message: Message
        let agentKey: String
    }

    private struct CacheKey: Hashable, Sendable {
        let resourceId: String
        let agentKey: String
    }

    private struct State: Sendable {
        var cache: [CacheKey: (owned: Bool, expiresAt: Date)] = [:]
        var retryAt: Date?
    }

    private final class StateBox: Sendable {
        let value = Mutex(State())
    }

    private let state: StateBox
    private let queue: BoundedLogQueue<Entry>
    private let worker: Task<Void, Never>
    private let now: @Sendable () -> Date

    init(
        logger: Logger,
        now: @escaping @Sendable () -> Date = Date.init,
        bufferLimitBytes: Int = BoundedLogQueue<Entry>.defaultByteLimit,
        batchInterval: Duration = .milliseconds(100),
        outageInterval: TimeInterval = 30,
        checkOwnership: @escaping OwnershipCheck,
        push: @escaping Push
    ) {
        precondition(outageInterval > 0 && batchInterval >= .zero)
        self.now = now
        let state = StateBox()
        self.state = state
        let queue = BoundedLogQueue<Entry>(byteLimit: bufferLimitBytes) { snapshot, dropped, reason in
            Telemetry.recordWorkloadLogQueue(kind: Message.resourceKind, count: snapshot.count, bytes: snapshot.bytes)
            if dropped > 0 {
                Telemetry.workloadLogsDropped(kind: Message.resourceKind, reason: reason.rawValue, count: dropped)
            }
        }
        self.queue = queue
        // Capture dependencies, never the owner: shutdown/deinit cancels even
        // while the worker is awaiting a slow ownership check or Loki request.
        self.worker = Task {
            for await _ in queue.notifications {
                // Flush on size pressure, otherwise within the coalescing
                // window. Polling this bounded snapshot uses no per-line tasks.
                let deadline = ContinuousClock.now.advanced(by: batchInterval)
                do {
                    while ContinuousClock.now < deadline {
                        let pending = queue.snapshot
                        if pending.count >= 256 || pending.bytes >= 256 * 1024 { break }
                        try await Task.sleep(for: min(.milliseconds(5), ContinuousClock.now.duration(to: deadline)))
                    }
                } catch { break }
                guard !Task.isCancelled else { break }
                if state.value.withLock({ $0.retryAt.map { $0 > now() } ?? false }) {
                    queue.discard(reason: .backendUnavailable)
                    continue
                }
                let entries = queue.drain()
                var messages: [Message] = []
                var rejected = 0
                var accounted = false
                defer {
                    if !accounted, Task.isCancelled, entries.count > rejected {
                        Telemetry.workloadLogsDropped(
                            kind: Message.resourceKind, reason: "shutdown", count: entries.count - rejected)
                    }
                }
                for entry in entries {
                    guard !Task.isCancelled else { return }
                    let key = CacheKey(resourceId: entry.message.owningResourceID, agentKey: entry.agentKey)
                    let owned: Bool
                    if let cached = state.value.withLock({ $0.cache[key] }), cached.expiresAt > now() {
                        owned = cached.owned
                    } else {
                        owned = await checkOwnership(key.resourceId, key.agentKey)
                        state.value.withLock { state in
                            // A hard cardinality bound, even when all TTLs are
                            // live. Unknown resources cannot grow this cache.
                            if state.cache.count >= 1024 {
                                state.cache = state.cache.filter { $0.value.expiresAt > now() }
                                if state.cache.count >= 1024 { state.cache.removeAll(keepingCapacity: true) }
                            }
                            state.cache[key] = (owned, now().addingTimeInterval(Self.ownershipTTL))
                        }
                    }
                    if owned {
                        messages.append(entry.message)
                    } else {
                        rejected += 1
                        Telemetry.workloadLogsDropped(kind: Message.resourceKind, reason: "unowned", count: 1)
                    }
                }
                guard !Task.isCancelled, !messages.isEmpty else { continue }
                let started = ContinuousClock.now
                do {
                    try await push(messages)
                    state.value.withLock { $0.retryAt = nil }
                } catch {
                    if Task.isCancelled { return }
                    state.value.withLock { $0.retryAt = now().addingTimeInterval(outageInterval) }
                    Telemetry.workloadLogPushFailed(kind: Message.resourceKind)
                    Telemetry.workloadLogsDropped(
                        kind: Message.resourceKind, reason: "push_failed", count: messages.count)
                    queue.discard(reason: .backendUnavailable)
                    WorkloadLogOutageReporter.report(error, logger: logger)
                }
                accounted = true
                Telemetry.workloadLogBatchCompleted(kind: Message.resourceKind, elapsed: started.duration(to: .now))
            }
        }
    }

    deinit {
        queue.finish()
        worker.cancel()
    }

    var isCircuitOpen: Bool { state.value.withLock { $0.retryAt.map { $0 > now() } ?? false } }

    var queueSnapshot: BoundedLogQueue<Entry>.Snapshot { queue.snapshot }

    /// Cached negative ownership and open-circuit lines never occupy queue
    /// space. Cache misses stay in the bounded FIFO for the single worker.
    func enqueue(_ message: Message, fromAgentKey agentKey: String) {
        // Resource IDs are UUIDs and authenticated agent identities are short.
        // Bound retained cache keys too, including negative ownership answers.
        guard message.owningResourceID.utf8.count <= 256, agentKey.utf8.count <= 1024 else {
            Telemetry.workloadLogsDropped(kind: Message.resourceKind, reason: "unowned", count: 1)
            return
        }
        let reason: String? = state.value.withLock { state in
            if let retryAt = state.retryAt, retryAt > now() { return "backend_unavailable" }
            let key = CacheKey(resourceId: message.owningResourceID, agentKey: agentKey)
            if let cached = state.cache[key], cached.expiresAt > now(), !cached.owned { return "unowned" }
            return nil
        }
        if let reason {
            Telemetry.workloadLogsDropped(kind: Message.resourceKind, reason: reason, count: 1)
            return
        }
        queue.append(
            Entry(message: message, agentKey: agentKey), byteCount: message.retainedLogBytes + agentKey.utf8.count)
    }

    /// Pending telemetry is lossy at shutdown; cancel the active operation and
    /// release queued messages immediately rather than waiting on Loki.
    func shutdown() {
        queue.finish()
        worker.cancel()
    }
}

typealias SandboxLogIngestor = AgentLogIngestor<SandboxLogMessage>
typealias VMLogIngestor = AgentLogIngestor<VMLogMessage>

// MARK: - Application Extension

extension Application {
    private struct SandboxLogIngestorKey: StorageKey, LockKey {
        typealias Value = SandboxLogIngestor
    }

    private struct VMLogIngestorKey: StorageKey, LockKey {
        typealias Value = VMLogIngestor
    }

    func shutdownWorkloadLogIngestors() {
        storage[SandboxLogIngestorKey.self]?.shutdown()
        storage[VMLogIngestorKey.self]?.shutdown()
    }

    var sandboxLogIngestor: SandboxLogIngestor {
        get {
            lazyService(SandboxLogIngestorKey.self) {
                // Capture the services, not the Application, so the ingestor
                // does not retain the app that stores it.
                let agentService = self.agentService
                let lokiService = self.lokiService
                return SandboxLogIngestor(
                    logger: logger,
                    checkOwnership: { sandboxId, agentKey in
                        await agentService.sandboxIsOwnedByAgent(sandboxId: sandboxId, agentKey: agentKey)
                    },
                    push: { message in
                        try await lokiService.pushSandboxLogs(message)
                    }
                )
            }
        }
    }

    var vmLogIngestor: VMLogIngestor {
        get {
            lazyService(VMLogIngestorKey.self) {
                let agentService = self.agentService
                let lokiService = self.lokiService
                return VMLogIngestor(
                    logger: logger,
                    checkOwnership: { vmId, agentKey in
                        await agentService.vmIsOwnedByAgent(vmId: vmId, agentKey: agentKey)
                    },
                    push: { message in
                        try await lokiService.pushLogs(message)
                    }
                )
            }
        }
    }
}

struct WorkloadLogIngestorLifecycle: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        application.shutdownWorkloadLogIngestors()
    }
}
