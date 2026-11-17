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

}
