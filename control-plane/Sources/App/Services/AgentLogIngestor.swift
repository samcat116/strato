import Foundation
import StratoShared
import Vapor

/// A log line an agent reports on behalf of one of the resources it hosts,
/// admissible only once the reporting agent is confirmed to own that resource.
protocol AgentLoggedResourceMessage: Sendable {
    /// Resource kind as it reads in the drop warning ("sandbox", "VM").
    static var resourceKind: String { get }
    /// Metadata key carrying the resource id in that warning ("sandboxId", "vmId").
    static var resourceIDMetadataKey: String { get }
    /// The resource whose ownership is checked before the line is pushed.
    var owningResourceID: String { get }
}

extension SandboxLogMessage: AgentLoggedResourceMessage {
    static var resourceKind: String { "sandbox" }
    static var resourceIDMetadataKey: String { "sandboxId" }
    var owningResourceID: String { sandboxId }
}

extension VMLogMessage: AgentLoggedResourceMessage {
    static var resourceKind: String { "VM" }
    static var resourceIDMetadataKey: String { "vmId" }
    var owningResourceID: String { vmId }
}

/// Serial ingest pipeline for agent-reported workload log lines — sandbox
/// (`sandbox_log`) and VM (`vm_log`) messages each get their own instance.
///
/// The agent WebSocket dispatch enqueues synchronously (preserving frame
/// arrival order) and a single consumer task processes entries one at a time,
/// because:
/// - Loki rejects out-of-order entries per stream when `unordered_writes` is
///   disabled. One unstructured Task per line let racing tasks transpose the
///   lines the agent carefully sent in order, silently losing the stragglers.
/// - The per-line agent-ownership check was a Postgres point query; a chatty
///   workload meant thousands of queries per second (issue #698). A short-TTL
///   cache (both positive and negative answers) collapses those into one query
///   per resource/agent pair every ``ownershipTTL`` seconds.
///
/// Dependencies are injected as closures so the pipeline can be unit-tested
/// without an application (see `Application.sandboxLogIngestor` and
/// `Application.vmLogIngestor` for the production wiring).
final class AgentLogIngestor<Message: AgentLoggedResourceMessage>: @unchecked Sendable {
    typealias OwnershipCheck = @Sendable (_ resourceId: String, _ agentKey: String) async -> Bool
    typealias Push = @Sendable (_ message: Message) async throws -> Void

    /// How long a positive or negative ownership answer is reused before the
    /// database is consulted again. Short enough that a resource migrating
    /// between agents converges quickly; long enough to absorb log bursts.
    static var ownershipTTL: TimeInterval { 30 }

    /// Ownership-cache entries are swept once the map grows past this bound,
    /// so a churn of short-lived resources cannot grow it without limit.
    private static var ownershipCacheSweepThreshold: Int { 1024 }

    private struct Entry: Sendable {
        let message: Message
        let agentKey: String
    }

    private struct CacheKey: Hashable {
        let resourceId: String
        let agentKey: String
    }

    private let logger: Logger
    private let checkOwnership: OwnershipCheck
    private let push: Push
    private let now: @Sendable () -> Date
    private let continuation: AsyncStream<Entry>.Continuation

    /// Only ever touched from the single consumer task, so no lock is needed.
    private var ownershipCache: [CacheKey: (owned: Bool, expiresAt: Date)] = [:]

    init(
        logger: Logger,
        now: @escaping @Sendable () -> Date = Date.init,
        checkOwnership: @escaping OwnershipCheck,
        push: @escaping Push
    ) {
        self.logger = logger
        self.now = now
        self.checkOwnership = checkOwnership
        self.push = push

        let (stream, continuation) = AsyncStream.makeStream(of: Entry.self)
        self.continuation = continuation
        // `weak self` so the owning reference (Application storage) is the
        // only thing keeping the ingestor alive: when that clears at shutdown
        // the ingestor deinits, the continuation finishes, and the consumer
        // exits instead of pinning the process.
        Task { [weak self] in
            var iterator = stream.makeAsyncIterator()
            while let entry = await iterator.next() {
                guard let self else { return }
                await self.process(entry)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Queue one log line and return immediately. Called from the agent
    /// WebSocket's event loop, so it must never block or await.
    func enqueue(_ message: Message, fromAgentKey agentKey: String) {
        continuation.yield(Entry(message: message, agentKey: agentKey))
    }

    /// Stop the consumer once the queue drains (tests).
    func shutdown() {
        continuation.finish()
    }

    private func process(_ entry: Entry) async {
        // Only accept logs for a resource actually assigned to the reporting
        // agent. Without this a compromised agent could push fabricated log
        // lines tagged with another tenant's resource id, which would then
        // surface in that tenant's console/log view.
        let resourceId = entry.message.owningResourceID
        let owned = await resourceIsOwned(resourceId: resourceId, agentKey: entry.agentKey)
        guard owned else {
            logger.warning(
                "Dropping \(Message.resourceKind) log for a \(Message.resourceKind) not owned by the reporting agent",
                metadata: [
                    Message.resourceIDMetadataKey: .string(resourceId),
                    "agentKey": .string(entry.agentKey),
                ])
            return
        }
        do {
            try await push(entry.message)
        } catch {
            logger.error("Failed to push \(Message.resourceKind) log to Loki: \(error)")
        }
    }

    private func resourceIsOwned(resourceId: String, agentKey: String) async -> Bool {
        let key = CacheKey(resourceId: resourceId, agentKey: agentKey)
        let currentTime = now()
        if let cached = ownershipCache[key], cached.expiresAt > currentTime {
            return cached.owned
        }
        let owned = await checkOwnership(resourceId, agentKey)
        ownershipCache[key] = (owned: owned, expiresAt: currentTime.addingTimeInterval(Self.ownershipTTL))
        if ownershipCache.count > Self.ownershipCacheSweepThreshold {
            ownershipCache = ownershipCache.filter { $0.value.expiresAt > currentTime }
        }
        return owned
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
                        try await lokiService.pushSandboxLog(message)
                    }
                )
            }
        }
        set {
            setStorageValue(SandboxLogIngestorKey.self, to: newValue)
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
                        try await lokiService.pushLog(message)
                    }
                )
            }
        }
        set {
            setStorageValue(VMLogIngestorKey.self, to: newValue)
        }
    }
}
