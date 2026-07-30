import Foundation

/// Upper bounds on the sizing a caller may request for a workload — a VM or a
/// sandbox (issue #826). Requests above these are rejected with
/// `400 Bad Request`, alongside the volume ceiling (`Volume.maxSizeGB`).
///
/// The bounds are deliberately generous — far above any host Strato schedules
/// onto — but far below the point where the figures they gate can overflow a
/// quota's reservation counters. Without them, a mistyped or hostile size
/// committed a workload no agent could ever satisfy
/// (`SchedulerService.filterEligibleAgents` requires the host to have at least
/// the requested vCPUs and memory), leaving a permanently unplaceable resource
/// behind.
enum WorkloadSizeLimits {
    /// Ceiling on a workload's vCPU count. On a VM this is also the hotplug
    /// slot count its hypervisor process spawns with, which is where the bound
    /// was first needed (`VMController.maxHotpluggableCPUs` names it from that
    /// angle); a sandbox has no hot-add ceiling of its own, so it is bounded
    /// here directly.
    static let maxVCPUs = 512

    /// Ceiling on a workload's guest memory, and so on a VM's `maxMemory`
    /// hot-add headroom: 64 TiB, roughly double the largest commodity server.
    static let maxMemoryBytes: Int64 = 65_536 * 1024 * 1024 * 1024

    /// Ceiling on a VM's boot disk: the same 256 TiB a volume may request,
    /// since that disk becomes a volume.
    static let maxDiskBytes: Int64 = Int64(Volume.maxSizeGB) * 1024 * 1024 * 1024
}
