import Foundation
import StratoShared
import Vapor

/// Serial ingest pipeline for agent-reported sandbox workload log lines
/// (`sandbox_log` messages).
///
/// The agent WebSocket dispatch enqueues synchronously (preserving frame
/// arrival order) and a single consumer task processes entries one at a time,
/// because:
/// - Loki rejects out-of-order entries per stream when `unordered_writes` is
///   disabled. One unstructured Task per line let racing tasks transpose the
///   lines the agent carefully sent in order, silently losing the stragglers.
/// - The per-line agent-ownership check was a Postgres point query; a chatty
///   workload meant thousands of queries per second. A short-TTL cache (both
///   positive and negative answers) collapses those into one query per
///   sandbox/agent pair every ``ownershipTTL`` seconds.
///
/// Dependencies are injected as closures so the pipeline can be unit-tested
/// without an application (see `Application.sandboxLogIngestor` for the
/// production wiring).
final class SandboxLogIngestor: @unchecked Sendable {
    typealias OwnershipCheck = @Sendable (_ sandboxId: String, _ agentKey: String) async -> Bool
    typealias Push = @Sendable (_ message: SandboxLogMessage) async throws -> Void

    /// How long a positive or negative ownership answer is reused before the
    /// database is consulted again. Short enough that a sandbox migrating
    /// between agents converges quickly; long enough to absorb log bursts.
    static let ownershipTTL: TimeInterval = 30

    /// Ownership-cache entries are swept once the map grows past this bound,
    /// so a churn of short-lived sandboxes cannot grow it without limit.
    private static let ownershipCacheSweepThreshold = 1024

    private struct Entry: Sendable {
        let message: SandboxLogMessage
        let agentKey: String
    }

    private struct CacheKey: Hashable {
        let sandboxId: String
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
    func enqueue(_ message: SandboxLogMessage, fromAgentKey agentKey: String) {
        continuation.yield(Entry(message: message, agentKey: agentKey))
    }

    /// Stop the consumer once the queue drains (tests).
    func shutdown() {
        continuation.finish()
    }

    private func process(_ entry: Entry) async {
        // Only accept logs for a sandbox actually assigned to the reporting
        // agent — anti-spoofing parity with the `.vmLog` path.
        let owned = await sandboxIsOwned(sandboxId: entry.message.sandboxId, agentKey: entry.agentKey)
        guard owned else {
            logger.warning(
                "Dropping sandbox log for a sandbox not owned by the reporting agent",
                metadata: [
                    "sandboxId": .string(entry.message.sandboxId),
                    "agentKey": .string(entry.agentKey),
                ])
            return
        }
        do {
            try await push(entry.message)
        } catch {
            logger.error("Failed to push sandbox log to Loki: \(error)")
        }
    }

    private func sandboxIsOwned(sandboxId: String, agentKey: String) async -> Bool {
        let key = CacheKey(sandboxId: sandboxId, agentKey: agentKey)
        let currentTime = now()
        if let cached = ownershipCache[key], cached.expiresAt > currentTime {
            return cached.owned
        }
        let owned = await checkOwnership(sandboxId, agentKey)
        ownershipCache[key] = (owned: owned, expiresAt: currentTime.addingTimeInterval(Self.ownershipTTL))
        if ownershipCache.count > Self.ownershipCacheSweepThreshold {
            ownershipCache = ownershipCache.filter { $0.value.expiresAt > currentTime }
        }
        return owned
    }
}

// MARK: - Application Extension

extension Application {
    private struct SandboxLogIngestorKey: StorageKey, LockKey {
        typealias Value = SandboxLogIngestor
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
}
