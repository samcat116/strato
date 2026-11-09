import Foundation
import SwiftProtobuf

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
public typealias VMMemoryStats = Strato_Agent_V1_VMMemoryStats
extension Strato_Agent_V1_VMMemoryStats: Codable {
    /// Total memory visible to the guest OS (`stat-total-memory`). This can be
    /// less than the VM spec's memory grant: firmware reservations come out of
    /// it, and an inflated balloon shrinks it further.

    /// Memory the guest considers available for new allocations without
    /// swapping (`stat-available-memory`) — free pages plus reclaimable caches.
    /// The interesting number: `totalBytes - availableBytes` is what the guest
    /// is actually using.

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

    public init(
        totalBytes: Int64,
        availableBytes: Int64,
        balloonActualBytes: Int64? = nil
    ) {
        self.init()
        self._jsonTotalBytes = totalBytes
        self._jsonAvailableBytes = availableBytes
        self._jsonBalloonActualBytes = balloonActualBytes
    }

    private enum CodingKeys: String, CodingKey { case totalBytes; case availableBytes; case balloonActualBytes }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonTotalBytes = try container.decode(Int64.self, forKey: .totalBytes)
        self._jsonAvailableBytes = try container.decode(Int64.self, forKey: .availableBytes)
        self._jsonBalloonActualBytes = try container.decodeIfPresent(Int64.self, forKey: .balloonActualBytes)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonTotalBytes, forKey: .totalBytes)
        try container.encode(_jsonAvailableBytes, forKey: .availableBytes)
        try container.encodeIfPresent(_jsonBalloonActualBytes, forKey: .balloonActualBytes)
    }

    var _jsonTotalBytes: Int64 {
        get { totalBytes }
        set { let value = newValue; totalBytes = value }
    }
    var _jsonAvailableBytes: Int64 {
        get { availableBytes }
        set { let value = newValue; availableBytes = value }
    }
    var _jsonBalloonActualBytes: Int64? {
        get { hasBalloonActualBytes ? (balloonActualBytes) : nil }
        set { if let value = newValue { balloonActualBytes = value } else { clearBalloonActualBytes() } }
    }
}
