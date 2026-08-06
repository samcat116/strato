import Foundation

/// One named cleanup participant that must finish before a deleted resource's
/// row may leave the database — Kubernetes finalizers in Strato's shape
/// (ADR 0001, stage 3).
///
/// `DELETE` does not remove a row. It marks desired state `.absent` and stamps
/// the resource's finalizer list; each participant clears its own token from
/// wherever it actually runs, and the row is removed when the last token goes.
/// Every participant must therefore be **idempotent** (its trigger repeats:
/// clearing an already-cleared token is a no-op), **crash-safe** (the token
/// survives a crash mid-cleanup, so the work is simply retried), and
/// **independently retryable** (no participant depends on another's order).
///
/// A token this control plane does not recognize — a newer replica's, mid
/// rolling upgrade — is not dropped or force-cleared: it holds the row exactly
/// as an unfinished local participant would, and the replica that knows about
/// it clears it. That is the forward-compatible behavior, and the reason this
/// is a `RawRepresentable` string rather than a closed enum.
struct ResourceFinalizer: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The owning agent has confirmed teardown by omitting the resource from a
    /// full observed-state report (`ObservedStateApplier`). Stamped only for a
    /// placed resource — there is nothing to confirm for one that never
    /// reached an agent — and force-cleared by the direct-deletion path when
    /// the agent is offline, since a dead agent must not make its workloads
    /// undeletable.
    static let agentAbsent = ResourceFinalizer(rawValue: "agent.absent")

    // Participants the ADR names next — `ipam.release`, `dns.deregister`,
    // `fip.release` — are deliberately *not* stamped yet. Each is a database
    // cascade today, not an inline step: a VM's addresses go with its NIC rows
    // (`vm_interface_addresses` CASCADE), its DNS records are derived on
    // demand and never stored (`DNSZoneAssembler`), and its floating IPs
    // detach rather than release (`floating_ips.interface_id` SET NULL).
    // Making a token for work Postgres already does transactionally would
    // trade an atomic cascade for an eventually-consistent one. They become
    // participants when they gain an effect outside the row's transaction —
    // DNS first, when realization lands and a deletion has to withdraw
    // records from a live server.
}
