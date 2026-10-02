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
        case pageSize
        case kernelGranularity
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

    /// Use the enforcement host's actual page size. Explicit alignment avoids
    /// losing the pressure interval when the kernel quantizes memory controls.
    /// The earlier high threshold and extra hard-limit headroom are each less
    /// than one page. Never saturate an overflowing hard limit to infinity.
    public func kernelMemoryBytes(pageSize: Int64) throws -> (high: Int64, maximum: Int64) {
        guard pageSize >= 1024, pageSize.nonzeroBitCount == 1 else { throw InvalidLimits.pageSize }
        let high = (memoryHighBytes / pageSize) * pageSize
        let remainder = memoryMaxBytes % pageSize
        let padding = remainder == 0 ? 0 : pageSize - remainder
        let (maximum, overflow) = memoryMaxBytes.addingReportingOverflow(padding)
        guard !overflow else { throw InvalidLimits.overflow }
        guard high > 0, high < maximum else { throw InvalidLimits.kernelGranularity }
        return (high, maximum)
    }

    /// Page-aligned bytes are exactly representable in libvirt's KiB units.
    public func libvirtMemoryKibibytes(pageSize: Int64) throws -> (high: UInt64, maximum: UInt64) {
        let bytes = try kernelMemoryBytes(pageSize: pageSize)
        let high = UInt64(bytes.high) / 1024
        let maximum = UInt64(bytes.maximum) / 1024
        return (high, maximum)
    }

    /// Jailer limits are installed before the Firecracker process executes.
    /// Do not add cpu.max: unused CPU remains available to the shared tier.
    public func jailerEntries(pageSize: Int64) throws -> [String] {
        let bytes = try kernelMemoryBytes(pageSize: pageSize)
        return ["memory.high=\(bytes.high)", "memory.max=\(bytes.maximum)", "cpu.weight=\(cpuWeight)"]
    }
}
