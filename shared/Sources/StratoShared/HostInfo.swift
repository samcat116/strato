import Foundation

/// Descriptive hardware, platform, and OS details for a hypervisor host,
/// gathered by the agent at registration and surfaced on the agent object for
/// operators. Purely informational — the scheduler keys placement on the typed
/// `CPUArchitecture`, `HypervisorSupport`, and `AgentResources` fields, not on
/// anything here.
///
/// Every field is optional: probes are best-effort and platform-specific (a
/// value the agent couldn't read stays `nil`), and the whole struct is absent
/// for agents that registered before host-info reporting, so readers must
/// tolerate missing pieces rather than assume a complete record.
public struct HostInfo: Codable, Sendable, Equatable {
    /// Human-readable OS product/distribution name including its version, e.g.
    /// "Ubuntu 24.04.1 LTS" (from `/etc/os-release` `PRETTY_NAME`) or
    /// "macOS 15.1".
    public let osName: String?

    /// Kernel release string (`uname -r`), e.g. "6.8.0-45-generic" on Linux or
    /// the Darwin release "24.1.0" on macOS.
    public let kernelVersion: String?

    /// CPU brand/model string, e.g. "Apple M2 Pro" or
    /// "Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz".
    public let cpuModel: String?

    /// CPU vendor identifier, e.g. "GenuineIntel", "AuthenticAMD", or "Apple".
    public let cpuVendor: String?

    /// Number of physical CPU cores (distinct from `logicalCoreCount`, which
    /// counts hardware threads / hyperthreads).
    public let physicalCoreCount: Int?

    /// Number of logical CPU cores (hardware threads) available to the host.
    public let logicalCoreCount: Int?

    /// Total physical memory on the host, in bytes.
    public let totalMemoryBytes: Int64?

    /// Machine/hardware model identifier, e.g. "MacBookPro18,3" (macOS
    /// `hw.model`) or the DMI product name on Linux ("PowerEdge R650").
    public let machineModel: String?

    /// The instant the host last booted. A fixed point in time (unlike an
    /// uptime duration, which goes stale the moment it's stored), so the UI can
    /// render a live "up for N days" from it.
    public let bootTime: Date?

    public init(
        osName: String? = nil,
        kernelVersion: String? = nil,
        cpuModel: String? = nil,
        cpuVendor: String? = nil,
        physicalCoreCount: Int? = nil,
        logicalCoreCount: Int? = nil,
        totalMemoryBytes: Int64? = nil,
        machineModel: String? = nil,
        bootTime: Date? = nil
    ) {
        self.osName = osName
        self.kernelVersion = kernelVersion
        self.cpuModel = cpuModel
        self.cpuVendor = cpuVendor
        self.physicalCoreCount = physicalCoreCount
        self.logicalCoreCount = logicalCoreCount
        self.totalMemoryBytes = totalMemoryBytes
        self.machineModel = machineModel
        self.bootTime = bootTime
    }
}
