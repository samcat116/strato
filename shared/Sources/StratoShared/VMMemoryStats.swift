import Foundation

/// Guest memory usage for one VM, as reported by its virtio-balloon device's
/// guest statistics (issue #567), attached to the VM's `ObservedVMState` on the
/// agent → control-plane observed-state report.
///
/// Best-effort and informational, exactly like `GuestInfo`: the balloon stats
/// come from the *guest's* virtio_balloon driver, so the whole struct is absent
/// (`ObservedVMState.memoryStats == nil`) for VMs whose guest lacks the driver,
/// is still booting, or hasn't answered a stats poll yet — absence must never be
/// read as "zero memory used". Nothing keys convergence or scheduling on these
/// values today; they are the observability groundwork for reclaim/overcommit
/// policy later.
public struct VMMemoryStats: Codable, Sendable, Equatable {
    /// Total memory visible to the guest OS (`stat-total-memory`). This can be
    /// less than the VM spec's memory grant: firmware reservations come out of
    /// it, and an inflated balloon shrinks it further.
    public let totalBytes: Int64

    /// Memory the guest considers available for new allocations without
    /// swapping (`stat-available-memory`) — free pages plus reclaimable caches.
    /// The interesting number: `totalBytes - availableBytes` is what the guest
    /// is actually using.
    public let availableBytes: Int64

    /// Strictly free pages (`stat-free-memory`), excluding reclaimable caches,
    /// when the guest driver reports it. Nil when unreported.
    public let freeBytes: Int64?

    /// Memory the balloon currently leaves to the guest (`query-balloon`'s
    /// `actual`), in bytes — the host-side view of an operator's balloon
    /// target (issue #567 phase 2). Equal to the VM's memory grant on a VM
    /// with no target set, and it converges *toward* a newly set target as
    /// the guest's driver hands pages back, so a value above the target
    /// mid-inflation is expected, not a fault.
    ///
    /// Unlike the `stat-*` fields this comes from QEMU, not the guest, so it
    /// is reported even for a guest whose driver never loaded. Nil only when
    /// the VM has no balloon device (created before issue #567) or the query
    /// failed.
    public let balloonActualBytes: Int64?

    public init(
        totalBytes: Int64,
        availableBytes: Int64,
        freeBytes: Int64? = nil,
        balloonActualBytes: Int64? = nil
    ) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.freeBytes = freeBytes
        self.balloonActualBytes = balloonActualBytes
    }
}
