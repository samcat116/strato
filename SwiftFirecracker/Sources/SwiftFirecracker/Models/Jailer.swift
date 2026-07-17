import Foundation

/// How to wrap a Firecracker process in the `jailer` hardening barrier
/// (issue #425): chroot, privilege drop to a dedicated uid/gid, optional
/// network-namespace confinement, and optional cgroup limits.
///
/// The jailer runs `exec-file` inside `<chrootBaseDir>/<exec file name>/<vm id>/root`,
/// so every path handed to the Firecracker API afterwards (kernel, drives,
/// vsock UDS) is interpreted **inside that chroot** — the caller is responsible
/// for placing the files there (readable by `uid`/`gid`) *before* spawning, and
/// for translating between in-jail paths and their host views. `JailerOptions`
/// only describes the barrier; `FirecrackerClient` owns the spawn.
public struct JailerOptions: Sendable {
    /// Path to the `jailer` binary on the host.
    public var jailerBinaryPath: String
    /// Base directory for chroots (`--chroot-base-dir`). The concrete jail for
    /// a VM is derived via ``jailDirectory(chrootBaseDir:firecrackerBinaryPath:vmId:)``.
    public var chrootBaseDir: String
    /// The unprivileged uid the Firecracker process drops to.
    public var uid: UInt32
    /// The unprivileged gid the Firecracker process drops to.
    public var gid: UInt32
    /// Bind-mounted network-namespace file (`/var/run/netns/<name>`) the jailed
    /// process is confined to, or nil to stay in the host namespace. The
    /// namespace must exist before spawning, and any TAP device the VM should
    /// see must already live inside it.
    public var netnsPath: String?
    /// Cgroup hierarchy version to drive the jailer's `--cgroup` flags against
    /// (1 or 2), or nil to omit the flag (jailer defaults to v1). Only
    /// meaningful when `cgroups` is non-empty.
    public var cgroupVersion: Int?
    /// `--cgroup` entries in the jailer's `<file>=<value>` syntax
    /// (e.g. `memory.max=1207959552`). Empty means no cgroup limits.
    public var cgroups: [String]

    public init(
        jailerBinaryPath: String,
        chrootBaseDir: String,
        uid: UInt32,
        gid: UInt32,
        netnsPath: String? = nil,
        cgroupVersion: Int? = nil,
        cgroups: [String] = []
    ) {
        self.jailerBinaryPath = jailerBinaryPath
        self.chrootBaseDir = chrootBaseDir
        self.uid = uid
        self.gid = gid
        self.netnsPath = netnsPath
        self.cgroupVersion = cgroupVersion
        self.cgroups = cgroups
    }

    /// The API socket path *inside* the jail. This is Firecracker's own
    /// default when jailed; every jail uses the same in-chroot path, which is
    /// why adopted jailed processes are discovered by `--id` rather than by
    /// socket path.
    public static let apiSocketPathInJail = "/run/firecracker.socket"

    /// The per-VM jail directory: `<base>/<exec file name>/<vm id>`. The
    /// jailer creates (and on destroy the client removes) this whole subtree;
    /// the chroot root itself is its `root/` child.
    public static func jailDirectory(
        chrootBaseDir: String, firecrackerBinaryPath: String, vmId: String
    ) -> String {
        let execName = URL(fileURLWithPath: firecrackerBinaryPath).lastPathComponent
        return "\(chrootBaseDir)/\(execName)/\(vmId)"
    }

    /// The chroot root for a VM — the host directory that becomes `/` for the
    /// jailed Firecracker. Files the VM must reach (kernel, rootfs, drives) go
    /// under here, and in-jail paths map to host paths by prefixing it.
    public static func jailRoot(
        chrootBaseDir: String, firecrackerBinaryPath: String, vmId: String
    ) -> String {
        jailDirectory(chrootBaseDir: chrootBaseDir, firecrackerBinaryPath: firecrackerBinaryPath, vmId: vmId)
            + "/root"
    }

    /// Host view of a jailed VM's API socket.
    public static func socketPath(
        chrootBaseDir: String, firecrackerBinaryPath: String, vmId: String
    ) -> String {
        jailRoot(chrootBaseDir: chrootBaseDir, firecrackerBinaryPath: firecrackerBinaryPath, vmId: vmId)
            + apiSocketPathInJail
    }

    /// The full jailer argv (excluding argv[0]) for spawning one VM.
    ///
    /// The jailer itself appends `--id <vmId>` to the Firecracker arguments,
    /// so the trailing section (after `--`) deliberately does not repeat it —
    /// only the api-sock (pinned to the version-stable in-jail default) and
    /// the log level are passed through.
    public func arguments(vmId: String, firecrackerBinaryPath: String) -> [String] {
        var args = [
            "--id", vmId,
            "--exec-file", firecrackerBinaryPath,
            "--uid", String(uid),
            "--gid", String(gid),
            "--chroot-base-dir", chrootBaseDir,
        ]
        if let netnsPath {
            args += ["--netns", netnsPath]
        }
        if !cgroups.isEmpty {
            if let cgroupVersion {
                args += ["--cgroup-version", String(cgroupVersion)]
            }
            for cgroup in cgroups {
                args += ["--cgroup", cgroup]
            }
        }
        args += [
            "--",
            "--api-sock", Self.apiSocketPathInJail,
            "--level", "Info",
        ]
        return args
    }
}
