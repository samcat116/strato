import Foundation
import StratoShared

/// Host-readiness checks run at agent startup and on every registration.
///
/// The agent depends on a lot of host configuration — writable storage
/// directories, qemu-img, UEFI firmware, OVN/OVS sockets and CLI tools —
/// and historically none of it was verified until a VM operation tripped
/// over it minutes later with a generic error. The preflight verifies (and
/// where the agent owns the path, creates) all of it up front, so:
///
/// * a misconfigured host logs every problem with its remediation at startup;
/// * failures that make VM placement impossible gate the hypervisor
///   capabilities reported to the control plane (via `gate(_:)`), so the
///   scheduler avoids the host *and* the UI can show why;
/// * re-running on every registration means a fixed host recovers its
///   capabilities on the next reconnect without a restart.
///
/// Checks are pure filesystem/`PATH` probes with injectable inputs, so the
/// whole module is unit-testable with temp directories.
public enum HostPreflight {

    // MARK: - Check model

    /// One host dependency the agent verified.
    public enum CheckKind: String, Sendable, CaseIterable {
        case vmStorageDirectory = "vm_storage_dir"
        case volumeStorageDirectory = "volume_storage_dir"
        case imageCacheDirectory = "image_cache_dir"
        case firecrackerSocketDirectory = "firecracker_socket_dir"
        case firecrackerPIDFDSupport = "firecracker_pidfd"
        case sandboxJailerUIDRange = "sandbox_jailer_uid_range"
        case qemuImgBinary = "qemu-img"
        case uefiFirmware = "uefi_firmware"
        case qemuFirmwareDescriptors = "qemu_firmware_descriptors"
        case vtpmSupport = "vtpm"
        case libvirtConnection = "libvirtd"
        case libvirtVersion = "libvirt_version"
        case vhostVsockSupport = "vhost_vsock"
        case ovnDatabaseSocket = "ovn_nb_socket"
        case ovnDatabaseTLSFiles = "ovn_nb_tls_files"
        case ovsDatabaseSocket = "ovsdb_socket"
        case ipTool = "ip"
        case tcTool = "tc"
        case ovsVsctlTool = "ovs-vsctl"
        case ovnAppctlTool = "ovn-appctl"
        case corednsBinary = "coredns"
        case globalReversePathFilter = "rp_filter_all"
        case storageFreeSpace = "storage_free_space"
    }

    /// How a failed check affects the agent.
    public enum Severity: Sendable, Equatable {
        /// Gates a capability: the agent must not accept work that needs it.
        case gating
        /// Worth a loud log with remediation, but does not gate placement
        /// (e.g. missing UEFI firmware only affects disk-boot VMs).
        case advisory
    }

    public struct Check: Sendable, Equatable {
        public let kind: CheckKind
        public let severity: Severity
        public let passed: Bool
        /// False when this dependency does not exist on the current platform.
        /// Unsupported is a reported platform fact, not a failed check.
        public let supported: Bool
        /// Failure reason/remediation, or an unsupported-platform explanation.
        public let detail: String?

        static func pass(_ kind: CheckKind, severity: Severity = .gating) -> Check {
            Check(kind: kind, severity: severity, passed: true, supported: true, detail: nil)
        }

        static func fail(_ kind: CheckKind, severity: Severity = .gating, _ detail: String) -> Check {
            Check(kind: kind, severity: severity, passed: false, supported: true, detail: detail)
        }

        static func unsupported(_ kind: CheckKind, _ detail: String) -> Check {
            Check(kind: kind, severity: .advisory, passed: true, supported: false, detail: detail)
        }
    }

    // MARK: - Inputs

    /// Platform resolution for QEMU's kernel-backed virtio-vsock device.
    public enum VhostVsockSupport: Sendable, Equatable {
        /// The device node QEMU/libvirt must be able to open.
        case device(path: String)
        /// This kernel/device model does not exist on the current platform.
        case unsupportedPlatform(String)
    }

    /// Whether Firecracker process supervision can pin process identities
    /// against PID reuse with Linux pidfds.
    public enum FirecrackerPIDFDSupport: Sendable, Equatable {
        case available
        case unavailable(String)
        case unsupportedPlatform(String)
    }

    /// One host identity database file, captured by the caller so the jailer
    /// range check stays pure and tests never inspect the machine running them.
    public enum HostIdentityFile: Sendable, Equatable {
        /// The complete file contents.
        case contents(String)
        /// The path does not exist. This is valid only for the optional
        /// subordinate-id databases (`/etc/subuid` and `/etc/subgid`).
        case missing
        /// The path exists but could not be read. A reason is retained for the
        /// operator-facing preflight remediation.
        case unreadable(String)
    }

    /// Inputs for proving that the uid/gid range assigned to jailed sandbox
    /// processes is not already owned or delegated on this host.
    public struct SandboxJailerUIDRangeInputs: Sendable, Equatable {
        public var mode: SandboxJailerMode
        public var uidBase: UInt32
        public var passwd: HostIdentityFile
        public var group: HostIdentityFile
        public var subuid: HostIdentityFile
        public var subgid: HostIdentityFile

        public init(
            mode: SandboxJailerMode,
            uidBase: UInt32,
            passwd: HostIdentityFile,
            group: HostIdentityFile,
            subuid: HostIdentityFile,
            subgid: HostIdentityFile
        ) {
            self.mode = mode
            self.uidBase = uidBase
            self.passwd = passwd
            self.group = group
            self.subuid = subuid
            self.subgid = subgid
        }
    }

    /// Everything the preflight needs to know about this agent's
    /// configuration, resolved by the caller so the checks stay pure.
    public struct Inputs: Sendable {
        public var vmStoragePath: String
        public var volumeStoragePath: String
        public var imageCachePath: String
        public var qemuImgPath: String
        /// nil when Firecracker cannot exist on this platform (non-Linux).
        public var firecrackerSocketDirectory: String?
        /// nil when Firecracker cannot exist on this platform (non-Linux).
        public var firecrackerPIDFDSupport: FirecrackerPIDFDSupport?
        /// The resolved firmware path for this host's architecture — the CODE
        /// image of the split pair when one resolved, else the monolithic
        /// image — or nil when no candidate exists.
        public var firmwarePath: String?
        /// What libvirt reports about backing a guest vTPM (issue #565).
        /// `.supported` is what makes the agent advertise the TPM capability;
        /// anything else is advisory, since only VMs that ask for a vTPM are
        /// affected.
        public var tpmSupport: LibvirtProbe.TPMSupport
        /// Directory holding QEMU's firmware descriptors
        /// (`/usr/share/qemu/firmware/*.json`), which is what lets libvirt
        /// autoselect UEFI firmware from `<os firmware='efi'>`. nil skips the
        /// check on platforms that have no such directory.
        public var qemuFirmwareDescriptorPath: String?
        /// What `LibvirtProbe` found, or nil on a platform where libvirt cannot
        /// exist (non-Linux), which skips both libvirt checks entirely.
        public var libvirt: LibvirtProbe.Status?
        /// The oldest libvirt this agent will drive.
        public var minimumLibvirtVersion: LibvirtProbe.Version
        /// Linux resolves this to `/dev/vhost-vsock`; non-Linux callers state
        /// that the backend is unsupported rather than passing a fake path.
        public var vhostVsock: VhostVsockSupport
        /// Whether the agent runs with OVN networking (enables the OVN/OVS
        /// socket and tool checks).
        public var ovnMode: Bool
        /// OVN NB connection string (`unix:<path>`, `tcp:<host>:<port>`,
        /// `ssl:<host>:<port>`). The local-socket existence check only applies
        /// to unix connections — a remote site central can't be probed as a
        /// file, and its reachability surfaces at connect time instead.
        public var ovnNBConnection: String
        /// PEM files configured for an `ssl:` NB endpoint (CA, client
        /// cert/key). Each must exist — a typoed cert path should surface
        /// here with its config key, not as an opaque TLS handshake failure.
        public var ovnNBTLSFilePaths: [String]
        public var ovsSocketPath: String
        /// `PATH` used to locate CLI tools (`ip`, `ovs-vsctl`).
        public var searchPath: String
        /// `net.ipv4.conf.all.rp_filter`, read by the caller so the check stays
        /// pure. Nil when the sysctl could not be read at all, which is not a
        /// failure — see `checkGlobalReversePathFilter`.
        public var globalReversePathFilter: Int?
        /// Free-space floor for the advisory disk-space check.
        public var minimumFreeDiskBytes: Int64
        /// Host identity databases used to prove the sandbox jail uid/gid
        /// range is unassigned. Nil skips the Linux-only check.
        public var sandboxJailerUIDRange: SandboxJailerUIDRangeInputs?

        public init(
            vmStoragePath: String,
            volumeStoragePath: String,
            imageCachePath: String,
            qemuImgPath: String,
            firecrackerSocketDirectory: String? = nil,
            firecrackerPIDFDSupport: FirecrackerPIDFDSupport? = nil,
            firmwarePath: String? = nil,
            tpmSupport: LibvirtProbe.TPMSupport = .unknown("not probed"),
            qemuFirmwareDescriptorPath: String? = nil,
            libvirt: LibvirtProbe.Status? = nil,
            minimumLibvirtVersion: LibvirtProbe.Version = LibvirtProbe.minimumVersion,
            vhostVsock: VhostVsockSupport = .unsupportedPlatform(
                "virtio-vsock for QEMU is not supported on this platform"),
            ovnMode: Bool = false,
            ovnNBConnection: String = "unix:/var/run/ovn/ovnnb_db.sock",
            ovnNBTLSFilePaths: [String] = [],
            ovsSocketPath: String = "/var/run/openvswitch/db.sock",
            searchPath: String = ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            globalReversePathFilter: Int? = HostPreflight.readGlobalReversePathFilter(),
            minimumFreeDiskBytes: Int64 = 1 << 30,  // 1 GiB
            sandboxJailerUIDRange: SandboxJailerUIDRangeInputs? = nil
        ) {
            self.vmStoragePath = vmStoragePath
            self.volumeStoragePath = volumeStoragePath
            self.imageCachePath = imageCachePath
            self.qemuImgPath = qemuImgPath
            self.firecrackerSocketDirectory = firecrackerSocketDirectory
            self.firecrackerPIDFDSupport = firecrackerPIDFDSupport
            self.firmwarePath = firmwarePath
            self.tpmSupport = tpmSupport
            self.qemuFirmwareDescriptorPath = qemuFirmwareDescriptorPath
            self.libvirt = libvirt
            self.minimumLibvirtVersion = minimumLibvirtVersion
            self.vhostVsock = vhostVsock
            self.ovnMode = ovnMode
            self.ovnNBConnection = ovnNBConnection
            self.ovnNBTLSFilePaths = ovnNBTLSFilePaths
            self.ovsSocketPath = ovsSocketPath
            self.searchPath = searchPath
            self.globalReversePathFilter = globalReversePathFilter
            self.minimumFreeDiskBytes = minimumFreeDiskBytes
            self.sandboxJailerUIDRange = sandboxJailerUIDRange
        }
    }

    /// Reads `net.ipv4.conf.all.rp_filter` from procfs.
    ///
    /// Read rather than shelled out to: `sysctl` is one more binary a stripped
    /// service-manager `PATH` could hide, and the value is one integer in a
    /// file the agent can already reach. Nil on any failure, including the file
    /// simply not existing off Linux.
    public static func readGlobalReversePathFilter() -> Int? {
        guard
            let raw = try? String(
                contentsOfFile: "/proc/sys/net/ipv4/conf/all/rp_filter", encoding: .utf8)
        else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Report

    public struct Report: Sendable {
        public let checks: [Check]

        public init(checks: [Check]) {
            self.checks = checks
        }

        public var failures: [Check] {
            checks.filter { !$0.passed }
        }

        public var unsupported: [Check] {
            checks.filter { !$0.supported }
        }

        public func check(_ kind: CheckKind) -> Check? {
            checks.first { $0.kind == kind }
        }

        private func failed(_ kind: CheckKind) -> Bool {
            check(kind).map { !$0.passed } ?? false
        }

        /// Whether the host can materialize and store VM disks at all. When
        /// false, no hypervisor can create a VM here, whatever its own probe
        /// says.
        public var storageReady: Bool {
            !failed(.vmStorageDirectory) && !failed(.volumeStorageDirectory)
                && !failed(.imageCacheDirectory) && !failed(.qemuImgBinary)
        }

        /// The first storage failure's detail, for capability gating messages.
        public var storageFailureDetail: String? {
            let storageKinds: [CheckKind] = [
                .vmStorageDirectory, .volumeStorageDirectory, .imageCacheDirectory, .qemuImgBinary,
            ]
            for kind in storageKinds {
                if let check = check(kind), !check.passed {
                    return check.detail
                }
            }
            return nil
        }

        /// Whether this host can back a guest TPM 2.0 — the signal the agent
        /// reports as `AgentRegisterMessage.tpmCapable` (issue #565).
        public var tpmAvailable: Bool {
            check(.vtpmSupport)?.passed ?? false
        }

        /// Whether QEMU can attach its host-backed virtio-vsock device. An
        /// unsupported platform deliberately returns false even though the
        /// diagnostic check itself is not a startup failure.
        public var vhostVsockAvailable: Bool {
            guard let check = check(.vhostVsockSupport) else { return false }
            return check.supported && check.passed
        }

        /// Why the sandbox jail uid/gid range is unusable, for the jailer
        /// resolver and sandbox capability report.
        public var sandboxJailerUIDRangeFailureDetail: String? {
            guard let check = check(.sandboxJailerUIDRange), !check.passed else { return nil }
            return check.detail
        }

        /// Whether this host's libvirt is usable: reachable at
        /// `qemu:///system` and new enough. True when the libvirt checks were
        /// skipped, which is the non-Linux case — there the QEMU probe already
        /// reports unavailable, so nothing is left for this to gate.
        public var libvirtReady: Bool {
            !failed(.libvirtConnection) && !failed(.libvirtVersion)
        }

        /// Why libvirt is unusable, for capability-gating messages.
        public var libvirtFailureDetail: String? {
            for kind in [CheckKind.libvirtConnection, .libvirtVersion] {
                if let check = check(kind), !check.passed { return check.detail }
            }
            return nil
        }

        /// Applies host-level gates on top of the per-hypervisor probes: a
        /// hypervisor whose own binary probe passed is still unusable when
        /// the host cannot store disks (or, for Firecracker, when its socket
        /// directory is unwritable). The demoted entries keep a reason so the
        /// control plane can surface *why* the host is ineligible.
        public func gate(_ hypervisors: [HypervisorSupport]) -> [HypervisorSupport] {
            hypervisors.map { hypervisor in
                guard hypervisor.available else { return hypervisor }

                var reason: String?
                if !storageReady {
                    reason = "host storage not ready: \(storageFailureDetail ?? "unknown storage failure")"
                } else if hypervisor.type == .qemu, !libvirtReady {
                    // A QEMU placement *is* a libvirt domain (STR-136), so a
                    // daemon this node cannot reach — or one too old to serve
                    // the operations it will be asked for — makes it ineligible.
                    // This is the whole of the QEMU availability check now:
                    // `HypervisorProbe` has no binary left to look for.
                    reason = "libvirt not usable: \(libvirtFailureDetail ?? "unknown libvirt failure")"
                } else if hypervisor.type == .firecracker, let check = check(.firecrackerSocketDirectory),
                    !check.passed
                {
                    reason = check.detail
                } else if hypervisor.type == .firecracker,
                    let check = check(.firecrackerPIDFDSupport), !check.passed
                {
                    reason = check.detail
                }

                guard let unavailabilityReason = reason else { return hypervisor }
                return HypervisorSupport(
                    type: hypervisor.type,
                    available: false,
                    accelerated: hypervisor.accelerated,
                    unavailabilityReason: unavailabilityReason,
                    supportsSnapshots: hypervisor.supportsSnapshots,
                    supportsVsock: hypervisor.supportsVsock,
                    supportsGuestExec: hypervisor.supportsGuestExec,
                    supportsVolumeIOLimits: hypervisor.supportsVolumeIOLimits,
                    version: hypervisor.version
                )
            }
        }
    }

}
