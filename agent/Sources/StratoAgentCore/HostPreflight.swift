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
        case ovnDatabaseSocket = "ovn_nb_socket"
        case ovsDatabaseSocket = "ovsdb_socket"
        case ipTool = "ip"
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
        /// The resolved firmware path for this host's architecture, or nil
        /// when no candidate exists.
        public var firmwarePath: String?
        /// Whether the agent runs with OVN networking (enables the OVN/OVS
        /// socket and tool checks).
        public var ovnMode: Bool
        /// OVN NB connection string (`unix:<path>`, `tcp:<host>:<port>`,
        /// `ssl:<host>:<port>`). The local-socket existence check only applies
        /// to unix connections — a remote site central can't be probed as a
        /// file, and its reachability surfaces at connect time instead.
        public var ovnNBConnection: String
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
            ovnMode: Bool = false,
            ovnNBConnection: String = "unix:/var/run/ovn/ovnnb_db.sock",
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
            self.ovnMode = ovnMode
            self.ovnNBConnection = ovnNBConnection
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

        /// Whether the OVN-specific host dependencies (database sockets and
        /// CLI tools) all passed. Only meaningful when the preflight ran in
        /// OVN mode.
        public var ovnReady: Bool {
            !failed(.ovnDatabaseSocket) && !failed(.ovsDatabaseSocket) && !failed(.ipTool)
                && !failed(.ovsVsctlTool)
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
            checks.append(
                checkSocket(
                    inputs.ovsSocketPath, kind: .ovsDatabaseSocket,
                    hint: "is Open vSwitch (ovsdb-server / ovs-vswitchd) installed and running on this host?"))
            checks.append(
                checkTool(
                    "ip", kind: .ipTool, searchPath: inputs.searchPath,
                    hint: "install iproute2; the agent needs it to manage TAP devices"))
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
        let fileManager = FileManager.default
        let found = searchPath.split(separator: ":").contains { directory in
            fileManager.isExecutableFile(atPath: "\(directory)/\(tool)")
        }
        guard found else {
            return .fail(kind, severity: severity, "`\(tool)` not found on PATH — \(hint)")
        }
        return .pass(kind, severity: severity)
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
