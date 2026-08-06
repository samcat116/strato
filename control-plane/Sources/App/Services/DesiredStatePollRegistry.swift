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

    /// Park until the doorbell rings for `agentKey`, `deadline` passes, or the
    /// calling request is cancelled (client hung up). Never throws: every
    /// outcome is "go re-assemble and decide", and the caller distinguishes
    /// them by re-checking the clock.
    func wait(agentKey: String, until deadline: ContinuousClock.Instant) async {
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
                    await self.resume(agentKey: agentKey, id: id)
                }
            }
        } onCancel: {
            Task { await self.resume(agentKey: agentKey, id: id) }
        }
    }

    /// Wake every poll parked for `agentKey`. Contentless: a woken poll
    /// re-assembles and decides for itself whether anything actually changed,
    /// so a spurious ring costs one assembly and never a wrong answer.
    func ring(agentKey: String) {
        guard let parked = waiters.removeValue(forKey: agentKey) else { return }
        for continuation in parked.values {
            continuation.resume()
        }
    }

    /// Wake every poll parked here, whoever it belongs to. The fleet-wide
    /// counterpart of `ring`, for changes whose blast radius is the whole
    /// fleet (security groups, networks, site topology). Each woken poll still
    /// re-assembles and decides for itself, so the ones that were not actually
    /// affected simply park again.
    func ringAll() {
        let parked = waiters
        waiters.removeAll()
        for continuations in parked.values {
            for continuation in continuations.values {
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
