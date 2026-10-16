import StratoShared

/// A backend must pass the complete canonical enforcement contract before
/// taking a burstable execution path. Controller discovery alone is insufficient.
public enum BurstableRuntimeGate {
    public static func requireSupport(
        resourceClass: WorkloadResourceClassSnapshot?,
        enforcement: WorkloadResourceClassEnforcement? = nil
    ) throws {
        guard resourceClass?.policy.kind == .burstable else { return }
        guard enforcement?.supportsBurstable == true else {
            throw ConvergenceError.blocked(
                "Burstable runtime enforcement is unavailable: delegated CPU/memory controllers, stable owned cgroup, "
                    + "pre-execution controls and effective readback are all required")
        }
    }
}
