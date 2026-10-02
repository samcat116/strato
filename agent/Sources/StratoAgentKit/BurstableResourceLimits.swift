import Foundation
import StratoShared

/// Backend controls computed from an admitted class snapshot. This is an
/// agent-local enforcement plan, not a resource-class or wire model.
public struct BurstableResourceLimits: Sendable, Equatable {
    public enum InvalidLimits: Error, Equatable {
        case overflow
        case pageSize
        case kernelGranularity
    }

    private let intent: WorkloadRuntimeLimits
    public var memoryHighBytes: Int64 { intent.memoryHighBytes }
    public var memoryMaxBytes: Int64 { intent.memoryMaxBytes }
    public var cpuWeight: Int { intent.cpuWeight }

    public init(guestGrantBytes: Int64, backendOverheadBytes: Int64, memoryHighPercent: Int, cpuWeight: Int) throws {
        let policy = try WorkloadResourceClassPolicy(
            kind: .burstable, cpuWeight: cpuWeight, memoryHighPercent: memoryHighPercent)
        self.intent = try policy.runtimeLimits(guestBytes: guestGrantBytes, backendOverheadBytes: backendOverheadBytes)
    }

    private init(intent: WorkloadRuntimeLimits) {
        self.intent = intent
    }

    /// Missing and guaranteed snapshots preserve the existing runtime path.
    /// Consume the persisted admitted policy, never the current class catalog.
    public static func plan(
        resourceClass: WorkloadResourceClassSnapshot?, guestGrantBytes: Int64, backendOverheadBytes: Int64
    ) throws -> Self? {
        guard let resourceClass, resourceClass.policy.kind == .burstable else { return nil }
        return Self(
            intent: try resourceClass.policy.runtimeLimits(
                guestBytes: guestGrantBytes, backendOverheadBytes: backendOverheadBytes))
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
