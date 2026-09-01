import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import StratoShared
import StratoAgentCore
import StratoAgentSPIFFE

#if os(Linux)
// One shared Firecracker client backs both VMs and sandboxes (issue #421).
import SwiftFirecracker
// geteuid(): the jailer needs root, so the start-time jailer resolution
// (issue #425) checks the effective uid.
import Glibc
#endif

/// Owns startup host capability probes and admission diagnostics.
extension Agent {
    // MARK: - Host preflight

    /// Probes libvirtd, whose reachability and version the preflight checks.
    /// Linux-only: libvirt's QEMU driver is, and the whole point of the probe is
    /// the daemon a hypervisor node manages VMs through.
    ///
    /// Spawns a subprocess, hence async and separate from `runHostPreflight` —
    /// the same split `HypervisorProbe.firecrackerVersion` uses.
    func probeLibvirt() async -> LibvirtProbe.Status? {
        #if os(Linux)
        return await LibvirtProbe.probe()
        #else
        return nil
        #endif
    }

    /// Whether libvirt can back a guest vTPM (issue #565).
    ///
    /// Asked only of a daemon that already answered `probeLibvirt()`. Off Linux
    /// there is no daemon at all, and on a host whose libvirt is missing or
    /// unreachable the answer is decided by that failure rather than by
    /// anything a second `virsh` invocation would find.
    func probeTPMSupport(libvirt: LibvirtProbe.Status?) async -> LibvirtProbe.TPMSupport {
        #if os(Linux)
        guard case .reachable = libvirt else {
            return .unknown(libvirt?.summary ?? "libvirt was not probed")
        }
        return await LibvirtProbe.probeTPM()
        #else
        return .unknown("libvirt is only supported on Linux")
        #endif
    }

    /// Runs the host-readiness checks against this agent's resolved
    /// configuration. Called at every registration (initial and reconnect) so
    /// the reported capabilities always reflect the host as it is now.
    func runHostPreflight(
        libvirt: LibvirtProbe.Status? = nil,
        tpmSupport: LibvirtProbe.TPMSupport = .unknown("not probed")
    ) -> HostPreflight.Report {
        #if os(Linux)
        let firecrackerSocketDirectory: String? = firecrackerSocketDir
        let qemuFirmwareDescriptorPath: String? = "/usr/share/qemu/firmware"
        let vhostVsock: HostPreflight.VhostVsockSupport = .device(path: "/dev/vhost-vsock")
        #else
        let firecrackerSocketDirectory: String? = nil
        let qemuFirmwareDescriptorPath: String? = nil
        let vhostVsock: HostPreflight.VhostVsockSupport = .unsupportedPlatform(
            "virtio-vsock for QEMU is not supported on this platform")
        #endif

        // Mirror the driver's firmware resolution so the preflight reports
        // what a VM would actually boot with: the split pair's CODE image when
        // one resolves, else the monolithic fallback (issue #565).
        let resolvedFirmwarePath: String?
        switch try? FirmwareResolver.resolve(secureBoot: false, overrides: firmware) {
        case .pflash(let code, _):
            resolvedFirmwarePath = code
        case .monolithic(let path):
            resolvedFirmwarePath = path
        case nil:
            resolvedFirmwarePath = nil
        }

        return HostPreflight.run(
            HostPreflight.Inputs(
                vmStoragePath: vmStoragePath,
                volumeStoragePath: volumeStoragePath,
                imageCachePath: imageCachePath ?? ImageCacheService.defaultCachePath,
                qemuImgPath: FileSystemStorageBackend.defaultQemuImgPath,
                firecrackerSocketDirectory: firecrackerSocketDirectory,
                firmwarePath: resolvedFirmwarePath,
                tpmSupport: tpmSupport,
                qemuFirmwareDescriptorPath: qemuFirmwareDescriptorPath,
                libvirt: libvirt,
                vhostVsock: vhostVsock,
                ovnMode: effectiveNetworkMode == .ovn,
                ovnNBConnection: ovnNorthbound ?? "unix:/var/run/ovn/ovnnb_db.sock",
                ovnNBTLSFilePaths: ovnNorthboundTLS?.configuredFilePaths ?? []
            ))
    }

    /// Logs every failed preflight check with its remediation — gating
    /// failures as errors, advisory ones as warnings — so a misconfigured
    /// host explains itself at startup instead of failing VM operations
    /// minutes later.
    func logHostPreflight(_ report: HostPreflight.Report) {
        for unsupported in report.unsupported {
            logger.info(
                "Host preflight: \(unsupported.detail ?? "not supported on this platform")",
                metadata: ["check": .string(unsupported.kind.rawValue)])
        }
        for failure in report.failures {
            let detail = failure.detail ?? failure.kind.rawValue
            let metadata: Logger.Metadata = ["check": .string(failure.kind.rawValue)]
            switch failure.severity {
            case .gating:
                logger.error("Host preflight failed: \(detail)", metadata: metadata)
            case .advisory:
                logger.warning("Host preflight failed: \(detail)", metadata: metadata)
            }
        }
    }
}
