import Foundation

/// Machine configuration for Firecracker VM
/// Maps to PUT /machine-config API endpoint
public struct MachineConfig: Codable, Sendable {
    /// Number of vCPUs (1-32)
    let vcpuCount: Int

    /// Memory size in MiB
    let memSizeMib: Int

    /// CPU template: "C3" or "T2" for Intel, "T2A" for AMD, "V1N1" for ARM
    let cpuTemplate: String?

    enum CodingKeys: String, CodingKey {
        case vcpuCount = "vcpu_count"
        case memSizeMib = "mem_size_mib"
        case cpuTemplate = "cpu_template"
    }

    public init(
        vcpuCount: Int,
        memSizeMib: Int,
        cpuTemplate: String? = nil
    ) {
        self.vcpuCount = vcpuCount
        self.memSizeMib = memSizeMib
        self.cpuTemplate = cpuTemplate
    }
}
