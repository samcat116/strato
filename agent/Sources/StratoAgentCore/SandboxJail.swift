import Foundation

/// How the agent applies Firecracker's jailer to sandboxes (issue #425).
///
/// Sandboxes run **untrusted** workloads by definition, so their VMM processes
/// get a hardening barrier VMs (operator-trusted workloads) don't yet have:
/// chroot, privilege drop to a per-sandbox uid/gid, an empty per-sandbox
/// network namespace, and — on cgroup-v2 hosts — a memory ceiling. The policy
/// knob is `sandbox_jailer_mode`:
///
/// - `auto` (default): jail when the host can (root + jailer binary); log a
///   prominent warning and run unjailed otherwise, so dev hosts keep working.
/// - `required`: never run a sandbox unjailed — when the jailer is unusable,
///   the agent does not advertise the sandbox capability at all. This is the
///   production posture.
/// - `disabled`: never jail (dev/debug escape hatch).
public enum SandboxJailerMode: String, Sendable, Codable, CaseIterable {
    case auto
    case required
    case disabled
}

/// The agent-level jailer settings, resolved from config + defaults.
public struct SandboxJailerConfig: Sendable, Equatable {
    public let jailerBinaryPath: String
    /// Base directory for per-sandbox chroots (`--chroot-base-dir`). Sized for
    /// a full writable rootfs copy per sandbox, so it defaults under the VM
    /// storage path rather than the jailer's tiny `/srv/jailer` default.
    public let chrootBaseDir: String
    /// First uid/gid of the per-sandbox range (see `SandboxJailPlan` for the
    /// derivation).
    public let uidBase: UInt32
    /// Absolute path of the iproute2 `ip` binary, resolved once at start
    /// (`SandboxJailerResolver.resolveIPBinaryPath`). Invoked directly — a
    /// service manager's stripped `PATH` must not turn a host the resolver
    /// declared usable into one whose netns calls fail at create time. Nil
    /// when the host has no `ip`, in which case the resolver never returns
    /// `.jailed`; only namespace *creation* needs the binary (teardown is
    /// direct umount+unlink and works regardless).
    public let ipBinaryPath: String?

    /// Size of the per-sandbox uid/gid range. Fixed: 2^16 ids starting at
    /// `uidBase`.
    public static let uidCount: UInt32 = 65536

    public init(jailerBinaryPath: String, chrootBaseDir: String, uidBase: UInt32, ipBinaryPath: String? = nil) {
        self.jailerBinaryPath = jailerBinaryPath
        self.chrootBaseDir = chrootBaseDir
        self.uidBase = uidBase
        self.ipBinaryPath = ipBinaryPath
    }
}

/// Decides, once at agent start, whether sandboxes run jailed. Pure — every
/// host fact is injected — so the `mode × host` matrix is unit-testable.
public enum SandboxJailerResolver {
    /// The start-time decision. `unjailed` carries the reason (surfaced as a
    /// warning in `auto` mode); `blocked` means `required` could not be
    /// satisfied and the sandbox capability must not be advertised.
    public enum Resolution: Equatable, Sendable {
        case jailed
        case unjailed(reason: String?)
        case blocked(reason: String)
    }

    /// Where the iproute2 `ip` binary is looked for. Jailed creates shell out
    /// to `ip netns add`, so a host without it must resolve unjailed/blocked
    /// up front rather than advertise a capability every placement would then
    /// fail at.
    public static let ipBinaryCandidates = ["/usr/sbin/ip", "/sbin/ip", "/usr/bin/ip", "/bin/ip"]

    /// The `ip` binary the runtime will actually invoke (first executable
    /// candidate), or nil when the host has none. Resolved once and carried in
    /// `SandboxJailerConfig.ipBinaryPath` so the spawn never depends on the
    /// service manager's `PATH` agreeing with this probe.
    public static func resolveIPBinaryPath(isExecutable: (String) -> Bool) -> String? {
        ipBinaryCandidates.first(where: isExecutable)
    }

    public static func resolve(
        mode: SandboxJailerMode,
        jailerBinaryPath: String,
        isRoot: Bool,
        isExecutable: (String) -> Bool
    ) -> Resolution {
        switch mode {
        case .disabled:
            return .unjailed(reason: nil)
        case .auto, .required:
            var missing: [String] = []
            if !isExecutable(jailerBinaryPath) {
                missing.append("jailer binary not executable at \(jailerBinaryPath)")
            }
            if !isRoot {
                missing.append("the agent is not running as root (the jailer needs root to chroot and drop privileges)")
            }
            if resolveIPBinaryPath(isExecutable: isExecutable) == nil {
                missing.append(
                    "the `ip` tool (iproute2) was not found — jailed sandboxes need it to create network namespaces")
            }
            guard !missing.isEmpty else { return .jailed }
            let reason = missing.joined(separator: "; ")
            return mode == .required ? .blocked(reason: reason) : .unjailed(reason: reason)
        }
    }
}

/// The fully-derived jail layout for one sandbox: uid/gid, chroot paths, the
/// in-jail names the Firecracker API sees and their host-side views, the
/// network-namespace name, and the cgroup memory ceiling.
///
/// Pure and deterministic — derived only from the sandbox id and the jailer
/// config — so create, adoption after an agent restart, and teardown always
/// agree on every path without persisting anything.
public struct SandboxJailPlan: Sendable, Equatable {
    public let sandboxId: String
    /// The unprivileged uid/gid the jailed Firecracker drops to: `uidBase +
    /// (FNV-1a-64(sandboxId) % uidCount)`, never colliding with uid 0. A
    /// stateless hash keeps the mapping stable across agent restarts; two
    /// sandboxes sharing a slot (rare at 2^16) weakens only their *mutual*
    /// isolation, never the host boundary.
    public let uid: UInt32
    public let gid: UInt32
    /// The per-sandbox jail directory (`<base>/<exec name>/<id>`) — the whole
    /// subtree the jailer owns and teardown removes.
    public let jailDirectory: String
    /// The chroot root (`<jailDirectory>/root`): the jailed process's `/`.
    public let jailRoot: String
    /// Name of the sandbox's dedicated (and, until guest networking lands,
    /// deliberately empty) network namespace.
    public let netnsName: String

    // In-jail paths — what the Firecracker API is given. Fixed names: the
    // per-sandbox directory *is* the namespace.
    public static let rootfsPathInJail = "/rootfs.ext4"
    public static let configPathInJail = "/config.img"
    public static let kernelPathInJail = "/kernel"
    public static let initramfsPathInJail = "/initramfs"
    /// The vsock UDS Firecracker binds inside the jail. Lives under `run/`
    /// beside the API socket (both are created at runtime by the jailed
    /// process, which owns that directory).
    public static let vsockUDSPathInJail = "/run/vsock.sock"

    public init(sandboxId: String, config: SandboxJailerConfig, firecrackerBinaryPath: String) {
        self.sandboxId = sandboxId
        let slot = UInt32(Self.fnv1a64(sandboxId) % UInt64(SandboxJailerConfig.uidCount))
        let id = config.uidBase &+ slot
        self.uid = id == 0 ? 1 : id
        self.gid = self.uid
        let execName = URL(fileURLWithPath: firecrackerBinaryPath).lastPathComponent
        self.jailDirectory = "\(config.chrootBaseDir)/\(execName)/\(sandboxId)"
        self.jailRoot = jailDirectory + "/root"
        self.netnsName = "strato-sbx-\(sandboxId)"
    }

    /// Host view of an in-jail path.
    public func hostPath(forInJail path: String) -> String {
        jailRoot + path
    }

    /// Host view of the vsock UDS the runtime's control connections dial.
    public var vsockUDSHostPath: String { hostPath(forInJail: Self.vsockUDSPathInJail) }

    /// The netns bind-mount path `ip netns add` creates and the jailer joins.
    public var netnsPath: String { "/var/run/netns/\(netnsName)" }

    /// The jailer cgroup memory ceiling for a sandbox with `guestMemoryBytes`
    /// of guest RAM: guest size plus a fixed 128 MiB VMM allowance
    /// (Firecracker's own overhead is single-digit MiB; the headroom covers
    /// virtio queues, vsock buffers, and jemalloc slack). This is a
    /// host-protection backstop against a compromised VMM ballooning host
    /// memory — *not* an accounting input; the agent's manifest-based
    /// reservation remains the only capacity owner.
    public static func memoryLimitBytes(guestMemoryBytes: Int64) -> Int64 {
        guestMemoryBytes + 128 * 1024 * 1024
    }

    /// Whether this host mounts cgroup v2 (the only hierarchy the agent
    /// drives jailer cgroup limits against; v1 hosts get no limits and a log
    /// line). Injectable for tests.
    public static func hostUsesCgroupV2(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        fileExists("/sys/fs/cgroup/cgroup.controllers")
    }

    /// Fixed FNV-1a 64 (not Swift's per-process-seeded `Hasher`), so uid
    /// derivation is stable across agent restarts.
    private static func fnv1a64(_ input: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
