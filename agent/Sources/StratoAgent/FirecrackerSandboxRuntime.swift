import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import Glibc
import SwiftFirecracker

/// The concrete sandbox runtime (issue #421): OCI-image Firecracker microVMs.
///
/// A sandbox is a Firecracker microVM booted from the maintained guest kernel +
/// initramfs (issue #419), with the flattened container image (issue #418)
/// attached as its root disk and a small config drive telling the guest init
/// what to run. The host reaches the in-guest control agent over vsock (issue
/// #420) for health and exit-code reporting.
///
/// **Shares Firecracker process management with `FirecrackerService`.** Both are
/// handed the same `FirecrackerClient` by the `Agent`, so process spawning,
/// socket-directory layout, and re-adoption (issue #433) live in one place;
/// sandbox IDs and VM IDs are distinct UUIDs, so they never collide in the
/// shared process registry. Resource reservation is likewise shared at a higher
/// level: the `Agent` accounts for sandbox vCPU/memory straight from the
/// manifest, so this runtime intentionally exposes no `reservedResources()`.
///
/// **Lifecycle model.** A non-deleted sandbox always has a live Firecracker
/// process (Firecracker has no stop-that-keeps-state), so the states map onto
/// the microVM as: created ⇒ `Not started`, running ⇒ `Running`, stopped ⇒
/// `Paused`. Booting starts or resumes; stopping pauses; deleting tears the
/// process down. Keeping the process alive means NIC and vsock wiring are
/// configured exactly once (at create) and re-adoption after an agent restart
/// is uniform. A stopped sandbox therefore still holds its reserved memory —
/// consistent with the manifest-based, state-independent reservation model.
/// Cold-boot stop (releasing memory) is future work.
actor FirecrackerSandboxRuntime: SandboxRuntimeService {
    let logger: Logger
    let client: FirecrackerClient
    let imageService: SandboxImageService
    let socketDirectory: String
    let sandboxStoragePath: String
    let guestImagePath: String
    /// The Firecracker binary the shared client spawns — the jail layout keys
    /// on its basename, so create/adopt/teardown derive identical chroots.
    let firecrackerBinaryPath: String
    /// Jailer settings (issue #425). Always present: even when new sandboxes
    /// run unjailed (`jailNewSandboxes == false`), the *layout* is what lets
    /// jailed orphans from a previous agent life be re-adopted and torn down
    /// after the operator flips the mode — a running process keeps the
    /// barrier it was born with.
    let jailerConfig: SandboxJailerConfig
    /// Whether newly created sandboxes get the jailer barrier
    /// (`sandbox_jailer_mode` resolution — see `SandboxJailerMode`).
    let jailNewSandboxes: Bool
    /// Non-nil when `sandbox_jailer_mode = "required"` is unmet on this host:
    /// creating a sandbox is refused (running one unjailed is not an option),
    /// while everything an *existing* sandbox needs — adoption, status, stop,
    /// delete — keeps working, since none of it spawns a new jailer. Without
    /// this, jailed orphans would outlive their deletion unmanaged.
    let jailerBlockedReason: String?
    /// Moves exported snapshot artifacts between this host and control-plane
    /// object storage over SVID mTLS (issue #428). Nil when SPIFFE is not
    /// configured — snapshot export and cross-agent restore/fork then fail
    /// with a clear error while everything agent-local keeps working.
    let snapshotTransfer: SnapshotArtifactTransfer?
    /// Logged once: hosts without a usable cgroup-v2 memory controller get no
    /// jailer memory ceiling.
    var warnedNoMemoryCeiling = false

    // MARK: Warm start (issue #426)

    /// Whether warm start is actually in effect: requested via
    /// `sandbox_warm_start` AND the runtime jails new sandboxes. Unjailed
    /// warm start is structurally impossible — the snapshot vmstate records
    /// the template's *absolute* drive/vsock paths, which are gone after
    /// template teardown; only jailed snapshots (chroot-relative paths,
    /// identical in every jail) restore into a different sandbox's layout.
    /// Every warm failure falls back to a cold boot, so this only trades
    /// boot latency, never correctness.
    let warmStartActive: Bool
    /// The per-(image, guest, machine shape) template snapshot cache, rooted
    /// under the sandbox storage directory.
    let warmCache: WarmSandboxSnapshotCache
    /// LRU budget for `warmCache`, swept after each template publish.
    let warmCacheBudgetBytes: Int64
    /// Cheap identity for the Firecracker binary (size + mtime), part of the
    /// warm key: snapshots do not load across Firecracker builds, so a binary
    /// upgrade must miss the old entries rather than fail restoring them.
    let firecrackerFingerprint: String
    /// Template builds in flight, keyed by the warm key's directory name.
    /// Also serves as the global concurrency gate: at most one template
    /// microVM (an unaccounted, guest-memory-sized guest) builds at a time.
    var warmBuildsInFlight: Set<String> = []
    /// Failed template builds and when they may be retried. A failure damps
    /// retries for `warmBuildRetryInterval` instead of forever: permanent
    /// causes (a guest image without `warm_hold`) age out naturally when the
    /// guest image — part of the key — changes, while transient causes
    /// (disk pressure, a slow boot) deserve another attempt.
    var warmBuildFailures: [String: Date] = [:]
    static let warmBuildRetryInterval: TimeInterval = 15 * 60
    /// One-shot sweep of template debris left by a crash mid-build (template
    /// microVMs are deliberately not in the manifest, so ordinary orphan
    /// recovery never finds them). Runs on the first create.
    var warmTemplateSweepDone = false

    /// Whether this host's Firecracker can repoint a restored network device
    /// at a different host TAP (STR-104), resolved once per agent life from
    /// `firecracker --version`. The binary cannot change under a running
    /// agent — an update replaces the agent too — so a version the probe
    /// actually read is cached for good.
    ///
    /// A probe *failure* is not, deliberately: `firecrackerVersion` answers nil
    /// for a spawn error, a timeout and a non-zero exit as readily as for a
    /// build too old to say, and memoizing that would let one `--version` fork
    /// timing out under create pressure make every networked fork on the host
    /// fail permanently until a restart.
    var networkOverridesSupport: Bool?

    /// The Firecracker interface id every sandbox NIC is configured with. It
    /// is what `network_overrides` names on a snapshot load, so it has to be
    /// the same string on the cold path, the template path, and the restore.
    static let networkInterfaceId = "eth0"

    /// The MAC a warm template's throwaway NIC is created with.
    ///
    /// Deliberately constant and obviously synthetic: it is baked into every
    /// template snapshot, the guest never configures the device while held,
    /// and the sandbox's real MAC is applied by the `launch` request. A
    /// per-template random MAC would only make identical templates differ.
    static let templateMACAddress = "06:00:00:00:00:01"

    /// Guest context ID for the single vsock device. CIDs 0–2 are reserved, so
    /// 3 is the first usable guest CID.
    ///
    /// The same constant for every sandbox, and deliberately not drawn from
    /// `VsockCIDAllocator` (STR-72): Firecracker emulates virtio-vsock inside
    /// its own process and gives the host a Unix-domain socket rather than an
    /// AF_VSOCK endpoint, so this number is scoped to one microVM and never
    /// enters the host kernel's namespace. Two sandboxes on CID 3 collide over
    /// nothing. Allocating host CIDs here would spend a genuinely host-global
    /// resource on devices that occupy none of it, and would suggest a shared
    /// namespace where there is not one.
    static let guestCID: UInt32 = 3

    /// Everything the runtime tracks for one managed sandbox.
    struct Managed {
        let spec: SandboxSpec
        /// Per-sandbox writable ext4 copy of the flattened image (the shared
        /// cache entry stays pristine and read-only).
        let rootfsPath: String
        /// The staged config block image.
        let configPath: String
        /// Host UDS backing the vsock device for host→guest control traffic.
        let vsockUdsPath: String
        /// The boot nonce stamped into the config drive, echoed by the guest.
        let identityNonce: String
        /// Learned from a validated current-version `pong`. Nil means only that
        /// a paused guest was adopted before the host could query it; such a
        /// guest must resume and verify before it can be checkpointed.
        var guestControlProtocolVersion: Int? = nil
        /// The jail layout when this sandbox runs inside the jailer barrier
        /// (issue #425); nil for an unjailed sandbox (jailer disabled, or an
        /// orphan adopted from a pre-jailer life).
        let jail: SandboxJailPlan?
        /// The registry credential the sandbox was created with, kept so the
        /// warm-launch fallback (demote to cold) can re-materialize a
        /// private-registry image even after the rootfs cache evicted it.
        var registryCredential: RegistryCredential? = nil
        /// The host-side NICs the orchestrator realized for this sandbox, kept
        /// for the same reason as the credential: a re-provision under the same
        /// id must reconfigure the same devices rather than silently drop them.
        var networkAttachments: [ResolvedNetworkAttachment] = []
        /// For a warm-provisioned sandbox that has not launched yet: the
        /// template identity its held guest must echo before the workload is
        /// launched into it (issue #426). Nil after launch, for cold boots,
        /// and for adopted sandboxes (where the binding is unrecoverable and
        /// the held-state check alone gates the launch).
        var warmHeldIdentity: (templateId: String, templateNonce: String)? = nil
        /// The live Firecracker session, present for the sandbox's whole life.
        var manager: FirecrackerManager
        /// The workload's exit code once it has ended, cached so it survives a
        /// guest that later stops answering.
        var lastExitCode: Int?
        /// Bumped whenever this sandbox's exec sessions are swept (stop or
        /// delete). `startExec` snapshots it before its awaits and re-checks
        /// after, so a session whose handshake raced a sweep is refused
        /// instead of being registered against a stopped sandbox (where it
        /// would never receive a terminal event).
        var execSweepEpoch: UInt64 = 0
    }

    var sandboxes: [String: Managed] = [:]

    /// Sandboxes with a checkpoint or restore in flight (issue #426). The
    /// snapshot sequence drains vsock connections and pauses the guest, so
    /// while a sandbox is in this set: lifecycle operations (boot, stop,
    /// exec) are refused as transient, and status mapping skips the guest
    /// vsock poll — actor reentrancy would otherwise let a concurrent status
    /// poll open a connection between the drain and the pause, which
    /// Firecracker rejects a vsock snapshot over.
    var checkpointing: Set<String> = []

    // MARK: Exec/log state (issue #423)

    /// One live exec session: a dedicated guest connection plus the detached
    /// reader task draining its output. Keyed by the control plane's
    /// sessionId in `execSessions`; `sandboxId` lets a sandbox teardown find
    /// its sessions.
    struct ExecSession {
        let sandboxId: String
        let connection: VsockConnection
        let events: @Sendable (SandboxExecEvent) -> Void
        var reader: Task<Void, Never>?
    }

    var execSessions: [String: ExecSession] = [:]

    /// Per-sandbox log follow state. The entry outlives individual follow
    /// tasks (shutdown stops the task, boot starts a new one) so `lastSeq`
    /// resumes delivery where it left off and a partial line buffered in
    /// `assembler` is completed rather than split across a pause.
    struct LogFollow {
        /// Monotonic ownership token: every (re)started follow task gets a
        /// fresh generation, and only the current generation may register a
        /// connection or record records — a superseded loop that limps past
        /// its cancellation cannot corrupt its successor's state.
        var generation: UInt64
        var task: Task<Void, Never>?
        /// The loop's live connection, registered so a stop can close it and
        /// unblock the loop's blocking read.
        var connection: VsockConnection?
        /// Highest ring-buffer seq recorded; the next connect resumes at
        /// `lastSeq + 1`.
        var lastSeq: UInt64
        var assembler: SandboxLogLineAssembler
    }

    var logFollows: [String: LogFollow] = [:]
    var logHandler: (@Sendable (String, String, String) -> Void)?

    /// Wall-clock budget for opening an exec/log connection and for the exec
    /// spawn handshake.
    static let execConnectTimeout: TimeInterval = 10

    /// Default LRU budget for the warm-snapshot cache. Entries are roughly
    /// guest-memory sized, so this holds a handful of distinct
    /// (image, machine shape) combinations.
    static let defaultWarmCacheBudgetBytes: Int64 = 20 * 1024 * 1024 * 1024

    init(
        logger: Logger,
        client: FirecrackerClient,
        imageService: SandboxImageService,
        socketDirectory: String,
        sandboxStoragePath: String,
        guestImagePath: String,
        firecrackerBinaryPath: String,
        jailer: SandboxJailerConfig,
        jailNewSandboxes: Bool,
        jailerBlockedReason: String? = nil,
        warmStartEnabled: Bool = true,
        warmCacheBudgetBytes: Int64? = nil,
        snapshotTransfer: SnapshotArtifactTransfer? = nil
    ) {
        self.logger = logger
        self.client = client
        self.imageService = imageService
        self.socketDirectory = socketDirectory
        self.sandboxStoragePath = sandboxStoragePath
        self.guestImagePath = guestImagePath
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.jailerConfig = jailer
        self.jailNewSandboxes = jailNewSandboxes
        self.jailerBlockedReason = jailerBlockedReason
        self.snapshotTransfer = snapshotTransfer
        // Unjailed warm start cannot work (see `warmStartActive`); requesting
        // it on an unjailed runtime silently degrades to cold boots.
        self.warmStartActive = warmStartEnabled && jailNewSandboxes
        self.warmCache = WarmSandboxSnapshotCache(rootPath: sandboxStoragePath + "/warm-snapshots")
        self.warmCacheBudgetBytes = warmCacheBudgetBytes ?? Self.defaultWarmCacheBudgetBytes
        let attributes = try? FileManager.default.attributesOfItem(atPath: firecrackerBinaryPath)
        let binarySize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let binaryMTime = (attributes?[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) } ?? 0
        self.firecrackerFingerprint = "\(binarySize)-\(binaryMTime)"

        if warmStartEnabled && !jailNewSandboxes {
            logger.info(
                "Sandbox warm start is unavailable on unjailed runtimes (snapshots record absolute paths); sandboxes will cold-boot"
            )
        }
        logger.info(
            "Sandbox runtime initialized",
            metadata: [
                "socketDirectory": .string(socketDirectory),
                "guestImagePath": .string(guestImagePath),
                "jailed": .stringConvertible(jailNewSandboxes),
                "warmStart": .stringConvertible(warmStartActive),
            ])
    }

    /// In-flight import downloads, keyed by snapshot id, so a fork fan-out
    /// hitting this host does not download the same multi-gigabyte memory
    /// file once per fork (actor reentrancy would otherwise allow exactly
    /// that).
    var snapshotImportsInFlight: [String: Task<Void, any Error>] = [:]

    /// Bytes the in-flight imports above are still expecting to write. The
    /// sweep reserves against this *plus* the incoming archive, because each
    /// import used to size its reservation from its own descriptors alone —
    /// leaving the budget blind to every other download racing it (issue #428
    /// review).
    var snapshotImportBytesInFlight: Int64 = 0

    /// Ceiling on simultaneous imports of *distinct* snapshots. Deduplication
    /// only collapses forks of the same snapshot; without this, a scheduler
    /// burst placing forks of many snapshots on one host opens that many
    /// parallel multi-gigabyte downloads. Excess imports are refused rather
    /// than queued — restore is reconciler-driven, so the next pass retries.
    static let maxConcurrentSnapshotImports = 2
}

#endif
