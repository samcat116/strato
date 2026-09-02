import Foundation
import StratoShared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Probes the host for actually-usable hypervisors, instead of assuming them
/// from the platform. Availability means "a VM could be created right now":
/// for QEMU, libvirtd is reachable at `qemu:///system`; for Firecracker, its
/// binary is executable and the hardware virtualization it depends on is
/// accessible.
///
/// The probe results are reported to the control plane at registration so the
/// scheduler can filter placement by what each host can really run.
public enum HypervisorProbe {

    /// Probe every hypervisor this agent could manage on the current host.
    ///
    /// `libvirt` is what `LibvirtProbe.probe()` found, or nil on a platform
    /// where libvirt cannot exist. It is a parameter rather than something this
    /// probe goes and looks up because the caller has already paid for it: the
    /// host preflight needs the same answer, and asking twice would mean two
    /// `virsh` invocations per registration.
    public static func probeAll(
        libvirt: LibvirtProbe.Status?, firecrackerBinaryPath: String
    ) -> [HypervisorSupport] {
        let acceleration = probeAcceleration()
        var reports = [qemuReport(libvirt: libvirt, acceleration: acceleration)]

        #if os(Linux)
        reports.append(firecrackerReport(binaryPath: firecrackerBinaryPath, acceleration: acceleration))
        #else
        reports.append(
            HypervisorSupport(
                type: .firecracker,
                available: false,
                accelerated: false,
                unavailabilityReason: "Firecracker is only supported on Linux",
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

    /// QEMU availability is a **libvirt** fact, not a binary one (STR-136): the
    /// agent no longer spawns `qemu-system-*` itself, and libvirtd picks the
    /// emulator from its own capabilities, so there is no path here to check.
    /// A daemon the host cannot reach is a host that cannot run a VM, so that is
    /// what this reports on.
    ///
    /// The **version floor** is deliberately not applied here — it belongs to
    /// `HostPreflight`, which owns the check and the remediation that goes with
    /// it, and duplicating the comparison would give two places to get it wrong.
    /// `HostPreflight.gate` demotes this entry for a too-old daemon (and for
    /// unusable storage). This function answers the cruder question so that a
    /// caller which never reaches the gate cannot come away believing a host
    /// with no libvirt can run VMs.
    ///
    /// Off Linux there is no libvirt at all and the registered backend is a
    /// mock, so it reports unavailable rather than letting real placements land
    /// on it. Without KVM a host can still run VMs under TCG emulation, so
    /// acceleration only affects the `accelerated` flag.
    public static func qemuReport(
        libvirt: LibvirtProbe.Status?, acceleration: AccelerationProbe
    ) -> HypervisorSupport {
        #if os(Linux)
        guard let libvirt else {
            return HypervisorSupport(
                type: .qemu, available: false, accelerated: false,
                unavailabilityReason: "libvirt was not probed, so QEMU cannot be reported as usable",
            )
        }
        guard case .reachable = libvirt else {
            return HypervisorSupport(
                type: .qemu, available: false, accelerated: false,
                unavailabilityReason:
                    "libvirtd is not usable at \(LibvirtProbe.systemURI): \(libvirt.summary)",
            )
        }
        return HypervisorSupport(
            type: .qemu,
            available: true,
            accelerated: acceleration.available,
            unavailabilityReason: nil,
        )
        #else
        return HypervisorSupport(
            type: .qemu,
            available: false,
            accelerated: false,
            unavailabilityReason: "QEMU is driven through libvirtd, which is only supported on Linux",
        )
        #endif
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
        )
    }

    /// How long the version probe waits for the binary to answer. This runs
    /// inline on the registration path, which has no other escape hatch, so a
    /// `firecracker_binary_path` pointing at something that blocks (a wrapper
    /// script waiting on a lock, a stalled network mount) must not be able to
    /// wedge the agent's registration and every subsequent reconnect. Printing
    /// a version string is sub-millisecond work; seconds is already generous.
    public static let versionProbeTimeout: Duration = .seconds(5)

    /// The Firecracker binary's version, from `firecracker --version` output
    /// like "Firecracker v1.7.0" — normalized without the cosmetic "v" so it
    /// compares equal to the `vmm_version` recorded on snapshots. Snapshot
    /// mobility (issue #428) keys cross-agent restore placement on this;
    /// nil (probe failed, timed out, unparseable output) just keeps this host
    /// ineligible as a cross-agent restore target.
    public static func firecrackerVersion(
        binaryPath: String, timeout: Duration = versionProbeTimeout
    ) async -> String? {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return nil }
        guard
            let result = try? await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: binaryPath), arguments: ["--version"],
                timeout: timeout),
            result.terminationStatus == 0,
            let output = String(data: result.standardOutput, encoding: .utf8)
        else { return nil }
        // First line: "Firecracker v1.7.0"; take the last whitespace-separated
        // token and strip the prefix.
        guard let firstLine = output.split(separator: "\n").first,
            let token = firstLine.split(separator: " ").last
        else { return nil }
        let version = token.hasPrefix("v") ? String(token.dropFirst()) : String(token)
        return version.isEmpty ? nil : version
    }

    /// Returns `hypervisors` with `version` stamped onto the Firecracker
    /// entry. Separate from `probeAll` because reading the version spawns a
    /// subprocess (async), while the availability probes are synchronous.
    public static func stampingFirecrackerVersion(
        _ hypervisors: [HypervisorSupport], version: String?
    ) -> [HypervisorSupport] {
        guard let version else { return hypervisors }
        return hypervisors.map { support in
            guard support.type == .firecracker else { return support }
            return HypervisorSupport(
                type: support.type,
                available: support.available,
                accelerated: support.accelerated,
                unavailabilityReason: support.unavailabilityReason,
                version: version
            )
        }
    }
}
