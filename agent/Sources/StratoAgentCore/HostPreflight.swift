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
        case qemuImgBinary = "qemu-img"
        case uefiFirmware = "uefi_firmware"
        case qemuFirmwareDescriptors = "qemu_firmware_descriptors"
        case swtpmBinary = "swtpm"
        case libvirtConnection = "libvirtd"
        case libvirtVersion = "libvirt_version"
        case ovnDatabaseSocket = "ovn_nb_socket"
        case ovnDatabaseTLSFiles = "ovn_nb_tls_files"
        case ovsDatabaseSocket = "ovsdb_socket"
        case ipTool = "ip"
        case tcTool = "tc"
        case ovsVsctlTool = "ovs-vsctl"
        case ovnAppctlTool = "ovn-appctl"
        case storageFreeSpace = "storage_free_space"
    }

    /// How a failed check affects the agent.
    public enum Severity: Sendable, Equatable {
        /// Gates a capability: the agent must not accept work that needs it.
        case gating
        /// Worth a loud log with remediation, but does not gate placement
        /// (e.g. missing UEFI firmware only affects disk-boot VMs).
        case advisory
        /// A dependency this build does not use yet: worth stating once per
        /// registration so an operator can get ahead of it, but not a problem
        /// with the host as it stands, so it is logged at info rather than
        /// warning. Every node in every fleet would otherwise report libvirt
        /// missing on every reconnect for a requirement that isn't one until
        /// issue #902.
        case informational
    }

    public struct Check: Sendable, Equatable {
        public let kind: CheckKind
        public let severity: Severity
        public let passed: Bool
        /// Failure reason including the remediation; nil when passed.
        public let detail: String?

        static func pass(_ kind: CheckKind, severity: Severity = .gating) -> Check {
            Check(kind: kind, severity: severity, passed: true, detail: nil)
        }

        static func fail(_ kind: CheckKind, severity: Severity = .gating, _ detail: String) -> Check {
            Check(kind: kind, severity: severity, passed: false, detail: detail)
        }
    }

    // MARK: - Inputs

    /// Everything the preflight needs to know about this agent's
    /// configuration, resolved by the caller so the checks stay pure.
    public struct Inputs: Sendable {
        public var vmStoragePath: String
        public var volumeStoragePath: String
        public var imageCachePath: String
        public var qemuImgPath: String
        /// nil when Firecracker cannot exist on this platform (non-Linux).
        public var firecrackerSocketDirectory: String?
        /// The resolved firmware path for this host's architecture — the CODE
        /// image of the split pair when one resolved, else the monolithic
        /// image — or nil when no candidate exists.
        public var firmwarePath: String?
        /// The configured `swtpm` binary, or nil when none was found. Its
        /// presence is what makes the agent advertise the TPM capability
        /// (issue #565); its absence is advisory, since only VMs that ask for
        /// a vTPM are affected.
        public var swtpmBinaryPath: String?
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
        /// Whether this agent actually manages VMs through libvirt, which is
        /// what makes the libvirt checks gating rather than advisory. See
        /// `LibvirtProbe.driverBuilt`.
        public var libvirtRequired: Bool
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
        /// Free-space floor for the advisory disk-space check.
        public var minimumFreeDiskBytes: Int64

        public init(
            vmStoragePath: String,
            volumeStoragePath: String,
            imageCachePath: String,
            qemuImgPath: String,
            firecrackerSocketDirectory: String? = nil,
            firmwarePath: String? = nil,
            swtpmBinaryPath: String? = nil,
            qemuFirmwareDescriptorPath: String? = nil,
            libvirt: LibvirtProbe.Status? = nil,
            minimumLibvirtVersion: LibvirtProbe.Version = LibvirtProbe.minimumVersion,
            libvirtRequired: Bool = LibvirtProbe.driverBuilt,
            ovnMode: Bool = false,
            ovnNBConnection: String = "unix:/var/run/ovn/ovnnb_db.sock",
            ovnNBTLSFilePaths: [String] = [],
            ovsSocketPath: String = "/var/run/openvswitch/db.sock",
            searchPath: String = ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            minimumFreeDiskBytes: Int64 = 1 << 30  // 1 GiB
        ) {
            self.vmStoragePath = vmStoragePath
            self.volumeStoragePath = volumeStoragePath
            self.imageCachePath = imageCachePath
            self.qemuImgPath = qemuImgPath
            self.firecrackerSocketDirectory = firecrackerSocketDirectory
            self.firmwarePath = firmwarePath
            self.swtpmBinaryPath = swtpmBinaryPath
            self.qemuFirmwareDescriptorPath = qemuFirmwareDescriptorPath
            self.libvirt = libvirt
            self.minimumLibvirtVersion = minimumLibvirtVersion
            self.libvirtRequired = libvirtRequired
            self.ovnMode = ovnMode
            self.ovnNBConnection = ovnNBConnection
            self.ovnNBTLSFilePaths = ovnNBTLSFilePaths
            self.ovsSocketPath = ovsSocketPath
            self.searchPath = searchPath
            self.minimumFreeDiskBytes = minimumFreeDiskBytes
        }
    }

    // MARK: - Report

    public struct Report: Sendable {
        public let checks: [Check]

        public var failures: [Check] {
            checks.filter { !$0.passed }
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
        public var swtpmAvailable: Bool {
            check(.swtpmBinary)?.passed ?? false
        }

        /// Whether this host's libvirt is usable: reachable at
        /// `qemu:///system` and new enough. True when the libvirt checks were
        /// skipped, so callers that don't yet require libvirt are unaffected —
        /// ask `check(.libvirtConnection)` when the distinction matters.
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

        /// Whether the OVN-specific host dependencies (database sockets and
        /// CLI tools) all passed. Only meaningful when the preflight ran in
        /// OVN mode.
        public var ovnReady: Bool {
            !failed(.ovnDatabaseSocket) && !failed(.ovnDatabaseTLSFiles) && !failed(.ovsDatabaseSocket)
                && !failed(.ipTool) && !failed(.ovsVsctlTool)
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
                } else if hypervisor.type == .firecracker, let check = check(.firecrackerSocketDirectory),
                    !check.passed
                {
                    reason = check.detail
                }

                guard let unavailabilityReason = reason else { return hypervisor }
                return HypervisorSupport(
                    type: hypervisor.type,
                    available: false,
                    accelerated: hypervisor.accelerated,
                    unavailabilityReason: unavailabilityReason,
                    capabilities: hypervisor.capabilities
                )
            }
        }
    }

    // MARK: - Running the checks

    public static func run(_ inputs: Inputs) -> Report {
        var checks: [Check] = []

        checks.append(
            ensureWritableDirectory(
                inputs.vmStoragePath, kind: .vmStorageDirectory, configKey: "vm_storage_dir"))
        checks.append(
            ensureWritableDirectory(
                inputs.volumeStoragePath, kind: .volumeStorageDirectory, configKey: "volume storage path"))
        checks.append(
            ensureWritableDirectory(
                inputs.imageCachePath, kind: .imageCacheDirectory, configKey: "image cache path"))
        if let firecrackerSocketDir = inputs.firecrackerSocketDirectory {
            checks.append(
                ensureWritableDirectory(
                    firecrackerSocketDir, kind: .firecrackerSocketDirectory,
                    configKey: "firecracker_socket_dir"))
        }

        checks.append(checkQemuImg(inputs.qemuImgPath))
        checks.append(checkFirmware(inputs.firmwarePath))
        checks.append(checkSwtpm(inputs.swtpmBinaryPath))
        if let descriptorPath = inputs.qemuFirmwareDescriptorPath {
            checks.append(checkFirmwareDescriptors(descriptorPath))
        }
        if let libvirt = inputs.libvirt {
            checks.append(
                contentsOf: checkLibvirt(
                    libvirt, minimumVersion: inputs.minimumLibvirtVersion,
                    severity: inputs.libvirtRequired ? .gating : .informational))
        }

        if inputs.ovnMode {
            if inputs.ovnNBConnection.hasPrefix("unix:") {
                checks.append(
                    checkSocket(
                        String(inputs.ovnNBConnection.dropFirst("unix:".count)), kind: .ovnDatabaseSocket,
                        hint: "is OVN (ovn-central / ovn-controller) installed and running on this host?"))
            } else {
                // Remote NB (shared site central): nothing local to probe;
                // reachability surfaces when the network service connects.
                checks.append(.pass(.ovnDatabaseSocket))
            }
            if !inputs.ovnNBTLSFilePaths.isEmpty {
                checks.append(checkTLSFiles(inputs.ovnNBTLSFilePaths))
            }
            checks.append(
                checkSocket(
                    inputs.ovsSocketPath, kind: .ovsDatabaseSocket,
                    hint: "is Open vSwitch (ovsdb-server / ovs-vswitchd) installed and running on this host?"))
            checks.append(
                checkTool(
                    "ip", kind: .ipTool, searchPath: inputs.searchPath,
                    hint: "install iproute2; the agent needs it to manage TAP devices"))
            // Advisory: only *networked sandboxes* need `tc` (it installs the
            // redirects splicing a jailed VMM's TAP to its veth). VMs and
            // network-free sandboxes are unaffected, so a host without it is
            // degraded, not broken.
            //
            // The hint names the candidate list because this check and the
            // resolver disagree by construction: the check walks `PATH`, while
            // the attach path invokes an absolute path resolved from a fixed
            // list (a service manager's stripped `PATH` must not break it). A
            // `tc` outside that list passes here and still refuses every
            // networked sandbox, so the hint has to point at the real cause.
            checks.append(
                checkTool(
                    "tc", kind: .tcTool, severity: .advisory, searchPath: inputs.searchPath,
                    hint: "install iproute2; without `tc` the agent cannot attach a NIC into a jailed "
                        + "sandbox's network namespace. It must be at one of "
                        + SandboxJailerResolver.tcBinaryCandidates.joined(separator: ", ")
                        + " — the agent invokes it by absolute path, not via PATH"))
            checks.append(
                checkTool(
                    "ovs-vsctl", kind: .ovsVsctlTool, searchPath: inputs.searchPath,
                    hint: "install openvswitch-switch; the agent needs it to attach VM NICs to the integration bridge"
                ))
            checks.append(
                checkTool(
                    "ovn-appctl", kind: .ovnAppctlTool, severity: .advisory, searchPath: inputs.searchPath,
                    hint: "install ovn-host; without it the agent cannot verify ovn-controller is connected "
                        + "to the southbound database"))
        }

        checks.append(checkFreeSpace(inputs.vmStoragePath, minimum: inputs.minimumFreeDiskBytes))

        return Report(checks: checks)
    }

    // MARK: - Individual checks

    /// Creates the directory (with intermediate directories) if needed, then
    /// proves writability by creating and removing a probe file — a
    /// permissions problem must surface here, not mid-VM-create.
    static func ensureWritableDirectory(_ path: String, kind: CheckKind, configKey: String) -> Check {
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return .fail(
                kind,
                "\(path) exists but is not a directory. Remove it or point \(configKey) at a directory.")
        }

        do {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            return .fail(
                kind,
                "cannot create \(path): \(error.localizedDescription). "
                    + "Create it manually with write permission for the agent user, or point \(configKey) at a writable location."
            )
        }

        let probePath = (path as NSString).appendingPathComponent(".strato-preflight-probe")
        guard fileManager.createFile(atPath: probePath, contents: Data()) else {
            return .fail(
                kind,
                "\(path) is not writable by the agent user. "
                    + "Fix its ownership/permissions, or point \(configKey) at a writable location.")
        }
        try? fileManager.removeItem(atPath: probePath)
        return .pass(kind)
    }

    static func checkQemuImg(_ path: String) -> Check {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .fail(
                .qemuImgBinary,
                "qemu-img not found or not executable at \(path). "
                    + "Install QEMU tools (Debian/Ubuntu: `apt install qemu-utils`, macOS: `brew install qemu`); "
                    + "the agent cannot create or convert VM disks without it.")
        }
        return .pass(.qemuImgBinary)
    }

    static func checkFirmware(_ path: String?) -> Check {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            return .fail(
                .uefiFirmware, severity: .advisory,
                "no UEFI firmware found\(path.map { " at \($0)" } ?? "") — disk-image VMs may fail to boot "
                    + "(direct-kernel boots are unaffected). Install EDK2 firmware "
                    + "(Debian/Ubuntu: `apt install ovmf qemu-efi-aarch64`, macOS: bundled with `brew install qemu`) "
                    + "or set firmware_path_arm64/firmware_path_x86_64 in the agent configuration.")
        }
        return .pass(.uefiFirmware, severity: .advisory)
    }

    /// swtpm backs guest vTPMs (issue #565). Advisory, not gating: a host
    /// without it runs every VM that doesn't ask for a TPM exactly as before,
    /// and the scheduler keeps vTPM VMs away via the reported capability.
    static func checkSwtpm(_ path: String?) -> Check {
        guard let path, FileManager.default.isExecutableFile(atPath: path) else {
            return .fail(
                .swtpmBinary, severity: .advisory,
                "swtpm not found\(path.map { " at \($0)" } ?? "") — this host cannot run VMs with a TPM 2.0 "
                    + "(Windows 11 and Server 2025 require one). Install it "
                    + "(Debian/Ubuntu: `apt install swtpm swtpm-tools`) or set swtpm_binary_path "
                    + "in the agent configuration.")
        }
        return .pass(.swtpmBinary, severity: .advisory)
    }

    /// QEMU's firmware descriptors are what libvirt reads to autoselect a
    /// CODE/VARS pair for `<os firmware='efi'>`. Advisory: without them libvirt
    /// cannot autoselect, and the agent has to name firmware paths explicitly
    /// (which `FirmwareResolver` can already do), so a host missing them still
    /// boots VMs.
    static func checkFirmwareDescriptors(_ directory: String) -> Check {
        let descriptors =
            (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .filter { $0.hasSuffix(".json") } ?? []
        guard !descriptors.isEmpty else {
            return .fail(
                .qemuFirmwareDescriptors, severity: .advisory,
                "no QEMU firmware descriptors (*.json) in \(directory) — libvirt cannot autoselect UEFI "
                    + "firmware, so VMs boot with the explicitly configured firmware paths instead. "
                    + "Install EDK2 firmware (Debian/Ubuntu: `apt install ovmf qemu-efi-aarch64`).")
        }
        return .pass(.qemuFirmwareDescriptors, severity: .advisory)
    }

    /// libvirtd reachability and its version floor.
    ///
    /// `severity` follows `LibvirtProbe.driverBuilt`: gating once the agent
    /// really manages VMs through libvirt — a host that cannot reach
    /// `qemu:///system`, or runs a libvirt too old to snapshot UEFI guests,
    /// cannot then serve the VM operations it is asked for — and merely
    /// informational until then, so hosts running today's direct-QEMU driver
    /// hear about the coming requirement without being declared broken.
    /// `gate(_:)` starts consuming `libvirtReady` with the driver (issue #902).
    ///
    /// The wording follows the same split: while the dependency is unused, each
    /// message says so rather than reading as a live fault.
    static func checkLibvirt(
        _ status: LibvirtProbe.Status, minimumVersion: LibvirtProbe.Version, severity: Severity
    ) -> [Check] {
        // Prefix, not a whole second set of strings: the remediation is
        // identical either way, only its urgency changes.
        let lede =
            severity == .gating
            ? "" : "libvirt will be required for VM management (issue #902), and is not usable here yet: "

        switch status {
        case .clientMissing:
            return [
                .fail(
                    .libvirtConnection, severity: severity,
                    lede
                        + "libvirt is not installed on this host (no `virsh` on PATH) — the agent manages VMs "
                        + "through libvirtd. Install it (Debian/Ubuntu: "
                        + "`apt install libvirt-daemon-system libvirt-clients`) and start "
                        + "virtqemud.socket (or libvirtd.socket on a monolithic install); re-running "
                        + "deploy/agent/install.sh does both.")
            ]
        case .unreachable(let detail):
            return [
                .fail(
                    .libvirtConnection, severity: severity,
                    lede + "cannot connect to \(LibvirtProbe.systemURI): \(detail). Start the daemon "
                        + "(`systemctl start virtqemud.socket`, or libvirtd.socket on a monolithic "
                        + "install); if it is running, the agent's account needs access to its socket — "
                        + "run the agent as root, or add its user to the `libvirt` group.")
            ]
        case .unrecognizedOutput(let detail):
            // The daemon replied, so nothing about starting it or socket
            // permissions applies. This is the state a mis-parsed (e.g.
            // localized) or unexpectedly-shaped virsh lands in.
            return [
                .fail(
                    .libvirtConnection, severity: severity,
                    lede + "connected to \(LibvirtProbe.systemURI), but could not read the daemon version "
                        + "from `virsh version --daemon` — it printed \"\(detail)\". The version floor "
                        + "cannot be checked without it: confirm `virsh -c \(LibvirtProbe.systemURI) "
                        + "version --daemon` prints a `Running against daemon:` line, and that virsh and "
                        + "the daemon come from the same libvirt build.")
            ]
        case .reachable(let version):
            let connection = Check.pass(.libvirtConnection, severity: severity)
            guard version >= minimumVersion else {
                return [
                    connection,
                    .fail(
                        .libvirtVersion, severity: severity,
                        lede
                            + "libvirt \(version) is older than the required \(minimumVersion) — VM checkpoints "
                            + "need internal snapshots of UEFI guests, which libvirt supports only from "
                            + "10.9 and reliably only from 11.5. Ubuntu 24.04 ships 10.0.0 and is not a "
                            + "supported hypervisor host; use Ubuntu 26.04 (libvirt 12.0.0) or another "
                            + "distribution shipping \(minimumVersion) or newer."),
                ]
            }
            return [connection, .pass(.libvirtVersion, severity: severity)]
        }
    }

    /// All PEM files configured for the ssl: NB endpoint must exist.
    static func checkTLSFiles(_ paths: [String]) -> Check {
        let missing = paths.filter { !FileManager.default.fileExists(atPath: $0) }
        guard missing.isEmpty else {
            return .fail(
                .ovnDatabaseTLSFiles,
                "ovn_northbound_tls file(s) not found: \(missing.joined(separator: ", ")) — "
                    + "fix the [ovn_northbound_tls] paths in the agent configuration, or issue the "
                    + "certificates (e.g. with ovn-pki) and place them there.")
        }
        return .pass(.ovnDatabaseTLSFiles)
    }

    static func checkSocket(_ path: String, kind: CheckKind, hint: String) -> Check {
        guard FileManager.default.fileExists(atPath: path) else {
            return .fail(kind, "\(kind.rawValue) not found at \(path) — \(hint)")
        }
        return .pass(kind)
    }

    /// Looks a tool up on `searchPath`, mirroring how the network service
    /// invokes it (`/usr/bin/env <tool>`).
    static func checkTool(
        _ tool: String, kind: CheckKind, severity: Severity = .gating, searchPath: String, hint: String
    ) -> Check {
        guard locateTool(tool, searchPath: searchPath) != nil else {
            return .fail(kind, severity: severity, "`\(tool)` not found on PATH — \(hint)")
        }
        return .pass(kind, severity: severity)
    }

    /// First executable named `tool` on `searchPath`, or nil.
    public static func locateTool(_ tool: String, searchPath: String) -> String? {
        for directory in searchPath.split(separator: ":") {
            let candidate = "\(directory)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func checkFreeSpace(_ path: String, minimum: Int64) -> Check {
        guard let free = freeDiskSpace(atPath: path) else {
            return .fail(
                .storageFreeSpace, severity: .advisory,
                "cannot determine free disk space for \(path); resource reporting to the scheduler will show 0 disk."
            )
        }
        guard free >= minimum else {
            return .fail(
                .storageFreeSpace, severity: .advisory,
                "only \(byteString(free)) free on the filesystem backing \(path) "
                    + "(floor: \(byteString(minimum))). VM disk creation and image downloads are likely to fail; free up space."
            )
        }
        return .pass(.storageFreeSpace, severity: .advisory)
    }

    // MARK: - Filesystem helpers

    /// Free bytes of the filesystem backing `path`, resolved via the nearest
    /// existing ancestor when the path itself does not exist yet.
    public static func freeDiskSpace(atPath path: String) -> Int64? {
        let fileManager = FileManager.default
        var probePath = path.isEmpty ? "/" : path
        while !fileManager.fileExists(atPath: probePath) {
            let parent = (probePath as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == probePath {
                probePath = "/"
                break
            }
            probePath = parent
        }
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: probePath),
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
        else {
            return nil
        }
        return free
    }

    static func byteString(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unitIndex])
    }
}
