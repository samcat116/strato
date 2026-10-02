import Foundation

/// Backend controls computed from an admitted class snapshot. This is an
/// agent-local enforcement plan, not a resource-class or wire model.
public struct BurstableResourceLimits: Sendable, Equatable {
    public enum InvalidLimits: Error, Equatable {
        case guestGrant
        case backendOverhead
        case memoryHighPercent
        case cpuWeight
        case overflow
        case pressureThreshold
        case libvirtGranularity
    }

    public let memoryHighBytes: Int64
    public let memoryMaxBytes: Int64
    public let cpuWeight: Int

    public init(guestGrantBytes: Int64, backendOverheadBytes: Int64, memoryHighPercent: Int, cpuWeight: Int) throws {
        guard guestGrantBytes > 0 else { throw InvalidLimits.guestGrant }
        guard backendOverheadBytes >= 0 else { throw InvalidLimits.backendOverhead }
        guard (1...99).contains(memoryHighPercent) else { throw InvalidLimits.memoryHighPercent }
        guard (1...10000).contains(cpuWeight) else { throw InvalidLimits.cpuWeight }

        // Multiplying the entire grant by a percentage can overflow even
        // when its final quotient fits. Both products here are bounded by G.
        let percentage = Int64(memoryHighPercent)
        let guestHigh = (guestGrantBytes / 100) * percentage + (guestGrantBytes % 100) * percentage / 100
        let (maximum, maxOverflow) = guestGrantBytes.addingReportingOverflow(backendOverheadBytes)
        let (high, highOverflow) = guestHigh.addingReportingOverflow(backendOverheadBytes)
        guard !maxOverflow, !highOverflow else { throw InvalidLimits.overflow }
        guard high > 0, high < maximum else { throw InvalidLimits.pressureThreshold }
        self.memoryHighBytes = high
        self.memoryMaxBytes = maximum
        self.cpuWeight = cpuWeight
    }

    /// Libvirt memory parameters use KiB. Reclaim may start up to 1023 bytes
    /// earlier, while the existing hard-ceiling conversion rounds upward.
    /// Refuse an unrepresentable pressure threshold rather than disable it.
    public func libvirtMemoryKibibytes() throws -> (high: UInt64, maximum: UInt64) {
        let high = UInt64(memoryHighBytes) / 1024
        let maximum = (UInt64(memoryMaxBytes) + 1023) / 1024
        guard high > 0, high < maximum else { throw InvalidLimits.libvirtGranularity }
        return (high, maximum)
    }

    /// Jailer limits are installed before the Firecracker process executes.
    /// Do not add cpu.max: unused CPU remains available to the shared tier.
    public var jailerEntries: [String] {
        ["memory.high=\(memoryHighBytes)", "memory.max=\(memoryMaxBytes)", "cpu.weight=\(cpuWeight)"]
    }
}
