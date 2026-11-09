import Foundation
import SwiftProtobuf

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
public typealias HostInfo = Strato_Agent_V1_HostInfo
extension Strato_Agent_V1_HostInfo: Codable {
    /// Human-readable OS product/distribution name including its version, e.g.
    /// "Ubuntu 24.04.1 LTS" (from `/etc/os-release` `PRETTY_NAME`) or
    /// "macOS 15.1".

    /// Kernel release string (`uname -r`), e.g. "6.8.0-45-generic" on Linux or
    /// the Darwin release "24.1.0" on macOS.

    /// CPU brand/model string, e.g. "Apple M2 Pro" or
    /// "Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz".

    /// CPU vendor identifier, e.g. "GenuineIntel", "AuthenticAMD", or "Apple".

    /// Number of physical CPU cores (distinct from `logicalCoreCount`, which
    /// counts hardware threads / hyperthreads).

    /// Number of logical CPU cores (hardware threads) available to the host.

    /// Total physical memory on the host, in bytes.

    /// Machine/hardware model identifier, e.g. "MacBookPro18,3" (macOS
    /// `hw.model`) or the DMI product name on Linux ("PowerEdge R650").

    /// The instant the host last booted. A fixed point in time (unlike an
    /// uptime duration, which goes stale the moment it's stored), so the UI can
    /// render a live "up for N days" from it.

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
        self.init()
        self._jsonOsName = osName
        self._jsonKernelVersion = kernelVersion
        self._jsonCpuModel = cpuModel
        self._jsonCpuVendor = cpuVendor
        self._jsonPhysicalCoreCount = physicalCoreCount
        self._jsonLogicalCoreCount = logicalCoreCount
        self._jsonTotalMemoryBytes = totalMemoryBytes
        self._jsonMachineModel = machineModel
        self._jsonBootTime = bootTime
    }

    private enum CodingKeys: String, CodingKey {
        case osName; case kernelVersion; case cpuModel; case cpuVendor; case physicalCoreCount; case logicalCoreCount;
        case totalMemoryBytes; case machineModel; case bootTime
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonOsName = try container.decodeIfPresent(String.self, forKey: .osName)
        self._jsonKernelVersion = try container.decodeIfPresent(String.self, forKey: .kernelVersion)
        self._jsonCpuModel = try container.decodeIfPresent(String.self, forKey: .cpuModel)
        self._jsonCpuVendor = try container.decodeIfPresent(String.self, forKey: .cpuVendor)
        self._jsonPhysicalCoreCount = try container.decodeIfPresent(Int.self, forKey: .physicalCoreCount)
        self._jsonLogicalCoreCount = try container.decodeIfPresent(Int.self, forKey: .logicalCoreCount)
        self._jsonTotalMemoryBytes = try container.decodeIfPresent(Int64.self, forKey: .totalMemoryBytes)
        self._jsonMachineModel = try container.decodeIfPresent(String.self, forKey: .machineModel)
        self._jsonBootTime = try container.decodeIfPresent(Date.self, forKey: .bootTime)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonOsName, forKey: .osName)
        try container.encodeIfPresent(_jsonKernelVersion, forKey: .kernelVersion)
        try container.encodeIfPresent(_jsonCpuModel, forKey: .cpuModel)
        try container.encodeIfPresent(_jsonCpuVendor, forKey: .cpuVendor)
        try container.encodeIfPresent(_jsonPhysicalCoreCount, forKey: .physicalCoreCount)
        try container.encodeIfPresent(_jsonLogicalCoreCount, forKey: .logicalCoreCount)
        try container.encodeIfPresent(_jsonTotalMemoryBytes, forKey: .totalMemoryBytes)
        try container.encodeIfPresent(_jsonMachineModel, forKey: .machineModel)
        try container.encodeIfPresent(_jsonBootTime, forKey: .bootTime)
    }

    var _jsonOsName: String? {
        get { hasOsName ? (osName) : nil }
        set { if let value = newValue { osName = value } else { clearOsName() } }
    }
    var _jsonKernelVersion: String? {
        get { hasKernelVersion ? (kernelVersion) : nil }
        set { if let value = newValue { kernelVersion = value } else { clearKernelVersion() } }
    }
    var _jsonCpuModel: String? {
        get { hasCpuModel ? (cpuModel) : nil }
        set { if let value = newValue { cpuModel = value } else { clearCpuModel() } }
    }
    var _jsonCpuVendor: String? {
        get { hasCpuVendor ? (cpuVendor) : nil }
        set { if let value = newValue { cpuVendor = value } else { clearCpuVendor() } }
    }
    var _jsonPhysicalCoreCount: Int? {
        get { hasPhysicalCoreCount ? (Int(physicalCoreCount)) : nil }
        set { if let value = newValue { physicalCoreCount = Int64(value) } else { clearPhysicalCoreCount() } }
    }
    var _jsonLogicalCoreCount: Int? {
        get { hasLogicalCoreCount ? (Int(logicalCoreCount)) : nil }
        set { if let value = newValue { logicalCoreCount = Int64(value) } else { clearLogicalCoreCount() } }
    }
    var _jsonTotalMemoryBytes: Int64? {
        get { hasTotalMemoryBytes ? (totalMemoryBytes) : nil }
        set { if let value = newValue { totalMemoryBytes = value } else { clearTotalMemoryBytes() } }
    }
    var _jsonMachineModel: String? {
        get { hasMachineModel ? (machineModel) : nil }
        set { if let value = newValue { machineModel = value } else { clearMachineModel() } }
    }
    var _jsonBootTime: Date? {
        get { hasBootTime ? (bootTime.date) : nil }
        set { if let value = newValue { bootTime = Google_Protobuf_Timestamp(date: value) } else { clearBootTime() } }
    }
}
