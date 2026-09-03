import Foundation
import StratoShared

extension HostPreflight {
    // MARK: - Individual checks

    public static func checkFirecrackerPIDFD(_ support: FirecrackerPIDFDSupport) -> Check {
        switch support {
        case .available:
            return .pass(.firecrackerPIDFDSupport)
        case .unavailable(let reason):
            return .fail(
                .firecrackerPIDFDSupport,
                "Firecracker process supervision requires pidfd_open and pidfd_send_signal: \(reason). "
                    + "Use Linux kernel 5.3 or newer and allow both system calls in the agent service sandbox")
        case .unsupportedPlatform(let reason):
            return .unsupported(.firecrackerPIDFDSupport, reason)
        }
    }

    /// Proves that `[uidBase, uidBase + 65536)` is not a host uid/gid or a
    /// delegated subordinate-id range. The snapshots are injected so this is a
    /// pure parser and interval check; the caller owns reading the four named
    /// host files.
    public static func checkSandboxJailerUIDRange(_ inputs: SandboxJailerUIDRangeInputs) -> Check {
        let severity: Severity = inputs.mode == .required ? .gating : .advisory
        guard inputs.mode != .disabled else {
            return .pass(.sandboxJailerUIDRange, severity: severity)
        }

        let start = UInt64(inputs.uidBase)
        let count = UInt64(SandboxJailerConfig.uidCount)
        let end = start + count
        guard end <= UInt64(UInt32.max) else {
            return .fail(
                .sandboxJailerUIDRange, severity: severity,
                "sandbox_jailer_uid_base \(inputs.uidBase) does not leave room for the "
                    + "\(SandboxJailerConfig.uidCount)-id jail uid/gid range")
        }
        let jailRange = start..<end

        var problems: [String] = []
        problems.append(
            contentsOf: accountIDProblems(
                inputs.passwd, path: "/etc/passwd", idName: "uid", jailRange: jailRange))
        problems.append(
            contentsOf: accountIDProblems(
                inputs.group, path: "/etc/group", idName: "gid", jailRange: jailRange))
        problems.append(
            contentsOf: subordinateIDProblems(
                inputs.subuid, path: "/etc/subuid", idName: "uid", jailRange: jailRange))
        problems.append(
            contentsOf: subordinateIDProblems(
                inputs.subgid, path: "/etc/subgid", idName: "gid", jailRange: jailRange))

        guard problems.isEmpty else {
            return .fail(
                .sandboxJailerUIDRange, severity: severity,
                "sandbox jail uid/gid range \(start)..<\(end) is not isolated on this host: "
                    + problems.joined(separator: "; ")
                    + ". Reassign the conflicting host identity or subordinate range, or choose and reserve a "
                    + "non-overlapping sandbox_jailer_uid_base")
        }
        return .pass(.sandboxJailerUIDRange, severity: severity)
    }

    private static func accountIDProblems(
        _ file: HostIdentityFile,
        path: String,
        idName: String,
        jailRange: Range<UInt64>
    ) -> [String] {
        switch file {
        case .missing:
            return ["required \(path) is missing"]
        case .unreadable(let reason):
            return ["cannot read required \(path): \(reason)"]
        case .contents(let contents):
            return colonRecords(contents).compactMap { lineNumber, fields in
                guard fields.count >= 3, let id = UInt64(fields[2]) else {
                    return "cannot parse \(idName) on \(path) line \(lineNumber)"
                }
                guard jailRange.contains(id) else { return nil }
                let name = fields[0].isEmpty ? "<unnamed>" : fields[0]
                return "\(path) entry '\(name)' uses \(idName) \(id)"
            }
        }
    }

    private static func subordinateIDProblems(
        _ file: HostIdentityFile,
        path: String,
        idName: String,
        jailRange: Range<UInt64>
    ) -> [String] {
        switch file {
        case .missing:
            // The subordinate-id files are optional. Their absence means this
            // host delegates no file-backed subordinate ids of that kind.
            return []
        case .unreadable(let reason):
            // An existing but unreadable optional database cannot be treated
            // like an absent one: it may contain a conflicting delegation.
            return ["cannot read \(path): \(reason)"]
        case .contents(let contents):
            return colonRecords(contents).compactMap { lineNumber, fields in
                guard fields.count >= 3,
                    let start = UInt64(fields[1]),
                    let count = UInt64(fields[2]),
                    count > 0
                else {
                    return "cannot parse subordinate \(idName) range on \(path) line \(lineNumber)"
                }
                let (end, overflow) = start.addingReportingOverflow(count)
                guard !overflow else {
                    return "subordinate \(idName) range overflows on \(path) line \(lineNumber)"
                }
                guard start < jailRange.upperBound, jailRange.lowerBound < end else { return nil }
                let owner = fields[0].isEmpty ? "<unnamed>" : fields[0]
                return "\(path) delegates \(idName)s \(start)..<\(end) to '\(owner)'"
            }
        }
    }

    /// Non-empty, non-comment colon records with their one-based line number.
    /// Empty fields stay present so a malformed numeric field fails closed.
    private static func colonRecords(_ contents: String) -> [(Int, [String])] {
        contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap {
            offset, rawLine in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return (
                offset + 1,
                line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            )
        }
    }

    /// Whether `net.ipv4.conf.all.rp_filter` leaves the resolver's foot able to
    /// receive guest queries (STR-40).
    ///
    /// `ResolverHostPortPlan` sets `rp_filter=2` (loose) on its own interface,
    /// but the kernel validates a source against
    /// `max(conf.all.rp_filter, conf.<dev>.rp_filter)` — so a host whose `all`
    /// is `1` stays *strict* on that interface no matter what the per-device
    /// value says. A guest query arrives sourced from a tenant address the main
    /// table has no route for, strict mode drops it, and the symptom is a
    /// resolver that answers nothing while every log on the host stays quiet.
    ///
    /// Advisory rather than a fix, deliberately: lowering `all` would weaken
    /// source validation on the hypervisor's own NICs, and that is an
    /// operator's call rather than this feature's. `0` and `2` both pass — `0`
    /// disables validation entirely, which is Ubuntu's default.
    static func checkGlobalReversePathFilter(_ value: Int?) -> Check {
        guard let value else {
            // Unreadable is not failed: the sysctl is absent on non-Linux and
            // on a kernel built without it, and neither is a misconfiguration.
            return .pass(.globalReversePathFilter, severity: .advisory)
        }
        guard value == 1 else { return .pass(.globalReversePathFilter, severity: .advisory) }
        return .fail(
            .globalReversePathFilter, severity: .advisory,
            "net.ipv4.conf.all.rp_filter is 1 (strict), which overrides the loose setting the agent "
                + "puts on each network's resolver interface — the kernel uses the max of the two. "
                + "Guest DNS queries to the resolver address will be dropped. Set "
                + "net.ipv4.conf.all.rp_filter=2 (loose) or 0, keeping per-interface strictness where "
                + "you need it")
    }

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

    /// The Linux vhost-vsock backend libvirt opens for a `<vsock>` domain
    /// device. Checking the character device proves the module is loaded (or
    /// built in) and the kernel registered its userspace endpoint; merely
    /// finding a module file on disk would not.
    static func checkVhostVsock(_ support: VhostVsockSupport) -> Check {
        switch support {
        case .unsupportedPlatform(let detail):
            return .unsupported(.vhostVsockSupport, detail)

        case .device(let path):
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard attributes?[.type] as? FileAttributeType == .typeCharacterSpecial else {
                return .fail(
                    .vhostVsockSupport, severity: .advisory,
                    "vhost-vsock is unavailable at \(path) — VMs with the Strato guest agent cannot start. "
                        + "Load the kernel module (`modprobe vhost_vsock`) and configure it to load at boot; "
                        + "if the module is absent, install the matching Linux extra-modules package.")
            }
            return .pass(.vhostVsockSupport, severity: .advisory)
        }
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

    /// Whether libvirt can back a guest vTPM (issue #565). Advisory, not
    /// gating: a host without one runs every VM that doesn't ask for a TPM
    /// exactly as before, and the scheduler keeps vTPM VMs away via the
    /// reported capability.
    ///
    /// The question goes to libvirt rather than to the filesystem (STR-136).
    /// libvirt starts and supervises swtpm per domain, so an `swtpm` binary the
    /// agent can see says nothing about whether *libvirtd* can use it — a
    /// containerized agent sees its own image, not the host's.
    static func checkTPMSupport(_ support: LibvirtProbe.TPMSupport, libvirtUsable: Bool) -> Check {
        // `libvirtUsable` suppresses the remedy rather than the check. On a host
        // with no usable libvirt the vTPM answer is unknown *because* of the
        // gating failure right above it, and telling that operator to install
        // swtpm would send them after the wrong thing — the second message they
        // read would contradict the first.
        guard libvirtUsable else {
            return .fail(
                .vtpmSupport, severity: .advisory,
                "not checked: libvirt is not usable on this host (see the libvirt check), so it could not "
                    + "be asked whether it can back a guest TPM 2.0. Fix libvirt first; this answers itself.")
        }

        // Shared, because the remedy is the same either way and only the lede
        // differs. The restart matters: libvirtd caches its capabilities, so
        // installing swtpm under a running daemon changes nothing until it is
        // restarted — which is the failure mode where an operator installs the
        // package and the host still refuses to advertise a TPM.
        let remedy =
            " — this host cannot run VMs with a TPM 2.0 (Windows 11 and Server 2025 require one). "
            + "Install swtpm (Debian/Ubuntu: `apt install swtpm swtpm-tools`) and restart libvirtd "
            + "(`systemctl restart virtqemud.socket virtqemud`, or libvirtd on a monolithic install), "
            + "which caches its capabilities."

        switch support {
        case .supported:
            return .pass(.vtpmSupport, severity: .advisory)
        case .unsupported:
            return .fail(
                .vtpmSupport, severity: .advisory,
                "libvirt reports no emulated TPM backend at \(LibvirtProbe.systemURI)" + remedy)
        case .unknown(let detail):
            return .fail(
                .vtpmSupport, severity: .advisory,
                "could not ask libvirt whether it can back a vTPM: \(detail)" + remedy)
        }
    }

    /// QEMU's firmware descriptors are what libvirt reads to autoselect a
    /// CODE/VARS pair for `<os firmware='efi'>`.
    ///
    /// Advisory, and *more* advisory since STR-188: the agent names the pair
    /// itself on every host `FirmwareResolver` can resolve one for, so the
    /// descriptors matter only where it cannot and the document falls back to
    /// autoselection. They arrive with the same package as the firmware, so a
    /// host missing them is usually a host missing EDK2 — which `uefi_firmware`
    /// reports separately, and with the remedy.
    static func checkFirmwareDescriptors(_ directory: String) -> Check {
        let descriptors =
            (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .filter { $0.hasSuffix(".json") } ?? []
        guard !descriptors.isEmpty else {
            return .fail(
                .qemuFirmwareDescriptors, severity: .advisory,
                "no QEMU firmware descriptors (*.json) in \(directory) — libvirt cannot autoselect UEFI "
                    + "firmware, which is the fallback for a host whose EDK2 build the agent cannot find. "
                    + "Install EDK2 firmware (Debian/Ubuntu: `apt install ovmf qemu-efi-aarch64`).")
        }
        return .pass(.qemuFirmwareDescriptors, severity: .advisory)
    }

    /// libvirtd reachability and its version floor.
    ///
    /// Always gating (STR-136): a QEMU placement *is* a libvirt domain, so a
    /// host that cannot reach `qemu:///system`, or runs a libvirt too old to
    /// snapshot UEFI guests, cannot serve the VM operations it would be asked
    /// for. These checks only run at all where `Inputs.libvirt` is non-nil,
    /// which is Linux.
    static func checkLibvirt(
        _ status: LibvirtProbe.Status, minimumVersion: LibvirtProbe.Version
    ) -> [Check] {
        let severity = Severity.gating

        switch status {
        case .clientMissing:
            return [
                .fail(
                    .libvirtConnection, severity: severity,
                    "libvirt is not installed on this host (no `virsh` on PATH) — the agent manages VMs "
                        + "through libvirtd. Install it (Debian/Ubuntu: "
                        + "`apt install libvirt-daemon-system libvirt-clients`) and start "
                        + "virtqemud.socket (or libvirtd.socket on a monolithic install); re-running "
                        + "deploy/agent/install.sh does both.")
            ]
        case .unreachable(let detail):
            return [
                .fail(
                    .libvirtConnection, severity: severity,
                    "cannot connect to \(LibvirtProbe.systemURI): \(detail). Start the daemon "
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
                    "connected to \(LibvirtProbe.systemURI), but could not read the daemon version "
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
                        "libvirt \(version) is older than the required \(minimumVersion) — VM checkpoints "
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

}
