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
    private let logger: Logger
    private let client: FirecrackerClient
    private let imageService: SandboxImageService
    private let socketDirectory: String
    private let sandboxStoragePath: String
    private let guestImagePath: String
    /// The Firecracker binary the shared client spawns — the jail layout keys
    /// on its basename, so create/adopt/teardown derive identical chroots.
    private let firecrackerBinaryPath: String
    /// Jailer settings (issue #425). Always present: even when new sandboxes
    /// run unjailed (`jailNewSandboxes == false`), the *layout* is what lets
    /// jailed orphans from a previous agent life be re-adopted and torn down
    /// after the operator flips the mode — a running process keeps the
    /// barrier it was born with.
    private let jailerConfig: SandboxJailerConfig
    /// Whether newly created sandboxes get the jailer barrier
    /// (`sandbox_jailer_mode` resolution — see `SandboxJailerMode`).
    private let jailNewSandboxes: Bool
    /// Non-nil when `sandbox_jailer_mode = "required"` is unmet on this host:
    /// creating a sandbox is refused (running one unjailed is not an option),
    /// while everything an *existing* sandbox needs — adoption, status, stop,
    /// delete — keeps working, since none of it spawns a new jailer. Without
    /// this, jailed orphans would outlive their deletion unmanaged.
    private let jailerBlockedReason: String?
    /// Logged once: hosts without a usable cgroup-v2 memory controller get no
    /// jailer memory ceiling.
    private var warnedNoMemoryCeiling = false

    // MARK: Warm start (issue #426)

    /// Whether warm start is actually in effect: requested via
    /// `sandbox_warm_start` AND the runtime jails new sandboxes. Unjailed
    /// warm start is structurally impossible — the snapshot vmstate records
    /// the template's *absolute* drive/vsock paths, which are gone after
    /// template teardown; only jailed snapshots (chroot-relative paths,
    /// identical in every jail) restore into a different sandbox's layout.
    /// Every warm failure falls back to a cold boot, so this only trades
    /// boot latency, never correctness.
    private let warmStartActive: Bool
    /// The per-(image, guest, machine shape) template snapshot cache, rooted
    /// under the sandbox storage directory.
    private let warmCache: WarmSandboxSnapshotCache
    /// LRU budget for `warmCache`, swept after each template publish.
    private let warmCacheBudgetBytes: Int64
    /// Cheap identity for the Firecracker binary (size + mtime), part of the
    /// warm key: snapshots do not load across Firecracker builds, so a binary
    /// upgrade must miss the old entries rather than fail restoring them.
    private let firecrackerFingerprint: String
    /// Template builds in flight, keyed by the warm key's directory name.
    /// Also serves as the global concurrency gate: at most one template
    /// microVM (an unaccounted, guest-memory-sized guest) builds at a time.
    private var warmBuildsInFlight: Set<String> = []
    /// Failed template builds and when they may be retried. A failure damps
    /// retries for `warmBuildRetryInterval` instead of forever: permanent
    /// causes (a guest image without `warm_hold`) age out naturally when the
    /// guest image — part of the key — changes, while transient causes
    /// (disk pressure, a slow boot) deserve another attempt.
    private var warmBuildFailures: [String: Date] = [:]
    private static let warmBuildRetryInterval: TimeInterval = 15 * 60
    /// One-shot sweep of template debris left by a crash mid-build (template
    /// microVMs are deliberately not in the manifest, so ordinary orphan
    /// recovery never finds them). Runs on the first create.
    private var warmTemplateSweepDone = false

    /// Guest context ID for the single vsock device. CIDs 0–2 are reserved, so
    /// 3 is the first usable guest CID.
    private static let guestCID: UInt32 = 3

    /// Everything the runtime tracks for one managed sandbox.
    private struct Managed {
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
        /// The jail layout when this sandbox runs inside the jailer barrier
        /// (issue #425); nil for an unjailed sandbox (jailer disabled, or an
        /// orphan adopted from a pre-jailer life).
        let jail: SandboxJailPlan?
        /// The registry credential the sandbox was created with, kept so the
        /// warm-launch fallback (demote to cold) can re-materialize a
        /// private-registry image even after the rootfs cache evicted it.
        var registryCredential: RegistryCredential? = nil
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

    private var sandboxes: [String: Managed] = [:]

    /// Sandboxes with a checkpoint or restore in flight (issue #426). The
    /// snapshot sequence drains vsock connections and pauses the guest, so
    /// while a sandbox is in this set: lifecycle operations (boot, stop,
    /// exec) are refused as transient, and status mapping skips the guest
    /// vsock poll — actor reentrancy would otherwise let a concurrent status
    /// poll open a connection between the drain and the pause, which
    /// Firecracker rejects a vsock snapshot over.
    private var checkpointing: Set<String> = []

    // MARK: Exec/log state (issue #423)

    /// One live exec session: a dedicated guest connection plus the detached
    /// reader task draining its output. Keyed by the control plane's
    /// sessionId in `execSessions`; `sandboxId` lets a sandbox teardown find
    /// its sessions.
    private struct ExecSession {
        let sandboxId: String
        let connection: VsockConnection
        let events: @Sendable (SandboxExecEvent) -> Void
        var reader: Task<Void, Never>?
    }

    private var execSessions: [String: ExecSession] = [:]

    /// Per-sandbox log follow state. The entry outlives individual follow
    /// tasks (shutdown stops the task, boot starts a new one) so `lastSeq`
    /// resumes delivery where it left off and a partial line buffered in
    /// `assembler` is completed rather than split across a pause.
    private struct LogFollow {
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

    private var logFollows: [String: LogFollow] = [:]
    private var logHandler: (@Sendable (String, String, String) -> Void)?

    /// Wall-clock budget for opening an exec/log connection and for the exec
    /// spawn handshake.
    private static let execConnectTimeout: TimeInterval = 10

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
        warmCacheBudgetBytes: Int64? = nil
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

    // MARK: - SandboxRuntimeService

    func createSandbox(
        sandboxId: String,
        spec: SandboxSpec,
        registryCredential: RegistryCredential?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        // Idempotent: a replayed create for an already-defined sandbox is a
        // no-op (the Firecracker process is already configured).
        if sandboxes[sandboxId] != nil {
            return
        }

        // The jailer is required but unusable: creating this sandbox would
        // mean running an untrusted workload unjailed, which `required`
        // forbids. (Normally unreachable — the capability is dark — but a
        // stray desired entry must fail here, not fall through.)
        if let jailerBlockedReason {
            throw SandboxRuntimeError.jailerRequiredUnavailable(jailerBlockedReason)
        }

        // v1 has no in-guest networking: the guest init mounts the rootfs and
        // execs the workload without bringing up eth0 or DHCP, and the guest
        // kernel has no IP autoconfiguration. Attaching a TAP would leave the
        // workload with an unconfigured interface while the sandbox reported
        // running, so reject networked specs rather than mis-converging. (The
        // scheduler/IPAM path exists — #415/#416 — but the guest cannot yet use
        // it; enabling it is a guest-image change.)
        guard spec.network == nil, networkAttachments.isEmpty else {
            throw SandboxRuntimeError.networkingUnsupported
        }

        logger.info(
            "Creating sandbox",
            metadata: ["sandboxId": .string(sandboxId), "image": .string(spec.image)])

        // Once per agent life: clear template debris a crash mid-build left
        // behind (templates are invisible to manifest-driven orphan
        // recovery). Deliberately NOT gated on `warmStartActive`: a previous
        // life may have built templates before the operator disabled warm
        // start — often *because* of a problem — and disabling the feature
        // must not strand its leftovers.
        if !warmTemplateSweepDone {
            warmTemplateSweepDone = true
            await sweepLeakedWarmTemplates()
        }

        let guestImage = try SandboxGuestImage.resolve(atDirectory: guestImagePath)

        // Materialize the flattened container rootfs (cache-owned, read-only),
        // then copy it to a per-sandbox writable image — container semantics
        // give the workload a writable root, and the cache entry must never be
        // written. (An overlay would avoid the copy; that is future work.)
        let materialized = try await imageService.materializeRootfs(
            image: spec.image, imageDigest: spec.imageDigest, credential: registryCredential)

        // Stage the config drive the guest init reads at boot. Every config
        // drive is padded to one standard capacity so a warm restore (below)
        // can stage a different sandbox's document at the exact device size
        // the template snapshot recorded.
        let nonce = UUID().uuidString
        let configDrive = SandboxConfigDrive(
            sandboxId: sandboxId, identityNonce: nonce,
            guestConfig: materialized.guestConfig, spec: spec)
        let configData = try configDrive.blockImage(
            minimumBytes: SandboxConfigDrive.standardBlockImageBytes)

        // Warm start (issue #426): when a template snapshot for this exact
        // (image, guest, machine shape) exists, provision by restoring it —
        // the microVM comes up already booted to the held point, and
        // `bootSandbox` launches the real workload into it. Any failure here
        // falls back to the cold path; a config document too large for the
        // standard capacity is cold-only (the device size would not match
        // the template's).
        let warmEligible =
            warmStartActive && configData.count == SandboxConfigDrive.standardBlockImageBytes
        let warmKey = warmSnapshotKey(
            imageDigest: materialized.manifestDigest, guestImage: guestImage, spec: spec)
        var warmMissed = true
        if warmEligible, let warmEntry = warmCache.lookup(warmKey) {
            warmMissed = false
            do {
                // The meta sidecar carries the template identity the held
                // guest must echo at boot; an entry without one is unusable.
                guard let meta = warmCache.loadMeta(warmKey) else {
                    throw SandboxRuntimeError.warmStartFailed(
                        "cache entry has no readable meta sidecar")
                }
                let vm = try await provisionFromWarmSnapshot(
                    sandboxId: sandboxId, spec: spec, entry: warmEntry, configData: configData)
                sandboxes[sandboxId] = Managed(
                    spec: spec, rootfsPath: vm.rootfsPath, configPath: vm.configPath,
                    vsockUdsPath: vm.vsockUdsPath, identityNonce: nonce, jail: vm.jail,
                    registryCredential: registryCredential,
                    warmHeldIdentity: (meta.templateId, meta.templateNonce),
                    manager: vm.manager, lastExitCode: nil)
                logger.info(
                    "Sandbox created from warm snapshot",
                    metadata: [
                        "sandboxId": .string(sandboxId),
                        "warmKey": .string(warmKey.directoryName),
                    ])
                return
            } catch {
                // A stale or corrupt entry (e.g. the Firecracker binary
                // changed under an unchanged mtime) must not wedge creates:
                // drop it and cold-boot.
                logger.warning(
                    "Warm-start provisioning failed; invalidating the cache entry and cold-booting",
                    metadata: [
                        "sandboxId": .string(sandboxId),
                        "warmKey": .string(warmKey.directoryName),
                        "error": .string(error.localizedDescription),
                    ])
                warmCache.invalidate(warmKey)
                warmMissed = true
            }
        }

        try await coldProvisionAndRegister(
            sandboxId: sandboxId, spec: spec, credential: registryCredential,
            materialized: materialized, guestImage: guestImage, nonce: nonce, configData: configData)

        // This image had no usable warm template: build one in the background
        // so the next sandbox for the same (image, machine shape) warm-starts.
        if warmEligible, warmMissed {
            maybeStartWarmTemplateBuild(
                key: warmKey, materialized: materialized, guestImage: guestImage, spec: spec)
        }
    }

    /// Provision a cold microVM and register it as this sandbox. Shared by
    /// the ordinary cold create path and the warm-launch demotion fallback,
    /// so the two can never drift apart.
    private func coldProvisionAndRegister(
        sandboxId: String,
        spec: SandboxSpec,
        credential: RegistryCredential?,
        materialized: MaterializedRootfs,
        guestImage: SandboxGuestImage,
        nonce: String,
        configData: Data
    ) async throws {
        let vm = try await provisionColdMicroVM(
            vmId: sandboxId, spec: spec, rootfsSourcePath: materialized.rootfsPath,
            configData: configData, guestImage: guestImage)
        sandboxes[sandboxId] = Managed(
            spec: spec, rootfsPath: vm.rootfsPath, configPath: vm.configPath,
            vsockUdsPath: vm.vsockUdsPath, identityNonce: nonce, jail: vm.jail,
            registryCredential: credential, manager: vm.manager, lastExitCode: nil)
        logger.info(
            "Sandbox created",
            metadata: [
                "sandboxId": .string(sandboxId),
                "jailed": .stringConvertible(vm.jail != nil),
            ])
    }

    /// The staged artifacts and live Firecracker session `provision*` hands
    /// back for registration (or, for a warm template, direct use).
    private struct ProvisionedMicroVM {
        let rootfsPath: String
        let configPath: String
        let vsockUdsPath: String
        let jail: SandboxJailPlan?
        let manager: FirecrackerManager
    }

    /// Stage a microVM's artifacts and spawn + fully configure its
    /// Firecracker process, leaving it in `Not started`. The cold-boot
    /// staging path, shared between sandbox creation and warm-template
    /// builds; cleans up after itself on failure.
    private func provisionColdMicroVM(
        vmId: String,
        spec: SandboxSpec,
        rootfsSourcePath: String,
        configData: Data,
        guestImage: SandboxGuestImage
    ) async throws -> ProvisionedMicroVM {
        // Stage the per-VM artifacts. Jailed (issue #425), everything the
        // microVM touches lives inside its chroot and the Firecracker API is
        // given in-jail paths; unjailed, the historical flat layout is kept.
        // `rootfsPath`/`configPath`/`vsockUdsPath` are always the *host* views.
        let jailPlan: SandboxJailPlan?
        let rootfsPath: String
        let configPath: String
        let vsockUdsPath: String
        let apiPaths: (rootfs: String, config: String, kernel: String, initrd: String, vsock: String)
        var jailOptions: JailerOptions?

        if jailNewSandboxes {
            let jailer = jailerConfig
            let plan = SandboxJailPlan(
                sandboxId: vmId, config: jailer, firecrackerBinaryPath: firecrackerBinaryPath)
            jailPlan = plan
            // This id is being created fresh, so anything already under its
            // jail is a stale leftover from a crashed previous life.
            try? FileManager.default.removeItem(atPath: plan.jailDirectory)
            // `run/` holds the API socket and vsock UDS the jailed process
            // creates at runtime, so it must exist and be writable by its uid.
            try FileManager.default.createDirectory(
                atPath: plan.jailRoot + "/run", withIntermediateDirectories: true)

            rootfsPath = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            try await reflinkCopy(from: rootfsSourcePath, to: rootfsPath)
            configPath = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            try configData.write(to: URL(fileURLWithPath: configPath))
            // Kernel/initramfs are shared read-only artifacts: hard-link when
            // the chroot shares their filesystem, copy otherwise. They stay
            // root-owned (world-readable suffices, and chowning a hard link
            // would chown the installed guest image itself).
            try linkOrCopy(
                from: guestImage.kernelPath,
                to: plan.hostPath(forInJail: SandboxJailPlan.kernelPathInJail))
            try linkOrCopy(
                from: guestImage.initramfsPath,
                to: plan.hostPath(forInJail: SandboxJailPlan.initramfsPathInJail))
            // The jailed process runs as the per-sandbox uid: it writes the
            // rootfs and creates sockets under run/.
            for path in [plan.jailRoot, plan.jailRoot + "/run", rootfsPath, configPath] {
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }

            // A dedicated — and, until guest networking lands, deliberately
            // empty — network namespace: even a compromised VMM sees no host
            // interfaces. The future TAP attach flow creates the device in the
            // host namespace, plugs it into the OVS bridge, and moves it in
            // here before spawn.
            try await createNetns(plan.netnsName)

            vsockUdsPath = plan.vsockUDSHostPath
            apiPaths = (
                rootfs: SandboxJailPlan.rootfsPathInJail,
                config: SandboxJailPlan.configPathInJail,
                kernel: SandboxJailPlan.kernelPathInJail,
                initrd: SandboxJailPlan.initramfsPathInJail,
                vsock: SandboxJailPlan.vsockUDSPathInJail
            )

            jailOptions = makeJailerOptions(plan: plan, guestMemoryBytes: spec.memoryBytes)
        } else {
            jailPlan = nil
            let dir = sandboxDirectory(vmId)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            rootfsPath = dir + "/rootfs.ext4"
            // Unlink any previous incarnation's rootfs first: `cp --force`
            // would truncate the existing inode in place, letting a stale
            // process that still holds it open scribble on the new copy.
            if FileManager.default.fileExists(atPath: rootfsPath) {
                try FileManager.default.removeItem(atPath: rootfsPath)
            }
            try await reflinkCopy(from: rootfsSourcePath, to: rootfsPath)
            configPath = dir + "/config.img"
            try configData.write(to: URL(fileURLWithPath: configPath))
            vsockUdsPath = vsockUDSPath(vmId)
            apiPaths = (
                rootfs: rootfsPath, config: configPath,
                kernel: guestImage.kernelPath, initrd: guestImage.initramfsPath,
                vsock: vsockUdsPath
            )
        }

        // Spawn and fully configure the Firecracker microVM, leaving it in
        // `Not started` (== stopped). Roll the process back on any configuration
        // failure so a retry starts from a clean slate rather than
        // `vmAlreadyRunning`.
        let manager: FirecrackerManager
        do {
            manager = try await client.createVM(vmId: vmId, jail: jailOptions)
        } catch {
            if let plan = jailPlan {
                await removeJailArtifacts(plan)
            }
            throw error
        }
        do {
            try await manager.configureMachine(
                MachineConfig(
                    vcpuCount: spec.cpus,
                    memSizeMib: Int(spec.memoryBytes / (1024 * 1024))))

            let bootSource = SwiftFirecracker.BootSource(
                kernelImagePath: apiPaths.kernel,
                initrdPath: apiPaths.initrd,
                bootArgs: guestImage.bootArgs + " strato.config=/dev/vdb")
            try await manager.configureBootSource(bootSource)

            // Drive order fixes device naming: rootfs first ⇒ /dev/vda (what the
            // config drive names), config second ⇒ /dev/vdb (what the guest
            // reads by default).
            try await manager.configureDrive(
                Drive.rootDrive(id: "rootfs", path: apiPaths.rootfs, readOnly: false))
            try await manager.configureDrive(
                Drive.dataDrive(id: "config", path: apiPaths.config, readOnly: true))

            // No network interface: networked specs are rejected above until the
            // guest image can configure one.

            try await manager.configureVsock(
                VsockConfig(guestCid: Self.guestCID, udsPath: apiPaths.vsock))
        } catch {
            try? await client.destroyVM(vmId: vmId)
            if let plan = jailPlan {
                await removeJailArtifacts(plan)
            }
            throw error
        }

        return ProvisionedMicroVM(
            rootfsPath: rootfsPath, configPath: configPath, vsockUdsPath: vsockUdsPath,
            jail: jailPlan, manager: manager)
    }

    /// Provision a new sandbox by restoring the warm template snapshot (issue
    /// #426): stage the jail with clones of the template's rootfs +
    /// memory/vmstate and this sandbox's *own* config drive, then spawn +
    /// load without resuming — the microVM lands in `Paused`, which
    /// `bootSandbox` resumes and launches. Jailed-only by construction (see
    /// `warmStartActive`): the snapshot's chroot-relative paths are what let
    /// it load under a different sandbox's jail at all. Cleans up after
    /// itself on failure so the caller can fall back to a cold provision.
    private func provisionFromWarmSnapshot(
        sandboxId: String,
        spec: SandboxSpec,
        entry: WarmSnapshotEntry,
        configData: Data
    ) async throws -> ProvisionedMicroVM {
        guard jailNewSandboxes else {
            throw SandboxRuntimeError.warmStartFailed(
                "warm restore requires the jailer (snapshots record chroot-relative paths)")
        }
        let plan = SandboxJailPlan(
            sandboxId: sandboxId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
        do {
            try? FileManager.default.removeItem(atPath: plan.jailDirectory)
            try FileManager.default.createDirectory(
                atPath: plan.jailRoot + "/run", withIntermediateDirectories: true)
            // Kernel/initramfs are deliberately absent: a snapshot load
            // restores guest memory directly and never reads the boot
            // source (the restore-in-place path established this layout).
            let rootfsHost = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            try await reflinkCopy(from: entry.rootfsPath, to: rootfsHost)
            let configHost = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            try configData.write(to: URL(fileURLWithPath: configHost))
            let snapshotDirHost = plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail)
            try FileManager.default.createDirectory(
                atPath: snapshotDirHost, withIntermediateDirectories: true)
            // Copied (reflink where the filesystem supports it), not
            // hard-linked: the chown below would chown a link's shared inode
            // — the cache entry itself — and hard-linking would also bet on
            // Firecracker never opening the memory backend for write.
            // Sparse-aware copies keep the cost proportional to the
            // template's touched pages; revisit as an optimization once
            // load semantics are pinned down on a KVM host.
            try await reflinkCopy(
                from: entry.memoryPath,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail))
            try await reflinkCopy(
                from: entry.vmstatePath,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail))
            for path in [
                plan.jailRoot, plan.jailRoot + "/run", rootfsHost, configHost, snapshotDirHost,
                plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail),
                plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail),
            ] {
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }
            try await createNetns(plan.netnsName)

            let manager = try await client.restoreVM(
                vmId: sandboxId, jail: makeJailerOptions(plan: plan, guestMemoryBytes: spec.memoryBytes),
                snapshot: SnapshotLoadConfig(
                    snapshotPath: SandboxJailPlan.snapshotVmstatePathInJail,
                    memFilePath: SandboxJailPlan.snapshotMemoryPathInJail,
                    resumeVM: false))
            return ProvisionedMicroVM(
                rootfsPath: rootfsHost, configPath: configHost,
                vsockUdsPath: plan.vsockUDSHostPath, jail: plan, manager: manager)
        } catch {
            try? await client.destroyVM(vmId: sandboxId)
            await removeJailArtifacts(plan)
            throw error
        }
    }

    /// The jailer options for one microVM's jail plan — shared by cold
    /// provisioning, warm restores, and checkpoint restores so isolation
    /// settings can never drift between the three spawn paths.
    private func makeJailerOptions(plan: SandboxJailPlan, guestMemoryBytes: Int64) -> JailerOptions {
        let cgroups = jailerCgroups(guestMemoryBytes: guestMemoryBytes)
        return JailerOptions(
            jailerBinaryPath: jailerConfig.jailerBinaryPath,
            chrootBaseDir: jailerConfig.chrootBaseDir,
            uid: plan.uid,
            gid: plan.gid,
            netnsPath: plan.netnsPath,
            cgroupVersion: cgroups.version,
            cgroups: cgroups.entries)
    }

    func bootSandbox(sandboxId: String) async throws {
        try await bootSandbox(sandboxId: sandboxId, allowWarmLaunch: true)
    }

    /// `allowWarmLaunch: false` is the post-demotion retry: the freshly
    /// cold-provisioned guest must answer with its own identity, and a
    /// mismatch is terminal rather than another warm-launch attempt — a
    /// structural bound on the demote/boot recursion.
    private func bootSandbox(sandboxId: String, allowWarmLaunch: Bool) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        let bootStarted = Date()

        let info = try await managed.manager.getInstanceInfo()
        switch info.state {
        case .running:
            break  // already running — idempotent
        case .notStarted:
            logger.info("Booting sandbox", metadata: ["sandboxId": .string(sandboxId)])
            try await managed.manager.start()
        case .paused:
            logger.info("Resuming sandbox", metadata: ["sandboxId": .string(sandboxId)])
            try await managed.manager.resume()
        }

        // Wait for the guest control agent to answer, so "booted" means the
        // guest is actually up. A miss here is transient — the reconciler
        // re-drives boot on the next sync.
        let response = try await sendControl(.ping, udsPath: managed.vsockUdsPath, timeout: 20)
        guard case .pong(let echoedId, let echoedNonce) = response else {
            throw SandboxControlError.malformedResponse("expected pong, got \(response)")
        }

        var bootPath = "cold"
        if !identityMatches(response, sandboxId: sandboxId, expectedNonce: managed.identityNonce) {
            // Not this sandbox's identity. One legitimate way that happens: a
            // warm-provisioned guest still holding the *template's* identity,
            // waiting for its launch (issue #426). Anything else is the
            // classic stale-generation problem and must fail the boot.
            let mismatch = SandboxControlError.identityMismatch(
                expected: "\(sandboxId)/\(managed.identityNonce)", got: "\(echoedId)/\(echoedNonce)")
            guard allowWarmLaunch else { throw mismatch }
            let status = try? await sendControl(.getStatus, udsPath: managed.vsockUdsPath, timeout: 10)
            guard let status, case .status(let heldId, let heldNonce, .held, _) = status else {
                throw mismatch
            }
            // Bind the held responder to the template this sandbox was
            // provisioned from, so a workload can never be launched into
            // some other process answering on the deterministic UDS. For an
            // adopted sandbox the binding did not survive the restart; the
            // template id shape is the remaining gate.
            if let expected = managed.warmHeldIdentity {
                guard heldId == expected.templateId, heldNonce == expected.templateNonce else {
                    throw SandboxControlError.identityMismatch(
                        expected: "\(expected.templateId)/\(expected.templateNonce)",
                        got: "\(heldId)/\(heldNonce)")
                }
            } else {
                guard heldId.hasPrefix("warm-template-") else { throw mismatch }
            }
            do {
                try await launchWarmHeldGuest(sandboxId: sandboxId, managed: managed)
                sandboxes[sandboxId]?.warmHeldIdentity = nil
                bootPath = "warm"
            } catch {
                // A warm launch that fails must not wedge convergence on this
                // sandbox: demote it to a freshly provisioned cold microVM
                // and boot that once, warm launch disallowed.
                logger.warning(
                    "Warm launch failed; demoting the sandbox to a cold boot",
                    metadata: [
                        "sandboxId": .string(sandboxId),
                        "error": .string(error.localizedDescription),
                    ])
                try await demoteWarmSandboxToCold(sandboxId)
                try await bootSandbox(sandboxId: sandboxId, allowWarmLaunch: false)
                return
            }
        }
        logger.info(
            "Sandbox guest agent healthy",
            metadata: [
                "sandboxId": .string(sandboxId),
                "bootPath": .string(bootPath),
                "bootMillis": .stringConvertible(Int(Date().timeIntervalSince(bootStarted) * 1000)),
            ])

        // The guest is confirmed up: ship its workload output from here on
        // (resuming from the last seq this host saw, so a pause/resume cycle
        // doesn't drop or duplicate lines).
        startLogFollow(sandboxId: sandboxId)
    }

    /// Launch the real workload into a warm-held guest (issue #426): resync
    /// the wall clock (frozen at template-snapshot time), deliver the
    /// sandbox's identity + process + fresh entropy via `launch`, and verify
    /// the guest now answers as this sandbox. The launch payload is
    /// reconstructed from the staged config drive, so the flow survives agent
    /// restarts between create and boot with no extra persisted state.
    private func launchWarmHeldGuest(sandboxId: String, managed: Managed) async throws {
        guard let data = FileManager.default.contents(atPath: managed.configPath),
            let drive = try? SandboxConfigDrive.decode(fromBlockImage: data),
            drive.sandboxId == sandboxId
        else {
            throw SandboxRuntimeError.warmStartFailed(
                "staged config drive at \(managed.configPath) is unreadable; cannot reconstruct the launch payload"
            )
        }

        // Clock first, launch second: the workload should start with a sane
        // wall clock. Best-effort, mirroring the restore-in-place flow.
        await resyncGuestClock(sandboxId: sandboxId, udsPath: managed.vsockUdsPath)

        // Fresh randomness so N sandboxes launched from one template do not
        // share the snapshot's frozen RNG pool (best-effort until #427's
        // proper reseed).
        var generator = SystemRandomNumberGenerator()
        var entropy = Data(capacity: 32)
        for _ in 0..<4 {
            withUnsafeBytes(of: generator.next()) { entropy.append(contentsOf: $0) }
        }
        let launch = SandboxControlProtocol.LaunchRequest(
            sandboxId: sandboxId, identityNonce: drive.identityNonce,
            imageConfig: drive.imageConfig, overrides: drive.overrides, entropy: entropy)
        let response = try await sendControl(
            .launch(launch), udsPath: managed.vsockUdsPath, timeout: 20)
        guard case .launched = response else {
            throw SandboxControlError.malformedResponse("expected launched, got \(response)")
        }

        let verify = try await sendControl(.ping, udsPath: managed.vsockUdsPath, timeout: 10)
        guard identityMatches(verify, sandboxId: sandboxId, expectedNonce: drive.identityNonce) else {
            throw SandboxControlError.identityMismatch(
                expected: "\(sandboxId)/\(drive.identityNonce)", got: "\(verify)")
        }
    }

    /// Replace a warm-provisioned sandbox whose launch failed with a freshly
    /// cold-provisioned one under the same id and spec.
    ///
    /// The `checkpointing` guard makes the multi-await teardown/rebuild
    /// atomic with respect to the rest of the actor's surface — without it,
    /// a delete interleaving the awaits would complete against the removed
    /// entry and the demotion would then resurrect a deleted sandbox. All
    /// fallible acquisition (guest image, rootfs re-materialization — with
    /// the create-time credential, since the rootfs cache may have evicted a
    /// private image by now) happens *before* the old microVM is destroyed,
    /// so a failure leaves the held guest intact for the next boot retry.
    private func demoteWarmSandboxToCold(_ sandboxId: String) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        checkpointing.insert(sandboxId)
        defer { checkpointing.remove(sandboxId) }

        let guestImage = try SandboxGuestImage.resolve(atDirectory: guestImagePath)
        let materialized = try await imageService.materializeRootfs(
            image: managed.spec.image, imageDigest: managed.spec.imageDigest,
            credential: managed.registryCredential)
        let nonce = UUID().uuidString
        let configDrive = SandboxConfigDrive(
            sandboxId: sandboxId, identityNonce: nonce,
            guestConfig: materialized.guestConfig, spec: managed.spec)
        let configData = try configDrive.blockImage(
            minimumBytes: SandboxConfigDrive.standardBlockImageBytes)

        try? await client.destroyVM(vmId: sandboxId)
        if let plan = managed.jail {
            await removeJailArtifacts(plan)
        }
        removeArtifacts(sandboxId)
        sandboxes.removeValue(forKey: sandboxId)

        try await coldProvisionAndRegister(
            sandboxId: sandboxId, spec: managed.spec, credential: managed.registryCredential,
            materialized: materialized, guestImage: guestImage, nonce: nonce, configData: configData)
    }

    /// Best-effort wall-clock resync after a snapshot restore or warm
    /// launch: the guest's CLOCK_REALTIME froze at snapshot time. Guests
    /// that predate `sync_clock` answer `error`, which is logged and
    /// tolerated. Shared by restore-in-place and the warm-launch path.
    private func resyncGuestClock(sandboxId: String, udsPath: String) async {
        let unixNanos = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        do {
            _ = try await sendControl(.syncClock(unixNanos: unixNanos), udsPath: udsPath, timeout: 5)
        } catch {
            logger.warning(
                "Guest did not accept clock resync (older guest image?)",
                metadata: [
                    "sandboxId": .string(sandboxId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    func shutdownSandbox(sandboxId: String) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        // A paused guest can't serve exec sessions or the log follow stream:
        // end the former (terminal for their control-plane sessions) and stop
        // the latter. The log follow keeps its seq/partial-line state so a
        // later boot resumes cleanly.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox stopped")
        await stopLogFollow(sandboxId: sandboxId, retire: false)

        // Firecracker cannot stop-and-keep-state, so a "stopped" sandbox is a
        // paused microVM. Only a running one needs pausing; a not-started or
        // already-paused sandbox is idempotently satisfied.
        let info = try await managed.manager.getInstanceInfo()
        if info.state == .running {
            logger.info("Stopping sandbox", metadata: ["sandboxId": .string(sandboxId)])
            try await managed.manager.pause()
        }
    }

    func deleteSandbox(sandboxId: String) async throws {
        // A delete interleaving with a checkpoint/restore (actor reentrancy
        // across their awaits) could tear the sandbox down mid-sequence and
        // leave the restore's freshly spawned process untracked. Refuse as
        // transient; the reconciler re-drives the delete once the
        // checkpoint/restore finishes.
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        logger.info("Deleting sandbox", metadata: ["sandboxId": .string(sandboxId)])
        // End interactive/log streams first: the guest is about to disappear,
        // and their control-plane sessions must learn why. Deleting is the
        // true end-of-stream for the workload's logs, so flush any partial
        // line the assembler is holding.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox deleted")
        await stopLogFollow(sandboxId: sandboxId, retire: true)
        // Tear the Firecracker process down (idempotent — a sandbox whose
        // process the client no longer tracks throws, which we ignore), then
        // remove the per-sandbox artifacts. The client removes a jailed
        // sandbox's chroot subtree itself, but a delete can also arrive for a
        // sandbox this runtime never tracked (crash leftovers): sweep the
        // derived jail layout best-effort so netns and chroot never leak.
        try? await client.destroyVM(vmId: sandboxId)
        removeArtifacts(sandboxId)
        let plan =
            sandboxes[sandboxId]?.jail
            ?? SandboxJailPlan(
                sandboxId: sandboxId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
        await removeJailArtifacts(plan)
        sandboxes.removeValue(forKey: sandboxId)
    }

    func adoptSandbox(sandboxId: String, spec: SandboxSpec) async throws -> SandboxStatus {
        if sandboxes[sandboxId] != nil {
            // A replayed sync can race adoption; if already managed, adoption is
            // satisfied — just report the current status.
            return try await getSandboxStatus(sandboxId: sandboxId)
        }

        // A jailed orphan's socket lives inside its chroot, an unjailed one's
        // in the flat socket directory — and both files can exist at once (a
        // stale chroot left by a crashed jailed life beside a live unjailed
        // recreation, or vice versa). A running process keeps whatever barrier
        // it was born with, so every layout whose socket exists is *attempted*,
        // jail first; only a candidate whose socket is dead falls through to
        // the next, and existence alone never rules the live one out.
        var candidates: [(jailPlan: SandboxJailPlan?, jailOptions: JailerOptions?, socketPath: String)] = []
        let jailedSocketPath = JailerOptions.socketPath(
            chrootBaseDir: jailerConfig.chrootBaseDir,
            firecrackerBinaryPath: firecrackerBinaryPath,
            vmId: sandboxId)
        if FileManager.default.fileExists(atPath: jailedSocketPath) {
            let plan = SandboxJailPlan(
                sandboxId: sandboxId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
            candidates.append(
                (
                    plan,
                    JailerOptions(
                        jailerBinaryPath: jailerConfig.jailerBinaryPath,
                        chrootBaseDir: jailerConfig.chrootBaseDir,
                        uid: plan.uid, gid: plan.gid),
                    jailedSocketPath
                ))
        }
        let flatSocketPath = FirecrackerClient.socketPath(socketDirectory: socketDirectory, vmId: sandboxId)
        if FileManager.default.fileExists(atPath: flatSocketPath) {
            candidates.append((nil, nil, flatSocketPath))
        }
        guard !candidates.isEmpty else {
            throw SandboxRuntimeError.adoptionTargetGone(
                "sandbox \(sandboxId) has no Firecracker API socket at \(flatSocketPath) nor inside its jail")
        }

        var adoption: (manager: FirecrackerManager, info: InstanceInfo, jailPlan: SandboxJailPlan?)?
        var lastError: Error?
        for candidate in candidates {
            logger.info(
                "Re-adopting orphaned sandbox",
                metadata: [
                    "sandboxId": .string(sandboxId),
                    "socket": .string(candidate.socketPath),
                    "jailed": .stringConvertible(candidate.jailPlan != nil),
                ])
            do {
                let (manager, info) = try await client.adoptVM(vmId: sandboxId, jail: candidate.jailOptions)
                adoption = (manager, info, candidate.jailPlan)
                break
            } catch {
                // A live Firecracker always answers its API socket, so a failed
                // connect means this candidate's process is gone and its socket
                // merely outlived it — try the next layout.
                lastError = error
            }
        }
        guard let (manager, info, jailPlan) = adoption else {
            // Every candidate socket is dead. The Agent re-creates from the
            // desired entry in that case.
            throw SandboxRuntimeError.adoptionTargetGone(
                "sandbox \(sandboxId) has no live Firecracker API socket: \(lastError?.localizedDescription ?? "unknown error")"
            )
        }

        let rootfsPath: String
        let configPath: String
        let vsockUdsPath: String
        if let plan = jailPlan {
            rootfsPath = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            configPath = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            vsockUdsPath = plan.vsockUDSHostPath
        } else {
            let dir = sandboxDirectory(sandboxId)
            rootfsPath = dir + "/rootfs.ext4"
            configPath = dir + "/config.img"
            vsockUdsPath = vsockUDSPath(sandboxId)
        }
        // Recover the boot nonce from the staged config drive so post-adoption
        // identity checks can still distinguish this generation.
        let identityNonce = recoverIdentityNonce(configPath: configPath)
        sandboxes[sandboxId] = Managed(
            spec: spec, rootfsPath: rootfsPath, configPath: configPath,
            vsockUdsPath: vsockUdsPath, identityNonce: identityNonce, jail: jailPlan,
            manager: manager, lastExitCode: nil)

        let status = await mappedStatus(
            instance: info.state, udsPath: vsockUdsPath, sandboxId: sandboxId)
        if info.state == .running {
            // Same contract as boot: while the microVM runs, the guest serves
            // vsock and its retained ring buffer must ship — even when the
            // workload itself is still starting or has already exited (its
            // final output is still buffered guest-side). Seq state from a
            // previous incarnation is gone, so this resumes from the oldest
            // retained ring-buffer record.
            startLogFollow(sandboxId: sandboxId)
        }
        logger.info(
            "Sandbox re-adopted",
            metadata: ["sandboxId": .string(sandboxId), "status": .string(status.rawValue)])
        return status
    }

    func getSandboxStatus(sandboxId: String) async throws -> SandboxStatus {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        let info: InstanceInfo
        do {
            info = try await managed.manager.getInstanceInfo()
        } catch {
            return .unknown
        }
        return await mappedStatus(instance: info.state, udsPath: managed.vsockUdsPath, sandboxId: sandboxId)
    }

    func exitCode(sandboxId: String) async -> Int? {
        sandboxes[sandboxId]?.lastExitCode
    }

    // MARK: - Snapshots / checkpoint-resume (issue #426)

    /// Archive filenames inside a snapshot directory. `configImage` rides
    /// along (it is tiny) so a jailed restore can re-stage the chroot without
    /// depending on the live sandbox's staging surviving.
    private enum SnapshotFile {
        static let memory = "memory.snap"
        static let vmstate = "vmstate.snap"
        static let rootfs = "rootfs.ext4"
        static let configImage = "config.img"
    }

    /// Host-owned archive directory for one snapshot. Lives under the
    /// sandbox's storage directory, so snapshot artifacts are removed with
    /// the sandbox (same-agent restore only in v1 — the volume-snapshot
    /// precedent).
    private func snapshotDirectory(_ sandboxId: String, snapshotId: String) -> String {
        sandboxDirectory(sandboxId) + "/snapshots/" + snapshotId
    }

    func snapshotSandbox(
        sandboxId: String, snapshotId: String, mode: SandboxSnapshotMode
    ) async throws -> SandboxSnapshotResult {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        checkpointing.insert(sandboxId)
        defer { checkpointing.remove(sandboxId) }

        let info = try await managed.manager.getInstanceInfo()
        guard info.state != .notStarted else {
            throw SandboxRuntimeError.notSnapshottable("the sandbox has never been booted")
        }
        // A warm-provisioned sandbox that has not launched yet is the same
        // lifecycle position as never-booted, even though its microVM sits
        // paused: the guest memory still carries the *template's* identity,
        // so a checkpoint taken now could never pass restore's identity
        // check. (The instance-state guard above cannot see this — a
        // pre-launch warm sandbox is `Paused`, exactly like a stopped one.)
        guard managed.warmHeldIdentity == nil else {
            throw SandboxRuntimeError.notSnapshottable(
                "the sandbox has never been booted (warm-provisioned, awaiting launch)")
        }

        logger.info(
            "Checkpointing sandbox",
            metadata: [
                "sandboxId": .string(sandboxId),
                "snapshotId": .string(snapshotId),
                "mode": .string(mode.rawValue),
            ])

        // Stage the archive directory before touching the guest, so a
        // filesystem failure here cannot leave the sandbox paused.
        let archiveDir = snapshotDirectory(sandboxId, snapshotId: snapshotId)
        // A leftover from a failed earlier attempt must not pollute this one.
        try? FileManager.default.removeItem(atPath: archiveDir)
        try FileManager.default.createDirectory(atPath: archiveDir, withIntermediateDirectories: true)

        // Drain host-side vsock connections first: Firecracker refuses to
        // snapshot a vsock device with live connections, and a paused guest
        // could not serve them anyway. Exec sessions end terminally; the log
        // follow keeps its seq state for the resume.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox checkpoint")
        await stopLogFollow(sandboxId: sandboxId, retire: false)

        let wasRunning = info.state == .running
        if wasRunning {
            do {
                try await managed.manager.pause()
            } catch {
                // The guest is still running; put the drained log follow
                // back before surfacing the failure.
                startLogFollow(sandboxId: sandboxId)
                throw error
            }
        }

        let archiveMemory = archiveDir + "/" + SnapshotFile.memory
        let archiveVmstate = archiveDir + "/" + SnapshotFile.vmstate
        let archiveRootfs = archiveDir + "/" + SnapshotFile.rootfs
        let archiveConfig = archiveDir + "/" + SnapshotFile.configImage

        do {
            try await captureSnapshot(
                manager: managed.manager, jail: managed.jail,
                memoryTarget: archiveMemory, vmstateTarget: archiveVmstate)

            // Copy the rootfs (and the tiny config drive, which a jailed
            // restore re-stages the chroot from) while the guest is still
            // paused, so disk and memory are one consistent point in time.
            // `cp --reflink=auto` makes this a free clone on filesystems that
            // support it and a full copy otherwise.
            try await reflinkCopy(from: managed.rootfsPath, to: archiveRootfs)
            try await reflinkCopy(from: managed.configPath, to: archiveConfig)
        } catch {
            // Failed checkpoint: drop partial artifacts and put the guest
            // back the way it was found.
            try? FileManager.default.removeItem(atPath: archiveDir)
            if wasRunning {
                try? await managed.manager.resume()
                startLogFollow(sandboxId: sandboxId)
            }
            throw error
        }

        if mode == .resume, wasRunning {
            try await managed.manager.resume()
            startLogFollow(sandboxId: sandboxId)
        }
        // `mode == .stop` leaves the microVM paused — exactly the state a
        // control-plane stop produces, so the sandbox converges to `stopped`
        // and can later resume from this checkpoint via restore.

        let result = SandboxSnapshotResult(
            memorySizeBytes: fileSize(archiveMemory),
            vmstateSizeBytes: fileSize(archiveVmstate),
            rootfsSizeBytes: fileSize(archiveRootfs),
            storagePath: archiveDir,
            firecrackerVersion: info.vmlinuxVersion)
        logger.info(
            "Sandbox checkpoint complete",
            metadata: [
                "sandboxId": .string(sandboxId),
                "snapshotId": .string(snapshotId),
                "totalBytes": .stringConvertible(result.totalSizeBytes),
            ])
        return result
    }

    func restoreSandbox(sandboxId: String, snapshotId: String) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        checkpointing.insert(sandboxId)
        defer { checkpointing.remove(sandboxId) }

        let archiveDir = snapshotDirectory(sandboxId, snapshotId: snapshotId)
        let archiveMemory = archiveDir + "/" + SnapshotFile.memory
        let archiveVmstate = archiveDir + "/" + SnapshotFile.vmstate
        let archiveRootfs = archiveDir + "/" + SnapshotFile.rootfs
        let archiveConfig = archiveDir + "/" + SnapshotFile.configImage
        // The config image is required too: the jailed re-staging below reads
        // it unconditionally, and a gap must surface before the live VM is
        // destroyed, not after.
        for required in [archiveMemory, archiveVmstate, archiveRootfs, archiveConfig] {
            guard FileManager.default.fileExists(atPath: required) else {
                throw SandboxRuntimeError.snapshotNotFound(sandboxId: sandboxId, snapshotId: snapshotId)
            }
        }

        logger.info(
            "Restoring sandbox from snapshot",
            metadata: ["sandboxId": .string(sandboxId), "snapshotId": .string(snapshotId)])

        // The current guest is about to be replaced wholesale.
        await closeExecSessions(sandboxId: sandboxId, reason: "sandbox restore")
        await stopLogFollow(sandboxId: sandboxId, retire: false)

        // Tear down the current Firecracker process. For a jailed sandbox
        // this removes the whole chroot subtree, which the staging below
        // rebuilds from the archive.
        try? await client.destroyVM(vmId: sandboxId)

        let newManager: FirecrackerManager
        if let plan = managed.jail {
            // Re-stage the jail exactly as at snapshot time. The kernel and
            // initramfs are deliberately absent: a snapshot load restores
            // guest memory directly and never reads the boot source.
            try FileManager.default.createDirectory(
                atPath: plan.jailRoot + "/run", withIntermediateDirectories: true)
            let rootfsHost = plan.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
            try await reflinkCopy(from: archiveRootfs, to: rootfsHost)
            let configHost = plan.hostPath(forInJail: SandboxJailPlan.configPathInJail)
            try await reflinkCopy(from: archiveConfig, to: configHost)
            let snapshotDirHost = plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail)
            try FileManager.default.createDirectory(
                atPath: snapshotDirHost, withIntermediateDirectories: true)
            try await reflinkCopy(
                from: archiveMemory,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail))
            try await reflinkCopy(
                from: archiveVmstate,
                to: plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail))
            for path in [
                plan.jailRoot, plan.jailRoot + "/run", rootfsHost, configHost, snapshotDirHost,
                plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail),
                plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail),
            ] {
                try chownPath(path, uid: plan.uid, gid: plan.gid)
            }
            // The namespace usually survives the old process; recreate for a
            // crash-swept host (reused when it exists).
            try await createNetns(plan.netnsName)

            newManager = try await client.restoreVM(
                vmId: sandboxId,
                jail: makeJailerOptions(plan: plan, guestMemoryBytes: managed.spec.memoryBytes),
                snapshot: SnapshotLoadConfig(
                    snapshotPath: SandboxJailPlan.snapshotVmstatePathInJail,
                    memFilePath: SandboxJailPlan.snapshotMemoryPathInJail,
                    resumeVM: true))
        } else {
            // Unjailed: replace the live rootfs with the checkpointed copy
            // and load memory/vmstate straight from the archive (Firecracker
            // only reads the memory file for a file-backed load).
            try? FileManager.default.removeItem(atPath: managed.rootfsPath)
            try await reflinkCopy(from: archiveRootfs, to: managed.rootfsPath)
            if !FileManager.default.fileExists(atPath: managed.configPath) {
                try await reflinkCopy(from: archiveConfig, to: managed.configPath)
            }
            // The restored vsock device re-binds the deterministic UDS; a
            // stale file from the old process would make that bind fail.
            try? FileManager.default.removeItem(atPath: managed.vsockUdsPath)
            newManager = try await client.restoreVM(
                vmId: sandboxId, jail: nil,
                snapshot: SnapshotLoadConfig(
                    snapshotPath: archiveVmstate,
                    memFilePath: archiveMemory,
                    resumeVM: true))
        }

        sandboxes[sandboxId]?.manager = newManager
        // Whatever exit the pre-restore guest reported no longer describes
        // this guest; the restored one re-reports over vsock.
        sandboxes[sandboxId]?.lastExitCode = nil

        // Health check: the restored guest must answer with this sandbox's
        // identity (the checkpointed memory carries the original nonce).
        let response = try await sendControl(.ping, udsPath: managed.vsockUdsPath, timeout: 20)
        guard identityMatches(response, sandboxId: sandboxId, expectedNonce: managed.identityNonce) else {
            throw SandboxControlError.identityMismatch(
                expected: "\(sandboxId)/\(managed.identityNonce)", got: "\(response)")
        }

        // Best-effort clock resync: the restored guest's wall clock froze at
        // checkpoint time.
        await resyncGuestClock(sandboxId: sandboxId, udsPath: managed.vsockUdsPath)

        startLogFollow(sandboxId: sandboxId)
        logger.info(
            "Sandbox restored from snapshot",
            metadata: ["sandboxId": .string(sandboxId), "snapshotId": .string(snapshotId)])
    }

    func deleteSandboxSnapshot(sandboxId: String, snapshotId: String) async throws {
        // Independent of the microVM's state, and deliberately no managed
        // guard: cleanup must work for snapshots whose sandbox this runtime
        // never tracked (crash leftovers). Idempotent — a missing directory
        // confirms cleanly — but a real removal failure (permissions, I/O)
        // must surface: the control plane releases the storage charge on
        // this response, and a silent failure would strand real bytes
        // unaccounted.
        let directory = snapshotDirectory(sandboxId, snapshotId: snapshotId)
        if FileManager.default.fileExists(atPath: directory) {
            do {
                try FileManager.default.removeItem(atPath: directory)
            } catch {
                throw SandboxRuntimeError.snapshotIOFailed(
                    "removing snapshot artifacts at \(directory) failed: \(error.localizedDescription)")
            }
        }
        logger.info(
            "Sandbox snapshot deleted",
            metadata: ["sandboxId": .string(sandboxId), "snapshotId": .string(snapshotId)])
    }

    /// Write a paused microVM's memory + vmstate to the given host paths.
    /// Jailed, Firecracker can only write inside its chroot, so the files are
    /// staged in the in-jail snapshot directory and moved out; unjailed they
    /// are written directly. Shared between sandbox checkpoints and warm
    /// template builds (issue #426).
    private func captureSnapshot(
        manager: FirecrackerManager, jail: SandboxJailPlan?,
        memoryTarget: String, vmstateTarget: String
    ) async throws {
        if let plan = jail {
            let stagingHost = plan.hostPath(forInJail: SandboxJailPlan.snapshotDirInJail)
            try? FileManager.default.removeItem(atPath: stagingHost)
            try FileManager.default.createDirectory(
                atPath: stagingHost, withIntermediateDirectories: true)
            try chownPath(stagingHost, uid: plan.uid, gid: plan.gid)
            try await manager.createSnapshot(
                SnapshotCreateConfig(
                    snapshotPath: SandboxJailPlan.snapshotVmstatePathInJail,
                    memFilePath: SandboxJailPlan.snapshotMemoryPathInJail,
                    snapshotType: .full))
            try moveReplacingItem(
                from: plan.hostPath(forInJail: SandboxJailPlan.snapshotMemoryPathInJail),
                to: memoryTarget)
            try moveReplacingItem(
                from: plan.hostPath(forInJail: SandboxJailPlan.snapshotVmstatePathInJail),
                to: vmstateTarget)
            try? FileManager.default.removeItem(atPath: stagingHost)
        } else {
            try await manager.createSnapshot(
                SnapshotCreateConfig(
                    snapshotPath: vmstateTarget,
                    memFilePath: memoryTarget,
                    snapshotType: .full))
        }
    }

    // MARK: - Warm start (issue #426)

    /// The warm-snapshot cache key for one (image, guest, machine shape)
    /// combination on this host. Templates are always built with
    /// standard-capacity config drives, and only standard-capacity sandboxes
    /// are warm-eligible, so the capacity component is the constant.
    private func warmSnapshotKey(
        imageDigest: String, guestImage: SandboxGuestImage, spec: SandboxSpec
    ) -> WarmSnapshotKey {
        WarmSnapshotKey(
            imageDigest: imageDigest,
            guestVersion: guestImage.version,
            arch: guestImage.arch,
            firecrackerFingerprint: firecrackerFingerprint,
            vcpus: spec.cpus,
            memoryMiB: spec.memoryBytes / (1024 * 1024),
            configCapacityBytes: SandboxConfigDrive.standardBlockImageBytes,
            jailed: jailNewSandboxes)
    }

    /// Kick off a background warm-template build for `key`. Skipped — not
    /// failed — when any build is already running (one at a time host-wide:
    /// each build boots an unaccounted, guest-memory-sized microVM) or when
    /// this key failed within the retry interval; a later create re-triggers.
    private func maybeStartWarmTemplateBuild(
        key: WarmSnapshotKey, materialized: MaterializedRootfs, guestImage: SandboxGuestImage,
        spec: SandboxSpec
    ) {
        guard warmStartActive, warmBuildsInFlight.isEmpty else { return }
        let token = key.directoryName
        if let failedAt = warmBuildFailures[token],
            Date().timeIntervalSince(failedAt) < Self.warmBuildRetryInterval
        {
            return
        }
        warmBuildsInFlight.insert(token)
        Task {
            await self.buildWarmTemplate(
                key: key, materialized: materialized, guestImage: guestImage, spec: spec)
        }
    }

    /// Boot a throwaway template microVM to the guest's held point, snapshot
    /// it, and publish the artifacts into the warm cache. The template rides
    /// the exact cold-provision path a real sandbox would, with `warm_hold`
    /// set in its config drive so the guest parks instead of launching a
    /// workload. Failures are logged and remembered, never surfaced — warm
    /// start is an optimization, and sandboxes keep cold-booting without it.
    private func buildWarmTemplate(
        key: WarmSnapshotKey, materialized: MaterializedRootfs, guestImage: SandboxGuestImage,
        spec: SandboxSpec
    ) async {
        defer { warmBuildsInFlight.remove(key.directoryName) }
        let templateId = "warm-template-" + UUID().uuidString.lowercased()
        let started = Date()
        logger.info(
            "Building warm-start template snapshot",
            metadata: [
                "warmKey": .string(key.directoryName),
                "image": .string(spec.image),
                "templateId": .string(templateId),
            ])

        var vm: ProvisionedMicroVM?
        do {
            let nonce = UUID().uuidString
            let configDrive = SandboxConfigDrive(
                sandboxId: templateId,
                identityNonce: nonce,
                imageConfig: SandboxConfigDrive.ImageConfig(
                    env: materialized.guestConfig.env,
                    entrypoint: materialized.guestConfig.entrypoint,
                    cmd: materialized.guestConfig.cmd,
                    workingDir: materialized.guestConfig.workingDir ?? "",
                    user: materialized.guestConfig.user ?? ""),
                overrides: SandboxConfigDrive.ProcessOverrides(
                    entrypoint: nil, cmd: nil, env: [:], workdir: nil, user: nil),
                warmHold: true)
            let configData = try configDrive.blockImage(
                minimumBytes: SandboxConfigDrive.standardBlockImageBytes)
            guard configData.count == SandboxConfigDrive.standardBlockImageBytes else {
                throw SandboxRuntimeError.warmStartFailed(
                    "the image config exceeds the standard config-drive capacity")
            }

            let provisioned = try await provisionColdMicroVM(
                vmId: templateId, spec: spec, rootfsSourcePath: materialized.rootfsPath,
                configData: configData, guestImage: guestImage)
            vm = provisioned
            try await provisioned.manager.start()

            // The guest must actually honor `warm_hold`: an older guest
            // ignores the unknown field and execs the image's default
            // command — snapshotting that would capture a running workload
            // under the template's identity.
            let status = try await sendControl(
                .getStatus, udsPath: provisioned.vsockUdsPath, timeout: 30)
            guard case .status(let id, let echoedNonce, .held, _) = status,
                id == templateId, echoedNonce == nonce
            else {
                throw SandboxRuntimeError.warmStartFailed(
                    "the guest did not enter the held state (guest image predates warm start?)")
            }

            try await provisioned.manager.pause()

            let staging = try warmCache.makeStagingDirectory()
            do {
                try await captureSnapshot(
                    manager: provisioned.manager, jail: provisioned.jail,
                    memoryTarget: staging + "/" + WarmSandboxSnapshotCache.memoryFile,
                    vmstateTarget: staging + "/" + WarmSandboxSnapshotCache.vmstateFile)
                // The template's rootfs AS OF the snapshot: the held guest
                // has it mounted, so restores must clone exactly these bytes
                // (the pristine image would no longer match the page cache).
                try await reflinkCopy(
                    from: provisioned.rootfsPath,
                    to: staging + "/" + WarmSandboxSnapshotCache.rootfsFile)
                let info = try await provisioned.manager.getInstanceInfo()
                let meta = WarmSandboxSnapshotCache.Meta(
                    templateId: templateId,
                    templateNonce: nonce,
                    imageDigest: key.imageDigest,
                    guestVersion: key.guestVersion,
                    firecrackerVersion: info.vmlinuxVersion,
                    createdAtUnixSeconds: Int64(Date().timeIntervalSince1970))
                try JSONEncoder().encode(meta).write(
                    to: URL(fileURLWithPath: staging + "/" + WarmSandboxSnapshotCache.metaFile))
            } catch {
                try? FileManager.default.removeItem(atPath: staging)
                throw error
            }
            try warmCache.publish(stagingDirectory: staging, for: key)

            await teardownWarmTemplate(templateId: templateId, vm: vm)
            warmBuildFailures.removeValue(forKey: key.directoryName)
            // The sweep walks and deletes multi-GB entries; run it off the
            // actor so it cannot stall sandbox operations. Sweep twice: once
            // now, and once after DiskCacheLRU's recent-use grace window has
            // passed — a burst of builds can land the cache over budget with
            // every entry still grace-protected, and without the re-sweep
            // nothing would enforce the cap until the next publish.
            let cache = warmCache
            let budget = warmCacheBudgetBytes
            let sweepLogger = logger
            Task.detached(priority: .utility) {
                cache.sweep(budgetBytes: budget, logger: sweepLogger)
                let regraceDelay = DiskCacheLRU.defaultGraceInterval + 60
                try? await Task.sleep(nanoseconds: UInt64(regraceDelay * 1_000_000_000))
                cache.sweep(budgetBytes: budget, logger: sweepLogger)
            }
            logger.info(
                "Warm-start template snapshot ready",
                metadata: [
                    "warmKey": .string(key.directoryName),
                    "buildMillis": .stringConvertible(Int(Date().timeIntervalSince(started) * 1000)),
                ])
        } catch {
            warmBuildFailures[key.directoryName] = Date()
            logger.warning(
                "Warm-start template build failed; sandboxes for this image cold-boot until a later retry",
                metadata: [
                    "warmKey": .string(key.directoryName),
                    "error": .string(error.localizedDescription),
                ])
            await teardownWarmTemplate(templateId: templateId, vm: vm)
        }
    }

    /// Remove template debris a crash mid-build left behind: destroy any
    /// still-running template microVM (best-effort adopt-then-destroy — the
    /// self-describing `warm-template-` id prefix is what makes this safe
    /// without manifest bookkeeping), then its jail, storage, and socket
    /// leftovers. Templates are jailed-only, so only the jail layout is
    /// probed for live processes.
    private func sweepLeakedWarmTemplates() async {
        let fileManager = FileManager.default
        // Staging directories abandoned by a crash are excluded from the
        // budget sweep, so this is their only cleanup path — and it must not
        // age-gate: this call runs synchronously before this method's first
        // suspension, and the sweep precedes any template build this process
        // can start (first create, before maybeStartWarmTemplateBuild), so
        // no staging directory can be live here regardless of age. A restart
        // shortly after a crash would otherwise skip the debris forever.
        warmCache.removeAbandonedStaging(olderThan: 0)
        var leaked: Set<String> = []
        if let names = try? fileManager.contentsOfDirectory(atPath: sandboxStoragePath) {
            leaked.formUnion(names.filter { $0.hasPrefix("warm-template-") })
        }
        let jailBase =
            jailerConfig.chrootBaseDir + "/" + (firecrackerBinaryPath as NSString).lastPathComponent
        if let names = try? fileManager.contentsOfDirectory(atPath: jailBase) {
            leaked.formUnion(names.filter { $0.hasPrefix("warm-template-") })
        }
        for templateId in leaked.sorted() {
            logger.warning(
                "Sweeping leaked warm-template artifacts from a previous agent life",
                metadata: ["templateId": .string(templateId)])
            let plan = SandboxJailPlan(
                sandboxId: templateId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
            let socketPath = JailerOptions.socketPath(
                chrootBaseDir: jailerConfig.chrootBaseDir,
                firecrackerBinaryPath: firecrackerBinaryPath,
                vmId: templateId)
            if fileManager.fileExists(atPath: socketPath),
                (try? await client.adoptVM(
                    vmId: templateId,
                    jail: JailerOptions(
                        jailerBinaryPath: jailerConfig.jailerBinaryPath,
                        chrootBaseDir: jailerConfig.chrootBaseDir,
                        uid: plan.uid, gid: plan.gid))) != nil
            {
                try? await client.destroyVM(vmId: templateId)
            }
            await teardownWarmTemplate(templateId: templateId, vm: nil)
        }
        // The previous life may also have left the cache over budget (its
        // post-publish sweeps could have been cut short); re-enforce once,
        // off-actor.
        let cache = warmCache
        let budget = warmCacheBudgetBytes
        let sweepLogger = logger
        Task.detached(priority: .utility) {
            cache.sweep(budgetBytes: budget, logger: sweepLogger)
        }
    }

    /// Best-effort teardown of a template microVM and its staging artifacts.
    /// The jail layout is derived from the template id rather than trusting
    /// `vm`: a provisioning failure leaves `vm` nil with a partially staged
    /// jail, and — template ids being random, never retried — nothing else
    /// would ever clean it this agent life (the leak sweep already ran).
    private func teardownWarmTemplate(templateId: String, vm: ProvisionedMicroVM?) async {
        try? await client.destroyVM(vmId: templateId)
        let plan =
            vm?.jail
            ?? SandboxJailPlan(
                sandboxId: templateId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
        await removeJailArtifacts(plan)
        removeArtifacts(templateId)
        try? FileManager.default.removeItem(atPath: vsockUDSPath(templateId))
    }

    /// `stat(2)` size of a file, 0 when unreadable (sizes are advisory —
    /// quota accounting — never load-bearing for correctness).
    private func fileSize(_ path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Move a file, replacing any existing target. `moveItem` falls back to
    /// copy+delete across filesystems, so this works whether or not the
    /// archive shares a filesystem with the jail chroot.
    private func moveReplacingItem(from source: String, to target: String) throws {
        if FileManager.default.fileExists(atPath: target) {
            try FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.moveItem(atPath: source, toPath: target)
    }

    /// Copy a file via `cp --reflink=auto --sparse=auto`: a metadata-only
    /// clone on filesystems that support reflinks (btrfs, XFS, future ZFS
    /// pools — issue #350), a regular copy otherwise. Sparse regions of the
    /// memory file stay sparse either way.
    private func reflinkCopy(from source: String, to target: String) async throws {
        let cpCandidates = ["/usr/bin/cp", "/bin/cp"]
        guard let cpBinary = cpCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            // No cp binary — fall back to a plain (non-reflink) copy.
            if FileManager.default.fileExists(atPath: target) {
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.copyItem(atPath: source, toPath: target)
            return
        }
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: cpBinary),
            arguments: ["--reflink=auto", "--sparse=auto", "--force", source, target])
        if result.terminationStatus != 0 {
            throw SandboxRuntimeError.snapshotIOFailed(
                "`cp --reflink=auto \(source) \(target)` failed (exit \(result.terminationStatus)): "
                    + result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Exec sessions (issue #423)

    func startExec(
        sandboxId: String,
        sessionId: String,
        request: SandboxExecRequest,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        guard let managed = sandboxes[sandboxId] else {
            throw SandboxRuntimeError.sandboxNotFound(sandboxId)
        }
        guard !checkpointing.contains(sandboxId) else {
            throw SandboxRuntimeError.checkpointInProgress(sandboxId)
        }
        guard execSessions[sessionId] == nil else {
            // Session ids are minted per attach by the control plane; a
            // duplicate start is a stream replay we must not double-bridge.
            return
        }

        logger.info(
            "Starting sandbox exec session",
            metadata: [
                "sandboxId": .string(sandboxId),
                "sessionId": .string(sessionId),
                "tty": .stringConvertible(request.tty),
            ])

        // Snapshot the sweep epoch before suspending: a concurrent stop or
        // delete sweeps `execSessions` while this session is still mid-
        // handshake and would miss it.
        let sweepEpoch = managed.execSweepEpoch

        // A dedicated connection per session: its first line (`exec`) turns it
        // into the session's channel, and closing it later kills the exec
        // process group guest-side.
        let connection = try await VsockConnection.connect(
            udsPath: managed.vsockUdsPath, port: SandboxConfigDrive.defaultVsockPort,
            timeout: Self.execConnectTimeout, logger: logger)

        // Wait (bounded) for the guest to confirm the spawn. Bytes the guest
        // sent after `exec_started` in the same chunk are handed to the reader
        // so no early output is lost.
        let leftover: Data
        do {
            leftover = try await Self.withConnectionDeadline(connection, timeout: Self.execConnectTimeout) {
                try await Self.awaitExecStarted(.exec(request.guestRequest), on: connection)
            }
        } catch {
            await connection.close()
            throw error
        }

        // Back on the actor: re-check that no teardown raced the awaits above.
        // If the sandbox was deleted, or a stop/delete swept its exec sessions
        // (epoch bumped) before this one was registered, registering now would
        // bind the session to a stopped/deleted sandbox that can never deliver
        // a terminal event — refuse instead; the thrown error becomes the
        // control plane's `sandboxExecClosed`.
        guard let current = sandboxes[sandboxId], current.execSweepEpoch == sweepEpoch else {
            await connection.close()
            throw SandboxRuntimeError.sandboxNotFound(
                "\(sandboxId) (stopped or deleted while the exec session was starting)")
        }

        // Confirmed: report `.started` before any output, then drain the
        // session on a detached reader (its reads block between output chunks,
        // which must never park the actor).
        events(.started)
        var session = ExecSession(sandboxId: sandboxId, connection: connection, events: events, reader: nil)
        session.reader = Task.detached { [weak self, logger] in
            await Self.runExecReader(
                sessionId: sessionId, connection: connection, initial: leftover,
                events: events, runtime: self, logger: logger)
        }
        execSessions[sessionId] = session
    }

    func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws {
        guard let session = execSessions[sessionId] else {
            throw SandboxRuntimeError.execSessionNotFound(sessionId)
        }
        if let data, !data.isEmpty {
            try await session.connection.write(SandboxControlProtocol.Request.stdin(data).encodedLine())
        }
        if eof {
            try await session.connection.write(SandboxControlProtocol.Request.stdinEof.encodedLine())
        }
    }

    func resizeExec(sessionId: String, rows: Int, cols: Int) async throws {
        guard let session = execSessions[sessionId] else {
            throw SandboxRuntimeError.execSessionNotFound(sessionId)
        }
        try await session.connection.write(
            SandboxControlProtocol.Request.resize(rows: rows, cols: cols).encodedLine())
    }

    func closeExec(sessionId: String) async {
        guard let session = execSessions.removeValue(forKey: sessionId) else { return }
        logger.info(
            "Closing sandbox exec session",
            metadata: ["sandboxId": .string(session.sandboxId), "sessionId": .string(sessionId)])
        // Closing the connection kills the exec process group guest-side and
        // unblocks the reader, whose end-of-session callback finds the session
        // already deregistered and stays silent — the closer needs no event.
        await session.connection.close()
        session.reader?.cancel()
    }

    /// Terminal teardown of every live exec session of one sandbox (stop or
    /// delete): each session's control-plane side gets a `.closed` with the
    /// reason. Bumps the sandbox's sweep epoch so a `startExec` still awaiting
    /// its handshake refuses to register a session this sweep could not see.
    private func closeExecSessions(sandboxId: String, reason: String) async {
        sandboxes[sandboxId]?.execSweepEpoch += 1
        for (sessionId, session) in execSessions where session.sandboxId == sandboxId {
            execSessions.removeValue(forKey: sessionId)
            await session.connection.close()
            session.reader?.cancel()
            session.events(.closed(reason: reason))
        }
    }

    /// The reader's end-of-session callback: emits the terminal event unless
    /// the session was already deregistered (an explicit `closeExec` or a
    /// sandbox teardown, which speak for themselves).
    private func execSessionEnded(sessionId: String, terminal: SandboxExecEvent) async {
        guard let session = execSessions.removeValue(forKey: sessionId) else { return }
        await session.connection.close()
        logger.info(
            "Sandbox exec session ended",
            metadata: [
                "sandboxId": .string(session.sandboxId),
                "sessionId": .string(sessionId),
                "terminal": .string(String(describing: terminal)),
            ])
        session.events(terminal)
    }

    /// Write the `exec` line and read until the guest confirms `exec_started`.
    /// Returns any bytes read past the confirmation line (early output for the
    /// reader). A guest `error` line (spawn failure) throws.
    private static func awaitExecStarted(
        _ request: SandboxControlProtocol.Request, on connection: VsockConnection
    ) async throws -> Data {
        try await connection.write(request.encodedLine())

        var reader = VsockLineReader(readSize: 4096)
        guard let line = try await reader.nextLine(on: connection) else {
            throw SandboxControlError.malformedResponse("guest closed before confirming exec start")
        }
        let response = try SandboxControlProtocol.Response.decode(line: line)
        if case .error(let message) = response {
            throw SandboxControlError.guestError(message)
        }
        guard case .execStarted = response else {
            throw SandboxControlError.malformedResponse("expected exec_started, got \(response)")
        }
        return reader.leftover
    }

    /// Drains one exec session's connection for its whole life: decodes
    /// `output` records into `.output` events and finishes the session on
    /// `exec_exit`, a guest `error`, or the channel dying. Runs detached — the
    /// reads block between output chunks (fine off-actor: they park on
    /// `DispatchQueue.global()`, not the cooperative pool).
    private static func runExecReader(
        sessionId: String,
        connection: VsockConnection,
        initial: Data,
        events: @escaping @Sendable (SandboxExecEvent) -> Void,
        runtime: FirecrackerSandboxRuntime?,
        logger: Logger
    ) async {
        var reader = VsockLineReader(initial: initial, readSize: 65536)

        func finish(_ terminal: SandboxExecEvent) async {
            await runtime?.execSessionEnded(sessionId: sessionId, terminal: terminal)
        }

        while true {
            let line: String?
            do {
                line = try await reader.nextLine(on: connection)
            } catch {
                // A read failure on a session we tore down ourselves is the
                // expected wakeup; `execSessionEnded` stays silent then.
                await finish(.closed(reason: "sandbox exec channel failed: \(error.localizedDescription)"))
                return
            }
            guard let line else {
                await finish(.closed(reason: "sandbox exec channel closed"))
                return
            }

            let response: SandboxControlProtocol.Response
            do {
                response = try SandboxControlProtocol.Response.decode(line: line)
            } catch {
                await finish(.closed(reason: "malformed exec record from guest"))
                return
            }
            switch response {
            case .output(let stream, let data):
                events(.output(stream: stream, data: data))
            case .execExit(let exitCode):
                await finish(.exited(code: exitCode))
                return
            case .error(let message):
                await finish(.closed(reason: "guest error: \(message)"))
                return
            default:
                await finish(.closed(reason: "unexpected exec record from guest"))
                return
            }
        }
    }

    // MARK: - Control-plane connectivity (issue #423)

    func controlPlaneDisconnected() async {
        // Exec sessions: their frontends are unreachable and the control plane
        // cannot send sandboxExecClose over the dead socket. Closing the guest
        // connections kills the exec process groups; the .closed events this
        // emits are dropped by the (dead) send path, which is fine — the
        // control plane tears its side down in its own agent-close handler.
        let sandboxIds = Set(execSessions.values.map(\.sandboxId))
        for sandboxId in sandboxIds {
            await closeExecSessions(sandboxId: sandboxId, reason: "control plane disconnected")
        }

        // Log follows: suspend, keeping seq/partial-line state. Output the
        // workload produces during the gap stays in the guest ring buffer for
        // the resumed follow; only records consumed in the instant before the
        // drop was noticed can be lost (the delivery path has no acks).
        for sandboxId in Array(logFollows.keys) {
            await stopLogFollow(sandboxId: sandboxId, retire: false)
        }
    }

    func controlPlaneConnected() async {
        for (sandboxId, managed) in sandboxes {
            // A checkpoint/restore in flight has deliberately drained this
            // sandbox's vsock connections; it restarts the follow itself
            // when it finishes.
            guard !checkpointing.contains(sandboxId) else { continue }
            guard let info = try? await managed.manager.getInstanceInfo(), info.state == .running else {
                continue
            }
            startLogFollow(sandboxId: sandboxId)
        }
    }

    // MARK: - Workload log shipping (issue #423)

    func setSandboxLogHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) async {
        logHandler = handler
    }

    /// Start (or restart) the sandbox's log follow loop. Idempotent while a
    /// loop is live; seq/partial-line state carries over from a previous loop
    /// so delivery resumes without loss or duplication.
    private func startLogFollow(sandboxId: String) {
        guard logHandler != nil else { return }
        guard let managed = sandboxes[sandboxId] else { return }
        if logFollows[sandboxId]?.task != nil { return }

        var follow =
            logFollows[sandboxId]
            ?? LogFollow(generation: 0, task: nil, connection: nil, lastSeq: 0, assembler: SandboxLogLineAssembler())
        follow.generation += 1
        let generation = follow.generation
        let udsPath = managed.vsockUdsPath

        logger.debug(
            "Starting sandbox log follow",
            metadata: ["sandboxId": .string(sandboxId), "sinceSeq": .stringConvertible(follow.lastSeq + 1)])

        follow.task = Task.detached { [weak self, logger] in
            await Self.runLogFollowLoop(
                sandboxId: sandboxId, generation: generation, udsPath: udsPath,
                runtime: self, logger: logger)
        }
        logFollows[sandboxId] = follow
    }

    /// Stop the sandbox's log follow loop. `retire: true` (delete) is the
    /// workload's end-of-stream: any buffered partial line is flushed and the
    /// state dropped; `retire: false` (stop/pause) keeps seq and partial-line
    /// state for the next boot.
    private func stopLogFollow(sandboxId: String, retire: Bool) async {
        guard var follow = logFollows[sandboxId] else { return }
        // Bump the generation so a loop iteration already past its
        // cancellation check can no longer register connections or records.
        follow.generation += 1
        follow.task?.cancel()
        follow.task = nil
        if let connection = follow.connection {
            // Unblocks the loop's in-flight blocking read.
            await connection.close()
            follow.connection = nil
        }
        if retire {
            logFollows.removeValue(forKey: sandboxId)
            for line in follow.assembler.flush() {
                logHandler?(sandboxId, line.stream, line.text)
            }
        } else {
            logFollows[sandboxId] = follow
        }
    }

    /// The follow loop's per-connect checkpoint: the seq to resume from, or
    /// nil once this loop generation has been superseded or retired.
    private func logFollowSinceSeq(sandboxId: String, generation: UInt64) -> UInt64? {
        guard let follow = logFollows[sandboxId], follow.generation == generation else { return nil }
        return follow.lastSeq + 1
    }

    /// Adopt `connection` as the follow loop's live connection so a stop can
    /// close it. Returns false when the loop generation was superseded — the
    /// caller must close the connection and exit.
    private func registerLogConnection(
        sandboxId: String, generation: UInt64, connection: VsockConnection
    ) -> Bool {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return false }
        follow.connection = connection
        logFollows[sandboxId] = follow
        return true
    }

    private func unregisterLogConnection(sandboxId: String, generation: UInt64) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.connection = nil
        logFollows[sandboxId] = follow
    }

    /// Record one ring-buffer record: advance the resume seq, feed the line
    /// assembler, and hand every completed line to the log handler (in order —
    /// the follow loop awaits each record, so this runs sequentially).
    private func recordLog(
        sandboxId: String, generation: UInt64, seq: UInt64, stream: String, data: Data
    ) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.lastSeq = max(follow.lastSeq, seq)
        let lines = follow.assembler.append(stream: stream, data: data)
        logFollows[sandboxId] = follow
        for line in lines {
            logHandler?(sandboxId, line.stream, line.text)
        }
    }

    /// The guest reported log end-of-stream (`log_eof`): every workload stdio
    /// pipe hit EOF and every retained record was delivered. Flush a partial
    /// final line now (output that ended without a trailing newline would
    /// otherwise be held until delete), but keep the seq checkpoint — a later
    /// boot's follow reconnects, is told EOF again, and ends just as quietly,
    /// without replaying records as duplicates.
    private func finishLogFollow(sandboxId: String, generation: UInt64) {
        guard var follow = logFollows[sandboxId], follow.generation == generation else { return }
        follow.task = nil
        follow.connection = nil
        let lines = follow.assembler.flush()
        logFollows[sandboxId] = follow
        for line in lines {
            logHandler?(sandboxId, line.stream, line.text)
        }
    }

    /// The long-lived follow loop for one sandbox: connect, send
    /// `stream_logs` resuming after the last recorded seq, and feed records to
    /// the actor until the connection dies; then reconnect with 1s..30s
    /// exponential backoff for as long as the loop generation stays current.
    /// A paused sandbox surfaces as connect timeouts, so the loop idles at the
    /// backoff cap instead of spinning. Runs detached: the follow read blocks
    /// indefinitely between records, which is fine off-actor.
    private static func runLogFollowLoop(
        sandboxId: String,
        generation: UInt64,
        udsPath: String,
        runtime: FirecrackerSandboxRuntime?,
        logger: Logger
    ) async {
        var backoff: TimeInterval = 1

        while !Task.isCancelled {
            guard let runtime else { return }
            guard let sinceSeq = await runtime.logFollowSinceSeq(sandboxId: sandboxId, generation: generation)
            else { return }

            do {
                let connection = try await VsockConnection.connect(
                    udsPath: udsPath, port: SandboxConfigDrive.defaultVsockPort,
                    timeout: execConnectTimeout, logger: logger)
                guard
                    await runtime.registerLogConnection(
                        sandboxId: sandboxId, generation: generation, connection: connection)
                else {
                    await connection.close()
                    return
                }

                var streamComplete = false
                do {
                    try await connection.write(
                        SandboxControlProtocol.Request.streamLogs(sinceSeq: sinceSeq).encodedLine())
                    streamComplete = try await Self.followLogStream(
                        sandboxId: sandboxId, generation: generation, connection: connection,
                        runtime: runtime, backoff: &backoff)
                } catch {
                    logger.debug(
                        "Sandbox log follow stream ended",
                        metadata: [
                            "sandboxId": .string(sandboxId),
                            "error": .string(error.localizedDescription),
                        ])
                }
                await runtime.unregisterLogConnection(sandboxId: sandboxId, generation: generation)
                await connection.close()
                if streamComplete {
                    // The guest declared end-of-stream: nothing will ever
                    // arrive again, so the loop ends instead of reconnecting.
                    return
                }
            } catch {
                logger.debug(
                    "Sandbox log follow connect failed",
                    metadata: [
                        "sandboxId": .string(sandboxId),
                        "error": .string(error.localizedDescription),
                    ])
            }

            if Task.isCancelled { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                return  // cancelled during backoff
            }
            backoff = min(backoff * 2, 30)
        }
    }

    /// Read one follow connection to exhaustion, decoding `log` records and
    /// recording each with the actor. Any delivered record resets the caller's
    /// reconnect backoff (the guest is demonstrably healthy). Returns true when
    /// the guest sent `log_eof` — the stream is complete and the caller must
    /// stop reconnecting — and false when the connection merely closed.
    private static func followLogStream(
        sandboxId: String,
        generation: UInt64,
        connection: VsockConnection,
        runtime: FirecrackerSandboxRuntime,
        backoff: inout TimeInterval
    ) async throws -> Bool {
        var reader = VsockLineReader(readSize: 65536)
        while true {
            guard let line = try await reader.nextLine(on: connection) else {
                return false  // guest closed; the loop reconnects
            }
            switch try SandboxControlProtocol.Response.decode(line: line) {
            case .log(let seq, let stream, let data):
                await runtime.recordLog(
                    sandboxId: sandboxId, generation: generation, seq: seq, stream: stream, data: data)
                backoff = 1
            case .logEof:
                await runtime.finishLogFollow(sandboxId: sandboxId, generation: generation)
                return true
            default:
                throw SandboxControlError.malformedResponse(line)
            }
        }
    }

    // MARK: - Status mapping

    /// Fold the Firecracker instance state and (when running) the guest agent's
    /// workload state into the observed `SandboxStatus`.
    private func mappedStatus(
        instance: InstanceState, udsPath: String, sandboxId: String
    ) async -> SandboxStatus {
        switch instance {
        case .notStarted:
            return .stopped
        case .paused:
            // A control-plane stop; a workload that had already exited is
            // remembered as such.
            return sandboxes[sandboxId]?.lastExitCode != nil ? .exited : .stopped
        case .running:
            // A checkpoint/restore in flight has drained the guest control
            // channel; opening a fresh connection here would race the drain
            // (Firecracker refuses to snapshot a vsock device with live
            // connections). The instance is demonstrably running.
            if checkpointing.contains(sandboxId) {
                return .running
            }
            do {
                let response = try await sendControl(.getStatus, udsPath: udsPath, timeout: 5)
                guard case .status(_, _, let state, let exitCode) = response else {
                    return .starting
                }
                // Ignore a response from a stale generation still bound to the
                // deterministic UDS rather than reporting another sandbox's
                // status/exit code and advancing convergence on it.
                let expectedNonce = sandboxes[sandboxId]?.identityNonce ?? ""
                guard identityMatches(response, sandboxId: sandboxId, expectedNonce: expectedNonce) else {
                    logger.warning(
                        "Ignoring sandbox control status from a mismatched guest identity",
                        metadata: ["sandboxId": .string(sandboxId)])
                    return .unknown
                }
                switch state {
                case .starting:
                    return .starting
                case .held:
                    // A warm-provisioned guest awaiting its launch (issue
                    // #426): the microVM runs but the workload does not
                    // exist yet — still converging toward running.
                    return .starting
                case .running:
                    return .running
                case .exited:
                    if let exitCode {
                        sandboxes[sandboxId]?.lastExitCode = exitCode
                    }
                    return .exited
                }
            } catch {
                // The microVM is up but the guest agent isn't answering yet
                // (still booting) or is momentarily busy — still converging.
                return .starting
            }
        }
    }

    // MARK: - Guest control channel

    /// Open a fresh vsock connection, send one control request, and read the
    /// single newline-delimited JSON response. Stateless per call: the guest
    /// serve loop accepts many short-lived connections, and re-opening avoids
    /// stale file descriptors across polls.
    ///
    /// The read phase is bounded by racing it against a timeout: `VsockConnection.read`
    /// wraps a blocking `read(2)`, so a guest that accepts the connection but
    /// then wedges before sending a full line would otherwise block forever.
    /// When the deadline wins, closing the socket aborts the in-flight blocking
    /// read, so the poll actually returns.
    private func sendControl(
        _ request: SandboxControlProtocol.Request, udsPath: String, timeout: TimeInterval
    ) async throws -> SandboxControlProtocol.Response {
        let connection = try await VsockConnection.connect(
            udsPath: udsPath, port: SandboxConfigDrive.defaultVsockPort, timeout: timeout, logger: logger)

        do {
            let response = try await Self.withConnectionDeadline(connection, timeout: timeout) {
                try await Self.exchange(request, on: connection)
            }
            await connection.close()
            return response
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Race `operation` against a deadline. When the deadline wins, the
    /// connection is closed so any blocking read the operation is parked in
    /// returns instead of hanging (`VsockConnection.close()` shuts the socket
    /// down before closing it, which is what actually wakes a parked
    /// `read(2)`), and `SandboxControlError.timeout` is thrown. The caller
    /// still owns closing the connection on success.
    private static func withConnectionDeadline<T: Sendable>(
        _ connection: VsockConnection, timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await connection.close()
                throw SandboxControlError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Write one request and read the single newline-delimited response. A
    /// `static` (non-isolated) helper so it runs off the actor and its blocking
    /// read can be raced against a timeout (see `sendControl`).
    private static func exchange(
        _ request: SandboxControlProtocol.Request, on connection: VsockConnection
    ) async throws -> SandboxControlProtocol.Response {
        try await connection.write(request.encodedLine())

        var reader = VsockLineReader(readSize: 4096)
        guard let line = try await reader.nextLine(on: connection) else {
            throw SandboxControlError.malformedResponse("guest closed before sending a full response line")
        }
        let response = try SandboxControlProtocol.Response.decode(line: line)
        if case .error(let message) = response {
            throw SandboxControlError.guestError(message)
        }
        return response
    }

    // MARK: - Guest identity

    /// Confirm a control response echoes this sandbox's identity, so a stale
    /// generation still serving the deterministic vsock UDS (a leaked process, a
    /// pre-adoption resume) cannot be mistaken for the current one. The nonce is
    /// checked when known; an empty expected nonce (not yet recovered) falls
    /// back to the id alone.
    private func identityMatches(
        _ response: SandboxControlProtocol.Response, sandboxId: String, expectedNonce: String
    ) -> Bool {
        let echoedId: String
        let echoedNonce: String
        switch response {
        case .pong(let id, let nonce):
            (echoedId, echoedNonce) = (id, nonce)
        case .status(let id, let nonce, _, _):
            (echoedId, echoedNonce) = (id, nonce)
        default:
            return false
        }
        guard echoedId == sandboxId else { return false }
        if !expectedNonce.isEmpty, echoedNonce != expectedNonce { return false }
        return true
    }

    /// Read the boot nonce back from a sandbox's staged config drive (at its
    /// host-view path, flat or in-jail). Empty when the drive is missing or
    /// unreadable, in which case identity checks fall back to the sandbox id
    /// alone.
    private func recoverIdentityNonce(configPath: String) -> String {
        guard let data = FileManager.default.contents(atPath: configPath),
            let drive = try? SandboxConfigDrive.decode(fromBlockImage: data)
        else {
            return ""
        }
        return drive.identityNonce
    }

    // MARK: - Jail plumbing (issue #425)

    /// Hard-link `from` to `to` when both live on one filesystem (the shared
    /// kernel/initramfs are read-only, so a link is safe), falling back to a
    /// copy across filesystems.
    private func linkOrCopy(from: String, to: String) throws {
        if (try? FileManager.default.linkItem(atPath: from, toPath: to)) != nil {
            return
        }
        try FileManager.default.copyItem(atPath: from, toPath: to)
    }

    /// `chown(2)` wrapper — the jailed Firecracker runs as a per-sandbox uid
    /// and must own its writable artifacts.
    private func chownPath(_ path: String, uid: UInt32, gid: UInt32) throws {
        guard chown(path, uid_t(uid), gid_t(gid)) == 0 else {
            throw SandboxRuntimeError.jailSetupFailed(
                "chown \(uid):\(gid) \(path) failed: \(String(cString: strerror(errno)))")
        }
    }

    /// The jailer cgroup flags for one sandbox: on hosts with a cgroup-v2
    /// memory controller, a `memory.max` ceiling protecting the *host* from a
    /// compromised VMM (the agent's manifest accounting remains the only
    /// capacity owner — see docs/architecture/sandboxes.md). Hosts without
    /// one (cgroup v1, or v2 with the memory controller disabled — the jailer
    /// aborts on any `--cgroup` file it cannot write) get no ceiling and one
    /// warning.
    private func jailerCgroups(guestMemoryBytes: Int64) -> (version: Int?, entries: [String]) {
        guard SandboxJailPlan.hostSupportsMemoryCeiling() else {
            if !warnedNoMemoryCeiling {
                warnedNoMemoryCeiling = true
                logger.warning(
                    "Host has no usable cgroup-v2 memory controller; sandboxes run jailed but without a jailer memory ceiling"
                )
            }
            return (nil, [])
        }
        return (2, ["memory.max=\(SandboxJailPlan.memoryLimitBytes(guestMemoryBytes: guestMemoryBytes))"])
    }

    /// Create the sandbox's dedicated network namespace. A namespace left by
    /// a crashed previous life is reused — it is empty either way. Invokes
    /// the `ip` binary the resolver located, never a `PATH` lookup: the
    /// resolution that declared this host jail-capable and the spawn must
    /// agree on the same binary.
    private func createNetns(_ name: String) async throws {
        guard let ipBinaryPath = jailerConfig.ipBinaryPath else {
            // Unreachable when the resolver gated jailing: it requires `ip`.
            throw SandboxRuntimeError.jailSetupFailed(
                "the `ip` tool (iproute2) was not found on this host")
        }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: ipBinaryPath),
                arguments: ["netns", "add", name])
        } catch {
            throw SandboxRuntimeError.jailSetupFailed(
                "spawning `\(ipBinaryPath) netns add \(name)` failed: \(error.localizedDescription)")
        }
        if result.terminationStatus != 0 {
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.contains("File exists") { return }
            throw SandboxRuntimeError.jailSetupFailed(
                "`ip netns add \(name)` failed (exit \(result.terminationStatus)): \(output)")
        }
    }

    /// Best-effort teardown of a jailed sandbox's host-side leftovers: the
    /// chroot subtree and per-VM cgroup directory (normally the client's job,
    /// but a crash can orphan both) and the network namespace.
    private func removeJailArtifacts(_ plan: SandboxJailPlan) async {
        try? FileManager.default.removeItem(atPath: plan.jailDirectory)
        _ = rmdir(
            JailerOptions.cgroupDirectory(
                firecrackerBinaryPath: firecrackerBinaryPath, vmId: plan.sandboxId))
        // `ip netns delete` is just an unmount plus unlink of the bind-mounted
        // name (ip-netns(8)); doing the syscalls directly means teardown keeps
        // working even when iproute2 was removed after a previous agent life
        // created the namespace. Best effort — ENOENT (never created) and
        // EPERM (non-root dev agent, which never created one) are both fine.
        _ = umount2(plan.netnsPath, Int32(MNT_DETACH))
        _ = unlink(plan.netnsPath)
    }

    // MARK: - Paths

    private func sandboxDirectory(_ sandboxId: String) -> String {
        sandboxStoragePath + "/" + sandboxId
    }

    private func vsockUDSPath(_ sandboxId: String) -> String {
        socketDirectory + "/" + sandboxId + ".vsock"
    }

    private func removeArtifacts(_ sandboxId: String) {
        try? FileManager.default.removeItem(atPath: sandboxDirectory(sandboxId))
    }
}

/// Incremental newline framing over a vsock connection, shared by every read
/// loop in the runtime (control exchange, exec handshake, exec reader, log
/// follow) so buffering and line-splitting behavior cannot drift between them.
///
/// `nextLine` returns complete lines (without the `\n`) one at a time, reading
/// more from the connection only when no complete line is buffered; `nil`
/// means the guest closed the connection (EOF). Read errors and timeouts
/// propagate from `VsockConnection.read` untouched, so callers keep their own
/// EOF/error semantics and any external deadline racing (`withConnectionDeadline`)
/// works exactly as it does against a bare read.
private struct VsockLineReader {
    /// Bytes received but not yet returned: everything past the last returned
    /// line's newline.
    private(set) var buffer: Data
    /// Per-read chunk size (small for one-line control exchanges, large for
    /// streaming loops).
    private let readSize: Int

    init(initial: Data = Data(), readSize: Int) {
        self.buffer = initial
        self.readSize = readSize
    }

    /// Bytes buffered past the last returned line (e.g. early exec output
    /// received in the same chunk as the `exec_started` confirmation).
    var leftover: Data { buffer }

    /// The next complete line, or nil once the guest closes the connection.
    mutating func nextLine(on connection: VsockConnection) async throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            let chunk = try await connection.read(maxLength: readSize)
            if chunk.isEmpty {
                return nil
            }
            buffer.append(chunk)
        }
    }
}

#else

/// Stub sandbox runtime for non-Linux platforms. Sandboxes are Firecracker/KVM
/// workloads (Linux only); the `Agent` never constructs this off Linux, but the
/// type must exist so `StratoAgent` compiles everywhere.
actor FirecrackerSandboxRuntime: SandboxRuntimeService {
    init(
        logger: Logger,
        socketDirectory: String,
        sandboxStoragePath: String,
        guestImagePath: String
    ) {
        // No-op: never constructed on non-Linux hosts.
    }

    func createSandbox(
        sandboxId: String, spec: SandboxSpec, registryCredential: RegistryCredential?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func bootSandbox(sandboxId: String) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func shutdownSandbox(sandboxId: String) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func deleteSandbox(sandboxId: String) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func adoptSandbox(sandboxId: String, spec: SandboxSpec) async throws -> SandboxStatus {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func getSandboxStatus(sandboxId: String) async throws -> SandboxStatus {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func exitCode(sandboxId: String) async -> Int? {
        nil
    }

    func snapshotSandbox(
        sandboxId: String, snapshotId: String, mode: SandboxSnapshotMode
    ) async throws -> SandboxSnapshotResult {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func restoreSandbox(sandboxId: String, snapshotId: String) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func deleteSandboxSnapshot(sandboxId: String, snapshotId: String) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func startExec(
        sandboxId: String, sessionId: String, request: SandboxExecRequest,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func resizeExec(sessionId: String, rows: Int, cols: Int) async throws {
        throw HypervisorServiceError.notSupported("sandboxes are only available on Linux")
    }

    func closeExec(sessionId: String) async {
        // No sessions can exist on non-Linux hosts.
    }

    func setSandboxLogHandler(_ handler: @escaping @Sendable (String, String, String) -> Void) async {
        // No sandboxes can run on non-Linux hosts, so no logs will flow.
    }

    func controlPlaneDisconnected() async {
        // No sessions or follows can exist on non-Linux hosts.
    }

    func controlPlaneConnected() async {
        // No sessions or follows can exist on non-Linux hosts.
    }
}
#endif
