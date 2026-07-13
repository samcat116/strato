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
    public struct Conditions: Sendable {
        /// How this process is installed. Containerized agents never
        /// self-converge — their binary is an immutable image layer.
        public let installMode: AgentInstallMode
        /// Managed Firecracker VMs whose process is (or may be) alive. They
        /// are not re-adopted after a restart (issue #433) and would be
        /// orphaned, so any non-zero count blocks. Includes transitional and
        /// unknown statuses: only a VM known to be at rest is safe to lose.
        public let runningFirecrackerVMs: Int
        /// Reconcile work items currently in flight. The update runs as its
        /// own step only once the per-VM lanes have drained; a busy agent
        /// waits for a later sync.
        public let inFlightReconcileItems: Int

        public init(
            installMode: AgentInstallMode,
            runningFirecrackerVMs: Int,
            inFlightReconcileItems: Int
        ) {
            self.installMode = installMode
            self.runningFirecrackerVMs = runningFirecrackerVMs
            self.inFlightReconcileItems = inFlightReconcileItems
        }
    }

    /// Why the update cannot proceed right now, or nil when every
    /// precondition holds. Checks are ordered permanent-first so the reported
    /// reason is the one an operator can act on: a containerized agent's
    /// count of running VMs is irrelevant.
    public static func blockedReason(_ conditions: Conditions) -> String? {
        if case .container(let marker) = conditions.installMode {
            return
                "the agent runs in a container (detected via \(marker)); its binary is managed externally — updates ship as a new image"
        }
        if conditions.runningFirecrackerVMs > 0 {
            return
                "\(conditions.runningFirecrackerVMs) Firecracker VM(s) are running and would be orphaned by an agent restart (re-adoption is not supported yet)"
        }
        if conditions.inFlightReconcileItems > 0 {
            return
                "\(conditions.inFlightReconcileItems) reconcile work item(s) are in flight; the update waits for the lanes to drain"
        }
        return nil
    }
}
