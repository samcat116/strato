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

/// A jailer UID range that cannot safely be represented without wrapping or
/// entering the host's conventional system/login-user space.
public enum SandboxJailerConfigError: Error, LocalizedError, Equatable, Sendable {
    case invalidUIDBase(UInt32)

    public var errorDescription: String? {
        switch self {
        case .invalidUIDBase(let base):
            return "sandbox jailer uid base \(base) must be at least "
                + "\(SandboxJailerConfig.minimumUIDBase) and leave room for "
                + "\(SandboxJailerConfig.uidCount) ids without wrapping"
        }
    }
}

public enum SandboxJailPlanError: Error, LocalizedError, Equatable, Sendable {
    case rootIdentity

    public var errorDescription: String? {
        "a sandbox jail plan cannot use uid/gid 0 or uid_t(-1)"
    }
}

/// The agent-level jailer settings, resolved from config + defaults.
public struct SandboxJailerConfig: Sendable, Equatable {
    public let jailerBinaryPath: String
    /// Base directory for per-sandbox chroots (`--chroot-base-dir`). Sized for
    /// a full writable rootfs copy per sandbox, so it defaults under the VM
    /// storage path rather than the jailer's tiny `/srv/jailer` default.
    public let chrootBaseDir: String
    /// First uid/gid of the range new sandbox identities are allocated from.
    public let uidBase: UInt32
    /// Absolute path of the iproute2 `ip` binary, resolved once at start
    /// (`SandboxJailerResolver.resolveIPBinaryPath`). Invoked directly — a
    /// service manager's stripped `PATH` must not turn a host the resolver
    /// declared usable into one whose netns calls fail at create time. Nil
    /// when the host has no `ip`, in which case the resolver never returns
    /// `.jailed`; only namespace *creation* needs the binary (teardown is
    /// direct umount+unlink and works regardless).
    public let ipBinaryPath: String?
    /// Absolute path of the iproute2 `tc` binary, resolved the same way and for
    /// the same reason as `ipBinaryPath`. Only *networked* sandboxes need it (it
    /// installs the redirects splicing the jail's TAP to its veth), so a host
    /// without it still runs sandboxes — it just refuses NICs.
    public let tcBinaryPath: String?

    /// Size of the per-sandbox uid/gid range. Fixed: 2^16 ids starting at
    /// `uidBase`.
    public static let uidCount: UInt32 = 65536

    /// Keep jail identities out of the 16-bit system/login-user space even
    /// before the host-specific passwd/group/subid preflight runs.
    public static let minimumUIDBase: UInt32 = 65_536

    /// Highest base whose inclusive last UID (`base + uidCount - 1`) stays
    /// below `UInt32.max`, which POSIX APIs reserve as `(uid_t)-1`. Kept
    /// explicit so neither configuration nor a direct public initializer can
    /// silently wrap or allocate the sentinel.
    public static let maximumUIDBase: UInt32 = UInt32.max - uidCount

    public init(
        jailerBinaryPath: String, chrootBaseDir: String, uidBase: UInt32, ipBinaryPath: String? = nil,
        tcBinaryPath: String? = nil
    ) throws {
        guard uidBase >= Self.minimumUIDBase, uidBase <= Self.maximumUIDBase else {
            throw SandboxJailerConfigError.invalidUIDBase(uidBase)
        }
        self.jailerBinaryPath = jailerBinaryPath
        self.chrootBaseDir = chrootBaseDir
        self.uidBase = uidBase
        self.ipBinaryPath = ipBinaryPath
        self.tcBinaryPath = tcBinaryPath
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

    /// Where the iproute2 `tc` binary is looked for. Deliberately *not* a
    /// jailing prerequisite: only a networked sandbox needs `tc`, so a host
    /// without it should still run sandboxes rather than lose the barrier.
    public static let tcBinaryCandidates = ["/usr/sbin/tc", "/sbin/tc", "/usr/bin/tc", "/bin/tc"]

    /// The `tc` binary the netns attachment will invoke, or nil when the host
    /// has none — in which case networked sandboxes are refused with a reason.
    public static func resolveTCBinaryPath(isExecutable: (String) -> Bool) -> String? {
        tcBinaryCandidates.first(where: isExecutable)
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

/// The jail layout for one sandbox: an explicitly allocated uid/gid, chroot paths, the
/// in-jail names the Firecracker API sees and their host-side views, the
/// network-namespace name, and the cgroup memory ceiling.
///
/// Paths remain deterministic from the sandbox id and jailer config. Identity
/// does not: the caller must supply the manifest-backed allocation, which
/// makes accidental hash collisions impossible on every new-create path.
public struct SandboxJailPlan: Sendable, Equatable {
    public let sandboxId: String
    /// The manifest-backed, host-unique identity the jailed Firecracker drops
    /// to. UID 0 and uid_t(-1) are never valid assignments. GID intentionally
    /// matches UID.
    public let uid: UInt32
    public let gid: UInt32
    /// The per-sandbox jail directory (`<base>/<exec name>/<id>`) — the whole
    /// subtree the jailer owns and teardown removes.
    public let jailDirectory: String
    /// The chroot root (`<jailDirectory>/root`): the jailed process's `/`.
    public let jailRoot: String
    /// Name of the sandbox's dedicated network namespace. Empty for a
    /// network-free sandbox; for one with a NIC it holds the veth peer and TAP
    /// the orchestrator wired in (issue STR-100).
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
    /// Where a jailed Firecracker writes snapshot files (`PUT /snapshot/create`)
    /// and reads them back on load (issue #426). Created and chowned to the
    /// per-sandbox uid by the runtime before a checkpoint or restore; the
    /// runtime archives the files to host-owned storage afterwards.
    public static let snapshotDirInJail = "/snapshots"
    public static let snapshotMemoryPathInJail = "/snapshots/memory.snap"
    public static let snapshotVmstatePathInJail = "/snapshots/vmstate.snap"

    public init(
        sandboxId: String,
        jailUID: UInt32,
        config: SandboxJailerConfig,
        firecrackerBinaryPath: String
    ) throws {
        guard jailUID != 0, jailUID != UInt32.max else {
            throw SandboxJailPlanError.rootIdentity
        }
        self.sandboxId = sandboxId
        self.uid = jailUID
        self.gid = self.uid
        self.jailDirectory = Self.jailDirectory(
            sandboxId: sandboxId,
            chrootBaseDir: config.chrootBaseDir,
            firecrackerBinaryPath: firecrackerBinaryPath)
        self.jailRoot = jailDirectory + "/root"
        self.netnsName = Self.netnsName(sandboxId: sandboxId)
    }

    /// The historical hash assignment used by manifests written before
    /// `VMManifestEntry.jailUID`. Kept only for one-time legacy adoption; new
    /// identities must come from `SandboxJailUIDAllocator`.
    public static func legacyUID(sandboxId: String, uidBase: UInt32) throws -> UInt32 {
        // Preserve the pre-STR-290 arithmetic exactly, including wrapping an
        // old directly-constructed/high configured base and mapping a wrapped
        // zero to 1. This helper is migration-only; new ranges are validated
        // before the allocator is constructed.
        guard uidBase > 0 else {
            throw SandboxJailerConfigError.invalidUIDBase(uidBase)
        }
        let slot = UInt32(FNV1a.hash64(sandboxId) % UInt64(SandboxJailerConfig.uidCount))
        let id = uidBase &+ slot
        guard id != UInt32.max else { throw SandboxJailPlanError.rootIdentity }
        return id == 0 ? 1 : id
    }

    /// Deterministic jail directory used by legacy-owner recovery and cleanup
    /// paths that do not yet have (or do not need) an identity assignment.
    public static func jailDirectory(
        sandboxId: String, chrootBaseDir: String, firecrackerBinaryPath: String
    ) -> String {
        let execName = URL(fileURLWithPath: firecrackerBinaryPath).lastPathComponent
        return "\(chrootBaseDir)/\(execName)/\(sandboxId)"
    }

    /// The namespace name for a sandbox, derived from its id **alone**.
    ///
    /// Split out from the full plan because network teardown needs it on an
    /// agent that has no jailer config any more (the sandbox runtime was
    /// deconfigured since the sandbox was created). Nothing else about the
    /// layout is reachable there, and nothing else is needed: device names come
    /// from the sandbox id too, and ownership is create-only.
    public static func netnsName(sandboxId: String) -> String {
        "strato-sbx-\(sandboxId)"
    }

    /// Host view of an in-jail path.
    public func hostPath(forInJail path: String) -> String {
        jailRoot + path
    }

    /// Host view of the vsock UDS the runtime's control connections dial.
    public var vsockUDSHostPath: String { hostPath(forInJail: Self.vsockUDSPathInJail) }

    /// Where `ip netns add` bind-mounts every namespace it creates. Scanned by
    /// the crash sweeps, which have to find namespaces whose owning workload
    /// left no other trace.
    public static let netnsDirectory = "/var/run/netns"

    /// The netns bind-mount path `ip netns add` creates and the jailer joins.
    public var netnsPath: String { "\(Self.netnsDirectory)/\(netnsName)" }

    /// The sandbox (or warm template) id a namespace name belongs to, or nil
    /// when the name is not one of ours. The inverse of ``netnsName(sandboxId:)``.
    public static func sandboxId(fromNetnsName name: String) -> String? {
        let prefix = netnsName(sandboxId: "")
        guard name.hasPrefix(prefix), name.count > prefix.count else { return nil }
        return String(name.dropFirst(prefix.count))
    }

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

    /// Whether this host can take the jailer memory ceiling: cgroup v2
    /// mounted (`cgroup.controllers` readable) **with** the `memory`
    /// controller actually listed. The jailer writes every `--cgroup` file it
    /// is given and aborts the spawn when one cannot be written, so passing
    /// `memory.max` on a v2 host whose hierarchy lacks the memory controller
    /// (e.g. `cgroup_disable=memory`) would fail every jailed create. Hosts
    /// without it — like v1 hosts — get the rest of the barrier and no
    /// ceiling. Injectable for tests.
    public static func hostSupportsMemoryCeiling(
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Bool {
        HostMemoryController.isAvailable(readFile: readFile)
    }

}
