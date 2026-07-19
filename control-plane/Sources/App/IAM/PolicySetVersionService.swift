import Fluent
import Foundation
import Vapor

/// Allocates and reads policy-set versions (issue #479).
///
/// See `PolicySetVersion` for what counts as a policy-set change and why
/// bindings are not one.
enum PolicySetVersionService {
    /// How many times to retry a policy write whose version allocation
    /// collided. A handful covers far more concurrency than policy writes ever
    /// see — these are administrative actions, not request-path work.
    private static let transactionAttempts = 5

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
    /// Call this in the same transaction as the change it describes, via
    /// `withPolicySetChange`. A bump that lands without its change would
    /// invalidate every replica's compiled set for nothing; a change that
    /// lands without its bump is worse — the replicas keep serving the old
    /// policy set and never learn otherwise.
    ///
    /// Allocation is a single attempt on purpose. `version` is `max + 1` under
    /// a uniqueness constraint, so two concurrent writers can pick the same
    /// number and one insert fails — and on Postgres that failure marks the
    /// whole transaction aborted, which makes retrying *inside* it impossible:
    /// every subsequent statement, including re-reading the max, fails too.
    /// The retry therefore belongs at the transaction boundary, not here.
    @discardableResult
    static func bump(reason: String, changedBy: UUID? = nil, on db: any Database) async throws -> Int {
        let next = try await current(on: db) + 1
        try await PolicySetVersion(version: next, reason: reason, changedBy: changedBy).save(on: db)
        return next
    }

    /// Run a policy-set change and its version bump as one transaction,
    /// retrying the whole thing if the version allocation collided.
    ///
    /// Every policy write goes through here. Two properties come from it:
    ///
    /// - **Atomicity.** The change and its version commit together, so a crash
    ///   can't leave a changed policy set that no replica will ever recompile
    ///   against — the failure mode that has no self-repair, because the next
    ///   boot finds nothing to reconcile and bumps nothing.
    /// - **Collision recovery.** A losing allocator aborts its transaction;
    ///   this re-runs the work from the top against a fresh one, where the max
    ///   version now includes the winner's row.
    ///
    /// Only uniqueness collisions retry. Errors the work itself raises — a
    /// duplicate guardrail name, a malformed ceiling — are already translated
    /// out of `DatabaseError` by the store, so they surface on the first
    /// attempt rather than being retried four more times.
    static func withPolicySetChange<T: Sendable>(
        on db: any Database,
        _ work: @Sendable @escaping (any Database) async throws -> T
    ) async throws -> T {
        for attempt in 1...transactionAttempts {
            do {
                return try await db.transaction { transaction in
                    try await work(transaction)
                }
            } catch {
                guard let dbError = error as? any DatabaseError, dbError.isConstraintFailure else { throw error }
                guard attempt < transactionAttempts else { throw error }
            }
        }
        // Unreachable: the loop either returns or throws on its last attempt.
        throw Abort(.internalServerError, reason: "Could not commit the policy-set change")
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
    /// Called on every observed version change, with the new version.
    /// Edge-triggered: silent while the version holds still.
    private var onChange: [@Sendable (Int) async -> Void] = []
    /// Called after every successful re-read with the latest version, changed
    /// or not. Level-triggered: this is what the compiled-policy-set cache
    /// (#480) hangs off, so a rebuild that *failed* is retried at the next
    /// tick — an edge-only listener would never hear about the same version
    /// twice and a transient failure would stick until the next policy write.
    private var onRefresh: [@Sendable (Int) async -> Void] = []

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

    /// Register a listener fired on every successful refresh, with the latest
    /// version. Listeners must be cheap when nothing changed — this fires on
    /// each periodic tick, so idempotence is theirs to provide.
    func onEveryRefresh(_ handler: @escaping @Sendable (Int) async -> Void) {
        onRefresh.append(handler)
    }

    /// Re-read the version from the database; fire change listeners if it
    /// moved and refresh listeners either way.
    func refresh(on db: any Database) async {
        do {
            let latest = try await PolicySetVersionService.current(on: db)
            if latest != version {
                let previous = version
                version = latest
                logger.info(
                    "Policy set version changed",
                    metadata: ["from": .stringConvertible(previous), "to": .stringConvertible(latest)])
                for handler in onChange {
                    await handler(latest)
                }
            }
            for handler in onRefresh {
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
