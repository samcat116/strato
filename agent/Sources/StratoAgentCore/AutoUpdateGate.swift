import Foundation

// MARK: - Auto-update preconditions

/// Decides whether the agent may act on a `DesiredAgentUpdate` right now
/// (issue #434). Pure so the policy is unit-testable: the `Agent` actor
/// gathers the runtime facts and this type only judges them.
///
/// The declarative path is stricter than the operator-triggered one: an
/// operator acknowledges caveats interactively (the endpoint's `force`), but
/// auto-update runs unattended, so anything a restart would break blocks the
/// attempt outright. Blocking is never terminal — desired state is
/// level-triggered, so the agent re-evaluates on every sync and reports the
/// current reason back via `ObservedStateReport.agentUpdateStatus`.
public enum AutoUpdateGate {

    /// The runtime facts the gate judges, gathered by the `Agent` actor at
    /// evaluation time.
    ///
    /// Running VMs are deliberately NOT a condition: both QEMU and
    /// Firecracker VMs survive an agent restart and are re-adopted over
    /// their deterministic control sockets (issues #260, #433), so hosting
    /// live workloads is exactly the situation auto-update must work in.
    public struct Conditions: Sendable {
        /// How this process is installed. Containerized agents never
        /// self-converge — their binary is an immutable image layer.
        public let installMode: AgentInstallMode
        /// Reconcile work items currently in flight. The update runs as its
        /// own step only once the per-VM lanes have drained; a busy agent
        /// waits for a later sync.
        public let inFlightReconcileItems: Int

        public init(
            installMode: AgentInstallMode,
            inFlightReconcileItems: Int
        ) {
            self.installMode = installMode
            self.inFlightReconcileItems = inFlightReconcileItems
        }
    }

    /// Why the update cannot proceed right now, or nil when every
    /// precondition holds. Checks are ordered permanent-first so the reported
    /// reason is the one an operator can act on: a containerized agent's
    /// in-flight work is irrelevant.
    public static func blockedReason(_ conditions: Conditions) -> String? {
        if case .container(let marker) = conditions.installMode {
            return
                "the agent runs in a container (detected via \(marker)); its binary is managed externally — updates ship as a new image"
        }
        if conditions.inFlightReconcileItems > 0 {
            return
                "\(conditions.inFlightReconcileItems) reconcile work item(s) are in flight; the update waits for the lanes to drain"
        }
        return nil
    }
}
