import Foundation
import StratoShared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Probes the host for actually-usable hypervisors, instead of assuming them
/// from the platform. Availability means "a VM could be created right now":
/// the hypervisor binary exists and is executable, and (for Firecracker) the
/// hardware virtualization it depends on is accessible.
///
/// The probe results are reported to the control plane at registration so the
/// scheduler can filter placement by what each host can really run.
public enum HypervisorProbe {

    /// Probe every hypervisor this agent could manage on the current host.
    public static func probeAll(qemuBinaryPath: String, firecrackerBinaryPath: String) -> [HypervisorSupport] {
        let acceleration = probeAcceleration()
        var reports = [qemuReport(binaryPath: qemuBinaryPath, acceleration: acceleration)]

        #if os(Linux)
        reports.append(firecrackerReport(binaryPath: firecrackerBinaryPath, acceleration: acceleration))
        #else
        reports.append(HypervisorSupport(
            type: .firecracker,
            available: false,
            accelerated: false,
            unavailabilityReason: "Firecracker is only supported on Linux",
            capabilities: .firecracker
        ))
        #endif

        return reports
    }

    /// Result of probing for hardware-assisted virtualization.
    public struct AccelerationProbe {
        public init(available: Bool, reason: String?) {
            self.available = available
            self.reason = reason
        }

        /// Whether KVM (Linux) or HVF (macOS) is usable.
        public let available: Bool
        /// Why acceleration is unavailable, when it is.
        public let reason: String?
    }

    /// Check whether hardware virtualization is usable on this host:
    /// `/dev/kvm` readable and writable on Linux, `kern.hv_support` on macOS.
    public static func probeAcceleration() -> AccelerationProbe {
        #if os(Linux)
        guard FileManager.default.fileExists(atPath: "/dev/kvm") else {
            return AccelerationProbe(available: false, reason: "/dev/kvm not present")
        }
        guard access("/dev/kvm", R_OK | W_OK) == 0 else {
            return AccelerationProbe(available: false, reason: "/dev/kvm not accessible (permission denied)")
        }
        return AccelerationProbe(available: true, reason: nil)
        #elseif os(macOS)
        var hvSupport: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_support", &hvSupport, &size, nil, 0) == 0, hvSupport == 1 else {
            return AccelerationProbe(available: false, reason: "Hypervisor.framework not supported on this host")
        }
        return AccelerationProbe(available: true, reason: nil)
        #else
        return AccelerationProbe(available: false, reason: "No hardware acceleration on this platform")
        #endif
    }

    /// QEMU is available when its binary is executable; without KVM/HVF it can
    /// still run VMs under TCG emulation, so acceleration only affects the
    /// `accelerated` flag, not availability.
    public static func qemuReport(binaryPath: String, acceleration: AccelerationProbe) -> HypervisorSupport {
        let binaryUsable = FileManager.default.isExecutableFile(atPath: binaryPath)
        return HypervisorSupport(
            type: .qemu,
            available: binaryUsable,
            accelerated: binaryUsable && acceleration.available,
            unavailabilityReason: binaryUsable ? nil : "QEMU binary not found or not executable at \(binaryPath)",
            capabilities: .qemu
        )
    }

    /// Firecracker has no emulation fallback: it needs both its binary and KVM.
    public static func firecrackerReport(binaryPath: String, acceleration: AccelerationProbe) -> HypervisorSupport {
        let binaryUsable = FileManager.default.isExecutableFile(atPath: binaryPath)

        let reason: String?
        if !binaryUsable {
            reason = "Firecracker binary not found or not executable at \(binaryPath)"
        } else if !acceleration.available {
            reason = acceleration.reason ?? "KVM unavailable"
        } else {
            reason = nil
        }

        return HypervisorSupport(
            type: .firecracker,
            available: binaryUsable && acceleration.available,
            accelerated: binaryUsable && acceleration.available,
            unavailabilityReason: reason,
            capabilities: .firecracker
        )
    }
}
