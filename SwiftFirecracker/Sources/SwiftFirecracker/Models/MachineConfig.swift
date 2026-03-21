import Foundation

/// Machine configuration for Firecracker VM
/// Maps to PUT /machine-config API endpoint
public struct MachineConfig: Codable, Sendable {
    /// Number of vCPUs (1-32)
    public let vcpuCount: Int

    /// Memory size in MiB
    public let memSizeMib: Int

    /// Enable simultaneous multithreading (hyperthreading)
    public let smt: Bool?

    /// Enable dirty page tracking for live migration/snapshotting
    public let trackDirtyPages: Bool?

    /// CPU template: "C3" or "T2" for Intel, "T2A" for AMD, "V1N1" for ARM
    public let cpuTemplate: String?

    enum CodingKeys: String, CodingKey {
        case vcpuCount = "vcpu_count"
        case memSizeMib = "mem_size_mib"
        case smt
        case trackDirtyPages = "track_dirty_pages"
        case cpuTemplate = "cpu_template"
    }

    public init(
        vcpuCount: Int,
        memSizeMib: Int,
        smt: Bool? = nil,
        trackDirtyPages: Bool? = nil,
        cpuTemplate: String? = nil
    ) {
        self.vcpuCount = vcpuCount
        self.memSizeMib = memSizeMib
        self.smt = smt
        self.trackDirtyPages = trackDirtyPages
        self.cpuTemplate = cpuTemplate
    }
}

/// Response from GET /machine-config
public struct MachineConfigResponse: Codable, Sendable {
    public let vcpuCount: Int
    public let memSizeMib: Int
    public let smt: Bool
    public let trackDirtyPages: Bool
    public let cpuTemplate: String?

    enum CodingKeys: String, CodingKey {
        case vcpuCount = "vcpu_count"
        case memSizeMib = "mem_size_mib"
        case smt
        case trackDirtyPages = "track_dirty_pages"
        case cpuTemplate = "cpu_template"
    }
}
