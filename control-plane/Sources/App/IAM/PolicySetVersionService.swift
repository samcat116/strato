import Fluent
import Foundation
import Vapor

/// Allocates and reads policy-set versions (issue #479).
///
/// See `PolicySetVersion` for what counts as a policy-set change and why
/// bindings are not one.
enum PolicySetVersionService {
    /// How many times to retry the `max + 1` allocation when another replica
    /// (or another request on this one) wins the race. Each retry re-reads the
    /// max, so a handful covers far more concurrency than policy writes ever
    /// see — these are administrative actions, not request-path work.
    private static let allocationAttempts = 5

    /// The version currently in force. Zero when nothing has been recorded
    /// yet, which is the correct answer for a fresh database: the policy set
    /// exists, it has simply never changed.
    static func current(on db: any Database) async throws -> Int {
        let latest = try await PolicySetVersion.query(on: db)
            .sort(\.$version, .descending)
            .first()
        return latest?.version ?? 0
    }

    /// Record a policy-set change and return the new version.
    ///
    /// Call this in the same transaction as the change it describes. A bump
    /// that lands without its change would invalidate every replica's compiled
    /// set for nothing; a change that lands without its bump is worse — the
    /// replicas keep serving the old policy set and never learn otherwise.
    @discardableResult
    static func bump(reason: String, changedBy: UUID? = nil, on db: any Database) async throws -> Int {
        for attempt in 1...allocationAttempts {
            let next = try await current(on: db) + 1
            do {
                try await PolicySetVersion(version: next, reason: reason, changedBy: changedBy).save(on: db)
                return next
            } catch {
                // Someone else took this version. Re-read and try the next one.
                // Inside an already-aborted Postgres transaction the re-read
                // throws instead, which is right: the whole write retries as a
                // unit rather than this half of it limping on.
                guard let dbError = error as? any DatabaseError, dbError.isConstraintFailure else { throw error }
                guard attempt < allocationAttempts else { throw error }
            }
        }
        // Unreachable: the loop either returns or throws on its last attempt.
        throw Abort(.internalServerError, reason: "Could not allocate a policy-set version")
    }
}

/// Each replica's view of the current policy-set version, and the seam the
/// compiled-policy-set cache hangs off (#480).
///
/// Invalidation is the pattern the rest of the multi-replica design uses
/// (docs/architecture/multi-replica.md): a write publishes on a Valkey channel
/// and every replica refreshes, backstopped by a periodic re-read so a lost
/// message costs one interval of staleness rather than permanent divergence.
/// Unlike the `replica:{id}:*` channels this one is a **broadcast** — a policy
/// change concerns every replica, not the one holding some socket.
///
/// Fails open in the same sense the rest of the coordination layer does: if
/// Valkey is unreachable, the periodic re-read still converges every replica.
actor PolicySetVersionCache {
    /// The backstop interval. Policy changes are rare and the nudge is the
    /// fast path, so this only has to bound how long a *lost* nudge can leave
    /// a replica stale.
    static let refreshIntervalSeconds = 30

    /// The broadcast channel. Not `replica:{id}:`-scoped: every replica cares.
    static let channel = "policy-set:version"

    private let logger: Logger
    private var version: Int = 0
    /// Called on every observed version change, with the new version. This is
    /// where #480 rebuilds the compiled policy set.
    private var onChange: [@Sendable (Int) async -> Void] = []

    init(logger: Logger) {
        self.logger = logger
    }

    /// The last version this replica observed. Cheap and non-throwing: callers
    /// on the request path (decision logging) must never block on the database
    /// to stamp a version.
    var currentVersion: Int { version }

    /// Register a listener fired whenever the observed version changes.
    func onVersionChange(_ handler: @escaping @Sendable (Int) async -> Void) {
        onChange.append(handler)
    }

    /// Re-read the version from the database and fire listeners if it moved.
    func refresh(on db: any Database) async {
        do {
            let latest = try await PolicySetVersionService.current(on: db)
            guard latest != version else { return }
            let previous = version
            version = latest
            logger.info(
                "Policy set version changed",
                metadata: ["from": .stringConvertible(previous), "to": .stringConvertible(latest)])
            for handler in onChange {
                await handler(latest)
            }
        } catch {
            // Staleness beats crashing a background task: the next tick, or
            // the next nudge, tries again.
            logger.warning(
                "Failed to read policy set version",
                metadata: ["error": .string("\(error)")])
        }
    }
}

extension Application {
    private struct PolicySetVersionCacheKey: StorageKey, LockKey {
        typealias Value = PolicySetVersionCache
    }

    /// This replica's policy-set version cache.
    var policySetVersion: PolicySetVersionCache {
        lazyService(PolicySetVersionCacheKey.self) { PolicySetVersionCache(logger: logger) }
    }

    /// Announce a policy-set change to every replica, this one included.
    ///
    /// Best-effort by design: publishing is a latency optimization over the
    /// periodic re-read, so a failure is logged rather than thrown. It must not
    /// fail the policy write that already committed.
    func announcePolicySetChange() async {
        await policySetVersion.refresh(on: db)
        do {
            try await coordination.publish(channel: PolicySetVersionCache.channel, message: "changed")
        } catch {
            logger.warning(
                "Failed to publish policy set change; replicas will pick it up on the next periodic re-read",
                metadata: ["error": .string("\(error)")])
        }
    }

    /// Subscribe to policy-set change broadcasts and arm the periodic re-read.
    /// Called once at boot.
    func startPolicySetVersionWatch() async {
        await policySetVersion.refresh(on: db)

        do {
            try await coordination.subscribe(channel: PolicySetVersionCache.channel) { [self] _ in
                backgroundTasks.spawn {
                    await self.policySetVersion.refresh(on: self.db)
                }
            }
        } catch {
            logger.warning(
                "Failed to subscribe to policy set changes; falling back to periodic re-read only",
                metadata: ["error": .string("\(error)")])
        }

        backgroundTasks.spawn { [self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(PolicySetVersionCache.refreshIntervalSeconds))
                } catch {
                    return
                }
                await policySetVersion.refresh(on: db)
            }
        }
    }
}
