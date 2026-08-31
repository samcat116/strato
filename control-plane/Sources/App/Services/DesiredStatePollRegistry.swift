import Foundation
import Vapor

/// The parked desired-state long-polls this replica is holding (ADR 0001
/// stage 10).
///
/// This is what replaces the `agent:{name}:replica` routing directory for
/// desired state. A mutation no longer has to discover *which* replica can
/// reach an agent: it rings a contentless broadcast doorbell, every replica
/// asks its own registry whether it happens to hold that agent's poll, at most
/// one does, and the rest no-op. The registry is deliberately in-memory and
/// process-local — it describes sockets this process is holding open, which is
/// not information any other process can use or needs to durably know.
///
/// Losing a wake-up is safe by construction. A parked poll always has a
/// deadline, so the worst case for a dropped doorbell is that the poll returns
/// `304` at its hold window and the agent immediately re-polls; and the agent's
/// unconditional periodic re-fetch sits behind that as the correctness
/// invariant. Over-ringing is free.
actor DesiredStatePollRegistry {
    /// Per agent key, the continuations of every poll parked here. Normally at
    /// most one, but a re-poll racing its predecessor's teardown (long-poll
    /// timeout fires while the old request is still registered, or a
    /// load balancer re-routes on reconnect) legitimately produces two for a
    /// moment, so this is a collection rather than a single slot.
    private var waiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// Rings waiting to be delivered, and the task that will deliver them.
    /// See `coalesceWindow`.
    private var pendingKeys: Set<String> = []
    private var pendingAll = false
    private var flushTask: Task<Void, Never>?

    /// How long a ring is held so that rings arriving behind it collapse into
    /// the same wake-up.
    ///
    /// Without this, a burst of mutations costs one full assembly per ring per
    /// parked poll: the woken poll re-assembles, finds the same digest, parks
    /// again, and is woken by the next ring. Fleet-wide rings make that worse
    /// than it sounds, because they wake *every* parked poll on *every*
    /// replica — a script adding twenty security-group rules would otherwise
    /// burn twenty assemblies per agent in the fleet, for a change most of them
    /// are not affected by.
    ///
    /// The cost is up to this much added doorbell latency, which is nothing
    /// against the reconcile that follows (a VM create is seconds of work
    /// agent-side). Correctness does not depend on it either way: a woken poll
    /// re-reads current state from Postgres, so collapsing two rings into one
    /// wake-up loses nothing — the single assembly sees both mutations.
    static let coalesceWindow: Duration = .milliseconds(50)

    /// Ceiling on polls parked simultaneously for one agent.
    ///
    /// A healthy agent has exactly one. Two is legitimate and transient — a
    /// re-poll racing its predecessor's teardown, or a load balancer re-routing
    /// on reconnect — which is why the cap is not one and why `waiters` holds a
    /// collection per key. Past it, a misbehaving or looping agent would
    /// otherwise be able to park unbounded polls, each doing a full assembly on
    /// every doorbell; the endpoint is deliberately exempt from rate limiting
    /// (`RateLimitMiddleware`, where one shared sidecar IP would bucket the
    /// whole fleet together), so this is what bounds that amplification.
    static let maxParkedPollsPerAgent = 3

    /// Whether a `wait` actually parked. `refused` means the per-agent cap was
    /// already reached — the caller must idle rather than answer immediately,
    /// or the excess polls turn into a hot loop.
    enum ParkOutcome: Sendable, Equatable {
        case parked
        case refused
    }

    /// Park until the doorbell rings for `agentKey`, `deadline` passes, or the
    /// calling request is cancelled (client hung up). Never throws: every
    /// outcome is "go re-assemble and decide", and the caller distinguishes
    /// them by re-checking the clock.
    @discardableResult
    func wait(agentKey: String, until deadline: ContinuousClock.Instant) async -> ParkOutcome {
        guard (waiters[agentKey]?.count ?? 0) < Self.maxParkedPollsPerAgent else {
            return .refused
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // `onCancel` fires immediately — and therefore possibly before
                // this body runs — when the task is already cancelled on entry.
                // Registering anyway would park a request nobody is waiting on
                // until the deadline timer swept it up. Checking here closes
                // that window: this runs on the actor, so it cannot interleave
                // with `resume`.
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters[agentKey, default: [:]][id] = continuation
                // The deadline lives in a detached child rather than in a
                // `race` helper so that resuming via the doorbell removes the
                // waiter immediately; the timer then finds nothing and exits.
                // Unstructured on purpose — it must outlive a cancelled parent
                // long enough to clean up its own entry.
                Task {
                    try? await Task.sleep(until: deadline, clock: ContinuousClock())
                    self.resume(agentKey: agentKey, id: id)
                }
            }
        } onCancel: {
            Task { await self.resume(agentKey: agentKey, id: id) }
        }
        return .parked
    }

    /// Wake every poll parked for `agentKey`. Contentless: a woken poll
    /// re-assembles and decides for itself whether anything actually changed,
    /// so a spurious ring costs one assembly and never a wrong answer.
    func ring(agentKey: String) {
        pendingKeys.insert(agentKey)
        scheduleFlush()
    }

    /// Wake every poll parked here, whoever it belongs to. The fleet-wide
    /// counterpart of `ring`, for changes whose blast radius is the whole
    /// fleet (security groups, networks, site topology). Each woken poll still
    /// re-assembles and decides for itself, so the ones that were not actually
    /// affected simply park again.
    func ringAll() {
        pendingAll = true
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: Self.coalesceWindow, clock: ContinuousClock())
            self.flush()
        }
    }

    private func flush() {
        flushTask = nil
        let all = pendingAll
        let keys = pendingKeys
        pendingAll = false
        pendingKeys.removeAll()

        if all {
            let parked = waiters
            waiters.removeAll()
            for continuations in parked.values {
                for continuation in continuations.values {
                    continuation.resume()
                }
            }
            return
        }
        for key in keys {
            guard let parked = waiters.removeValue(forKey: key) else { continue }
            for continuation in parked.values {
                continuation.resume()
            }
        }
    }

    /// The agent keys with at least one parked poll. Test seam — production
    /// code never asks, because "do I hold this agent's poll?" is answered by
    /// `ring` doing nothing.
    var parkedAgentKeys: Set<String> {
        Set(waiters.filter { !$0.value.isEmpty }.keys)
    }

    private func resume(agentKey: String, id: UUID) {
        guard let continuation = waiters[agentKey]?.removeValue(forKey: id) else { return }
        if waiters[agentKey]?.isEmpty == true {
            waiters.removeValue(forKey: agentKey)
        }
        continuation.resume()
    }
}

extension Application {
    private struct DesiredStatePollRegistryKey: StorageKey, LockKey {
        typealias Value = DesiredStatePollRegistry
    }

    /// The long-polls parked on this replica. Through `lazyService` so two
    /// concurrent first accesses cannot end up holding different registries —
    /// a poll parked on one and rung on the other would sleep out its full
    /// hold window.
    var desiredStatePollRegistry: DesiredStatePollRegistry {
        lazyService(DesiredStatePollRegistryKey.self) { DesiredStatePollRegistry() }
    }
}
