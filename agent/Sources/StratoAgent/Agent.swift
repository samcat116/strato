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

enum AgentError: Error, LocalizedError {
    case registrationTimeout
    /// The control plane explicitly rejected our identity — retrying with the
    /// same SVID can never succeed.
    case registrationRejected(String)
    /// Registration failed for an unclassified (potentially transient) reason,
    /// e.g. a control-plane database blip — safe to retry with backoff.
    case registrationFailed(String)
    /// A newer registration attempt replaced this one before it resolved (e.g. a
    /// reconnect fired while an earlier attempt was still parked). Fails the stale
    /// attempt so it doesn't leak its awaiter.
    case registrationSuperseded
    case notRegistered
    case spiffeConfigurationError(String)

    var errorDescription: String? {
        switch self {
        case .registrationTimeout:
            return "Registration timed out waiting for control plane response"
        case .registrationRejected(let reason):
            return "Registration rejected by control plane: \(reason)"
        case .registrationFailed(let reason):
            return "Registration failed (control plane error): \(reason)"
        case .registrationSuperseded:
            return "Registration attempt was superseded by a newer attempt"
        case .notRegistered:
            return "Agent is not registered with control plane"
        case .spiffeConfigurationError(let message):
            return "SPIFFE configuration error: \(message)"
        }
    }
}

actor Agent {
    private let initialAgentID: String  // ID used for registration (hostname or CLI arg)
    private var assignedAgentID: String?  // UUID assigned by control plane after registration
    // The URL to dial. It carries no credential — the agent authenticates with
    // its SPIFFE X.509 SVID over mTLS — only the agent's `name`.
    private let webSocketURL: String
    private let qemuSocketDir: String
    private let logger: Logger

    /// The HTTP(S) base of the control plane, derived from the dialed
    /// WebSocket URL: query off first (the `name` parameter would otherwise
    /// trail every request), scheme swapped to HTTP, `/agent/ws` suffix
    /// dropped. Relative image-download paths resolve against this base and
    /// are fetched over SVID mTLS (issue #493) — the same Envoy listener that
    /// carries the WebSocket.
    private var controlPlaneHTTPBase: String {
        (WebSocketURLs.removingQuery(from: webSocketURL) ?? webSocketURL)
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "/agent/ws", with: "")
    }

    private var websocketClient: WebSocketClient?
    // Registry of hypervisor drivers keyed by backend type, populated once in
    // start(). This registry and `getHypervisorService(for:)` are the only
    // places message handling may reach the concrete services — everything
    // else goes through the `HypervisorService` protocol, so adding a backend
    // means one new registration here (plus the enum case and its data tables
    // in HypervisorTypes.swift), not new switch sites.
    private var hypervisorServices: [HypervisorType: any HypervisorService] = [:]
    private var networkService: (any NetworkServiceProtocol)?
    private var imageCacheService: ImageCacheService?
    private var storageBackend: (any StorageBackend)?
    private var consoleSocketManager: ConsoleSocketManager?
    private var reconnectTask: Task<Void, Never>?
    private var isRunning = false
    // Set once a graceful shutdown has been requested (e.g. by a signal
    // handler calling stop()). Guards start() against parking if stop() ran
    // during startup, which would otherwise hang the process on exit.
    private var shutdownRequested = false
    // Resumed by stop() to unblock start(), which parks here for the agent's
    // lifetime instead of busy-sleeping.
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var registrationContinuation: CheckedContinuation<String, Error>?
    // Bound to `registrationContinuation`: cancelled the moment the continuation
    // is resolved so a resolved registration never leaves a 30s timer dangling.
    private var registrationTimeoutTask: Task<Void, Never>?
    // Incremented per registration attempt so a timeout fired by a superseded
    // attempt can be told apart from — and can't fail — the current one.
    private var registrationGeneration: UInt64 = 0
    private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    // Ordered inbound-message pipeline. The WebSocket client yields decoded frames into
    // `inboundContinuation` in arrival order; `messageConsumerTask` drains the stream and
    // routes each frame onto a per-resource serial lane in `messageQueue`, so operations on
    // the same VM/volume are applied in the order the control plane sent them (issue #179).
    private nonisolated let inboundMessages: AsyncStream<MessageEnvelope>
    private nonisolated let inboundContinuation: AsyncStream<MessageEnvelope>.Continuation
    private let messageQueue = SerialTaskQueue()
    private var messageConsumerTask: Task<Void, Never>?

    // Reconciliation phase 2 (issue #260): converges hypervisor reality toward
    // the control plane's desired-state syncs. Work items run on the same
    // per-VM lanes as imperative messages, so the two modes can never
    // interleave operations on one VM.
    private var reconciler: Reconciler?
    // What this host's link-local metadata service serves its guests (STR-52),
    // written by the reconciler from each sync's `DesiredVMState.metadata`.
    // Owned here rather than by the reconciler because the guest-facing
    // listener will read the same instance.
    private let metadataStore = MetadataStore()
    // Whether the control plane we registered with speaks state sync (wire
    // protocol >= 2). Gates observed-state reports so an old control plane
    // isn't sent envelopes it logs as unknown.
    private var controlPlaneSupportsStateSync = false

    // Durable, backend-agnostic record of the VMs this agent owns, keyed by vmId.
    // `managedVMs` are actively managed by this process; `orphanedVMs` were managed
    // by a previous incarnation — their hypervisor processes may still be running,
    // so they stay routable to the right backend and their reservations keep
    // counting against host capacity until they are deleted or re-created. Both
    // sets are persisted via `manifestStore` so routing survives restarts.
    private let manifestStore: VMManifestStore
    private var managedVMs: [String: VMManifestEntry] = [:]
    private var orphanedVMs: [String: VMManifestEntry] = [:]

    // Set when the manifest could not be read at all (STR-138), which means
    // this host's workloads are unknown — not that there are none. The agent
    // quarantines itself: it advertises no available capacity, converges
    // nothing, never writes over the file it could not read, and reports the
    // condition on every observed-state report so an operator sees it in the
    // UI rather than in one log line on the node. Cleared only by a later read
    // that actually succeeds (retried on the heartbeat, so a storage volume
    // that mounted late recovers without a restart).
    private var manifestReadFailure: ManifestReadFailure?
    // Entries that exist but this build cannot route (an unrecognized
    // hypervisor type after a rollback, an undecodable spec). They keep
    // reserving capacity, block a re-create of their id, and are re-persisted
    // verbatim so rolling forward again restores them intact.
    private var quarantinedWorkloads: [String: QuarantinedManifestEntry] = [:]

    // Sandbox workload tracking (issue #417): same manifest contract as VMs,
    // kept in separate maps so the VM paths never have to filter by kind.
    // `sandboxRuntime` is the driver seam (issue #421): the Firecracker
    // runtime on Linux hosts with a guest image, the mock runtime in
    // simulation mode (issue #470), nil otherwise. With no runtime the sandbox
    // capability stays off and only orphaned entries — written by a runtime-
    // bearing incarnation, then inherited across a downgrade/restart — can
    // appear; they keep reserving capacity and can be deleted (manifest-only),
    // but cannot be re-adopted.
    private var sandboxRuntime: (any SandboxRuntimeService)?
    private var managedSandboxes: [String: VMManifestEntry] = [:]
    private var orphanedSandboxes: [String: VMManifestEntry] = [:]

    // Virtual size per volume, so the reconciler can tell a volume that needs
    // growing from one that is already the size the sync asks for (STR-148).
    // In memory only, and deliberately: it is a cache of something the storage
    // backend can always re-derive, and paying one `qemu-img info` per volume
    // once per agent lifetime is cheaper than persisting a second source of
    // truth that could drift from the disk.
    private var volumeSizes: [String: Int64] = [:]

    // Snapshot artifacts this host holds (STR-150), across all three families.
    //
    // Durable, unlike `volumeSizes`, because none of what it holds can be
    // re-derived: a Firecracker checkpoint's fork-layout version and CPU
    // template are not recoverable from its files at all, and a qcow2 internal
    // snapshot's footprint costs a subprocess per artifact per report. The
    // control plane learns every one of these facts from the observed report,
    // so they are recorded once, when the only party that can measure them
    // does.
    //
    // `snapshotInventoryUnreadable` is the artifact counterpart of
    // `manifestReadFailure` and does the same job: an empty inventory is
    // authoritative downstream — omission from a full list is how a deletion is
    // confirmed — so a host that could not read the file reports *no* list
    // rather than an empty one, and never writes over what it could not read.
    private let snapshotRecordStore: SnapshotRecordStore
    private var snapshotRecords: [UUID: SnapshotRecord] = [:]
    private var snapshotInventoryUnreadable = false

    // Sandbox exec/attach bridging and workload log shipping (issue #423).
    // The runtime's callbacks yield into these streams *synchronously*, so
    // per-session event order and per-sandbox line order survive the hop out
    // of the runtime; two pump tasks drain them into outbound WebSocket
    // messages one at a time (mirroring the ordered inbound pipeline above).
    private nonisolated let sandboxExecEvents: AsyncStream<(String, String, SandboxExecEvent)>
    private nonisolated let sandboxExecEventsContinuation: AsyncStream<(String, String, SandboxExecEvent)>.Continuation
    private nonisolated let sandboxLogLines: AsyncStream<(String, String, String)>
    private nonisolated let sandboxLogLinesContinuation: AsyncStream<(String, String, String)>.Continuation
    private var sandboxExecPumpTask: Task<Void, Never>?
    private var sandboxLogPumpTask: Task<Void, Never>?
    // Set when a manifest write failed (disk full, permissions); the write is
    // retried on every heartbeat until it succeeds, so a transient failure only
    // leaves the on-disk manifest stale for a bounded window.
    private var manifestPersistFailed = false
    // Last successful observation of each hypervisor, reported when a live query
    // exceeds its budget. Liveness must not depend on hypervisor progress: a
    // stuck hypervisor call used to block the heartbeat, so the control plane
    // read a busy agent as a dead one and failed its in-flight work (issue #516).
    // Bumped when an observed-state report starts assembling. A report that
    // overran its budget was abandoned mid-flight, so it must not transmit
    // afterwards: reports carry full-list semantics and the control plane
    // applies them in receive order, so a late one would overwrite a newer
    // report's view with stale observations (issue #516).
    private var observedReportEpoch: UInt64 = 0

    // Last-known QEMU guest-agent info per VM (issue #563), refreshed off the
    // hot path by a throttled slow poll and read verbatim into each
    // `ObservedVMState`. Keeping the probe out of `sendObservedStateReport`
    // means a qga round-trip (which routinely times out for a guest with no
    // agent) never delays the report itself. Wholesale-replaced each refresh, so
    // entries for gone or no-longer-running VMs prune themselves.
    private var guestInfoCache: [String: GuestInfo] = [:]
    // Last-known balloon memory stats per VM (issue #567), maintained by the
    // same slow poll with the same lifecycle as `guestInfoCache`.
    private var memoryStatsCache: [String: VMMemoryStats] = [:]
    /// When the guest-info cache was last refreshed, to throttle probing to the
    /// slow-poll cadence regardless of how often reports/heartbeats fire.
    private var lastGuestInfoRefresh: ContinuousClock.Instant?
    /// Minimum spacing between guest-info refreshes.
    private static let guestInfoRefreshInterval: Duration = .seconds(30)

    private let networkMode: NetworkMode?
    // Chassis-level OVN settings (ovn-remote/encap external_ids) the network
    // service bootstraps onto the local OVS at connect time.
    private let ovnChassisConfig: OVNChassisConfig
    private let ovnUplink: OVNUplinkConfig?
    // OVN native dynamic routing (issue #344): BGP advertisement of floating
    // IPs / connected routes via FRR on the egress host.
    private let ovnDynamicRouting: OVNDynamicRoutingConfig?
    private let ovnNorthbound: String?
    // TLS material for an ssl: ovn_northbound endpoint (nil = tcp/unix).
    private let ovnNorthboundTLS: OVNNorthboundTLSConfig?
    // The networking backend actually selected at startup (config value plus
    // platform fallbacks). Drives the networking capability advertised at
    // registration: a Linux agent configured for user-mode networking must not
    // claim OVN/VM-to-VM support.
    private var effectiveNetworkMode: NetworkMode = .user
    // Whether the selected network service is currently connected. An OVN
    // agent whose OVN/OVS connection failed must not advertise
    // ovn_networking, or the scheduler would place VM-to-VM workloads on a
    // backend that will throw notConnected. A failed connection is retried in
    // the background (`networkConnectTask`) and again at each registration,
    // so a fixed host recovers the capability without a restart.
    private var networkServiceConnected = false
    // Background retry loop for a network service that failed to connect.
    private var networkConnectTask: Task<Void, Never>?
    private let imageCachePath: String?
    // Byte budgets for the image caches; nil means unbounded (see
    // image_cache_max_size_gb / sandbox_image_cache_max_size_gb).
    private let imageCacheMaxSizeBytes: Int64?
    private let sandboxImageCachePath: String?
    private let sandboxImageCacheMaxSizeBytes: Int64?
    private let vmStoragePath: String
    // Root of the managed-volume tree for the filesystem storage backend and
    // the host preflight's writability probe.
    private let volumeStoragePath: String
    private let qemuBinaryPath: String
    // Operator-configured EDK2 firmware paths (issue #565): the split
    // CODE/VARS pairs and the legacy monolithic image.
    private let firmware: FirmwareOverrides
    // `swtpm`, when this host has it. Nil keeps the TPM capability dark at
    // registration, so the scheduler never places a vTPM VM here.
    private let swtpmBinaryPath: String?
    private let firecrackerBinaryPath: String
    private let firecrackerSocketDir: String
    // Where the sandbox guest base image (issue #419) is installed; its
    // presence gates the sandbox-runtime capability advertised at
    // registration (issue #415).
    private let sandboxGuestImagePath: String?
    // Sandbox jailer policy (issue #425): resolved once at start() into
    // either a SandboxJailerConfig for the runtime or, when mode is
    // `required` and the host can't satisfy it, a blocked-reason that keeps
    // the sandbox capability dark at every registration.
    private let sandboxJailerMode: SandboxJailerMode
    private let sandboxJailerBinaryPath: String
    private let sandboxJailerChrootDir: String
    private let sandboxJailerUidBase: UInt32
    private var sandboxJailerBlockedReason: String?
    // The resolved jail layout, built unconditionally at start() — even an
    // unjailed agent needs it to tear down jailed leftovers from a previous
    // life. Nil only when this build/host has no sandbox runtime at all.
    private var sandboxJailerConfig: SandboxJailerConfig?
    // Whether *new* sandboxes get the jailer barrier. A sandbox NIC lives in
    // the jail's network namespace, so without the barrier there is nowhere to
    // put it and networked specs are refused (issue STR-100).
    private var sandboxJailNewSandboxes = false
    // Warm start (issue #426): provision sandboxes from per-image template
    // snapshots when possible. Default on; warm failures cold-boot.
    private let sandboxWarmStart: Bool
    private let sandboxWarmCacheMaxSizeBytes: Int64?
    private let hypervisorType: HypervisorType
    private let hardwareAccelerationEnabled: Bool

    // Simulation ("dummy agent") mode: the agent speaks the full control-plane
    // protocol but drives a no-op mock hypervisor with no real
    // networking/storage, and reports the configured fake host capacity instead
    // of probing the machine. Lets a fleet of dummies scale-test a control plane
    // far larger than the compute available to run real VMs. Nil/disabled means
    // a normal agent.
    private let simulation: SimulationConfig?
    private var isSimulationMode: Bool { simulation?.enabled ?? false }

    // SPIFFE/SPIRE support
    private let spiffeConfig: SPIFFEConfig?
    private var svidManager: SVIDManager?

    // How much of this host one sync's confirmed teardowns may remove (STR-98).
    private let teardownGuard: TeardownGuard

    // Desired-state transport (STR-146). `desiredStatePullEnabled` is what the
    // operator asked for; the poller only actually starts once a registration
    // response confirms the control plane serves the endpoint.
    private let desiredStatePullEnabled: Bool
    private let desiredStateFullRefetchInterval: Duration
    private var desiredStatePoller: DesiredStatePoller?

    // Set when a failure is unrecoverable (e.g. the agent's identity was
    // rejected); start() rethrows it so the process exits non-zero instead
    // of idling disconnected.
    private var terminalError: Error?
    // Set after a successful self-update binary swap (issue #432): stop() is
    // about to run and the process must exit with
    // `AgentUpdater.restartExitCode` so the supervisor (Restart=on-failure)
    // starts the new binary. Read by launchAgent once start() returns.
    private(set) var updateRestartPending = false
    // Declarative auto-update state (issue #434). `autoUpdateStatus` is the
    // blocked/failed reason carried on observed-state reports so the control
    // plane's rollout can tell "waiting on a precondition" from "the update
    // itself failed". `attemptedAutoUpdateArtifacts` remembers artifacts
    // already tried this process lifetime: retrying a failed artifact on
    // every sync would loop downloads (or, for an artifact whose binary
    // reports the wrong version, restart-loop the agent), and the control
    // plane halts the rollout on the reported failure anyway.
    private var autoUpdateStatus: ObservedAgentUpdateStatus?
    private var attemptedAutoUpdateArtifacts: Set<String> = []

    init(
        agentID: String,
        webSocketURL: String,
        qemuSocketDir: String,
        networkMode: NetworkMode?,
        ovnChassisConfig: OVNChassisConfig = OVNChassisConfig(),
        ovnUplink: OVNUplinkConfig? = nil,
        ovnDynamicRouting: OVNDynamicRoutingConfig? = nil,
        ovnNorthbound: String? = nil,
        ovnNorthboundTLS: OVNNorthboundTLSConfig? = nil,
        logger: Logger,
        imageCachePath: String? = nil,
        imageCacheMaxSizeBytes: Int64? = nil,
        sandboxImageCachePath: String? = nil,
        sandboxImageCacheMaxSizeBytes: Int64? = nil,
        vmStoragePath: String,
        volumeStoragePath: String = FileSystemStorageBackend.defaultStoragePath,
        qemuBinaryPath: String,
        firmware: FirmwareOverrides = FirmwareOverrides(),
        swtpmBinaryPath: String? = nil,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        firecrackerSocketDir: String = "/tmp/firecracker",
        sandboxGuestImagePath: String? = nil,
        sandboxJailerMode: SandboxJailerMode = .auto,
        sandboxJailerBinaryPath: String = "/usr/local/bin/jailer",
        sandboxJailerChrootDir: String = "/var/lib/strato/vms/jailer",
        sandboxJailerUidBase: UInt32 = AgentConfig.defaultSandboxJailerUidBase,
        sandboxWarmStart: Bool = true,
        sandboxWarmCacheMaxSizeBytes: Int64? = nil,
        hypervisorType: HypervisorType = .qemu,
        hardwareAccelerationEnabled: Bool = true,
        simulation: SimulationConfig? = nil,
        spiffeConfig: SPIFFEConfig? = nil,
        teardownGuard: TeardownGuard = TeardownGuard(),
        desiredStatePull: Bool = true,
        desiredStateFullRefetchInterval: Duration = DesiredStatePoller.defaultFullRefetchInterval
    ) {
        self.initialAgentID = agentID
        self.webSocketURL = webSocketURL
        self.qemuSocketDir = qemuSocketDir
        self.networkMode = networkMode
        self.ovnChassisConfig = ovnChassisConfig
        self.ovnUplink = ovnUplink
        self.ovnDynamicRouting = ovnDynamicRouting
        self.ovnNorthbound = ovnNorthbound
        self.ovnNorthboundTLS = ovnNorthboundTLS
        self.logger = logger
        self.imageCachePath = imageCachePath
        self.imageCacheMaxSizeBytes = imageCacheMaxSizeBytes
        self.sandboxImageCachePath = sandboxImageCachePath
        self.sandboxImageCacheMaxSizeBytes = sandboxImageCacheMaxSizeBytes
        self.vmStoragePath = vmStoragePath
        self.volumeStoragePath = volumeStoragePath
        self.qemuBinaryPath = qemuBinaryPath
        self.firmware = firmware
        self.swtpmBinaryPath = swtpmBinaryPath
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.firecrackerSocketDir = firecrackerSocketDir
        self.sandboxGuestImagePath = sandboxGuestImagePath
        self.sandboxJailerMode = sandboxJailerMode
        self.sandboxJailerBinaryPath = sandboxJailerBinaryPath
        self.sandboxJailerChrootDir = sandboxJailerChrootDir
        self.sandboxJailerUidBase = sandboxJailerUidBase
        self.sandboxWarmStart = sandboxWarmStart
        self.sandboxWarmCacheMaxSizeBytes = sandboxWarmCacheMaxSizeBytes
        self.hypervisorType = hypervisorType
        self.hardwareAccelerationEnabled = hardwareAccelerationEnabled
        self.simulation = simulation
        self.spiffeConfig = spiffeConfig
        self.teardownGuard = teardownGuard
        self.desiredStatePullEnabled = desiredStatePull
        self.desiredStateFullRefetchInterval = desiredStateFullRefetchInterval
        self.manifestStore = VMManifestStore(
            path: (vmStoragePath as NSString).appendingPathComponent("vm-manifest.json"),
            legacyQEMUManifestPath: (vmStoragePath as NSString).appendingPathComponent("qemu-manifest.json"),
            logger: logger
        )
        self.snapshotRecordStore = SnapshotRecordStore(
            path: (vmStoragePath as NSString).appendingPathComponent("snapshot-records.json"),
            logger: logger
        )

        let (stream, continuation) = AsyncStream.makeStream(of: MessageEnvelope.self)
        self.inboundMessages = stream
        self.inboundContinuation = continuation

        let (execEvents, execContinuation) = AsyncStream.makeStream(of: (String, String, SandboxExecEvent).self)
        self.sandboxExecEvents = execEvents
        self.sandboxExecEventsContinuation = execContinuation

        let (logLines, logContinuation) = AsyncStream.makeStream(of: (String, String, String).self)
        self.sandboxLogLines = logLines
        self.sandboxLogLinesContinuation = logContinuation
    }

    /// Returns the effective agent ID (assigned UUID if registered, initial ID otherwise)
    private var effectiveAgentID: String {
        return assignedAgentID ?? initialAgentID
    }

    func start() async throws {
        guard !isRunning else {
            logger.warning("Agent is already running")
            return
        }

        // Recover the workload manifest from a previous incarnation of this agent.
        // These workloads are not re-adopted here — the reconciler re-adopts them
        // when the backend supports it — but they stay routable to the backend that
        // owns them and keep reserving capacity until deleted or re-created.
        applyManifestLoad(manifestStore.load())
        applySnapshotInventory(snapshotRecordStore.load())

        // Simulation mode drives no real network backend. `NetworkOrchestrator`
        // already degrades to a no-op when `networkService` is nil, so
        // VM-create networking becomes a clean pass-through. Pretend networking
        // is connected in OVN mode so the agent advertises OVN networking and
        // looks like a full Linux host to the scheduler.
        if isSimulationMode {
            logger.info("Simulation mode: skipping real network service; advertising OVN networking")
            effectiveNetworkMode = .ovn
            networkServiceConnected = true
        } else {
            logger.info("Initializing network service")

            // Initialize network service based on config, falling back to platform defaults
            let selectedMode =
                networkMode
                ?? {
                    #if os(Linux)
                    return .ovn
                    #else
                    return .user
                    #endif
                }()

            switch selectedMode {
            case .ovn:
                #if os(Linux)
                logger.info("Network service initialized with SwiftOVN support")
                // Resolve iproute2 up front, absolutely: attaching a NIC into a
                // jailed sandbox's network namespace shells out to `ip` and
                // `tc`, and a service manager's stripped `PATH` must not be able
                // to break a host that has them (issue STR-100).
                let isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
                networkService = NetworkServiceLinux(
                    nbConnection: ovnNorthbound, nbTLS: ovnNorthboundTLS, chassisConfig: ovnChassisConfig,
                    uplink: ovnUplink, dynamicRouting: ovnDynamicRouting,
                    ipBinaryPath: SandboxJailerResolver.resolveIPBinaryPath(isExecutable: isExecutable),
                    tcBinaryPath: SandboxJailerResolver.resolveTCBinaryPath(isExecutable: isExecutable),
                    logger: logger)
                effectiveNetworkMode = .ovn
                #else
                logger.warning("OVN mode requested but not supported on macOS, falling back to user mode")
                networkService = NetworkServiceMacOS(logger: logger)
                effectiveNetworkMode = .user
                #endif
            case .user:
                logger.info("Network service initialized with user-mode networking")
                networkService = NetworkServiceMacOS(logger: logger)
                effectiveNetworkMode = .user
            }

            networkServiceConnected = await connectNetworkService()
            if !networkServiceConnected {
                logger.warning("VM networking will be limited until the network service connects")
                // Keep retrying in the background: OVN/OVS coming up after the
                // agent (boot ordering, or an operator installing it) restores
                // networking without an agent restart.
                startNetworkReconnectLoop()
            }
        }

        // Storage. A simulated agent still attracts volume work — it advertises
        // QEMU, and volume placement picks any online agent that supports it —
        // so the backend must be mocked too. Backing a dummy with the real one
        // would qemu-img a file per volume and pull the whole image through the
        // cache first; across a fleet that is enough disk and network traffic to
        // take out the host, and it would contradict the mode's promise of no
        // real storage. The image cache is skipped entirely for the same reason:
        // nothing in simulation may fetch image bytes.
        let storageBackend: any StorageBackend
        if isSimulationMode {
            logger.info("Simulation mode: registering mock storage backend (no image cache)")
            // Metadata goes in this agent's own storage dir, next to the VM
            // manifest — never the shared default volume root, which every
            // simulated agent on the host would otherwise write over. It is what
            // lets volumes the control plane still has placed here survive a
            // restart, exactly as the real backend's bytes on disk do.
            storageBackend = MockStorageBackend(
                logger: logger,
                metadataPath: (vmStoragePath as NSString).appendingPathComponent("mock-volumes.json")
            )
        } else {
            logger.info("Initializing image cache service")
            // Downloads present the agent's SVID as the client certificate.
            // The downloader looks the TLS config up per fetch, so building it
            // here — before the SVID manager exists — is fine: no download can
            // start until after registration, by which point the SVID is live.
            let artifactDownloader = makeMTLSArtifactDownloader()
            imageCacheService = ImageCacheService(
                logger: logger,
                cachePath: imageCachePath,
                controlPlaneURL: controlPlaneHTTPBase,
                maxCacheSizeBytes: imageCacheMaxSizeBytes,
                fetch: { url in try await artifactDownloader.fetchToTemporaryFile(url: url) }
            )

            logger.info("Initializing storage backend")
            storageBackend = FileSystemStorageBackend(
                logger: logger,
                volumeStoragePath: volumeStoragePath,
                imageSource: imageCacheService
            )
        }
        self.storageBackend = storageBackend

        if isSimulationMode {
            // One mock backend per hypervisor type, so the agent is eligible for
            // both QEMU and Firecracker placements. The mock tracks specs and
            // reports real reservations, so placements deplete the agent's
            // advertised capacity like a real host.
            //
            // Deliberately not gated on Linux, unlike the real drivers: a
            // simulated agent models a Linux fleet whatever host it runs on —
            // it already advertises ovn_networking on macOS for the same reason
            // — so a macOS dev box can scale-test Firecracker placement too.
            // Nothing here touches Firecracker itself.
            logger.info("Simulation mode: registering mock hypervisor backend(s)")
            for type in HypervisorType.allCases {
                hypervisorServices[type] = MockHypervisorService(logger: logger, hypervisorType: type)
            }

            // The mock sandbox runtime (issue #470), so simulated agents host
            // sandbox workloads too — sandbox scheduling, reconciliation, exec
            // bridging, and log shipping all get scale coverage. Not gated on
            // Linux, for the same reason as the mock hypervisors above: a
            // simulated agent models a Linux fleet whatever host it runs on.
            // No capacity accounting needed — sandbox reservations come from
            // this agent's manifest, exactly like real hosts.
            logger.info("Simulation mode: registering mock sandbox runtime")
            sandboxRuntime = MockSandboxRuntime(
                logger: logger,
                workloadLifetime: simulation?.resolvedSandboxLifetime,
                logInterval: simulation?.resolvedSandboxLogInterval
            )
        } else {
            logger.info("Initializing QEMU service")
            #if canImport(SwiftQEMU)
            hypervisorServices[.qemu] = QEMUService(
                logger: logger, storage: storageBackend,
                vmStoragePath: vmStoragePath, qemuBinaryPath: qemuBinaryPath, firmware: firmware,
                swtpmBinaryPath: swtpmBinaryPath,
                hardwareAccelerationEnabled: hardwareAccelerationEnabled)
            #else
            hypervisorServices[.qemu] = MockHypervisorService(logger: logger, hypervisorType: .qemu)
            #endif

            #if os(Linux)
            logger.info("Initializing Firecracker service (Linux only)")
            // One Firecracker client backs both VMs and sandboxes so they share the
            // process registry, socket directory, and re-adoption machinery.
            let firecrackerClient = FirecrackerClient(
                firecrackerBinaryPath: firecrackerBinaryPath,
                socketDirectory: firecrackerSocketDir,
                logger: logger
            )
            hypervisorServices[.firecracker] = FirecrackerService(
                logger: logger,
                storage: storageBackend,
                imageSource: imageCacheService,
                vmStoragePath: vmStoragePath,
                firecrackerBinaryPath: firecrackerBinaryPath,
                socketDirectory: firecrackerSocketDir,
                firecrackerClient: firecrackerClient
            )

            // The sandbox runtime (issue #421) shares that client. It lights up only
            // when a guest base image (issue #419) is configured — the same
            // prerequisite the capability probe gates on — so a build without one
            // leaves `sandboxRuntime` nil and never attracts sandbox placements.
            if let sandboxGuestImagePath {
                // Resolve the jailer barrier (issue #425) once, at start: sandboxes
                // run untrusted workloads, so the production posture is jailed.
                // The config (layout) is built unconditionally — even an unjailed
                // agent needs it to re-adopt and tear down jailed orphans from a
                // previous life; the resolution only decides whether *new*
                // sandboxes get the barrier.
                let isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
                let jailerConfig = SandboxJailerConfig(
                    jailerBinaryPath: sandboxJailerBinaryPath,
                    chrootBaseDir: sandboxJailerChrootDir,
                    uidBase: sandboxJailerUidBase,
                    ipBinaryPath: SandboxJailerResolver.resolveIPBinaryPath(isExecutable: isExecutable),
                    tcBinaryPath: SandboxJailerResolver.resolveTCBinaryPath(isExecutable: isExecutable))
                sandboxJailerConfig = jailerConfig
                var jailNewSandboxes = false
                switch SandboxJailerResolver.resolve(
                    mode: sandboxJailerMode,
                    jailerBinaryPath: sandboxJailerBinaryPath,
                    isRoot: geteuid() == 0,
                    isExecutable: isExecutable
                ) {
                case .jailed:
                    jailNewSandboxes = true
                    logger.info(
                        "Sandbox jailer enabled",
                        metadata: [
                            "jailerBinaryPath": .string(sandboxJailerBinaryPath),
                            "chrootBaseDir": .string(sandboxJailerChrootDir),
                        ])
                case .unjailed(let reason):
                    if let reason {
                        logger.warning(
                            "Sandbox jailer unavailable — sandboxes will run UNJAILED. Set sandbox_jailer_mode = \"required\" to refuse instead.",
                            metadata: ["reason": .string(reason)])
                    }
                case .blocked(let reason):
                    // `required` unmet: keep the capability dark (see
                    // registerWithControlPlane) and make the runtime refuse
                    // creates. The runtime itself is still constructed —
                    // adopting, stopping, and deleting *existing* jailed
                    // sandboxes needs no new jailer spawn, and skipping it
                    // would leave their processes running unmanaged.
                    sandboxJailerBlockedReason = reason
                    logger.error(
                        "sandbox_jailer_mode is 'required' but the jailer is unusable; sandbox capability disabled",
                        metadata: ["reason": .string(reason)])
                }
                sandboxJailNewSandboxes = jailNewSandboxes

                logger.info("Initializing sandbox runtime (Linux only)")
                // Snapshot mobility (issue #428): exported artifacts move
                // through the control plane's transfer routes over SVID mTLS,
                // like image downloads. The downloader resolves the TLS
                // config per call, so building this before the SVID manager
                // exists is fine — no transfer can start before registration.
                let snapshotDownloader = makeMTLSArtifactDownloader()
                let snapshotTransfer = SnapshotArtifactTransfer(
                    controlPlaneBaseURL: controlPlaneHTTPBase,
                    downloadFile: { url, destination in
                        try await snapshotDownloader.downloadSnapshotArtifact(url: url, to: destination)
                    },
                    uploadFile: { url, source in
                        try await snapshotDownloader.uploadFile(url: url, fromFile: source)
                    }
                )
                sandboxRuntime = FirecrackerSandboxRuntime(
                    logger: logger,
                    client: firecrackerClient,
                    imageService: SandboxImageService(
                        logger: logger,
                        cacheRootPath: sandboxImageCachePath,
                        cacheMaxSizeBytes: sandboxImageCacheMaxSizeBytes
                    ),
                    socketDirectory: firecrackerSocketDir,
                    sandboxStoragePath: vmStoragePath,
                    guestImagePath: sandboxGuestImagePath,
                    firecrackerBinaryPath: firecrackerBinaryPath,
                    jailer: jailerConfig,
                    jailNewSandboxes: jailNewSandboxes,
                    jailerBlockedReason: sandboxJailerBlockedReason,
                    warmStartEnabled: sandboxWarmStart,
                    warmCacheBudgetBytes: sandboxWarmCacheMaxSizeBytes,
                    snapshotTransfer: snapshotTransfer
                )
            } else {
                logger.info("Sandbox guest image path not configured; sandbox runtime disabled")
            }
            #endif
        }

        // Bridge the sandbox runtime's exec events and workload log lines onto
        // the agent WebSocket (issue #423). The handlers yield synchronously so
        // ordering survives; the pump tasks below serialize the sends.
        if let sandboxRuntime {
            await sandboxRuntime.setSandboxLogHandler {
                [continuation = sandboxLogLinesContinuation] sandboxId, streamName, line in
                continuation.yield((sandboxId, streamName, line))
            }
            startSandboxPumps()
        }

        // The reconciler drives desired-state syncs onto the shared per-VM
        // lanes; all hypervisor side effects go through this agent (the
        // actuator), so it must exist before the message consumer starts.
        reconciler = Reconciler(
            actuator: self, queue: messageQueue, logger: logger, teardownGuard: teardownGuard,
            metadataStore: metadataStore)

        logger.info("Initializing console socket manager")
        consoleSocketManager = ConsoleSocketManager(logger: logger, eventLoopGroup: eventLoopGroup)
        await consoleSocketManager?.setOnConsoleData { [weak self] vmId, sessionId, data in
            await self?.sendConsoleData(vmId: vmId, sessionId: sessionId, data: data)
        }

        await consoleSocketManager?.setOnConsoleClosed { [weak self] vmId, sessionId, reason in
            await self?.sendConsoleDisconnected(vmId: vmId, sessionId: sessionId, reason: reason)
        }

        // Initialize SPIFFE/mTLS. A SPIRE-issued X.509 SVID is the agent's only
        // means of authenticating to the control plane, so it is mandatory:
        // missing config or a failed issuance is fatal, never a fallback.
        guard let spiffe = spiffeConfig, spiffe.enabled else {
            throw AgentError.spiffeConfigurationError(
                "SPIFFE authentication is not configured. The agent authenticates to the control plane with a "
                    + "SPIRE-issued X.509 SVID; add a [spiffe] section with enabled = true to the agent config file."
            )
        }

        let tlsConfiguration: TLSConfiguration?
        let controlPlanePinning: SPIFFEPeerPinning?
        logger.info(
            "Initializing SPIFFE authentication",
            metadata: [
                "trustDomain": .string(spiffe.trustDomain ?? SPIFFEConfig.defaultTrustDomain),
                "sourceType": .string(spiffe.sourceType ?? "workload_api"),
                "controlPlaneSPIFFEID": .string(spiffe.resolvedControlPlaneSPIFFEID),
            ])

        do {
            let spiffeClient = try createSPIFFEClient(config: spiffe)
            // The control plane's trust domain, not necessarily our own: with
            // per-org trust domains (issue #600) the agent is issued in
            // `org-<id>.<platform>` while the control plane stays in the
            // platform domain, so every peer verification has to select that
            // domain's federated roots rather than the SVID's own bundle.
            svidManager = SVIDManager(
                client: spiffeClient,
                logger: logger,
                peerTrustDomain: SPIFFEIdentity(uri: spiffe.resolvedControlPlaneSPIFFEID)?.trustDomain
            )
            try await svidManager?.start()

            // Get TLS configuration from SVID, and pin the control plane's
            // SPIFFE identity: chaining to the trust bundle alone would let
            // any workload in the trust domain impersonate the control plane
            // (issue #552).
            tlsConfiguration = try await svidManager?.getTLSConfiguration()
            controlPlanePinning = try await makeControlPlanePinning(spiffe: spiffe)
            logger.info("SPIFFE authentication initialized successfully")

            // Register for SVID rotation
            await svidManager?.onRotation { [weak self] _ in
                guard let self = self else { return }
                await self.handleSVIDRotation()
            }
        } catch {
            logger.error("Failed to initialize SPIFFE: \(error)")
            throw AgentError.spiffeConfigurationError(
                "SPIFFE is required to authenticate with the control plane but failed to initialize: \(error)"
            )
        }

        // Begin draining inbound frames before the connection opens so the registration
        // response (and any early frames) are processed in order.
        startMessageConsumer()

        logger.info("Connecting to control plane", metadata: ["url": .string(webSocketURL)])
        websocketClient = WebSocketClient(
            url: webSocketURL, agent: self, logger: logger, tlsConfiguration: tlsConfiguration,
            spiffePinning: controlPlanePinning,
            inboundContinuation: inboundContinuation)

        if let client = websocketClient {
            try await client.connect()
        }

        // Register with control plane
        try await registerWithControlPlane()

        // Heartbeats are driven by the WebSocket client's connection-scoped loop
        // (see WebSocketClient.startHeartbeat), so it stops firing while
        // disconnected and restarts on reconnect — no separate agent-side loop.

        isRunning = true
        logger.info("Agent started successfully")

        // Park until stop() (typically from a SIGINT/SIGTERM handler) or a
        // terminal failure resumes this continuation. If shutdown was already
        // requested while we were still starting up, stop() has already torn
        // everything down — skip parking so the process can exit.
        if !shutdownRequested {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.shutdownContinuation = continuation
            }
        }

        if let error = terminalError {
            throw error
        }
    }

    /// Wakes start() out of its run-forever suspension after an unrecoverable
    /// failure (set `terminalError` first). stop() deliberately does NOT use
    /// this: it resumes the continuation only after teardown completes, so the
    /// process doesn't exit mid-cleanup.
    private func signalShutdown() {
        shutdownRequested = true
        isRunning = false
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    func stop() async {
        logger.info("Stopping agent")
        shutdownRequested = true
        isRunning = false

        reconnectTask?.cancel()
        reconnectTask = nil

        networkConnectTask?.cancel()
        networkConnectTask = nil

        // Stop polling before the inbound stream is finished, so an in-flight
        // poll cannot deliver into a consumer that is already gone.
        await desiredStatePoller?.stop()
        desiredStatePoller = nil

        // Fail any in-flight registration wait so a caller parked on it (and its
        // timeout timer) doesn't linger past shutdown.
        if let continuation = takeRegistrationContinuation() {
            continuation.resume(throwing: AgentError.registrationSuperseded)
        }

        // Stop draining inbound frames; finishing the stream ends the consumer loop.
        inboundContinuation.finish()
        messageConsumerTask?.cancel()
        messageConsumerTask = nil

        // Stop the sandbox exec/log pumps the same way.
        sandboxExecEventsContinuation.finish()
        sandboxLogLinesContinuation.finish()
        sandboxExecPumpTask?.cancel()
        sandboxExecPumpTask = nil
        sandboxLogPumpTask?.cancel()
        sandboxLogPumpTask = nil

        // Unregister from control plane — but not when restarting into an
        // updated binary: the agent re-registers seconds later, and the
        // unregister both marks it offline and fails the control plane's
        // in-flight requests for it, which races the just-sent update success
        // reply (frames are handled in independent tasks over there) into a
        // spurious connectionLost/502.
        if !updateRestartPending {
            do {
                try await unregisterFromControlPlane()
            } catch {
                logger.error("Failed to unregister from control plane: \(error)")
            }
        }

        if let client = websocketClient {
            await client.disconnect()
            await client.shutdown()
        }
        websocketClient = nil
        hypervisorServices.removeAll()

        // Close the console pty channels and release the event loops they run
        // on. Neither used to be torn down here, so both outlived a "completed"
        // shutdown (issue #522).
        await consoleSocketManager?.disconnectAll()
        consoleSocketManager = nil
        do {
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.debug("Error shutting down agent event loop group: \(error)")
        }

        if let service = networkService {
            await service.disconnect()
        }
        networkService = nil

        // Stop SVID manager
        if let manager = svidManager {
            await manager.stop()
        }
        svidManager = nil

        // Clear the in-memory workload records; the on-disk manifest keeps them
        // for the next incarnation to recover as orphans.
        managedVMs.removeAll()
        orphanedVMs.removeAll()
        managedSandboxes.removeAll()
        orphanedSandboxes.removeAll()

        logger.info("Agent stopped")

        // Unblock start(), which parks on this continuation for the agent's
        // lifetime, so the process can exit cleanly.
        if let continuation = shutdownContinuation {
            shutdownContinuation = nil
            continuation.resume()
        }
    }

    // MARK: - SPIFFE Helpers

    private func createSPIFFEClient(config: SPIFFEConfig) throws -> any SPIFFEClientProtocol {
        let trustDomain = config.trustDomain ?? SPIFFEConfig.defaultTrustDomain
        let agentName = initialAgentID.replacingOccurrences(of: ".", with: "-")
        let spiffeID = SPIFFEIdentity(trustDomain: trustDomain, path: "/agent/\(agentName)")

        switch config.sourceType {
        case "files":
            guard let certPath = config.certificatePath,
                let keyPath = config.privateKeyPath,
                let bundlePath = config.trustBundlePath
            else {
                throw AgentError.spiffeConfigurationError(
                    "File-based SPIFFE requires certificate_path, private_key_path, and trust_bundle_path"
                )
            }

            logger.info(
                "Using file-based SPIFFE client",
                metadata: [
                    "certificatePath": .string(certPath),
                    "spiffeID": .string(spiffeID.uri),
                ])

            return FileSPIFFEClient(
                certificatePath: certPath,
                privateKeyPath: keyPath,
                trustBundlePath: bundlePath,
                spiffeID: spiffeID,
                logger: logger
            )

        case "workload_api", nil:
            let socketPath = config.workloadAPISocketPath ?? SPIFFEConfig.defaultWorkloadAPISocketPath

            logger.info(
                "Using Workload API SPIFFE client",
                metadata: [
                    "socketPath": .string(socketPath),
                    "spiffeID": .string(spiffeID.uri),
                ])

            return WorkloadAPISPIFFEClient(
                socketPath: socketPath,
                logger: logger
            )

        default:
            throw AgentError.spiffeConfigurationError(
                "Unknown SPIFFE source_type: \(config.sourceType ?? "nil"). Use 'files' or 'workload_api'"
            )
        }
    }

    /// Pinned control-plane identity built from the configured (or
    /// trust-domain-derived) control-plane SPIFFE ID and the roots the current
    /// SVID holds for *that identity's* trust domain — the SVID's own bundle
    /// in a single-domain deployment, its federated bundle for the platform
    /// domain once the agent lives in its org's domain (issue #600). Rebuilt
    /// on every rotation so rotated roots are picked up along with the SVID.
    private func makeControlPlanePinning(spiffe: SPIFFEConfig) async throws -> SPIFFEPeerPinning {
        guard let svidManager else {
            throw AgentError.spiffeConfigurationError("SVID manager not initialized")
        }
        let svid = try await svidManager.getSVID()
        return try SPIFFEPeerPinning(
            expectedSPIFFEID: spiffe.resolvedControlPlaneSPIFFEID,
            svid: svid)
    }

    /// The current SVID-backed client TLS configuration, looked up fresh so
    /// rotated SVIDs are picked up without any re-wiring. Throws until the
    /// SVID manager has started.
    private func currentSVIDTLSConfiguration() async throws -> TLSConfiguration {
        guard let svidManager else {
            throw AgentError.spiffeConfigurationError("no SVID is available yet for an mTLS download")
        }
        return try await svidManager.getTLSConfiguration()
    }

    /// Downloader for control-plane artifacts (images, typed artifacts,
    /// control-plane-hosted update binaries), authenticating with the agent's
    /// SVID over mTLS.
    private func makeMTLSArtifactDownloader() -> MTLSArtifactDownloader {
        MTLSArtifactDownloader(
            tlsConfigurationProvider: { [weak self] in
                guard let self else {
                    throw AgentError.spiffeConfigurationError("agent is shutting down")
                }
                return try await self.currentSVIDTLSConfiguration()
            },
            logger: logger
        )
    }

    /// Downloader for agent-update artifacts: URLs targeting the control
    /// plane's origin fetch over SVID mTLS (they sit behind the Envoy mTLS
    /// listener, issue #493); everything else — GitHub release URLs, `file://`
    /// overrides on air-gapped hosts — keeps the stock path.
    private func makeUpdateArtifactDownload() -> AgentUpdater.Downloader {
        let mtlsDownloader = makeMTLSArtifactDownloader()
        let base = controlPlaneHTTPBase
        return { url, destination in
            if MTLSArtifactDownloader.targetsOrigin(url, of: base) {
                try await mtlsDownloader.downloadArtifact(url: url, to: destination)
            } else {
                try await AgentUpdater.defaultDownload(from: url, to: destination)
            }
        }
    }

    private func handleSVIDRotation() async {
        logger.info("SVID rotated, updating WebSocket TLS configuration")

        do {
            guard let spiffe = spiffeConfig else {
                // Unreachable while SPIFFE is mandatory at startup; log rather
                // than return silently so a future refactor that loosens that
                // shows up as a rotation that stopped happening.
                logger.error("SVID rotated but no SPIFFE configuration is present; pinning not updated")
                return
            }
            let newTLSConfig = try await svidManager?.getTLSConfiguration()
            let newPinning = try await makeControlPlanePinning(spiffe: spiffe)
            if let client = websocketClient {
                await client.updateTLSConfiguration(newTLSConfig, spiffePinning: newPinning)
            }
            logger.info("WebSocket TLS configuration updated after SVID rotation")
        } catch {
            logger.error("Failed to update TLS configuration after SVID rotation: \(error)")
        }
    }

    /// Display-only capability string for a host that can back guest vTPMs.
    /// The scheduler keys placement on `AgentRegisterMessage.tpmCapable`.
    static let vtpmCapabilityName = "vtpm"

    private func registerWithControlPlane() async throws {
        let resources = await getAgentResources()

        // A network service that failed to connect earlier may be fixable by
        // now (OVS installed, ovn-controller restarted); retry once before
        // computing the networking capability so a fixed host re-advertises
        // ovn_networking on reconnect instead of after a restart.
        if networkService != nil, !networkServiceConnected {
            networkServiceConnected = await connectNetworkService()
        }

        // Probe on every registration (initial and reconnect) so the control
        // plane sees the host as it is now, not as it was at process start —
        // e.g. Firecracker installed or /dev/kvm permissions fixed since then.
        // The host preflight (storage directories, qemu-img, firmware,
        // OVN/OVS dependencies) runs on the same cadence and gates the
        // per-hypervisor probes: a host that cannot store VM disks must not
        // advertise any hypervisor, whatever the binary probes say.
        //
        // Simulation mode bypasses the probes and preflight entirely: there is
        // no real hypervisor to detect, so it advertises the mock backends as
        // available+accelerated to make the agent placement-eligible.
        let hypervisors: [HypervisorSupport]
        // Whether this host can back a guest TPM 2.0 (issue #565). Simulation
        // mode asserts it for the same reason it asserts the sandbox runtime:
        // the host artifact it checks for is meaningless to a mock backend, and
        // withholding it would make simulated fleets unusable for scale-testing
        // Windows-shaped placement.
        var swtpmAvailable = isSimulationMode
        if isSimulationMode {
            hypervisors = simulatedHypervisorSupport()
        } else {
            let preflight = runHostPreflight(libvirt: await probeLibvirt())
            swtpmAvailable = preflight.swtpmAvailable
            logHostPreflight(preflight)
            let probed = preflight.gate(
                HypervisorProbe.probeAll(
                    qemuBinaryPath: qemuBinaryPath,
                    firecrackerBinaryPath: firecrackerBinaryPath
                ))
            // Firecracker's binary version rides the registration (issue
            // #428): snapshot mobility keys cross-agent restore placement on
            // version equality, so the control plane needs to know what each
            // host would load snapshots with.
            hypervisors = HypervisorProbe.stampingFirecrackerVersion(
                probed,
                version: await HypervisorProbe.firecrackerVersion(binaryPath: firecrackerBinaryPath))
        }
        let networkCapability = currentNetworkCapability()
        var capabilities = getAgentCapabilities(hypervisors: hypervisors, networkCapability: networkCapability)

        // Sandbox runtime: probed on the same cadence, gated on Firecracker
        // (binary + KVM, folded into its probe) plus the guest base image
        // present on disk. The typed flag is what the scheduler keys sandbox
        // placement on (issue #415); the capability string is display-only.
        //
        // Simulation mode bypasses the host probe, mirroring the hypervisor
        // bypass above: the host artifacts it checks for (a real Firecracker,
        // the guest base image on disk) are meaningless for the mock runtime
        // (issue #470). The "never advertise what we cannot serve" invariant
        // holds either way, because capability additionally requires this
        // agent to actually hold a runtime that will serve the workload —
        // the host probe alone is necessary but not sufficient.
        let sandboxProbe: SandboxRuntimeProbe.Report
        if isSimulationMode {
            sandboxProbe = SandboxRuntimeProbe.Report(capable: true)
        } else {
            sandboxProbe = SandboxRuntimeProbe.probe(
                firecracker: hypervisors.first { $0.type == .firecracker },
                guestImagePath: sandboxGuestImagePath,
                jailerBlockedReason: sandboxJailerBlockedReason
            )
        }
        let sandboxCapable = sandboxProbe.capable && sandboxRuntime != nil
        if sandboxCapable {
            capabilities.append(SandboxRuntimeProbe.capabilityName)
            // The sandbox-snapshot capture capability rides the same gate, and
            // has to: `getAgentCapabilities` runs before the runtime probe, so
            // advertising it there would claim a backend this host may not
            // have. A capture admitted against a runtime-less agent lands in
            // desired state, fails permanently, and leaves the client polling a
            // `202` until the convergence deadline — the outcome capture
            // admission exists to prevent (STR-150).
            capabilities.append(SnapshotArtifactKind.sandboxSnapshot.agentCapability)
        } else if !isSimulationMode {
            #if os(Linux)
            // Only worth a log where the runtime could ever exist.
            let reason = sandboxProbe.unavailabilityReason ?? "sandbox runtime was not initialized"
            logger.info(
                "Sandbox runtime unavailable; not advertising sandbox capability",
                metadata: [
                    "reason": .string(reason)
                ])
            #endif
        }

        // vTPM capability: the typed flag is what the scheduler gates on; the
        // capability string is display-only, matching the sandbox pattern.
        if swtpmAvailable {
            capabilities.append(Self.vtpmCapabilityName)
        }

        let message = AgentRegisterMessage(
            agentId: initialAgentID,
            hostname: ProcessInfo.processInfo.hostName,
            version: BuildInfo.version,
            capabilities: capabilities,
            resources: resources,
            hypervisorType: hypervisorType,
            architecture: CPUArchitecture.current,
            hypervisors: hypervisors,
            networkCapability: networkCapability,
            sandboxCapable: sandboxCapable,
            tpmCapable: swtpmAvailable,
            operatingSystem: OperatingSystem.current,
            hostInfo: HostInfoProbe.gather(),
            // Declared up front so the control plane can stop pushing to this
            // agent from the moment it registers. Claiming pull mode here does
            // not commit us to it — if the control plane turns out to predate
            // the endpoint we never start the poller, and it never stopped
            // pushing either, because it applies the same version gate.
            pullsDesiredState: desiredStatePullEnabled
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.info("Registration message sent to control plane, waiting for response...")

        // Wait for registration response with timeout
        let assignedId = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            self.armRegistrationWait(continuation)
        }

        self.assignedAgentID = assignedId
        logger.info("Registration complete, assigned ID: \(assignedId)")

        // Give a state-sync control plane a fresh baseline right away — it
        // will also send us its desired state on registration, and the two
        // together converge any drift accumulated while disconnected.
        if controlPlaneSupportsStateSync {
            await sendObservedStateReport()
        }

        // Resume sandbox log shipping suspended while disconnected (issue
        // #423): follows pick up from their seq checkpoints, so output the
        // workloads produced during the gap ships from the guest ring buffers
        // now. Idempotent on the initial registration.
        await self.sandboxRuntime?.controlPlaneConnected()
    }

    /// Parks the given continuation as the pending registration wait and arms a
    /// 30s timeout bound to *this* attempt. Each attempt gets its own generation
    /// so a timeout from a superseded attempt can't fail a newer one, and the
    /// timeout task is tracked so resolving the registration cancels it instead of
    /// leaving it to fire (and leak) later.
    private func armRegistrationWait(_ continuation: CheckedContinuation<String, Error>) {
        // A prior attempt's continuation may still be parked — e.g. a reconnect
        // fired before the last attempt resolved. Fail it now (cancelling its
        // timeout) so it neither leaks its awaiter nor lets a stale timeout fire.
        if let stale = takeRegistrationContinuation() {
            stale.resume(throwing: AgentError.registrationSuperseded)
        }

        registrationGeneration &+= 1
        let generation = registrationGeneration
        registrationContinuation = continuation
        registrationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.failRegistrationOnTimeout(generation: generation)
        }
    }

    /// Fails the registration attempt identified by `generation`, but only if it
    /// is still the current one — a timeout inherited from a superseded attempt is
    /// ignored.
    private func failRegistrationOnTimeout(generation: UInt64) {
        guard generation == registrationGeneration else { return }
        guard let continuation = takeRegistrationContinuation() else { return }
        continuation.resume(throwing: AgentError.registrationTimeout)
    }

    /// Clears the pending registration continuation and cancels its bound timeout,
    /// returning the continuation so the caller can resume it exactly once. Returns
    /// nil when no registration is currently pending.
    private func takeRegistrationContinuation() -> CheckedContinuation<String, Error>? {
        guard let continuation = registrationContinuation else { return nil }
        registrationContinuation = nil
        registrationTimeoutTask?.cancel()
        registrationTimeoutTask = nil
        return continuation
    }

    /// Handle registration response from control plane
    func handleRegistrationResponse(_ response: AgentRegisterResponseMessage) async {
        let controlPlaneProtocolVersion = response.protocolVersion ?? 0
        guard WireProtocol.supportsStateSync(controlPlaneProtocolVersion) else {
            let reason =
                "Control plane wire protocol version \(controlPlaneProtocolVersion) predates desired-state sync; "
                + "the imperative VM lifecycle protocol has been removed. Upgrade the control plane."
            logger.error("Registration rejected: \(reason)")
            if let continuation = takeRegistrationContinuation() {
                continuation.resume(throwing: AgentError.registrationRejected(reason))
            }
            return
        }

        if controlPlaneProtocolVersion != WireProtocol.currentVersion {
            logger.warning(
                "Control plane wire protocol version differs from agent",
                metadata: [
                    "controlPlaneProtocolVersion": .stringConvertible(controlPlaneProtocolVersion),
                    "agentProtocolVersion": .stringConvertible(WireProtocol.currentVersion),
                ])
        }
        controlPlaneSupportsStateSync = WireProtocol.supportsStateSync(controlPlaneProtocolVersion)
        await startDesiredStatePollerIfSupported(controlPlaneVersion: controlPlaneProtocolVersion)

        guard let continuation = takeRegistrationContinuation() else {
            logger.warning("Received registration response but no continuation waiting")
            return
        }
        continuation.resume(returning: response.agentId)
    }

    /// Start the desired-state long-poll loop, if both sides want it
    /// (STR-146). Called from every registration response, initial and
    /// reconnect; `DesiredStatePoller.start()` is idempotent, so a reconnect
    /// keeps the existing loop and its ETag rather than restarting from a full
    /// fetch.
    ///
    /// A control plane too old to serve the endpoint leaves the agent on the
    /// pushed transport, which is exactly what that control plane is still
    /// doing — it ignores the `pullsDesiredState` field it has never heard of.
    private func startDesiredStatePollerIfSupported(controlPlaneVersion: Int) async {
        guard desiredStatePullEnabled else { return }
        guard WireProtocol.supportsDesiredStatePull(controlPlaneVersion) else {
            logger.notice(
                "Control plane predates the desired-state pull endpoint; staying on pushed syncs",
                metadata: ["controlPlaneProtocolVersion": .stringConvertible(controlPlaneVersion)])
            return
        }
        guard desiredStatePoller == nil else {
            await desiredStatePoller?.start()
            return
        }

        guard let url = URL(string: controlPlaneHTTPBase + Self.desiredStatePollPath) else {
            logger.error(
                "Could not build the desired-state poll URL; staying on pushed syncs",
                metadata: ["base": .string(controlPlaneHTTPBase)])
            return
        }

        // The downloader is built per poller rather than per request, but it
        // still resolves the TLS configuration on every call, so a rotated SVID
        // is picked up by the next poll without restarting anything.
        let downloader = MTLSArtifactDownloader(
            tlsConfigurationProvider: { [weak self] in
                guard let self else {
                    throw AgentError.spiffeConfigurationError("agent is shutting down")
                }
                return try await self.currentSVIDTLSConfiguration()
            },
            logger: logger,
            timeouts: .longPoll
        )

        let poller = DesiredStatePoller(
            fetch: { ifNoneMatch in
                try await downloader.poll(url: url, ifNoneMatch: ifNoneMatch)
            },
            deliver: { [weak self] envelope in
                // Straight onto the same inbound path a pushed frame takes, so
                // a polled sync lands on the `.desiredState` serialization lane
                // and inherits the ordering guarantees the reconciler relies on.
                await self?.routeInboundMessage(envelope)
            },
            logger: logger,
            fullRefetchInterval: desiredStateFullRefetchInterval
        )
        desiredStatePoller = poller
        await poller.start()
        logger.info(
            "Desired state is now fetched by long-poll",
            metadata: [
                "url": .string(url.absoluteString),
                "fullRefetchSeconds": .stringConvertible(desiredStateFullRefetchInterval.components.seconds),
            ])
    }

    /// The control-plane path serving the desired-state long-poll. Under
    /// `/agent/` because that is the prefix Envoy routes with no timeout.
    private static let desiredStatePollPath = "/agent/desired-state"

    /// Handle an `error` envelope from the control plane.
    ///
    /// Previously these fell through to the `default` case and were logged as
    /// "unknown message type: error", discarding the real reason (e.g. an
    /// unrecognized agent identity). Now the reason is surfaced.
    ///
    /// If registration is still pending — we're waiting on `registrationContinuation`
    /// — the control plane has rejected this connection (it sends such errors with an
    /// empty `requestId` and closes the socket). Fail the registration with the real
    /// reason instead of letting it time out after 30s; the caller (initial start or
    /// the reconnect loop) then surfaces it and retries as appropriate.
    func handleErrorResponse(_ message: ErrorMessage) async {
        let detailSuffix = message.details.map { " (\($0))" } ?? ""

        if let continuation = takeRegistrationContinuation() {
            logger.error("Registration failed: \(message.error)\(detailSuffix)")
            // Only an explicit terminal code — a credential rejection, or a
            // protocol version the control plane refuses to drive — should
            // stop the reconnect loop; retrying either can never succeed
            // without operator action. Anything else, including envelopes
            // from control planes that predate the code field, is treated as
            // transient so the reconnect loop keeps backing off instead of
            // exiting.
            if message.code == ErrorMessage.ErrorCode.invalidToken
                || message.code == ErrorMessage.ErrorCode.unsupportedProtocolVersion
            {
                continuation.resume(throwing: AgentError.registrationRejected(message.error))
            } else {
                continuation.resume(throwing: AgentError.registrationFailed(message.error))
            }
            return
        }

        logger.error(
            "Control plane reported an error: \(message.error)\(detailSuffix)",
            metadata: [
                "requestId": .string(message.requestId)
            ])
    }

    /// The networking capability to report at registration, reflecting the
    /// backend selected at startup rather than the platform: a Linux agent
    /// configured for user-mode networking cannot provide OVN/VM-to-VM
    /// networking, and the scheduler relies on this to enforce the
    /// inter-VM-networking placement constraint.
    private func currentNetworkCapability() -> NetworkCapability? {
        switch (effectiveNetworkMode, networkServiceConnected) {
        case (.ovn, true):
            return .overlay
        case (.ovn, false):
            // OVN was selected but the OVN/OVS connection failed at startup:
            // report no networking capability rather than claiming VM-to-VM
            // support the backend cannot currently provide (and user-mode
            // would be a lie — the agent is not running SLIRP either).
            logger.warning("OVN network service not connected; not advertising ovn_networking capability")
            return nil
        case (.user, _):
            // User-mode (SLIRP) networking is built into QEMU and needs no
            // external service, so it is not gated on connection state.
            return .userMode
        }
    }

    /// Legacy string capability list, derived from the same probes that back
    /// the structured `hypervisors` report instead of hardcoded platform
    /// lists. Advertised hypervisors are hard placement constraints, so each
    /// one is gated on its probe (binary executable, and KVM for Firecracker)
    /// — the scheduler must not route VMs here that create would reject.
    private func getAgentCapabilities(hypervisors: [HypervisorSupport], networkCapability: NetworkCapability?)
        -> [String]
    {
        var capabilities = ["vm_management"]

        // Message-set capabilities: message types added after protocol
        // version 1 are advertised here so the control plane skips agents
        // that would silently drop the frame (an undecodable MessageType
        // fails envelope decoding before any error response can be sent,
        // leaving the control plane to time out).
        // Snapshot-artifact capabilities (STR-150). Since wire v33 these name
        // no message: a capture is desired state, and the version gate already
        // says the sync's `snapshots` list will be understood. What a version
        // cannot say is whether a *backend that can realize the capture* is
        // usable on this host — the `sandboxCapable` rule — so each family is
        // advertised separately and only when its backend is really there.
        //
        // The control plane reads these at capture admission: a checkpoint
        // requested against a host with no QEMU would otherwise be accepted
        // into a desired state that can only ever fail permanently.
        //
        // QEMU is the backend for two of the three: a VM checkpoint is a qcow2
        // internal snapshot, and a volume snapshot is a qcow2 overlay the
        // storage backend writes with `qemu-img`. The sandbox family's gate is
        // the sandbox runtime probe, which is not resolved until after this
        // returns — it is advertised beside `sandboxCapable` in
        // `registerWithControlPlane` instead.
        if hypervisors.contains(where: { $0.type == .qemu && $0.available }) {
            capabilities.append(SnapshotArtifactKind.vmCheckpoint.agentCapability)
            capabilities.append(SnapshotArtifactKind.volumeSnapshot.agentCapability)
        }

        for hypervisor in hypervisors {
            if hypervisor.available {
                capabilities.append(hypervisor.type.rawValue)
            } else if hypervisor.type == .qemu {
                // Error, not warning: without QEMU the agent is unusable for
                // most placements, and the scheduler will only report
                // "unsupported hypervisor" — this log points at the cause.
                logger.error(
                    "QEMU unusable; not advertising qemu capability",
                    metadata: [
                        "reason": .string(hypervisor.unavailabilityReason ?? "unknown"),
                        "qemuBinaryPath": .string(qemuBinaryPath),
                    ])
            } else {
                #if os(Linux)
                // Not worth a log on platforms where the backend can never
                // exist (e.g. Firecracker on macOS).
                logger.warning(
                    "\(hypervisor.type.displayName) unusable; not advertising \(hypervisor.type.rawValue) capability",
                    metadata: [
                        "reason": .string(hypervisor.unavailabilityReason ?? "unknown")
                    ])
                #endif
            }
        }

        if hypervisors.contains(where: { $0.accelerated }) {
            #if os(Linux)
            capabilities.append("kvm")
            #elseif os(macOS)
            capabilities.append("hvf")
            #endif
        }

        switch networkCapability {
        case .overlay:
            capabilities.append("ovn_networking")
        case .userMode:
            capabilities.append("user_networking")
        case nil:
            break  // backend selected but not connected; advertise nothing
        }

        if !HypervisorType.allCases.contains(where: { capabilities.contains($0.rawValue) }) {
            logger.error(
                "No usable hypervisor backend on this host; the agent will register but never be eligible for VM placement. Check qemu_binary_path (and firecracker_binary_path on Linux) in the agent configuration.",
                metadata: [
                    "qemuBinaryPath": .string(qemuBinaryPath)
                ])
        }

        return capabilities
    }

    private func unregisterFromControlPlane() async throws {
        let message = AgentUnregisterMessage(
            agentId: effectiveAgentID,
            reason: "Agent shutdown"
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.info("Unregistration message sent to control plane")
    }

    /// The hypervisor support to advertise in simulation mode: the mock
    /// backends this agent actually registered, reported as available and
    /// hardware-accelerated so the scheduler treats the dummy as a fully capable
    /// host. Derived from `HypervisorType.allCases`, exactly like the mock
    /// registration in `start()`, so the two cannot drift apart and a new
    /// backend is simulated the moment it has an enum case.
    private func simulatedHypervisorSupport() -> [HypervisorSupport] {
        HypervisorType.allCases.map { type in
            HypervisorSupport(
                type: type,
                available: true,
                accelerated: true,
                capabilities: HypervisorCapabilities.capabilities(for: type)
            )
        }
    }

    // MARK: - Host preflight

    /// Probes libvirtd, whose reachability and version the preflight checks.
    /// Linux-only: libvirt's QEMU driver is, and the whole point of the probe is
    /// the daemon a hypervisor node manages VMs through.
    ///
    /// Spawns a subprocess, hence async and separate from `runHostPreflight` —
    /// the same split `HypervisorProbe.firecrackerVersion` uses.
    private func probeLibvirt() async -> LibvirtProbe.Status? {
        #if os(Linux)
        return await LibvirtProbe.probe()
        #else
        return nil
        #endif
    }

    /// Runs the host-readiness checks against this agent's resolved
    /// configuration. Called at every registration (initial and reconnect) so
    /// the reported capabilities always reflect the host as it is now.
    private func runHostPreflight(libvirt: LibvirtProbe.Status? = nil) -> HostPreflight.Report {
        #if os(Linux)
        let firecrackerSocketDirectory: String? = firecrackerSocketDir
        let qemuFirmwareDescriptorPath: String? = "/usr/share/qemu/firmware"
        #else
        let firecrackerSocketDirectory: String? = nil
        let qemuFirmwareDescriptorPath: String? = nil
        #endif

        // Mirror QEMUService's firmware resolution so the preflight reports
        // what a VM would actually boot with: the split pair's CODE image when
        // one resolves, else the monolithic `-bios` fallback (issue #565).
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
                swtpmBinaryPath: swtpmBinaryPath,
                qemuFirmwareDescriptorPath: qemuFirmwareDescriptorPath,
                libvirt: libvirt,
                ovnMode: effectiveNetworkMode == .ovn,
                ovnNBConnection: ovnNorthbound ?? "unix:/var/run/ovn/ovnnb_db.sock",
                ovnNBTLSFilePaths: ovnNorthboundTLS?.configuredFilePaths ?? []
            ))
    }

    /// Logs every failed preflight check with its remediation — gating
    /// failures as errors, advisory ones as warnings — so a misconfigured
    /// host explains itself at startup instead of failing VM operations
    /// minutes later.
    private func logHostPreflight(_ report: HostPreflight.Report) {
        for failure in report.failures {
            let detail = failure.detail ?? failure.kind.rawValue
            let metadata: Logger.Metadata = ["check": .string(failure.kind.rawValue)]
            switch failure.severity {
            case .gating:
                logger.error("Host preflight failed: \(detail)", metadata: metadata)
            case .advisory:
                logger.warning("Host preflight failed: \(detail)", metadata: metadata)
            case .informational:
                // Not a fault with this host: a dependency this build does not
                // use yet. Both the level and the wording stay calm — warning
                // "failed" here would have every node in every fleet reporting a
                // non-problem on every reconnect.
                logger.info("Host preflight note: \(detail)", metadata: metadata)
            }
        }
    }

    // MARK: - Network service connection

    private struct NetworkConnectTimeout: Error, LocalizedError {
        let seconds: Int64
        var errorDescription: String? {
            "network service connect timed out after \(seconds)s — are the OVN/OVS daemons responsive?"
        }
    }

    /// Attempts to connect the network service, bounded by a timeout so a
    /// hung OVN/OVS database socket cannot stall agent startup indefinitely
    /// (the underlying connect has no deadline of its own). The budget covers
    /// the database connects plus chassis bootstrap and the ovn-controller
    /// connection check (which polls for several seconds on an unhealthy
    /// host). Returns whether the service is connected.
    private func connectNetworkService(timeoutSeconds: Int64 = 30) async -> Bool {
        guard let service = networkService else { return false }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await service.connect() }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw NetworkConnectTimeout(seconds: timeoutSeconds)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            logger.info("Network service connected successfully")
            return true
        } catch {
            logger.warning("Failed to connect to network service: \(error.localizedDescription)")
            return false
        }
    }

    /// Starts the background loop that keeps retrying a failed network
    /// service connection with backoff. Guarded against duplicates.
    private func startNetworkReconnectLoop() {
        guard networkConnectTask == nil else { return }
        networkConnectTask = Task { [weak self] in
            await self?.runNetworkReconnectLoop()
        }
    }

    /// Retries the network service connection with exponential backoff. On
    /// success, re-registers with the control plane (registration is an
    /// idempotent upsert) so the recovered networking capability is
    /// advertised immediately instead of after the next reconnect or restart.
    private func runNetworkReconnectLoop() async {
        defer { networkConnectTask = nil }

        var delaySeconds = 5.0
        let maxDelaySeconds = 60.0

        while !shutdownRequested, !networkServiceConnected {
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                return  // cancelled (agent stopping)
            }
            guard !shutdownRequested else { return }

            // Reset any half-open state left by the failed (or timed-out)
            // attempt before dialing again.
            if let service = networkService {
                await service.disconnect()
            }

            if await connectNetworkService() {
                networkServiceConnected = true
                logger.info("Network service connected after retry")
                if assignedAgentID != nil {
                    do {
                        try await registerWithControlPlane()
                        logger.info("Re-registered with control plane to advertise recovered networking capability")
                    } catch {
                        logger.warning(
                            "Could not refresh registration after network recovery; capability updates on next reconnect: \(error)"
                        )
                    }
                }
                return
            }

            delaySeconds = min(delaySeconds * 2, maxDelaySeconds)
        }
    }

    // MARK: - Reconnection

    /// Called by the WebSocket client when the connection to the control plane drops
    /// unexpectedly. Starts a single reconnection loop (guarded against duplicates).
    func handleConnectionLost() async {
        guard isRunning else { return }
        guard reconnectTask == nil else {
            logger.debug("Reconnection already in progress; ignoring duplicate signal")
            return
        }

        logger.warning("Lost connection to control plane; beginning reconnection with backoff")

        // The control plane tears down this agent's console sessions when our
        // socket drops (otherwise browser terminals freeze), and browsers must
        // re-establish once we reconnect. Close our side's console pty channels
        // now so they don't leak — the eventual browser-socket close on the
        // control plane no-ops on the already-deleted session and never sends
        // us a disconnect for them.
        await consoleSocketManager?.disconnectAll()

        // Quiesce sandbox streams for the gap (issue #423): live exec sessions
        // end (their frontends are unreachable and the control plane cannot
        // close them over a dead socket), and log follows suspend so workload
        // output waits in the guest ring buffers instead of being consumed
        // toward a socket that cannot deliver it. Registration restarts the
        // follows.
        await sandboxRuntime?.controlPlaneDisconnected()

        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    /// Repeatedly attempts to reconnect to the control plane with exponential backoff
    /// and jitter, re-registering on success. Runs until reconnected or the agent stops.
    private func runReconnectLoop() async {
        defer { reconnectTask = nil }

        var delaySeconds = 1.0
        let maxDelaySeconds = 30.0

        while isRunning {
            // Backoff with jitter to avoid thundering-herd reconnects across many agents.
            let jitter = Double.random(in: 0...(delaySeconds * 0.3))
            do {
                try await Task.sleep(for: .seconds(delaySeconds + jitter))
            } catch {
                return  // cancelled (agent stopping)
            }

            guard isRunning else { return }

            do {
                try await websocketClient?.connect()
                try await registerWithControlPlane()
                logger.info("Successfully reconnected and re-registered with control plane")
                return
            } catch AgentError.registrationRejected(let reason) {
                // The control plane explicitly rejected this agent's identity —
                // retrying with the same SVID can never succeed, so exit with
                // instructions instead of hammering a rejected identity.
                logger.error("Registration rejected by control plane: \(reason)")
                logger.error(
                    "Verify the SPIRE registration entry for this agent's SPIFFE ID, and that the control plane trusts the same trust domain."
                )
                await websocketClient?.disconnect()
                terminalError = AgentError.registrationRejected(reason)
                signalShutdown()
                return
            } catch {
                logger.error("Reconnection attempt failed, will retry: \(error)")
                // Tear down any half-open socket from this attempt (connect succeeded
                // but registration failed or timed out) so the next attempt starts
                // from a clean state instead of stacking connections. disconnect()
                // marks the close intentional, so it won't trigger a second loop.
                await websocketClient?.disconnect()
                delaySeconds = min(delaySeconds * 2, maxDelaySeconds)
            }
        }
    }

    func sendHeartbeat() async {
        do {
            try await _sendHeartbeat()
        } catch {
            logger.error("Failed to send heartbeat: \(error)")
        }
    }

    private func _sendHeartbeat() async throws {
        // Only send heartbeat if we have an assigned ID from registration
        guard assignedAgentID != nil else {
            logger.debug("Skipping heartbeat - not yet registered")
            return
        }

        // Retry a manifest that could not be *read*, so a host quarantined by a
        // transient cause recovers on its own (STR-138).
        retryManifestLoadIfQuarantined()

        // Retry a failed manifest write so a transient disk error can't leave the
        // on-disk manifest permanently behind the in-memory VM records.
        if manifestPersistFailed {
            persistManifest()
            if !manifestPersistFailed {
                logger.info("VM manifest write recovered on heartbeat retry")
            }
        }

        let resources = await getAgentResources()
        let runningVMs = await getRunningVMList()

        let message = AgentHeartbeatMessage(
            agentId: effectiveAgentID,
            resources: resources,
            runningVMs: runningVMs
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.debug("Heartbeat sent", metadata: ["agentId": .string(effectiveAgentID)])

        // Refresh the guest-agent view on the slow-poll cadence before the
        // report reads it (issue #563). Throttled and bounded, so most
        // heartbeats skip it and a slow probe can never stall the beat.
        if controlPlaneSupportsStateSync {
            await refreshGuestInfoCacheIfDue()
        }

        // On the same cadence, re-assert full observed state to a state-sync
        // control plane. The heartbeat keeps liveness/presence; the report is
        // the periodic correctness backstop for VM state (issue #260).
        if controlPlaneSupportsStateSync {
            // Bounded as a whole: the report walks every VM, and it runs on the
            // heartbeat's own task, so an overlong report delays the *next*
            // beat. Skipping one is harmless — it is a periodic backstop and
            // the next round re-drives it (issue #516).
            //
            // `.abandon` despite the report having an effect (it transmits):
            // `sendObservedStateReport` stamps an epoch and re-checks it
            // immediately before sending, so an abandoned report finds itself
            // superseded and drops instead of applying a stale full-list view
            // over a newer one. Remove that guard and this must become
            // `.cancelAndWait`.
            do {
                try await StageBudget.run(
                    seconds: 15, stage: "observed-state-report", onTimeout: .abandon
                ) { [self] in
                    await sendObservedStateReport()
                }
            } catch {
                logger.warning("Observed-state report exceeded its budget; skipping this round")
            }
        }
    }

    /// Refreshes the guest-info and balloon memory-stats caches for running
    /// QEMU VMs, but only once the slow-poll interval has elapsed. Probes run
    /// concurrently (each bounded inside `QEMUService`), and the whole pass is
    /// bounded here so a fleet of unresponsive guests can't stall the
    /// heartbeat. The caches are replaced wholesale, so VMs that stopped
    /// running or were deleted drop out.
    private func refreshGuestInfoCacheIfDue() async {
        let now = ContinuousClock.now
        if let last = lastGuestInfoRefresh, now - last < Self.guestInfoRefreshInterval {
            return
        }
        lastGuestInfoRefresh = now

        guard let qemu = hypervisorServices[.qemu] as? QEMUService else { return }
        let qemuVMIds = managedVMs.compactMap { $0.value.hypervisorType == .qemu ? $0.key : nil }
        guard !qemuVMIds.isEmpty else {
            guestInfoCache = [:]
            memoryStatsCache = [:]
            return
        }

        do {
            let observations = try await StageBudget.run(
                seconds: 15, stage: "guest-info-refresh", onTimeout: .abandon
            ) {
                await Self.probeGuestObservations(vmIds: qemuVMIds, using: qemu)
            }
            guestInfoCache = observations.guestInfo
            memoryStatsCache = observations.memoryStats
        } catch {
            // A whole-pass timeout leaves the previous caches in place; the
            // next slow poll retries. Individual probes already degrade to nil.
            logger.debug("Guest-info refresh exceeded its budget; keeping the previous cache")
        }
    }

    /// Concurrently probes each VM's guest agent and balloon device (each
    /// probe bounded inside `QEMUService`), returning only the VMs that
    /// answered. A VM must be observed running before we probe — qga on a
    /// stopped VM just times out, and a stopped VM has no stats socket.
    private static func probeGuestObservations(
        vmIds: [String], using qemu: QEMUService
    ) async -> (guestInfo: [String: GuestInfo], memoryStats: [String: VMMemoryStats]) {
        await withTaskGroup(of: (String, GuestInfo?, VMMemoryStats?).self) { group in
            for vmId in vmIds {
                group.addTask {
                    let status = (try? await qemu.getVMStatus(vmId: vmId)) ?? .unknown
                    guard status == .running else { return (vmId, nil, nil) }
                    return (vmId, await qemu.guestInfo(vmId: vmId), await qemu.memoryStats(vmId: vmId))
                }
            }
            var guestInfo: [String: GuestInfo] = [:]
            var memoryStats: [String: VMMemoryStats] = [:]
            for await (vmId, info, stats) in group {
                if let info { guestInfo[vmId] = info }
                if let stats { memoryStats[vmId] = stats }
            }
            return (guestInfo, memoryStats)
        }
    }

    private func getAgentResources() async -> AgentResources {
        // Host capacity. In simulation mode this is the configured fake capacity
        // — many dummies share one physical machine, so a spawner varies these
        // to give the scheduler a realistic spread of host sizes. Otherwise it
        // is probed live from the machine the agent runs on.
        let totalCPU: Int
        let totalMemory: Int64
        if let simulation, simulation.enabled {
            totalCPU = simulation.resolvedCPUCores
            totalMemory = simulation.resolvedMemoryBytes
        } else {
            totalCPU = HostResources.logicalCoreCount
            totalMemory = HostResources.physicalMemoryBytes
        }

        // Resources committed to VMs currently managed on this host. We report
        // available = total - reserved (1:1, no overcommit) so the scheduler treats
        // CPU/memory as hard constraints; overcommit ratios can be layered on later.
        var reservedCPU = 0
        var reservedMemory: Int64 = 0

        for (type, service) in hypervisorServices {
            // Falls back to the manifest, never to nothing: under-reporting
            // reservations advertises capacity this host does not have and
            // invites the scheduler to over-place.
            let reserved =
                await observe(type, "reserved-resources") {
                    await service.reservedResources()
                } ?? manifestReservations(for: type)
            reservedCPU += reserved.vcpus
            reservedMemory += reserved.memoryBytes
        }

        // VMs orphaned by a restart are not managed by any service, but their
        // hypervisor processes may still be running — the scheduler must not hand
        // their capacity to new placements until they are deleted or re-created.
        for entry in orphanedVMs.values {
            reservedCPU += entry.spec.cpus
            reservedMemory += entry.spec.memoryBytes
        }

        // Sandbox reservations always come from the manifest (managed and
        // orphaned alike): the sandbox runtime seam has no reservation query,
        // and the manifest entry is authoritative for the workload's sizing.
        for entry in managedSandboxes.values {
            reservedCPU += entry.spec.cpus
            reservedMemory += entry.spec.memoryBytes
        }
        for entry in orphanedSandboxes.values {
            reservedCPU += entry.spec.cpus
            reservedMemory += entry.spec.memoryBytes
        }

        // Workloads whose manifest entry this build cannot route (STR-138) are
        // still running; only the routing was lost, not the sizing. They
        // reserve exactly like an orphan — an entry we can't act on is the
        // last thing whose capacity should be handed to a new placement.
        for entry in quarantinedWorkloads.values {
            reservedCPU += entry.cpus
            reservedMemory += entry.memoryBytes
        }

        // An unreadable manifest means this host's contents are unknown, and
        // unknown has to advertise as full rather than empty (STR-138). The
        // alternative is what this replaced: a node running 40 VMs whose
        // manifest failed to decode reported its whole machine as free, and
        // `least_loaded` preferentially filled it — over-committing memory on a
        // host whose guests are all live.
        let inventoryUnknown = manifestReadFailure != nil
        let availableCPU = inventoryUnknown ? 0 : max(0, totalCPU - reservedCPU)
        let availableMemory = inventoryUnknown ? 0 : max(0, totalMemory - reservedMemory)

        // Disk. In simulation mode the total is the configured fake capacity
        // (the real filesystem is shared by every dummy and has nothing to do
        // with the sizes we're modeling), and committed disk is subtracted from
        // it manifest-side, mirroring the CPU/memory accounting above: the
        // manifest carries each VM's `diskBytes` from both the vmCreate and
        // reconciliation paths, and orphans keep reserving across restarts
        // (issue #473). Sandboxes reserve no disk, matching the scheduler.
        // Otherwise query the storage filesystem live — VM disks are created
        // directly on it, so this naturally accounts for existing disks
        // without tracking reservations.
        let totalDisk: Int64
        let availableDisk: Int64
        if let simulation, simulation.enabled {
            totalDisk = simulation.resolvedDiskBytes
            let reservedDisk =
                managedVMs.values.totalReservedDiskBytes + orphanedVMs.values.totalReservedDiskBytes
                + quarantinedWorkloads.values.reduce(0) { $0 + $1.diskBytes }
            availableDisk = inventoryUnknown ? 0 : max(0, totalDisk - reservedDisk)
        } else {
            let disk = HostResources.diskCapacity(forPath: vmStoragePath)
            if disk == nil {
                logger.warning(
                    "Unable to determine disk capacity for VM storage path",
                    metadata: [
                        "path": .string(vmStoragePath)
                    ])
            }
            totalDisk = disk?.total ?? 0
            availableDisk = inventoryUnknown ? 0 : (disk?.free ?? 0)
        }

        return AgentResources(
            totalCPU: totalCPU,
            availableCPU: availableCPU,
            totalMemory: totalMemory,
            availableMemory: availableMemory,
            totalDisk: totalDisk,
            availableDisk: availableDisk
        )
    }

    private func getRunningVMList() async -> [String] {
        var vmList: [String] = []

        for (type, service) in hypervisorServices {
            // Falls back to the manifest rather than omitting the hypervisor.
            // This list is not advisory: the control plane treats a VM absent
            // from the heartbeat as lost and sets it to `.error`
            // (`reconcileVMs`), so reporting a *short* list because a poll
            // timed out would corrupt the state of healthy VMs.
            let vms =
                await observe(type, "list-vms") {
                    await service.listVMs()
                } ?? manifestVMIds(for: type)
            vmList.append(contentsOf: vms)
        }

        return vmList
    }

    /// VMs this agent manages on `type`, from the durable manifest. Matches
    /// what a hypervisor's `listVMs()` reports (its managed set), so it stands
    /// in faithfully when the live query does not answer.
    private func manifestVMIds(for type: HypervisorType) -> [String] {
        managedVMs.compactMap { $0.value.hypervisorType == type ? $0.key : nil }
    }

    /// Reservations for `type` from the durable manifest, which carries every
    /// managed VM's sizing — authoritative, not a guess.
    private func manifestReservations(for type: HypervisorType) -> (vcpus: Int, memoryBytes: Int64) {
        var vcpus = 0
        var memoryBytes: Int64 = 0
        for entry in managedVMs.values where entry.hypervisorType == type {
            vcpus += entry.spec.cpus
            memoryBytes += entry.spec.memoryBytes
        }
        return (vcpus, memoryBytes)
    }

    /// Query a hypervisor for reporting purposes under a short budget,
    /// returning nil if it does not answer in time.
    ///
    /// These calls exist only to describe the host, but they run on the
    /// hypervisor's actor alongside real work. Before issue #516 the heartbeat
    /// awaited them unbounded, so one stuck hypervisor call stopped every
    /// subsequent heartbeat and the control plane marked a live agent offline.
    /// A stale-but-recent answer is far better than no heartbeat at all.
    private func observe<T: Sendable>(
        _ type: HypervisorType,
        _ stage: String,
        _ query: @escaping @Sendable () async -> T
    ) async -> T? {
        do {
            return try await StageBudget.run(
                seconds: StageBudget.observationSeconds, stage: stage, onTimeout: .abandon
            ) {
                await query()
            }
        } catch {
            logger.warning(
                "Hypervisor did not answer an observation query in time; reporting last known state",
                metadata: [
                    "hypervisor": .string(type.rawValue),
                    "stage": .string(stage),
                ])
            return nil
        }
    }
}

// MARK: - Message Handling

extension Agent {
    /// Start the single consumer that drains the ordered inbound stream. Idempotent, so
    /// repeated calls (e.g. across reconnects) reuse the existing consumer.
    private func startMessageConsumer() {
        guard messageConsumerTask == nil else { return }
        let stream = inboundMessages
        messageConsumerTask = Task { [weak self] in
            for await envelope in stream {
                await self?.routeInboundMessage(envelope)
            }
        }
    }

    /// Route a decoded inbound frame onto its per-resource serial lane. Frames for the same
    /// resource run in arrival order; frames for unrelated resources run concurrently.
    private func routeInboundMessage(_ envelope: MessageEnvelope) async {
        await messageQueue.enqueue(keys: envelope.serializationKeys) { [weak self] in
            await self?.handleMessage(envelope)
        }
    }

    func handleMessage(_ envelope: MessageEnvelope) async {
        logger.debug(
            "Handling message from control plane",
            metadata: [
                "type": .string(envelope.type.rawValue)
            ])

        do {
            switch envelope.type {
            case .agentRegisterResponse:
                let message = try envelope.decode(as: AgentRegisterResponseMessage.self)
                await handleRegistrationResponse(message)
            case .vmReboot:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMReboot(message)
            // Full-VM restore (issue #564). Capture and delete are desired
            // state since wire v33 (STR-150).
            case .vmRestore:
                let message = try envelope.decode(as: VMRestoreMessage.self)
                await handleVMRestore(message)
            case .desiredState:
                let message = try envelope.decode(as: DesiredStateMessage.self)
                // Realize logical networks (per-project routers, SNAT uplinks)
                // before converging VMs, so a VM's switch and L3 gateway exist
                // before its NIC attaches (issue #342). Level-triggered and
                // idempotent, like the VM reconcile that follows.
                //
                // Only a control plane that speaks network sync (v3+) sends an
                // authoritative `networks` list. An older control plane omits it
                // (decoded as []); that absence must NOT be read as "tear down
                // all L3" — skip network reconciliation and fall back to VM-only.
                if WireProtocol.supportsNetworkSync(envelope.senderVersion) {
                    // This host's own VM ports' desired security-group
                    // membership, derived from each NIC's spec (nicIndex is
                    // the NIC's position in the spec list, matching the LSP
                    // names createVMNetwork derives). Converged on every
                    // agent; port groups + ACLs themselves are authored only
                    // by the topology authority from `message.securityGroups`.
                    let portMemberships = message.vms.flatMap { vm in
                        vm.spec.networks.enumerated().map { index, spec in
                            DesiredPortMembership(
                                portName: OVNNaming.vmPortName(
                                    vmId: vm.vmId.uuidString, nicIndex: index),
                                securityGroupIds: spec.securityGroupIds)
                        }
                    }
                    // The networks this host must materialize the metadata
                    // address on (STR-49), derived from our own workload specs
                    // rather than `message.networks`: a sited agent that is not
                    // its site's network controller receives an empty topology
                    // list by design, yet its guests need the service just the
                    // same. Same derivation as `portMemberships` above, and the
                    // same "this host owns it without topology authority"
                    // reason. Nil for a control plane that predates the field,
                    // so silence is never read as "tear every namespace down".
                    let metadataNetworks: [UUID]?
                    if WireProtocol.supportsMetadataPort(envelope.senderVersion) {
                        var ids = Set(
                            message.vms.flatMap { $0.spec.networks }
                                .filter { $0.metadataEnabled == true }.map(\.networkId))
                        ids.formUnion(
                            message.sandboxes.compactMap { $0.spec.network }
                                .filter { $0.metadataEnabled == true }.map(\.networkId))
                        metadataNetworks = ids.sorted { $0.uuidString < $1.uuidString }
                    } else {
                        metadataNetworks = nil
                    }
                    await networkService?.reconcileNetworks(
                        message.networks, authoritative: message.networksAuthoritative,
                        securityGroups: message.securityGroups,
                        portMemberships: portMemberships,
                        metadataNetworks: metadataNetworks)
                }
                // Sandbox reconciliation is likewise gated on the sender: a
                // control plane older than the sandbox protocol (v5) omits
                // `sandboxes` (decoded as []), which must not be mistaken for
                // an authoritative "this host should have no sandboxes".
                // Volumes carry the same gate, plus a stricter one inside
                // `apply`: a nil `volumes` field skips the half whatever the
                // version says, because misreading silence there destroys the
                // only copy of user data (STR-148). Instance metadata (STR-52)
                // is gated for the same "silence is not an instruction" reason:
                // a rolled-back control plane must not empty what this host's
                // metadata service serves.
                await reconciler?.apply(
                    message,
                    includeSandboxes: WireProtocol.supportsSandboxSync(envelope.senderVersion),
                    includeVolumes: WireProtocol.supportsVolumeSync(envelope.senderVersion),
                    includeSnapshots: WireProtocol.supportsSnapshotSync(envelope.senderVersion),
                    includeMetadata: WireProtocol.supportsInstanceMetadata(envelope.senderVersion))
                // Declarative agent self-update (issue #434), after the
                // reconciler so freshly enqueued work items are visible to the
                // precondition gate — the update only runs on a sync that
                // arrives with the lanes already drained.
                await handleDesiredAgentUpdate(message.desiredAgentUpdate)
            case .consoleConnect:
                let message = try envelope.decode(as: ConsoleConnectMessage.self)
                await handleConsoleConnect(message)
            case .consoleDisconnect:
                let message = try envelope.decode(as: ConsoleDisconnectMessage.self)
                await handleConsoleDisconnect(message)
            case .consoleData:
                let message = try envelope.decode(as: ConsoleDataMessage.self)
                await handleConsoleData(message)
            // Sandbox exec sessions (issue #423)
            case .sandboxExecStart:
                let message = try envelope.decode(as: SandboxExecStartMessage.self)
                await handleSandboxExecStart(message)
            case .sandboxExecInput:
                let message = try envelope.decode(as: SandboxExecInputMessage.self)
                await handleSandboxExecInput(message)
            case .sandboxExecResize:
                let message = try envelope.decode(as: SandboxExecResizeMessage.self)
                await handleSandboxExecResize(message)
            case .sandboxExecClose:
                let message = try envelope.decode(as: SandboxExecCloseMessage.self)
                await handleSandboxExecClose(message)
            // Sandbox checkpoint-resume (issue #426). Capture, delete and
            // export are desired state since wire v33 (STR-150).
            case .sandboxRestore:
                let message = try envelope.decode(as: SandboxRestoreMessage.self)
                await handleSandboxRestore(message)
            // No volume frames remain: create/delete/attach/detach/resize/clone
            // became desired state at wire v31 (STR-148), `volume_info` was
            // deleted at v32 as a read that was never an action (STR-149), and
            // both snapshot verbs became desired artifacts at v33 (STR-150).
            case .success:
                // ACK to a control-plane-initiated request (incl. every heartbeat).
                // Logged at debug so it stops surfacing as "unknown message type".
                let message = try envelope.decode(as: SuccessMessage.self)
                logger.debug(
                    "Received success response from control plane",
                    metadata: [
                        "requestId": .string(message.requestId),
                        "message": .string(message.message ?? ""),
                    ])
            case .error:
                let message = try envelope.decode(as: ErrorMessage.self)
                await handleErrorResponse(message)
            default:
                logger.warning("Received unknown message type: \(envelope.type)")
            }
        } catch {
            logger.error("Failed to handle message: \(error)")
        }
    }

    /// Resolves VM network attachments before hypervisor drivers run and tears
    /// them down after VMs are deleted. Rebuilt per use because `networkService`
    /// is only set once the agent has started.
    private var networkOrchestrator: NetworkOrchestrator {
        NetworkOrchestrator(networkService: networkService, logger: logger)
    }

    /// Get the hypervisor service for a VM based on its type. A missing
    /// registry entry means no driver for that backend runs on this host
    /// (e.g. Firecracker on macOS). No silent fallback to another driver: the
    /// scheduler should never place such a VM here, so surface the mismatch
    /// as an error instead of booting the VM under a different hypervisor
    /// than requested.
    private func getHypervisorService(for hypervisorType: HypervisorType) -> (any HypervisorService)? {
        guard let service = hypervisorServices[hypervisorType] else {
            logger.error(
                "No \(hypervisorType.displayName) driver on this host; rejecting request for unsupported hypervisor")
            return nil
        }
        return service
    }

    /// Get the hypervisor service for an existing VM
    private func getHypervisorServiceForVM(vmId: String) -> (any HypervisorService)? {
        guard let entry = managedVMs[vmId] ?? orphanedVMs[vmId] else {
            // No silent QEMU fallback: routing a VM to a backend that never created
            // it can only yield misleading vmNotFound errors (or operate on the
            // wrong VM). An unknown vmId means this agent has no record of the VM.
            logger.error(
                "No hypervisor backend recorded for VM; rejecting operation", metadata: ["vmId": .string(vmId)])
            return nil
        }
        return getHypervisorService(for: entry.hypervisorType)
    }

    /// Persists managed + orphaned workloads (VMs and sandboxes) to the on-disk
    /// manifest so they can be detected as orphaned after an agent restart.
    /// Orphaned entries are carried over (active entries win on ID collision)
    /// so a second restart still knows about them.
    ///
    /// A write failure does not fail the operation that triggered it — the
    /// hypervisor-level change has already happened, so failing the response
    /// would diverge control-plane state from reality worse than a stale
    /// manifest does. Instead the failure is flagged and the write retried on
    /// every heartbeat (each write covers the full VM set, so one success
    /// heals all missed updates). The stale manifest only matters if the agent
    /// restarts before a retry succeeds.
    private func persistManifest() {
        // Never write over a manifest we could not read (STR-138). The first
        // write after a failed load is what turns "unreadable, but the bytes
        // are still there" into an unrecoverable loss — and what it would
        // write is the empty in-memory set, i.e. a confident claim that this
        // host runs nothing. There is nothing worth persisting in that state
        // anyway: the agent converges nothing while quarantined.
        if let failure = manifestReadFailure {
            logger.warning(
                "Refusing to write the VM manifest: the existing file could not be read and must not be overwritten",
                metadata: [
                    "path": .string(failure.path),
                    "preservedCopy": .string(failure.preservedCopyPath ?? "none"),
                ])
            return
        }

        // One flat map for every workload kind; ids cannot collide across kinds
        // (both sides are UUIDs minted by the control plane), so the only real
        // collisions are orphaned-vs-active within a kind — active wins.
        var manifest = orphanedVMs.merging(managedVMs) { _, active in active }
        manifest.merge(orphanedSandboxes.merging(managedSandboxes) { _, active in active }) { _, sandbox in sandbox }
        // Quarantined entries are re-emitted exactly as they were read: their
        // routing field is what a build that understands them needs, and this
        // one rewriting it in a shape it prefers would destroy that.
        manifestPersistFailed = !manifestStore.save(manifest, preserving: quarantinedWorkloads)
    }

    /// Fold a manifest read into the agent's view of the host.
    ///
    /// The three outcomes are three different facts, and the whole point of
    /// STR-138 is that they stay that way: a fresh host has nothing on it, a
    /// loaded manifest names what a previous incarnation was running, and an
    /// unreadable one means the contents are unknown — which must never be
    /// spelled the same way as "empty".
    private func applyManifestLoad(_ load: ManifestLoad) {
        switch load {
        case .fresh:
            manifestReadFailure = nil

        case .loaded(let entries, let quarantined):
            manifestReadFailure = nil
            quarantinedWorkloads = quarantined
            // Anything already managed by *this* incarnation stays managed: a
            // recovery re-read must not demote live workloads to orphans.
            var recovered: [String] = []
            for (id, entry) in entries where managedVMs[id] == nil && managedSandboxes[id] == nil {
                if entry.kind == .sandbox {
                    orphanedSandboxes[id] = entry
                } else {
                    orphanedVMs[id] = entry
                }
                recovered.append(id)
            }
            if !recovered.isEmpty {
                logger.warning(
                    "Found \(recovered.count) workload(s) managed before restart; their processes are now unmanaged but their resources stay reserved",
                    metadata: ["workloadIds": .string(recovered.sorted().joined(separator: ","))])
            }

        case .unreadable(let failure):
            // The store has already logged this loudly and preserved a copy.
            manifestReadFailure = failure
        }
    }

    /// Re-read a manifest that was unreadable, so a transient cause — a
    /// storage volume that mounted late, an EIO, a permissions fix — clears
    /// the quarantine without an agent restart.
    ///
    /// Only a successful *read* clears it. A manifest that has since vanished
    /// reads as `.fresh`, and a missing file is not evidence of an empty host:
    /// somebody deleted it. Accepting that would hand every running guest's
    /// capacity straight back to the scheduler, so deciding this host is empty
    /// stays a deliberate act — restart the agent.
    private func retryManifestLoadIfQuarantined() {
        guard manifestReadFailure != nil else { return }
        let load = manifestStore.load()
        guard case .loaded = load else { return }

        applyManifestLoad(load)
        logger.warning(
            "VM manifest became readable again; this host is no longer quarantined and will converge and advertise capacity normally"
        )
    }

    private func handleVMReboot(_ message: VMOperationMessage) async {
        logger.info("Rebooting VM", metadata: ["vmId": .string(message.vmId)])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            return
        }

        do {
            try await service.rebootVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM rebooted successfully")
            logger.info("VM rebooted successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to reboot VM: \(error.localizedDescription)")
            logger.error(
                "Failed to reboot VM",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    // MARK: - Full-VM restore (issue #564)

    private func handleVMRestore(_ message: VMRestoreMessage) async {
        logger.info(
            "VM restore request received",
            metadata: ["vmId": .string(message.vmId), "snapshotId": .string(message.snapshotId)])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            return
        }

        do {
            try await service.restoreVM(vmId: message.vmId, snapshotId: message.snapshotId)
            await sendSuccess(for: message.requestId, message: "VM restored from checkpoint")
        } catch {
            await sendError(
                for: message.requestId,
                error: "Failed to restore VM: \(error.localizedDescription)")
            logger.error(
                "Failed to restore VM from checkpoint",
                metadata: [
                    "vmId": .string(message.vmId),
                    "snapshotId": .string(message.snapshotId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    /// Self-update (issue #434): converge on the desired agent build carried by
    /// the sync — download, verify, swap, restart — gated on local
    /// preconditions. Since wire v28 this is the only update path there is: an
    /// operator's "update now" reaches the agent as this same field, assigned
    /// by the control plane rather than dispatched as a command, so the
    /// preconditions below hold for it too. Level-triggered: a blocked update
    /// is re-evaluated on every sync and the current reason is reported back on
    /// observed-state reports; a failed artifact is not retried within this
    /// process lifetime.
    private func handleDesiredAgentUpdate(_ update: DesiredAgentUpdate?) async {
        guard let update else {
            // No opinion from the control plane (rollout not reached us,
            // auto-update off, or an older control plane). Clear any stale
            // status so a withdrawn rollout stops surfacing old reasons.
            autoUpdateStatus = nil
            return
        }
        guard !updateRestartPending else { return }
        guard update.targetVersion != BuildInfo.version else {
            // Already converged; the control plane's canonical comparison
            // normally stops the field before this, so this is a cheap no-op
            // guard against redundant syncs racing the restart.
            autoUpdateStatus = nil
            return
        }
        if attemptedAutoUpdateArtifacts.contains(update.sha256) {
            // Keep the failure status recorded at attempt time; the control
            // plane halts the rollout on it rather than waiting out silence.
            return
        }

        // Restarting mid-convergence is equally disruptive for either
        // workload kind, so the gate counts VM and sandbox items alike.
        var inFlightReconcileItems = 0
        if let reconciler {
            inFlightReconcileItems += await reconciler.inFlightWorkloads(kind: .vm).count
            inFlightReconcileItems += await reconciler.inFlightWorkloads(kind: .sandbox).count
        }
        let conditions = AutoUpdateGate.Conditions(
            installMode: AgentInstallMode.detect(),
            inFlightReconcileItems: inFlightReconcileItems
        )
        if let reason = AutoUpdateGate.blockedReason(conditions) {
            let changed = autoUpdateStatus?.reason != reason
            autoUpdateStatus = ObservedAgentUpdateStatus(
                targetVersion: update.targetVersion,
                disposition: ObservedAgentUpdateStatus.dispositionBlocked,
                reason: reason
            )
            if changed {
                logger.notice(
                    "Desired agent update is blocked",
                    metadata: [
                        "targetVersion": .string(update.targetVersion),
                        "reason": .string(reason),
                    ])
                await sendObservedStateReport()
            }
            return
        }

        logger.notice(
            "Converging on desired agent update",
            metadata: [
                "targetVersion": .string(update.targetVersion),
                "currentVersion": .string(BuildInfo.version),
                // Redacted: the URL's query string may be a presigned credential.
                "artifactURL": .string(update.redactedArtifactURL),
            ])
        attemptedAutoUpdateArtifacts.insert(update.sha256)

        let outcome: AgentUpdateOutcome
        do {
            let updater = AgentUpdater(logger: logger, download: makeUpdateArtifactDownload())
            outcome = try await updater.applyUpdate(
                artifactURL: update.artifactURL,
                sha256: update.sha256,
                artifactKind: update.artifactKind,
                tarballMember: update.tarballMember
            )
        } catch {
            let reason = (error as? AgentUpdateError)?.description ?? "\(error)"
            logger.error(
                "Desired agent update failed",
                metadata: [
                    "targetVersion": .string(update.targetVersion),
                    "error": .string(reason),
                ])
            autoUpdateStatus = ObservedAgentUpdateStatus(
                targetVersion: update.targetVersion,
                disposition: ObservedAgentUpdateStatus.dispositionFailed,
                reason: reason
            )
            // Push the failure immediately so the rollout halts on the real
            // error instead of waiting out its health budget.
            await sendObservedStateReport()
            return
        }

        updateRestartPending = true
        autoUpdateStatus = nil
        // stop() from a separate task (this handler runs on the inbound
        // pipeline stop() tears down), then launchAgent exits with the restart
        // code for the supervisor. The new binary proves the update by
        // re-registering with its version.
        logger.notice(
            "Desired agent update applied; shutting down for supervisor restart",
            metadata: [
                "targetVersion": .string(update.targetVersion),
                "binaryPath": .string(outcome.binaryPath),
                "previousBinaryPath": .string(outcome.previousBinaryPath),
            ])
        Task {
            try? await Task.sleep(for: .seconds(1))
            await self.stop()
        }
    }

    private func sendSuccess(for requestId: String, message: String? = nil, data: AnyCodableValue? = nil) async {
        let successMessage = SuccessMessage(requestId: requestId, message: message, data: data)
        do {
            try await websocketClient?.sendMessage(successMessage)
        } catch {
            logger.error("Failed to send success message: \(error)")
        }
    }

    private func sendError(for requestId: String, error: String, details: String? = nil) async {
        let errorMessage = ErrorMessage(requestId: requestId, error: error, details: details)
        do {
            try await websocketClient?.sendMessage(errorMessage)
        } catch {
            logger.error("Failed to send error message: \(error)")
        }
    }

    /// Send a VM log message to the control plane for storage in Loki
    private func sendVMLog(
        vmId: String,
        level: VMLogLevel,
        eventType: VMEventType,
        message: String,
        operation: String? = nil,
        details: String? = nil,
        previousStatus: VMStatus? = nil,
        newStatus: VMStatus? = nil
    ) async {
        let logMessage = VMLogMessage(
            vmId: vmId,
            level: level,
            source: .agent,
            eventType: eventType,
            message: message,
            operation: operation,
            details: details,
            previousStatus: previousStatus,
            newStatus: newStatus
        )
        do {
            try await websocketClient?.sendMessage(logMessage)
        } catch {
            logger.error("Failed to send VM log: \(error)")
        }
    }

    // MARK: - Console Message Handlers

    /// Report a console that could not be opened, both ways.
    ///
    /// The correlated `ErrorMessage` is for logs and protocol symmetry, but it
    /// cannot reach the browser: console connects are sent fire-and-forget, so
    /// the control plane has no pending request to match a `requestId` against
    /// and drops it. `ConsoleDisconnectedMessage` is a stream event keyed by
    /// `sessionId`, which does route — and is what stops the tab waiting on a
    /// console that is never going to open.
    private func failConsoleConnect(_ message: ConsoleConnectMessage, reason: String) async {
        await sendError(for: message.requestId, error: reason)
        await sendConsoleDisconnected(vmId: message.vmId, sessionId: message.sessionId, reason: reason)
    }

    /// Tell the control plane a console session is over, and why, so it can
    /// close the browser's socket instead of leaving it attached to nothing.
    private func sendConsoleDisconnected(vmId: String, sessionId: String, reason: String) async {
        do {
            try await websocketClient?.sendMessage(
                ConsoleDisconnectedMessage(vmId: vmId, sessionId: sessionId, reason: reason))
        } catch {
            logger.error("Failed to send console disconnected message: \(error)")
        }
    }

    private func handleConsoleConnect(_ message: ConsoleConnectMessage) async {
        let stream = message.effectiveStream
        logger.info(
            "Console connect request received",
            metadata: [
                "vmId": .string(message.vmId),
                "sessionId": .string(message.sessionId),
                "requestId": .string(message.requestId),
                "stream": .string(stream.rawValue),
            ])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            logger.error(
                "Hypervisor service not available for console connect", metadata: ["vmId": .string(message.vmId)])
            await failConsoleConnect(message, reason: "Hypervisor service not available for VM")
            return
        }

        // Try serial socket first, then fall back to virtio-console if connect fails.
        logger.debug("Looking up console endpoint", metadata: ["vmId": .string(message.vmId)])
        let endpoint: ConsoleEndpoint?
        do {
            endpoint = try await service.consoleEndpoint(vmId: message.vmId)
        } catch {
            logger.error(
                "Console not available",
                metadata: [
                    "vmId": .string(message.vmId),
                    "error": .string(error.localizedDescription),
                ])
            await failConsoleConnect(
                message,
                reason: "Console not available for VM \(message.vmId): \(error.localizedDescription)")
            return
        }

        // The text console has two candidate sockets and tries them in order;
        // the graphics console has exactly one and no fallback, because serial
        // bytes are not an RFB stream — handing them to noVNC would hang its
        // handshake instead of reporting anything (issue #566).
        let candidatePaths: [String]
        switch stream {
        case .serial:
            candidatePaths = [endpoint?.serialSocketPath, endpoint?.consoleSocketPath].compactMap { $0 }
            guard !candidatePaths.isEmpty else {
                logger.error(
                    "No console socket found (tried serial and virtio-console)",
                    metadata: ["vmId": .string(message.vmId)])
                await failConsoleConnect(message, reason: "Console socket not found for VM \(message.vmId)")
                return
            }
        case .vnc:
            guard let vncPath = endpoint?.vncSocketPath else {
                logger.error("No VNC socket found", metadata: ["vmId": .string(message.vmId)])
                // The display device is fixed in the QEMU process's arguments,
                // so this is not something a restart fixes — say so rather than
                // leaving the operator to guess.
                await failConsoleConnect(
                    message,
                    reason: "VM \(message.vmId) has no graphics console: it was created without a display. "
                        + "Recreate the VM with the display enabled.")
                return
            }
            candidatePaths = [vncPath]
        }

        guard let consoleManager = consoleSocketManager else {
            logger.error("Console manager not available")
            await failConsoleConnect(message, reason: "Console manager not available")
            return
        }

        // Clean up existing sessions on *this* stream to prevent stale data
        // routing. Scoped by stream so opening the graphics console does not
        // tear down a serial session on the same VM, or the reverse.
        //
        // Not done for VNC at all: QEMU multiplexes RFB clients on one socket,
        // so two viewers of the same framebuffer is a supported case rather
        // than a stale one.
        if stream != .vnc {
            let existingSessions = await consoleManager.getSessionsForVM(vmId: message.vmId, stream: stream)
            if !existingSessions.isEmpty {
                logger.info(
                    "Cleaning up existing console sessions for VM",
                    metadata: [
                        "vmId": .string(message.vmId),
                        "stream": .string(stream.rawValue),
                        "sessionCount": .stringConvertible(existingSessions.count),
                    ])
                await consoleManager.disconnectAllForVM(vmId: message.vmId, stream: stream)
            }
        }

        var connectedPath: String?
        var lastError: Error?

        for candidatePath in candidatePaths {
            do {
                try await consoleManager.connect(
                    vmId: message.vmId, sessionId: message.sessionId, stream: stream, socketPath: candidatePath)
                connectedPath = candidatePath
                logger.debug(
                    "Connected to console socket",
                    metadata: ["stream": .string(stream.rawValue), "socketPath": .string(candidatePath)])
                break
            } catch {
                lastError = error
                logger.warning(
                    "Failed to connect to console socket",
                    metadata: [
                        "vmId": .string(message.vmId),
                        "sessionId": .string(message.sessionId),
                        "socketPath": .string(candidatePath),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        guard connectedPath != nil else {
            let errorMessage = "Failed to connect to console: \(lastError?.localizedDescription ?? "unknown error")"
            await failConsoleConnect(message, reason: errorMessage)
            logger.error(
                "Failed to connect to console",
                metadata: [
                    "vmId": .string(message.vmId),
                    "sessionId": .string(message.sessionId),
                    "error": .string(lastError?.localizedDescription ?? "unknown"),
                ])
            return
        }

        // Send connected confirmation
        let connectedMessage = ConsoleConnectedMessage(
            requestId: message.requestId,
            vmId: message.vmId,
            sessionId: message.sessionId
        )
        do {
            try await websocketClient?.sendMessage(connectedMessage)
        } catch {
            logger.error("Failed to send console connected message: \(error)")
        }

        logger.info(
            "Console connected",
            metadata: [
                "vmId": .string(message.vmId),
                "sessionId": .string(message.sessionId),
                "socketPath": .string(connectedPath ?? "unknown"),
            ])
    }

    private func handleConsoleDisconnect(_ message: ConsoleDisconnectMessage) async {
        logger.info(
            "Console disconnect request",
            metadata: [
                "vmId": .string(message.vmId),
                "sessionId": .string(message.sessionId),
            ])

        guard let consoleManager = consoleSocketManager else {
            await sendError(for: message.requestId, error: "Console manager not available")
            return
        }

        await consoleManager.disconnect(sessionId: message.sessionId)

        // Send disconnected confirmation
        let disconnectedMessage = ConsoleDisconnectedMessage(
            requestId: message.requestId,
            vmId: message.vmId,
            sessionId: message.sessionId,
            reason: "User requested disconnect"
        )
        do {
            try await websocketClient?.sendMessage(disconnectedMessage)
        } catch {
            logger.error("Failed to send disconnected message: \(error)")
        }

        logger.info(
            "Console disconnected",
            metadata: [
                "vmId": .string(message.vmId),
                "sessionId": .string(message.sessionId),
            ])
    }

    private func handleConsoleData(_ message: ConsoleDataMessage) async {
        // User input from frontend - write to console socket
        guard let consoleManager = consoleSocketManager else {
            logger.warning("Console manager not available for data write")
            return
        }

        guard let data = message.rawData else {
            logger.warning("Invalid console data received (failed to decode base64)")
            return
        }

        do {
            try await consoleManager.write(sessionId: message.sessionId, data: data)
        } catch {
            logger.error(
                "Failed to write to console",
                metadata: [
                    "sessionId": .string(message.sessionId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    /// Called by ConsoleSocketManager when data arrives from VM console
    func sendConsoleData(vmId: String, sessionId: String, data: Data) async {
        let message = ConsoleDataMessage(
            vmId: vmId,
            sessionId: sessionId,
            rawData: data
        )
        do {
            try await websocketClient?.sendMessage(message)
        } catch {
            logger.error("Failed to send console data: \(error)")
        }
    }

    // MARK: - Sandbox Exec Message Handlers (issue #423)

    /// Start the pumps that drain the runtime's exec events and workload log
    /// lines into outbound WebSocket messages. Idempotent.
    private func startSandboxPumps() {
        if sandboxExecPumpTask == nil {
            let events = sandboxExecEvents
            sandboxExecPumpTask = Task { [weak self] in
                for await (sandboxId, sessionId, event) in events {
                    await self?.sendSandboxExecEvent(sandboxId: sandboxId, sessionId: sessionId, event: event)
                }
            }
        }
        if sandboxLogPumpTask == nil {
            let lines = sandboxLogLines
            sandboxLogPumpTask = Task { [weak self] in
                for await (sandboxId, stream, line) in lines {
                    await self?.sendSandboxLogLine(sandboxId: sandboxId, stream: stream, line: line)
                }
            }
        }
    }

    private func handleSandboxExecStart(_ message: SandboxExecStartMessage) async {
        logger.info(
            "Sandbox exec start request received",
            metadata: [
                "sandboxId": .string(message.sandboxId),
                "sessionId": .string(message.sessionId),
                "tty": .stringConvertible(message.tty),
            ])

        guard let runtime = sandboxRuntime else {
            logger.error(
                "Sandbox runtime not available for exec", metadata: ["sandboxId": .string(message.sandboxId)])
            await sendSandboxExecClosed(
                sessionId: message.sessionId, reason: "this agent has no sandbox runtime")
            return
        }

        let request = SandboxExecRequest(
            command: message.command, env: message.env, workingDir: message.workingDir,
            tty: message.tty, rows: message.rows, cols: message.cols)

        // Events yield into the ordered pump stream (never send directly from
        // the runtime's callback, which must stay non-blocking).
        let continuation = sandboxExecEventsContinuation
        let sandboxId = message.sandboxId
        let sessionId = message.sessionId
        do {
            try await runtime.startExec(sandboxId: sandboxId, sessionId: sessionId, request: request) { event in
                continuation.yield((sandboxId, sessionId, event))
            }
        } catch {
            logger.error(
                "Failed to start sandbox exec session",
                metadata: [
                    "sandboxId": .string(sandboxId),
                    "sessionId": .string(sessionId),
                    "error": .string(error.localizedDescription),
                ])
            await sendSandboxExecClosed(sessionId: sessionId, reason: error.localizedDescription)
        }
    }

    // MARK: - Sandbox checkpoint-resume (issue #426)

    private func handleSandboxRestore(_ message: SandboxRestoreMessage) async {
        logger.info(
            "Sandbox restore request received",
            metadata: [
                "sandboxId": .string(message.sandboxId),
                "snapshotId": .string(message.snapshotId),
            ])

        guard let runtime = sandboxRuntime else {
            await sendError(for: message.requestId, error: "this agent has no sandbox runtime")
            return
        }

        do {
            try await runtime.restoreSandbox(
                sandboxId: message.sandboxId, snapshotId: message.snapshotId,
                artifacts: message.artifacts)
            await sendSuccess(for: message.requestId, message: "Sandbox restored from snapshot")
        } catch {
            await sendError(
                for: message.requestId,
                error: "Failed to restore sandbox: \(error.localizedDescription)")
            logger.error(
                "Failed to restore sandbox from snapshot",
                metadata: [
                    "sandboxId": .string(message.sandboxId),
                    "snapshotId": .string(message.snapshotId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleSandboxExecInput(_ message: SandboxExecInputMessage) async {
        guard let runtime = sandboxRuntime else {
            await sendSandboxExecClosed(
                sessionId: message.sessionId, reason: "this agent has no sandbox runtime")
            return
        }
        if message.data != nil && message.rawData == nil {
            // The payload is present but not decodable base64: the stream is
            // corrupt, and forwarding nothing would silently swallow
            // keystrokes. Treat it as session-fatal, like the handler's other
            // failure paths: tear the session down and tell the control plane.
            logger.warning(
                "Invalid sandbox exec input received (failed to decode base64); closing session",
                metadata: ["sessionId": .string(message.sessionId)])
            await runtime.closeExec(sessionId: message.sessionId)
            await sendSandboxExecClosed(
                sessionId: message.sessionId, reason: "undecodable exec input (invalid base64)")
            return
        }
        do {
            try await runtime.sendExecInput(sessionId: message.sessionId, data: message.rawData, eof: message.eof)
        } catch {
            logger.warning(
                "Failed to write sandbox exec input",
                metadata: [
                    "sessionId": .string(message.sessionId),
                    "error": .string(error.localizedDescription),
                ])
            await sendSandboxExecClosed(sessionId: message.sessionId, reason: error.localizedDescription)
        }
    }

    private func handleSandboxExecResize(_ message: SandboxExecResizeMessage) async {
        guard let runtime = sandboxRuntime else {
            await sendSandboxExecClosed(
                sessionId: message.sessionId, reason: "this agent has no sandbox runtime")
            return
        }
        do {
            try await runtime.resizeExec(sessionId: message.sessionId, rows: message.rows, cols: message.cols)
        } catch {
            logger.warning(
                "Failed to resize sandbox exec session",
                metadata: [
                    "sessionId": .string(message.sessionId),
                    "error": .string(error.localizedDescription),
                ])
            await sendSandboxExecClosed(sessionId: message.sessionId, reason: error.localizedDescription)
        }
    }

    private func handleSandboxExecClose(_ message: SandboxExecCloseMessage) async {
        logger.info(
            "Sandbox exec close request received",
            metadata: [
                "sessionId": .string(message.sessionId),
                "reason": .string(message.reason ?? ""),
            ])
        // The control plane already tore its side down; closing is terminal
        // and needs no reply (and with no runtime there is nothing to close).
        await sandboxRuntime?.closeExec(sessionId: message.sessionId)
    }

    /// Translate one runtime exec event into its outbound message. Runs on the
    /// exec pump, so events are sent strictly in the order the runtime
    /// delivered them.
    private func sendSandboxExecEvent(sandboxId: String, sessionId: String, event: SandboxExecEvent) async {
        guard let websocketClient else {
            // No control-plane socket: the event (possibly the session's
            // terminal one) is dropped. The control plane's agent-disconnect
            // cleanup handles the user-facing side; just make the drop
            // observable.
            logger.warning(
                "Dropping sandbox exec event: no control plane connection",
                metadata: [
                    "sessionId": .string(sessionId),
                    "event": .string(String(describing: event)),
                ])
            return
        }
        do {
            switch event {
            case .started:
                try await websocketClient.sendMessage(
                    SandboxExecStartedMessage(sandboxId: sandboxId, sessionId: sessionId))
            case .output(let stream, let data):
                try await websocketClient.sendMessage(
                    SandboxExecOutputMessage(sessionId: sessionId, stream: stream, rawData: data))
            case .exited(let code):
                try await websocketClient.sendMessage(
                    SandboxExecExitMessage(sessionId: sessionId, exitCode: code))
            case .closed(let reason):
                try await websocketClient.sendMessage(
                    SandboxExecClosedMessage(sessionId: sessionId, reason: reason))
            }
        } catch {
            logger.error(
                "Failed to send sandbox exec message",
                metadata: [
                    "sessionId": .string(sessionId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func sendSandboxExecClosed(sessionId: String, reason: String?) async {
        guard let websocketClient else {
            // Terminal for the session but undeliverable; see
            // `sendSandboxExecEvent` for why a warning is enough.
            logger.warning(
                "Dropping sandbox exec closed message: no control plane connection",
                metadata: ["sessionId": .string(sessionId), "reason": .string(reason ?? "")])
            return
        }
        do {
            try await websocketClient.sendMessage(SandboxExecClosedMessage(sessionId: sessionId, reason: reason))
        } catch {
            logger.error(
                "Failed to send sandbox exec closed message",
                metadata: ["sessionId": .string(sessionId), "error": .string(error.localizedDescription)])
        }
    }

    /// Ship one assembled workload log line. Runs on the log pump, so lines
    /// arrive at the control plane in the order the guest emitted them.
    private func sendSandboxLogLine(sandboxId: String, stream: String, line: String) async {
        let message = SandboxLogMessage(sandboxId: sandboxId, stream: stream, message: line)
        do {
            try await websocketClient?.sendMessage(message)
        } catch {
            logger.error(
                "Failed to send sandbox log line",
                metadata: ["sandboxId": .string(sandboxId), "error": .string(error.localizedDescription)])
        }
    }

    // MARK: - Volume frames (none remain)

    // `handleVolumeInfo` is gone with the `volume_info` frame (wire v32, ADR
    // 0001 stage 7, STR-149), and `handleVolumeSnapshot`/`...Delete` with the
    // two artifact verbs (v33, stage 8, STR-150). `StorageBackend.volumeInfo` remains, as the
    // agent's own probe behind `volumeVirtualSize` — the size cache the resize
    // planner reads. Nothing asks the agent to read a volume on the control
    // plane's behalf anymore.
}

// MARK: - Reconciliation (issue #260)

/// Runtime side effects for the reconcile loop. VM items mirror the imperative
/// handlers (same manifest bookkeeping, same driver-registry routing) minus
/// the per-request response messaging: convergence outcomes are reported via
/// `ObservedStateReport` instead of success/error envelopes. Sandbox items
/// route to the sandbox runtime seam (issue #417; the driver itself is issue
/// #421) with the same manifest contract.
extension Agent: ReconcileActuator {
    /// Whether the presence snapshots below account for this host at all. False
    /// while the manifest is unreadable: the maps are empty because the agent
    /// has no memory of what it was running, not because the host is idle
    /// (STR-138).
    func presenceIsComplete() async -> Bool {
        manifestReadFailure == nil
    }

    func observedPresence() async -> [String: VMPresence] {
        var presence: [String: VMPresence] = [:]
        for (vmId, entry) in managedVMs {
            guard let service = hypervisorServices[entry.hypervisorType] else { continue }
            let status = (try? await service.getVMStatus(vmId: vmId)) ?? .unknown
            presence[vmId] = .managed(status)
        }
        for vmId in orphanedVMs.keys where presence[vmId] == nil {
            presence[vmId] = .orphaned
        }
        for (vmId, entry) in quarantinedWorkloads
        where entry.effectiveKind == .vm && presence[vmId] == nil {
            presence[vmId] = .quarantined
        }
        return presence
    }

    /// The sizing each managed VM is running with, from the manifest entry —
    /// which is written from the spec the VM was created (or last resized)
    /// with, so it is exactly the figure a new spec must be diffed against.
    /// Orphans are omitted: an unadopted VM has no control session to resize
    /// over, and adoption is planned for it first anyway.
    func observedSizing() async -> [String: VMSizing] {
        managedVMs.mapValues {
            VMSizing(
                cpus: $0.spec.cpus, memoryBytes: $0.spec.memoryBytes,
                balloonTargetBytes: $0.spec.balloonTargetBytes)
        }
    }

    func adoptVM(_ item: ReconcileWorkItem) async throws -> VMStatus {
        guard let entry = orphanedVMs[item.vmId] else {
            // A replayed sync may race re-adoption; if the VM is already
            // managed, adoption is satisfied.
            if let managed = managedVMs[item.vmId],
                let service = hypervisorServices[managed.hypervisorType]
            {
                return try await service.getVMStatus(vmId: item.vmId)
            }
            throw HypervisorServiceError.vmNotFound(item.vmId)
        }
        guard let service = getHypervisorService(for: entry.hypervisorType) else {
            throw HypervisorServiceError.hypervisorNotInstalled(entry.hypervisorType.rawValue)
        }

        // The manifest spec is what the surviving process was actually built
        // from; prefer the sync's spec only as metadata for future operations.
        let spec = item.desired?.spec ?? entry.spec
        let status: VMStatus
        do {
            status = try await service.adoptVM(vmId: item.vmId, spec: entry.spec)
        } catch HypervisorServiceError.adoptionTargetGone(let reason) {
            // The orphan's hypervisor process is gone, so there is nothing to
            // re-attach — but its disks persist and materialization reuses an
            // existing disk, so a fresh create rebuilds the same VM in the
            // "exists, not running" state. The next sync plans any remaining
            // power-state steps from `.created`.
            logger.warning(
                "Orphaned VM has no live process; re-creating it from the manifest spec",
                metadata: ["vmId": .string(item.vmId), "reason": .string(reason)])
            try await reconcileCreate(item)
            return .created
        }

        managedVMs[item.vmId] = VMManifestEntry(hypervisorType: entry.hypervisorType, spec: spec)
        orphanedVMs.removeValue(forKey: item.vmId)
        persistManifest()

        logger.info(
            "Orphaned VM re-adopted and managed again",
            metadata: [
                "vmId": .string(item.vmId),
                "status": .string(status.rawValue),
            ])
        await sendVMLog(
            vmId: item.vmId, level: .info, eventType: .operation,
            message: "VM re-adopted after agent restart", operation: "adopt")
        return status
    }

    func observedSandboxPresence() async -> [String: SandboxPresence] {
        var presence: [String: SandboxPresence] = [:]
        for sandboxId in managedSandboxes.keys {
            guard let runtime = sandboxRuntime else {
                presence[sandboxId] = .managed(.unknown)
                continue
            }
            let status = (try? await runtime.getSandboxStatus(sandboxId: sandboxId)) ?? .unknown
            presence[sandboxId] = .managed(status)
        }
        for sandboxId in orphanedSandboxes.keys where presence[sandboxId] == nil {
            presence[sandboxId] = .orphaned
        }
        for (sandboxId, entry) in quarantinedWorkloads
        where entry.effectiveKind == .sandbox && presence[sandboxId] == nil {
            presence[sandboxId] = .quarantined
        }
        return presence
    }

    func adoptSandbox(_ item: ReconcileWorkItem) async throws -> SandboxStatus {
        guard let entry = orphanedSandboxes[item.id] else {
            // A replayed sync may race re-adoption; if the sandbox is already
            // managed, adoption is satisfied.
            if managedSandboxes[item.id] != nil {
                return try await requireSandboxRuntime().getSandboxStatus(sandboxId: item.id)
            }
            throw SandboxRuntimeError.sandboxNotFound(item.id)
        }
        let runtime = try requireSandboxRuntime()
        guard let spec = entry.sandboxSpec else {
            // A sandbox-kind entry without its spec cannot be reattached; only
            // deletion can release it.
            throw SandboxRuntimeError.sandboxNotFound(item.id)
        }

        let status: SandboxStatus
        do {
            status = try await runtime.adoptSandbox(sandboxId: item.id, spec: spec)
        } catch SandboxRuntimeError.adoptionTargetGone(let reason) {
            // The orphan's Firecracker process is gone, so there is nothing to
            // re-attach — but its artifacts persist and create is idempotent, so
            // a fresh create rebuilds the same sandbox in the "exists, not
            // running" state. The next sync plans any remaining power-state
            // steps from `.stopped`. Requires the desired entry (present for an
            // orphan the control plane still wants); without it, re-adoption
            // simply failed.
            guard item.desiredSandbox != nil else { throw SandboxRuntimeError.sandboxNotFound(item.id) }
            logger.warning(
                "Orphaned sandbox has no live process; re-creating it from the desired entry",
                metadata: ["sandboxId": .string(item.id), "reason": .string(reason)])
            try await sandboxReconcileCreate(item)
            return .stopped
        }
        managedSandboxes[item.id] = entry
        orphanedSandboxes.removeValue(forKey: item.id)
        persistManifest()

        logger.info(
            "Orphaned sandbox re-adopted and managed again",
            metadata: [
                "sandboxId": .string(item.id),
                "status": .string(status.rawValue),
            ])
        return status
    }

    /// Every volume whose data this host holds, with the attachment the agent
    /// durably records for it (STR-148).
    ///
    /// Presence comes from the storage backend's own inventory — a volume is a
    /// file, so there is nothing to adopt and every entry is `.managed`.
    /// Attachment comes from the VM manifest entries, *not* from a live
    /// hypervisor query: a powered-off guest has no device list, and reading
    /// that silence as "detached" would plan an attach against a dead control
    /// channel on every sync.
    func observedVolumePresence() async -> [String: VolumePresence]? {
        // No storage backend is an *answer*: such a host holds no volumes, and
        // the control plane never places one on it.
        guard let storageBackend else { return [:] }
        let inventory: [String: DiskAttachment]
        do {
            inventory = try await storageBackend.listVolumes()
        } catch {
            // Nil, not `[:]`. An empty inventory is authoritative to everything
            // downstream — the reconciler would plan a create for every volume
            // the control plane wants here, and the observed report's full-list
            // semantics would confirm deletions that never happened. "I cannot
            // answer" is the only honest thing to say, and it costs one sync.
            logger.error(
                "Cannot enumerate the volume store; reporting no volume inventory at all this sync",
                metadata: ["error": .string(error.localizedDescription)])
            return nil
        }

        let attachments = recordedVolumeAttachments()
        var presence: [String: VolumePresence] = [:]
        for (volumeId, disk) in inventory {
            let attachment = attachments[volumeId]
            presence[volumeId] = .managed(
                ObservedVolumeFacts(
                    path: disk.path,
                    format: disk.format,
                    sizeBytes: await volumeVirtualSize(volumeId: volumeId, path: disk.path),
                    attachedVMId: attachment?.vmId,
                    deviceName: attachment?.deviceName))
        }
        // Sizes for volumes that no longer exist would leak across a long
        // uptime; the inventory is authoritative, so prune to it.
        volumeSizes = volumeSizes.filter { inventory[$0.key] != nil }
        return presence
    }

    /// Which VM each volume is plugged into, from the VM manifest entries'
    /// `spec.volumes` — the durable attachment record. Orphans are included:
    /// their disks are still presented to a process this agent has not
    /// re-adopted yet, so reporting them detached would plan a duplicate
    /// attach.
    private func recordedVolumeAttachments() -> [String: (vmId: String, deviceName: String)] {
        var attachments: [String: (vmId: String, deviceName: String)] = [:]
        for (vmId, entry) in managedVMs.merging(orphanedVMs, uniquingKeysWith: { managed, _ in managed }) {
            for volume in entry.spec.volumes {
                guard let volumeId = volume.volumeId?.uuidString else { continue }
                attachments[volumeId] = (vmId: vmId, deviceName: volume.deviceName.rawValue)
            }
        }
        return attachments
    }

    /// A volume's virtual size, cached in memory.
    ///
    /// Every write path records the size it produced, so the steady state runs
    /// no subprocess at all; the probe below only fires for a volume this
    /// process has not seen written — one created by a previous incarnation of
    /// the agent — and then once per volume, not once per sync. A probe that
    /// fails yields nil, which plans no resize: leaving an unreadable volume
    /// alone beats growing it repeatedly on a guess.
    private func volumeVirtualSize(volumeId: String, path: String) async -> Int64? {
        if let cached = volumeSizes[volumeId] { return cached }
        guard let storageBackend else { return nil }
        do {
            let info = try await storageBackend.volumeInfo(volumePath: path)
            volumeSizes[volumeId] = info.virtualSize
            return info.virtualSize
        } catch {
            logger.debug(
                "Could not read volume size; leaving its size unconverged",
                metadata: ["volumeId": .string(volumeId), "error": .string(error.localizedDescription)])
            return nil
        }
    }

    /// Every snapshot artifact this host holds (STR-150), from the durable
    /// record store.
    ///
    /// The record is the inventory, not the filesystem — which is a real
    /// tradeoff and worth naming. Two of the three families cannot be
    /// enumerated cheaply (a qcow2 internal snapshot costs a `qemu-img info`
    /// subprocess per VM) and none of them can be *described* by their bytes at
    /// all: a Firecracker checkpoint's fork-layout version and CPU template are
    /// not recoverable from the files. So the agent remembers what it captured,
    /// exactly as `VMManifestStore` remembers what it runs, and inherits the
    /// same caveat — an artifact deleted out of band still reports present
    /// until something tries to use it. Deletion is idempotent on every
    /// backend, so converging over it costs nothing.
    func observedSnapshotPresence() async -> [String: SnapshotPresence]? {
        // Nil, not `[:]`. An empty inventory is authoritative downstream: the
        // control plane reads omission from a full list as confirmation that an
        // artifact's bytes are gone and reaps the row, so a host that could not
        // read its record file must say it does not know.
        guard !snapshotInventoryUnreadable else { return nil }

        var presence: [String: SnapshotPresence] = [:]
        for (snapshotId, record) in snapshotRecords {
            presence[snapshotId.uuidString] = .managed(
                ObservedSnapshotArtifact(
                    kind: record.kind, parentId: record.parentId,
                    facts: record.facts, exported: record.exported))
        }
        return presence
    }

    func perform(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
        if item.kind.isSnapshotArtifact {
            try await performSnapshot(step, item: item)
            return
        }
        if item.kind == .volume {
            try await performVolume(step, item: item)
            return
        }
        if item.kind == .sandbox {
            try await performSandbox(step, item: item)
            return
        }
        switch step {
        case .adopt:
            // Adoption flows through adoptVM (the reconciler needs the
            // observed status back to plan the remaining steps).
            _ = try await adoptVM(item)
        case .create:
            try await reconcileCreate(item)
        case .boot:
            try await reconcileService(for: item.vmId).bootVM(vmId: item.vmId)
        case .pause:
            try await reconcileService(for: item.vmId).pauseVM(vmId: item.vmId)
        case .resume:
            try await reconcileService(for: item.vmId).resumeVM(vmId: item.vmId)
        case .resize:
            try await reconcileResize(item)
        case .shutdown:
            try await reconcileService(for: item.vmId).shutdownVM(vmId: item.vmId)
        case .delete:
            try await reconcileDelete(item)
        case .attach, .detach, .export:
            // Volume- and snapshot-only steps; both kinds were handled above
            // and the planner never emits these for a VM or sandbox.
            throw HypervisorServiceError.invalidConfiguration(
                "step \(step) is not applicable to a \(item.kind.rawValue) workload")
        }
    }

    func convergenceDidChange() async {
        await sendObservedStateReport()
    }

    // MARK: - Volume convergence

    private func performVolume(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
        switch step {
        case .create:
            try await volumeReconcileCreate(item)
        case .resize:
            try await volumeReconcileResize(item)
        case .delete:
            try await volumeReconcileDelete(item)
        case .attach:
            try await volumeReconcileAttach(item)
        case .detach:
            try await volumeReconcileDetach(item)
        case .adopt, .boot, .pause, .resume, .shutdown, .export:
            // A volume has no run state and nowhere to be exported to; the
            // planner never emits these.
            throw VolumeConvergenceError.unsupported("step \(step) is not applicable to a volume")
        }
    }

    // MARK: - Snapshot artifact convergence (ADR 0001 stage 8, STR-150)

    private func performSnapshot(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
        switch step {
        case .create:
            try await snapshotReconcileCapture(item)
        case .delete:
            try await snapshotReconcileDelete(item)
        case .export:
            try await snapshotReconcileExport(item)
        case .adopt, .boot, .pause, .resume, .shutdown, .resize, .attach, .detach:
            // An artifact is frozen bytes: it has no run state, no size that
            // can change, and nothing to plug in. The planner never emits any
            // of these.
            throw SnapshotConvergenceError.unsupported(
                "step \(step) is not applicable to a snapshot artifact")
        }
    }

    /// Capture one artifact. Runs **only** when the artifact is absent from
    /// this host — `planCore` plans `.create` for nothing else — which is what
    /// makes the whole conversion safe: a replayed sync can never re-checkpoint
    /// a live guest over the point in time the user is holding.
    ///
    /// Everything the control plane will ever learn about the capture is
    /// recorded here, because this is the only moment the agent can measure it.
    private func snapshotReconcileCapture(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredSnapshot else {
            throw SnapshotConvergenceError.unsupported("snapshot capture requires a desired entry")
        }
        try requireWritableSnapshotInventory()
        let snapshotId = desired.snapshotId.uuidString
        let parentId = desired.parentId.uuidString

        let facts: ObservedSnapshotFacts
        switch desired.kind {
        case .volumeSnapshot:
            // The backend's snapshot is a qcow2 overlay backed by the volume,
            // and nothing switches a running QEMU's active layer onto it — so a
            // snapshot taken while a guest is writing the base is not
            // point-in-time however well the guest was quiesced (issue #747).
            // The control plane refuses this at admission; the agent refuses it
            // again because a level-triggered entry outlives the request that
            // made it, and the volume may have been attached since.
            if let holder = desired.capture?.attachedVMId {
                throw SnapshotConvergenceError.unsupported(
                    "volume \(parentId) is attached to VM \(holder.uuidString); "
                        + "detach it before snapshotting, or the snapshot would not be point-in-time")
            }
            let backend = try requireStorageBackend()
            guard let disk = try await backend.listVolumes()[parentId] else {
                // The volume may be mid-create in this very sync; a dependency
                // wait burns no attempt and retries on the next one.
                throw SnapshotConvergenceError.sourceNotReady(
                    "volume \(parentId) is not present on this host yet")
            }
            let path = try await backend.createSnapshot(
                volumeId: parentId, snapshotId: snapshotId, volumePath: disk.path)
            facts = ObservedSnapshotFacts(
                sizeBytes: Self.fileSizeBytes(at: path),
                storagePath: path,
                architecture: CPUArchitecture.current)

        case .vmCheckpoint:
            guard let service = getHypervisorServiceForVM(vmId: parentId) else {
                throw SnapshotConvergenceError.sourceNotReady(
                    "VM \(parentId) is not present on this host yet")
            }
            let report = try await service.checkpointVM(vmId: parentId, snapshotId: snapshotId)
            facts = ObservedSnapshotFacts(
                // The machine state alone: the disks it lives inside are
                // already charged as volume storage, and an internal snapshot
                // does not copy them. Nil is "the build reported no size",
                // never "empty" — the control plane keeps its estimate.
                sizeBytes: report.vmStateSizeBytes,
                architecture: CPUArchitecture.current,
                deviceNodes: report.deviceNodes,
                qemuVersion: report.hypervisorVersion)

        case .sandboxSnapshot:
            guard let runtime = sandboxRuntime else {
                throw SnapshotConvergenceError.unsupported("this agent has no sandbox runtime")
            }
            let result = try await runtime.snapshotSandbox(
                sandboxId: parentId, snapshotId: snapshotId,
                mode: desired.capture?.sandboxMode ?? .resume)
            facts = ObservedSnapshotFacts(
                sizeBytes: result.totalSizeBytes,
                storagePath: result.storagePath,
                architecture: CPUArchitecture.current,
                memorySizeBytes: result.memorySizeBytes,
                vmstateSizeBytes: result.vmstateSizeBytes,
                rootfsSizeBytes: result.rootfsSizeBytes,
                firecrackerVersion: result.firecrackerVersion,
                guestControlProtocolVersion: result.guestControlProtocolVersion,
                forkLayoutVersion: result.forkLayoutVersion,
                cpuTemplate: result.cpuTemplate)
        }

        snapshotRecords[desired.snapshotId] = SnapshotRecord(
            snapshotId: desired.snapshotId, kind: desired.kind, parentId: desired.parentId,
            facts: facts)
        persistSnapshotRecords()
        logger.info(
            "Snapshot artifact captured",
            metadata: [
                "kind": .string(desired.kind.rawValue),
                "snapshotId": .string(snapshotId),
                "parentId": .string(parentId),
            ])
    }

    /// Remove an artifact's bytes from this host, then forget it.
    ///
    /// The record goes **after** the backend confirms, and only then: the
    /// record's absence is what the observed report turns into "this artifact
    /// is gone", which is what authorizes the control plane to reap the row.
    /// Forgetting first would confirm a deletion that had not happened and
    /// leak the bytes with nothing left pointing at them.
    ///
    /// A tombstoned artifact carries no desired entry, so its kind and parent
    /// come from the record — the same derivation the capture used, which is
    /// exactly why no path ever travels on the wire.
    private func snapshotReconcileDelete(_ item: ReconcileWorkItem) async throws {
        try requireWritableSnapshotInventory()
        guard let snapshotId = UUID(uuidString: item.id) else {
            throw SnapshotConvergenceError.unsupported("snapshot id '\(item.id)' is not a UUID")
        }
        let kind: SnapshotArtifactKind
        let parentId: UUID
        if let desired = item.desiredSnapshot {
            kind = desired.kind
            parentId = desired.parentId
        } else if let record = snapshotRecords[snapshotId] {
            kind = record.kind
            parentId = record.parentId
        } else {
            // Nothing here and nothing recorded: already converged.
            return
        }

        // Every backend's deletion is idempotent, so a re-driven delete over
        // bytes that are already gone confirms cleanly rather than failing.
        switch kind {
        case .volumeSnapshot:
            try await requireStorageBackend().deleteSnapshot(
                volumeId: parentId.uuidString, snapshotId: snapshotId.uuidString)
        case .vmCheckpoint:
            guard let service = getHypervisorServiceForVM(vmId: parentId.uuidString) else {
                // The checkpoint lives inside the VM's own disks. No VM here
                // means no disks here means no checkpoint here — the deletion
                // is satisfied, and refusing would strand the row forever on
                // the one host that can never confirm it.
                snapshotRecords.removeValue(forKey: snapshotId)
                persistSnapshotRecords()
                return
            }
            try await service.deleteVMCheckpoint(
                vmId: parentId.uuidString, snapshotId: snapshotId.uuidString)
        case .sandboxSnapshot:
            guard let runtime = sandboxRuntime else {
                throw SnapshotConvergenceError.unsupported("this agent has no sandbox runtime")
            }
            try await runtime.deleteSandboxSnapshot(
                sandboxId: parentId.uuidString, snapshotId: snapshotId.uuidString)
        }

        snapshotRecords.removeValue(forKey: snapshotId)
        persistSnapshotRecords()
        logger.info(
            "Snapshot artifact deleted",
            metadata: [
                "kind": .string(kind.rawValue),
                "snapshotId": .string(snapshotId.uuidString),
                "parentId": .string(parentId.uuidString),
            ])
    }

    /// Converge the placement fact "this artifact also exists in the control
    /// plane's object store" by streaming it there (issue #428, STR-150).
    ///
    /// The transfer itself stays a transport concern — one sequential mTLS PUT
    /// per artifact, hashed and sized control-plane-side as it lands — and only
    /// its *outcome* is state. Uploads are idempotent (each PUT replaces the
    /// object at its deterministic key), so a re-driven export after a lost
    /// report converges on the same bytes instead of duplicating them.
    private func snapshotReconcileExport(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredSnapshot, let export = desired.export else {
            throw SnapshotConvergenceError.unsupported("snapshot export requires an export target")
        }
        try requireWritableSnapshotInventory()
        guard desired.kind == .sandboxSnapshot else {
            // A VM checkpoint lives inside disks it does not own, and a volume
            // snapshot's overlay is meaningless without its backing chain;
            // neither has an off-node representation to upload. Permanent, so
            // the control plane degrades the artifact with the reason instead
            // of retrying an impossibility.
            throw SnapshotConvergenceError.unsupported(
                "\(desired.kind.rawValue) artifacts cannot be exported off this host")
        }
        guard let runtime = sandboxRuntime else {
            throw SnapshotConvergenceError.unsupported("this agent has no sandbox runtime")
        }
        try await runtime.exportSandboxSnapshot(
            sandboxId: desired.parentId.uuidString, snapshotId: desired.snapshotId.uuidString,
            uploads: export.uploads)

        snapshotRecords[desired.snapshotId]?.exported = true
        persistSnapshotRecords()
        logger.info(
            "Snapshot artifact exported",
            metadata: [
                "snapshotId": .string(desired.snapshotId.uuidString),
                "parentId": .string(desired.parentId.uuidString),
                "artifacts": .stringConvertible(export.uploads.count),
            ])
    }

    /// Refuse to converge snapshot work while the record file is unreadable.
    ///
    /// The first write after a failed read is what turns a recoverable file
    /// into a permanent loss (`VMManifestStore.save`'s rule), and every step
    /// here writes one. The reconciler already skips the snapshot half of a
    /// sync in this state — this is the belt to those braces, for work already
    /// queued when the read failed.
    private func requireWritableSnapshotInventory() throws {
        guard snapshotInventoryUnreadable else { return }
        throw SnapshotConvergenceError.unsupported(
            "this host cannot read its snapshot record file, so it will not write over it")
    }

    private func persistSnapshotRecords() {
        guard !snapshotInventoryUnreadable else { return }
        snapshotRecordStore.save(snapshotRecords)
    }

    private func applySnapshotInventory(_ inventory: SnapshotInventory) {
        switch inventory {
        case .fresh:
            snapshotRecords = [:]
            snapshotInventoryUnreadable = false
        case .loaded(let records):
            snapshotRecords = records
            snapshotInventoryUnreadable = false
            if !records.isEmpty {
                logger.info(
                    "Recovered snapshot artifacts recorded by a previous incarnation of this agent",
                    metadata: ["count": .stringConvertible(records.count)])
            }
        case .unreadable:
            // The store has already logged this loudly.
            snapshotInventoryUnreadable = true
        }
    }

    /// The allocated size of a file, or nil when it cannot be read. Nil is
    /// "unknown", never "empty" — a footprint the agent could not measure must
    /// not silently become a free one in the control plane's quota accounting.
    private static func fileSizeBytes(at path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

    private func requireStorageBackend() throws -> any StorageBackend {
        guard let storageBackend else {
            // A host with no storage backend can never grow one by retrying,
            // and the control plane only places volumes on QEMU-capable agents,
            // so this is a misconfiguration to surface rather than retry.
            throw VolumeConvergenceError.unsupported("storage backend not available on this agent")
        }
        return storageBackend
    }

    private func volumeReconcileCreate(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredVolume else {
            throw VolumeConvergenceError.unsupported("volume create requires a desired entry")
        }
        guard let format = DiskFormat(rawValue: desired.format) else {
            throw VolumeConvergenceError.unsupported("unsupported volume format '\(desired.format)'")
        }
        let backend = try requireStorageBackend()

        // The create strategy is read only here, when the volume does not yet
        // exist. A present volume never re-runs it, which is what makes a
        // replayed sync unable to clone over live data.
        let attachment: DiskAttachment
        switch desired.source?.kind {
        case DesiredVolumeSource.clone:
            guard let sourceId = desired.source?.sourceVolumeId?.uuidString else {
                throw VolumeConvergenceError.unsupported("clone source volume id missing")
            }
            // The control plane guarantees the source is on this agent, so the
            // path comes from our own inventory rather than the wire.
            guard let source = try await backend.listVolumes()[sourceId] else {
                // Genuinely a dependency, not a failure: the source may still
                // be converging earlier in this same sync.
                throw VolumeConvergenceError.sourceNotReady(
                    "source volume \(sourceId) is not present on this agent yet")
            }
            attachment = try await backend.cloneVolume(
                sourceVolumeId: sourceId, sourcePath: source.path, targetVolumeId: item.id)
        case DesiredVolumeSource.image:
            guard let imageInfo = desired.source?.imageInfo else {
                throw VolumeConvergenceError.unsupported("image create strategy carries no image info")
            }
            attachment = try await backend.createVolumeFromImage(
                volumeId: item.id, imageInfo: imageInfo, format: format)
        default:
            attachment = try await backend.createVolume(
                volumeId: item.id, sizeBytes: desired.sizeBytes, format: format)
        }

        // A cloned or image-backed volume inherits the source's size, which may
        // be smaller than what was asked for; the next sync plans the grow.
        volumeSizes[item.id] = try? await backend.volumeInfo(volumePath: attachment.path).virtualSize
        logger.info(
            "Volume converged into existence",
            metadata: [
                "volumeId": .string(item.id),
                "path": .string(attachment.path),
                "strategy": .string(desired.source?.kind ?? DesiredVolumeSource.blank),
            ])
    }

    private func volumeReconcileResize(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredVolume else {
            throw VolumeConvergenceError.unsupported("volume resize requires a desired entry")
        }
        let backend = try requireStorageBackend()
        guard let disk = try await backend.listVolumes()[item.id] else {
            throw VolumeConvergenceError.sourceNotReady("volume \(item.id) is not present on this agent")
        }
        let current = try await backend.volumeInfo(volumePath: disk.path).virtualSize
        guard desired.sizeBytes >= current else {
            // Shrinking a disk image truncates the guest's filesystem. There is
            // no retry that makes this safe, so it is permanent: the control
            // plane surfaces it as a degraded volume instead of a convergence
            // that quietly never finishes.
            throw VolumeConvergenceError.unsupported(
                "refusing to shrink volume \(item.id) from \(current) to \(desired.sizeBytes) bytes")
        }
        if desired.sizeBytes > current {
            try await backend.resizeVolume(volumePath: disk.path, newSizeBytes: desired.sizeBytes)
        }
        volumeSizes[item.id] = desired.sizeBytes
    }

    private func volumeReconcileDelete(_ item: ReconcileWorkItem) async throws {
        let backend = try requireStorageBackend()
        // Unplug before removing the bytes, or a running guest keeps an open
        // handle on a file that no longer exists. Best effort: a VM that is
        // already gone leaves nothing to unplug.
        if let attachment = recordedVolumeAttachments()[item.id] {
            try? await detachVolumeFromVM(
                volumeId: item.id, vmId: attachment.vmId, deviceName: attachment.deviceName)
        }
        try await backend.deleteVolume(volumeId: item.id)
        volumeSizes.removeValue(forKey: item.id)
        logger.info("Volume removed from this host", metadata: ["volumeId": .string(item.id)])
    }

    private func volumeReconcileAttach(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredVolume, let attachment = desired.attachment else {
            throw VolumeConvergenceError.unsupported("volume attach requires a desired attachment")
        }
        let backend = try requireStorageBackend()
        guard let disk = try await backend.listVolumes()[item.id] else {
            throw VolumeConvergenceError.sourceNotReady("volume \(item.id) is not present on this agent")
        }
        let vmId = attachment.vmId.uuidString
        guard let entry = managedVMs[vmId] ?? orphanedVMs[vmId] else {
            // The VM has not been created on this host yet — only ever a race
            // against its own convergence, since the control plane never sends
            // an attachment for a VM placed elsewhere. Classified as a
            // dependency so it burns no attempt and produces no error the
            // control plane would show an operator.
            throw VolumeConvergenceError.sourceNotReady(
                "VM \(vmId) is not present on this agent yet")
        }

        // Record first, then hot-plug. A crash in between leaves a recorded
        // attachment whose hot-plug the next sync re-drives (idempotently);
        // the other order would leave a plugged device nothing remembers, and
        // the guest would lose it at its next power cycle.
        let spec = VolumeSpec(
            volumeId: UUID(uuidString: item.id),
            deviceName: attachment.deviceName,
            storagePath: disk.path,
            readonly: attachment.readonly,
            bootOrder: attachment.bootOrder)
        await recordVolumeAttachment(spec, onVM: vmId, entry: entry)

        // A VM with no live hypervisor session (shut down, or an orphan not yet
        // re-adopted) needs no QMP at all: the record *is* the realization,
        // because the spawn path rebuilds its disk set from the manifest.
        guard let service = getHypervisorServiceForVM(vmId: vmId), await service.hasLiveSession(vmId: vmId) else {
            logger.info(
                "Recorded volume attachment for a VM with no live session; it lands at its next boot",
                metadata: ["volumeId": .string(item.id), "vmId": .string(vmId)])
            return
        }
        try await service.attachDisk(
            vmId: vmId, volumeId: item.id, volumePath: disk.path,
            deviceName: attachment.deviceName.rawValue, readonly: attachment.readonly)
    }

    private func volumeReconcileDetach(_ item: ReconcileWorkItem) async throws {
        guard let attachment = recordedVolumeAttachments()[item.id] else { return }
        try await detachVolumeFromVM(
            volumeId: item.id, vmId: attachment.vmId, deviceName: attachment.deviceName)
    }

    private func detachVolumeFromVM(volumeId: String, vmId: String, deviceName: String) async throws {
        // Unplug first, then drop the record: the inverse order of attach, and
        // for the inverse reason. A crash between the two leaves a record for a
        // device that is already gone, which the next sync's detach clears
        // idempotently; dropping the record first would strand a plugged device
        // nothing describes.
        if let service = getHypervisorServiceForVM(vmId: vmId), await service.hasLiveSession(vmId: vmId) {
            try await service.detachDisk(vmId: vmId, volumeId: volumeId, deviceName: deviceName)
        }
        guard let entry = managedVMs[vmId] ?? orphanedVMs[vmId] else { return }
        let remaining = entry.spec.volumes.filter { $0.volumeId?.uuidString != volumeId }
        let updated = VMManifestEntry(
            hypervisorType: entry.hypervisorType, spec: entry.spec.withVolumes(remaining))
        if managedVMs[vmId] != nil {
            managedVMs[vmId] = updated
        } else {
            orphanedVMs[vmId] = updated
        }
        persistManifest()
        if let service = getHypervisorServiceForVM(vmId: vmId) {
            await service.updateRecordedVolumes(vmId: vmId, volumes: remaining)
        }
    }

    /// Writes an attachment into the VM's manifest entry and into the driver's
    /// stored spawn configuration, so it survives both a guest power cycle
    /// (which respawns from that configuration) and an agent restart (which
    /// reloads the manifest).
    private func recordVolumeAttachment(_ spec: VolumeSpec, onVM vmId: String, entry: VMManifestEntry) async {
        var volumes = entry.spec.volumes.filter { $0.volumeId != spec.volumeId }
        volumes.append(spec)
        volumes.sort { lhs, rhs in
            switch (lhs.bootOrder, rhs.bootOrder) {
            case (let a?, let b?): return a < b
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.deviceName < rhs.deviceName
            }
        }
        let updated = VMManifestEntry(
            hypervisorType: entry.hypervisorType, spec: entry.spec.withVolumes(volumes))
        if managedVMs[vmId] != nil {
            managedVMs[vmId] = updated
        } else {
            orphanedVMs[vmId] = updated
        }
        persistManifest()
        if let service = getHypervisorServiceForVM(vmId: vmId) {
            await service.updateRecordedVolumes(vmId: vmId, volumes: volumes)
        }
    }

    private func reconcileService(for vmId: String) throws -> any HypervisorService {
        guard let service = getHypervisorServiceForVM(vmId: vmId) else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        return service
    }

    private func reconcileCreate(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desired else {
            throw HypervisorServiceError.invalidConfiguration("create work item without a desired entry")
        }
        guard let service = getHypervisorService(for: desired.hypervisorType) else {
            throw HypervisorServiceError.hypervisorNotInstalled(desired.hypervisorType.rawValue)
        }

        // Same contract as the imperative path: the orchestrator realizes the
        // VM's NICs on this host before the driver runs, and rolls them back
        // if the driver never created the VM.
        let attachments = try await networkOrchestrator.prepareAttachments(
            vmId: item.vmId, networks: desired.spec.networks)
        do {
            try await service.createVM(
                vmId: item.vmId, spec: desired.spec, imageInfo: desired.imageInfo,
                networkAttachments: attachments, metadata: desired.metadata)
        } catch {
            await networkOrchestrator.teardownAttachments(vmId: item.vmId, count: attachments.count)
            throw error
        }

        managedVMs[item.vmId] = VMManifestEntry(hypervisorType: desired.hypervisorType, spec: desired.spec)
        orphanedVMs.removeValue(forKey: item.vmId)
        persistManifest()
        await sendVMLog(
            vmId: item.vmId, level: .info, eventType: .statusChange,
            message: "VM created by reconciliation", operation: "create", newStatus: .created)
    }

    /// Applies a running VM's new vCPU/memory sizing (issue #568) and records
    /// it in the manifest, so the next sync diffs against what the VM is now
    /// actually running with instead of re-planning the same resize forever.
    ///
    /// The manifest write happens only after the driver reports success:
    /// recording the new sizing first would make a failed resize look applied
    /// and silently strand the VM at its old size.
    private func reconcileResize(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desired else {
            throw HypervisorServiceError.invalidConfiguration("resize work item without a desired entry")
        }
        guard let entry = managedVMs[item.vmId] else {
            throw HypervisorServiceError.vmNotFound(item.vmId)
        }
        let service = try reconcileService(for: item.vmId)
        try await service.resizeVM(vmId: item.vmId, spec: desired.spec)

        managedVMs[item.vmId] = VMManifestEntry(hypervisorType: entry.hypervisorType, spec: desired.spec)
        persistManifest()
        await sendVMLog(
            vmId: item.vmId, level: .info, eventType: .operation,
            message: "VM resized to \(desired.spec.cpus) vCPUs and \(desired.spec.memoryBytes) bytes of memory",
            operation: "resize")
    }

    /// Re-adopts an orphan that is being deleted, classifying a failure by
    /// whether it says the hypervisor process is gone (`OrphanDeleteAdoption`).
    /// The distinction is the whole point: `try?` here discarded it, and the
    /// resulting delete could never tell a VM whose process is gone (reclaim
    /// its directory) from a live one this agent cannot reach (leave it alone).
    private func adoptOrphanForDelete(
        vmId: String, entry: VMManifestEntry, service: (any HypervisorService)?
    ) async -> OrphanDeleteAdoption {
        guard let service else { return .indeterminate }
        do {
            _ = try await service.adoptVM(vmId: vmId, spec: entry.spec)
            return .adopted
        } catch {
            let adoption = OrphanDeleteAdoption.classify(adoptionFailure: error)
            logger.log(
                level: adoption == .processGone ? .info : .warning,
                "Could not re-adopt an orphaned VM to delete it",
                metadata: [
                    "vmId": .string(vmId),
                    "adoption": .string(String(describing: adoption)),
                    "error": .string(error.localizedDescription),
                ])
            return adoption
        }
    }

    private func reconcileDelete(_ item: ReconcileWorkItem) async throws {
        // Orphan with no live session: try to re-adopt first so the surviving
        // hypervisor process is actually torn down instead of leaking. If the
        // session cannot be reattached, fall back to releasing the manifest
        // entry, reclaiming as much as the failure proves is safe to reclaim.
        if managedVMs[item.vmId] == nil, let entry = orphanedVMs[item.vmId] {
            let service = getHypervisorService(for: entry.hypervisorType)
            let adoption = await adoptOrphanForDelete(vmId: item.vmId, entry: entry, service: service)
            switch adoption {
            case .adopted:
                managedVMs[item.vmId] = entry

            case .processGone, .indeterminate:
                // Reclaim before releasing the manifest entry, not after: that
                // entry is the only record on this host that the VM was ever
                // here, so a crash between the two must leave the record
                // standing rather than the files (STR-179). A replayed delete
                // re-reclaims harmlessly. `reclaimVMDirectory` reports its own
                // outcome — success and failure both — so nothing is claimed
                // about the removal here.
                if adoption == .processGone, let service {
                    // Nothing is running from this VM's disks, so its whole
                    // directory — boot disk included — goes with it.
                    await service.reclaimVMDirectory(vmId: item.vmId)
                } else {
                    logger.warning(
                        "Deleting an orphaned VM this agent could not re-adopt; any surviving hypervisor process and the VM's files must be cleaned up manually",
                        metadata: ["vmId": .string(item.vmId)])
                }

                orphanedVMs.removeValue(forKey: item.vmId)
                persistManifest()
                // Host-side network resources are derived from deterministic
                // names, so they can be torn down even with no live session.
                await networkOrchestrator.teardownAttachments(
                    vmId: item.vmId, count: entry.spec.networks.count)
                return
            }
        }

        guard let entry = managedVMs[item.vmId] else {
            return  // already absent — deletion is idempotent
        }
        let service = try reconcileService(for: item.vmId)

        // Stop gracefully first when the VM is actually running; deleting a
        // resting VM skips straight to teardown.
        let status = (try? await service.getVMStatus(vmId: item.vmId)) ?? .unknown
        if status == .running || status == .paused {
            try await service.stopAndDeleteVM(vmId: item.vmId)
        } else {
            try await service.deleteVM(vmId: item.vmId)
        }

        // Tear down the VM's host-side network resources now that the
        // hypervisor session is gone (best-effort; never blocks deletion).
        await networkOrchestrator.teardownAttachments(
            vmId: item.vmId, count: entry.spec.networks.count)

        managedVMs.removeValue(forKey: item.vmId)
        orphanedVMs.removeValue(forKey: item.vmId)
        persistManifest()
        await sendVMLog(
            vmId: item.vmId, level: .info, eventType: .operation,
            message: "VM deleted by reconciliation", operation: "delete")
    }

    // MARK: Sandbox actuation (issue #417)

    private func requireSandboxRuntime() throws -> any SandboxRuntimeService {
        guard let sandboxRuntime else {
            throw SandboxRuntimeError.runtimeUnavailable
        }
        return sandboxRuntime
    }

    private func performSandbox(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
        switch step {
        case .adopt:
            // Adoption flows through adoptSandbox (the reconciler needs the
            // observed status back to plan the remaining steps).
            _ = try await adoptSandbox(item)
        case .create:
            try await sandboxReconcileCreate(item)
        case .boot:
            try await requireSandboxRuntime().bootSandbox(sandboxId: item.id)
        case .shutdown:
            try await requireSandboxRuntime().shutdownSandbox(sandboxId: item.id)
        case .delete:
            try await sandboxReconcileDelete(item)
        case .pause, .resume, .resize, .attach, .detach, .export:
            // Not in the sandbox step vocabulary (v1); the planner never
            // emits these for sandbox items. `.export` acts on a sandbox's
            // *snapshot*, not on the sandbox, and arrives as a snapshot item.
            throw SandboxRuntimeError.unsupportedStep(String(describing: step))
        }
    }

    /// Where this host realizes a sandbox's NIC (issue STR-100).
    ///
    /// A sandbox NIC lives inside the jail's network namespace, which only
    /// exists when the jailer barrier is on. An unjailed sandbox has no
    /// namespace to attach into and no privilege boundary the attachment is
    /// protecting, so a networked spec is refused rather than quietly realized
    /// in the host namespace — the isolation is the point.
    ///
    /// `forTeardown` derives the placement even on an agent that no longer jails
    /// new sandboxes: the jail layout is built unconditionally precisely so a
    /// previous life's jailed leftovers can still be cleaned up.
    private func sandboxNICPlacement(sandboxId: String) throws -> NICPlacement {
        guard sandboxJailNewSandboxes, let jailerConfig = sandboxJailerConfig else {
            throw SandboxRuntimeError.networkingUnsupported(
                "a sandbox NIC lives in the jail's network namespace, and this agent creates sandboxes "
                    + "unjailed; set sandbox_jailer_mode = \"required\" and satisfy its prerequisites")
        }
        let plan = SandboxJailPlan(
            sandboxId: sandboxId, config: jailerConfig, firecrackerBinaryPath: firecrackerBinaryPath)
        return .sandboxNetns(
            netnsName: plan.netnsName, owner: JailOwner(uid: plan.uid, gid: plan.gid))
    }

    /// The placement teardown should use. Never throws, and never degrades to
    /// the host-namespace path: a sandbox NIC that was created jailed must be
    /// removed as one, or `sbx-<id>` stays in OVN NB and the veth stays on
    /// `br-int` while the VM teardown deletes `vm-<id>` and a TAP that never
    /// existed — silently, because teardown swallows errors by design.
    ///
    /// Nothing here needs the jailer config: the namespace name and all three
    /// device names come from the sandbox id, and ownership is create-only. So
    /// cleanup keeps working on an agent whose sandbox runtime was deconfigured
    /// since the sandbox was created, which is exactly the case that used to
    /// leak.
    private func sandboxTeardownPlacement(sandboxId: String) -> NICPlacement {
        .sandboxNetns(netnsName: SandboxJailPlan.netnsName(sandboxId: sandboxId), owner: nil)
    }

    private func sandboxReconcileCreate(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredSandbox else {
            throw HypervisorServiceError.invalidConfiguration("create work item without a desired entry")
        }
        let runtime = try requireSandboxRuntime()

        // Resolve the placement before reserving anything, so a host that
        // cannot realize a sandbox NIC at all surfaces the permanent reason
        // immediately instead of a transient network-prep failure that retries
        // until the operation budget expires.
        let networks = desired.spec.network.map { [$0] } ?? []
        // A network-free sandbox never reaches the placement, so don't refuse an
        // unjailed one over a NIC it doesn't have.
        let placement =
            networks.isEmpty ? NICPlacement.hostNamespace : try sandboxNICPlacement(sandboxId: item.id)

        // Same contract as the VM path: the orchestrator realizes the
        // sandbox's NIC on this host before the runtime runs, and rolls it
        // back if the runtime never created the sandbox.
        let attachments = try await networkOrchestrator.prepareAttachments(
            vmId: item.id, networks: networks, placement: placement)
        do {
            try await runtime.createSandbox(
                sandboxId: item.id, spec: desired.spec,
                registryCredential: desired.registryCredential, networkAttachments: attachments)
        } catch {
            await networkOrchestrator.teardownAttachments(
                vmId: item.id, count: attachments.count, placement: placement)
            throw error
        }

        managedSandboxes[item.id] = VMManifestEntry(sandboxSpec: desired.spec)
        orphanedSandboxes.removeValue(forKey: item.id)
        persistManifest()
    }

    private func sandboxReconcileDelete(_ item: ReconcileWorkItem) async throws {
        // Orphan with no live session: try to re-adopt first so the surviving
        // process is actually torn down instead of leaking. If the session
        // cannot be reattached (no runtime in this build, dead process), fall
        // back to releasing the manifest entry — the same manual-cleanup
        // contract as the VM path.
        if managedSandboxes[item.id] == nil, let entry = orphanedSandboxes[item.id] {
            if let runtime = sandboxRuntime, let spec = entry.sandboxSpec,
                (try? await runtime.adoptSandbox(sandboxId: item.id, spec: spec)) != nil
            {
                managedSandboxes[item.id] = entry
            } else {
                orphanedSandboxes.removeValue(forKey: item.id)
                persistManifest()
                // Host-side network resources are derived from deterministic
                // names, so they can be torn down even with no live session.
                await networkOrchestrator.teardownAttachments(
                    vmId: item.id, count: entry.sandboxSpec?.network != nil ? 1 : 0,
                    placement: sandboxTeardownPlacement(sandboxId: item.id))
                logger.warning(
                    "Deleted orphaned sandbox from manifest; any surviving process must be cleaned up manually",
                    metadata: ["sandboxId": .string(item.id)])
                return
            }
        }

        guard let entry = managedSandboxes[item.id] else {
            return  // already absent — deletion is idempotent
        }
        try await requireSandboxRuntime().deleteSandbox(sandboxId: item.id)

        await networkOrchestrator.teardownAttachments(
            vmId: item.id, count: entry.sandboxSpec?.network != nil ? 1 : 0,
            placement: sandboxTeardownPlacement(sandboxId: item.id))

        managedSandboxes.removeValue(forKey: item.id)
        orphanedSandboxes.removeValue(forKey: item.id)
        persistManifest()
    }

    /// Assemble and send the full observed state of this host: every managed
    /// VM with its live status, still-orphaned VMs, and VMs mid-convergence
    /// that don't exist on a hypervisor yet. Full-list semantics — a VM absent
    /// from the report does not exist here, which is how the control plane
    /// confirms deletions.
    func sendObservedStateReport() async {
        guard assignedAgentID != nil, let reconciler else { return }

        observedReportEpoch += 1
        let epoch = observedReportEpoch

        var observed: [ObservedVMState] = []
        var reported = Set<String>()

        for (vmId, entry) in managedVMs {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            let status: VMStatus
            if let service = hypervisorServices[entry.hypervisorType] {
                status = (try? await service.getVMStatus(vmId: vmId)) ?? .unknown
            } else {
                status = .unknown
            }
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: status,
                    observedGeneration: await reconciler.observedGeneration(for: vmId),
                    convergencePhase: await reconciler.convergencePhase(for: vmId),
                    lastError: await reconciler.lastError(for: vmId),
                    failedGeneration: await reconciler.failedGeneration(for: vmId),
                    // Last-known guest-agent view (issue #563) and balloon
                    // memory stats (issue #567); nil until the slow poll first
                    // sees a responsive qga / reporting balloon on this VM.
                    guestInfo: guestInfoCache[vmId],
                    memoryStats: memoryStatsCache[vmId]
                ))
            reported.insert(vmId)
        }

        // Orphans carry no synthesized error: fabricating a `lastError` in the
        // post-registration baseline report (sent while re-adoption is still
        // queued) would fail pending operations on the control plane seconds
        // before the registration sync's adopt converges them. Real adoption
        // failures surface through the reconciler's failure tracking.
        for vmId in orphanedVMs.keys where !reported.contains(vmId) {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: .unknown,
                    observedGeneration: await reconciler.observedGeneration(for: vmId),
                    convergencePhase: await reconciler.convergencePhase(for: vmId),
                    lastError: await reconciler.lastError(for: vmId),
                    failedGeneration: await reconciler.failedGeneration(for: vmId)
                ))
            reported.insert(vmId)
        }

        // Workloads whose manifest entry this build cannot route (STR-138).
        // They must appear here: a VM missing from this list is read as gone,
        // which would either confirm a deletion that never happened or drive
        // a live guest to `.error`. Status is `.unknown` with no synthesized
        // error, exactly like an orphan — the reason the agent can't act on
        // them travels on `manifestStatus` below, once, rather than as a
        // per-VM failure that would fail their pending operations.
        for (vmId, entry) in quarantinedWorkloads
        where entry.effectiveKind == .vm && !reported.contains(vmId) {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: .unknown,
                    observedGeneration: await reconciler.observedGeneration(for: vmId),
                    convergencePhase: await reconciler.convergencePhase(for: vmId),
                    lastError: await reconciler.lastError(for: vmId),
                    failedGeneration: await reconciler.failedGeneration(for: vmId)
                ))
            reported.insert(vmId)
        }

        // VMs still converging toward first existence (mid-create): include
        // them so the control plane sees progress and never mistakes an
        // in-flight create for an absence.
        for (vmId, _) in await reconciler.inFlightWorkloads(kind: .vm) where !reported.contains(vmId) {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: .unknown,
                    observedGeneration: await reconciler.observedGeneration(for: vmId),
                    convergencePhase: await reconciler.convergencePhase(for: vmId) ?? "converging",
                    lastError: await reconciler.lastError(for: vmId),
                    failedGeneration: await reconciler.failedGeneration(for: vmId)
                ))
            reported.insert(vmId)
        }

        // VMs whose convergence failed and that have no hypervisor presence
        // (e.g. a create that never produced a process): reported with the
        // error so the control plane can fail the pending operation with the
        // real reason instead of waiting out its budget.
        for (vmId, failure) in await reconciler.failedConvergences(kind: .vm) where !reported.contains(vmId) {
            guard let uuid = UUID(uuidString: vmId) else { continue }
            observed.append(
                ObservedVMState(
                    vmId: uuid,
                    status: .unknown,
                    observedGeneration: await reconciler.observedGeneration(for: vmId),
                    convergencePhase: nil,
                    lastError: failure.error,
                    failedGeneration: failure.generation
                ))
        }

        let report = ObservedStateReport(
            agentId: effectiveAgentID,
            vms: observed,
            sandboxes: await observedSandboxStates(reconciler: reconciler),
            resources: await getAgentResources(),
            agentUpdateStatus: autoUpdateStatus,
            // Workloads this host holds that no sync accounted for (STR-98).
            // They also appear above — the agent is genuinely running them —
            // and stay there until the control plane decides what they are.
            unrecognized: await reconciler.unrecognizedWorkloads(),
            teardownRefusal: await reconciler.lastTeardownRefusal(),
            // What the agent's own memory of this host was able to tell it
            // (STR-138). When the manifest is unreadable this also declares
            // the lists above to be no inventory at all, so the control plane
            // reads no absence from them.
            manifestStatus: manifestStatus(),
            // A list when this agent can account for its volume store — an
            // empty one is the honest "I hold no volumes" the control plane
            // needs to confirm deletions — and nil when it cannot enumerate the
            // store at all, which the control plane reads as "no opinion"
            // rather than as an inventory (STR-148).
            volumes: await observedVolumeStates(reconciler: reconciler),
            // Same list-or-nil contract as `volumes`, one step more expensive
            // to get wrong: an empty list the control plane believed would reap
            // every checkpoint row it holds for this agent, and a checkpoint is
            // a point in time nothing can recreate (STR-150).
            snapshots: await observedSnapshotStates(reconciler: reconciler)
        )
        // A newer report started while this one was assembling — which is
        // exactly what happens when this one overran its budget and was
        // abandoned. Sending now would apply stale observations on top of
        // fresher ones and could flip VM status backward.
        guard epoch == observedReportEpoch else {
            logger.debug(
                "Discarding superseded observed-state report",
                metadata: [
                    "epoch": .stringConvertible(epoch),
                    "current": .stringConvertible(observedReportEpoch),
                ])
            return
        }

        do {
            try await websocketClient?.sendMessage(report)
        } catch {
            logger.error("Failed to send observed-state report: \(error)")
        }
    }

    /// What this agent's durable manifest was able to tell it, for the report
    /// (STR-138). Nil in the steady state — the manifest read cleanly and
    /// every entry in it is routable.
    ///
    /// This is the operator's signal. The failure it describes used to be one
    /// `logger.error` line on a node that had already started accepting new
    /// placements; on the row it becomes something the agents UI shows.
    private func manifestStatus() -> ObservedManifestStatus? {
        if let failure = manifestReadFailure {
            var reason = "Workload manifest at \(failure.path) \(failure.reason)."
            reason +=
                " This host's workloads are unknown: it is advertising no capacity and converging nothing"
                + " until the manifest is repaired, or the agent is restarted after removing it."
            if let preserved = failure.preservedCopyPath {
                reason += " A copy of the unreadable file was preserved at \(preserved)."
            }
            return ObservedManifestStatus(
                inventoryComplete: false,
                quarantinedEntries: quarantinedWorkloads.count,
                reason: reason,
                preservedCopyPath: failure.preservedCopyPath
            )
        }

        guard !quarantinedWorkloads.isEmpty else { return nil }
        let reasons = Set(quarantinedWorkloads.values.map(\.reason)).sorted()
        return ObservedManifestStatus(
            inventoryComplete: true,
            quarantinedEntries: quarantinedWorkloads.count,
            reason:
                "\(quarantinedWorkloads.count) workload(s) in this host's manifest cannot be routed by this agent build "
                + "(\(reasons.joined(separator: "; "))). They keep running and keep reserving capacity, but nothing "
                + "here can start, stop, or delete them — run an agent build that understands them."
        )
    }

    /// Assemble the sandbox half of the observed-state report, mirroring the
    /// VM assembly section by section: managed sandboxes with their live
    /// status, still-orphaned ones, unroutable manifest entries, in-flight
    /// creates, and failed convergences with no runtime presence. Same
    /// full-list semantics — a sandbox absent from the report does not exist
    /// here.
    private func observedSandboxStates(reconciler: Reconciler) async -> [ObservedSandboxState] {
        var observed: [ObservedSandboxState] = []
        var reported = Set<String>()

        for sandboxId in managedSandboxes.keys {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            var status: SandboxStatus = .unknown
            var exitCode: Int?
            if let runtime = sandboxRuntime {
                status = (try? await runtime.getSandboxStatus(sandboxId: sandboxId)) ?? .unknown
                if status == .exited {
                    exitCode = await runtime.exitCode(sandboxId: sandboxId)
                }
            }
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: status,
                    observedGeneration: await reconciler.observedGeneration(for: sandboxId, kind: .sandbox),
                    convergencePhase: await reconciler.convergencePhase(for: sandboxId, kind: .sandbox),
                    lastError: await reconciler.lastError(for: sandboxId, kind: .sandbox),
                    failedGeneration: await reconciler.failedGeneration(for: sandboxId, kind: .sandbox),
                    exitCode: exitCode
                ))
            reported.insert(sandboxId)
        }

        // Orphans carry no synthesized error, for the same reason as VM
        // orphans: real adoption failures surface through the reconciler's
        // failure tracking.
        for sandboxId in orphanedSandboxes.keys where !reported.contains(sandboxId) {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: .unknown,
                    observedGeneration: await reconciler.observedGeneration(for: sandboxId, kind: .sandbox),
                    convergencePhase: await reconciler.convergencePhase(for: sandboxId, kind: .sandbox),
                    lastError: await reconciler.lastError(for: sandboxId, kind: .sandbox),
                    failedGeneration: await reconciler.failedGeneration(for: sandboxId, kind: .sandbox)
                ))
            reported.insert(sandboxId)
        }

        // Sandboxes whose manifest entry this build cannot route (STR-138),
        // reported for the same reason as their VM counterparts: absence here
        // confirms a deletion, and nothing was deleted.
        for (sandboxId, entry) in quarantinedWorkloads
        where entry.effectiveKind == .sandbox && !reported.contains(sandboxId) {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: .unknown,
                    observedGeneration: await reconciler.observedGeneration(for: sandboxId, kind: .sandbox),
                    convergencePhase: await reconciler.convergencePhase(for: sandboxId, kind: .sandbox),
                    lastError: await reconciler.lastError(for: sandboxId, kind: .sandbox),
                    failedGeneration: await reconciler.failedGeneration(for: sandboxId, kind: .sandbox)
                ))
            reported.insert(sandboxId)
        }

        // Sandboxes still converging toward first existence (mid-create).
        for (sandboxId, _) in await reconciler.inFlightWorkloads(kind: .sandbox)
        where !reported.contains(sandboxId) {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: .unknown,
                    observedGeneration: await reconciler.observedGeneration(for: sandboxId, kind: .sandbox),
                    convergencePhase: await reconciler.convergencePhase(for: sandboxId, kind: .sandbox)
                        ?? "converging",
                    lastError: await reconciler.lastError(for: sandboxId, kind: .sandbox),
                    failedGeneration: await reconciler.failedGeneration(for: sandboxId, kind: .sandbox)
                ))
            reported.insert(sandboxId)
        }

        // Sandboxes whose convergence failed with no runtime presence (e.g. a
        // create that never produced anything), so the control plane can fail
        // the pending operation with the real reason.
        for (sandboxId, failure) in await reconciler.failedConvergences(kind: .sandbox)
        where !reported.contains(sandboxId) {
            guard let uuid = UUID(uuidString: sandboxId) else { continue }
            observed.append(
                ObservedSandboxState(
                    sandboxId: uuid,
                    status: .unknown,
                    observedGeneration: await reconciler.observedGeneration(for: sandboxId, kind: .sandbox),
                    convergencePhase: nil,
                    lastError: failure.error,
                    failedGeneration: failure.generation
                ))
        }

        return observed
    }

    /// Every snapshot artifact this host holds, plus the ones still being
    /// captured or failed with nothing written (STR-150).
    ///
    /// Full-list, like `vms` and `volumes`: the control plane confirms a
    /// deletion by this list *omitting* the artifact, so the in-flight and
    /// failed entries below matter — they are what keeps a slow capture from
    /// reading as "already gone" and reaping a row whose bytes are about to
    /// appear.
    private func observedSnapshotStates(reconciler: Reconciler) async -> [ObservedSnapshotState]? {
        guard let present = await observedSnapshotPresence() else { return nil }

        var observed: [ObservedSnapshotState] = []
        var reported = Set<String>()

        for (snapshotId, presence) in present {
            guard let uuid = UUID(uuidString: snapshotId), case .managed(let artifact) = presence
            else { continue }
            let kind = artifact.kind.workloadKind
            observed.append(
                ObservedSnapshotState(
                    snapshotId: uuid,
                    kind: artifact.kind,
                    parentId: artifact.parentId,
                    present: true,
                    exported: artifact.exported,
                    facts: artifact.facts,
                    observedGeneration: await reconciler.observedGeneration(for: snapshotId, kind: kind),
                    convergencePhase: await reconciler.convergencePhase(for: snapshotId, kind: kind),
                    lastError: await reconciler.lastError(for: snapshotId, kind: kind),
                    failedGeneration: await reconciler.failedGeneration(for: snapshotId, kind: kind)
                ))
            reported.insert(snapshotId)
        }

        // In-flight and failed captures have no record yet — a capture writes
        // one only once it succeeds — so the artifact's identity has to come
        // from the reconciler's own bookkeeping, which is keyed by kind. That
        // is exactly what the three `WorkloadKind` cases buy: the family is
        // known without a record to read it from. The parent is not, and is
        // deliberately left as the artifact's own id rather than guessed: the
        // control plane only reads `parentId` from an entry it can act on, and
        // an entry with `present: false` is progress, not an inventory.
        for family in SnapshotArtifactKind.allCases {
            let kind = family.workloadKind
            for (snapshotId, _) in await reconciler.inFlightWorkloads(kind: kind)
            where !reported.contains(snapshotId) {
                guard let uuid = UUID(uuidString: snapshotId) else { continue }
                observed.append(
                    ObservedSnapshotState(
                        snapshotId: uuid,
                        kind: family,
                        parentId: uuid,
                        present: false,
                        observedGeneration: await reconciler.observedGeneration(for: snapshotId, kind: kind),
                        convergencePhase: await reconciler.convergencePhase(for: snapshotId, kind: kind)
                            ?? "converging",
                        lastError: await reconciler.lastError(for: snapshotId, kind: kind),
                        failedGeneration: await reconciler.failedGeneration(for: snapshotId, kind: kind)
                    ))
                reported.insert(snapshotId)
            }

            for (snapshotId, failure) in await reconciler.failedConvergences(kind: kind)
            where !reported.contains(snapshotId) {
                guard let uuid = UUID(uuidString: snapshotId) else { continue }
                observed.append(
                    ObservedSnapshotState(
                        snapshotId: uuid,
                        kind: family,
                        parentId: uuid,
                        present: false,
                        observedGeneration: await reconciler.observedGeneration(for: snapshotId, kind: kind),
                        convergencePhase: nil,
                        lastError: failure.error,
                        failedGeneration: failure.generation
                    ))
                reported.insert(snapshotId)
            }
        }

        return observed
    }

    /// Every volume this host holds, plus the ones still converging toward
    /// first existence or failed with no bytes at all (STR-148).
    ///
    /// Full-list, like `vms`: the control plane confirms a deletion by this
    /// list *omitting* the volume, so the in-flight and failed entries below
    /// matter — they are what keeps a slow create from reading as "already
    /// gone" and reaping a row whose data is about to appear.
    private func observedVolumeStates(reconciler: Reconciler) async -> [ObservedVolumeState]? {
        // Nil propagates all the way to the wire, where the control plane
        // already reads it as "this agent has no opinion about volumes" and
        // skips its whole volume half. That is the same treatment a pre-v31
        // agent gets, and for the same reason: the alternative is an empty list
        // the control plane would believe, reaping terminating volume rows
        // whose bytes are still on disk and erroring every live one.
        guard let present = await observedVolumePresence() else { return nil }

        var observed: [ObservedVolumeState] = []
        var reported = Set<String>()

        for (volumeId, presence) in present {
            guard let uuid = UUID(uuidString: volumeId), case .managed(let facts) = presence else { continue }
            observed.append(
                ObservedVolumeState(
                    volumeId: uuid,
                    present: true,
                    storagePath: facts.path,
                    format: facts.format.rawValue,
                    attachedVMId: facts.attachedVMId.flatMap { UUID(uuidString: $0) },
                    deviceName: facts.deviceName,
                    observedGeneration: await reconciler.observedGeneration(for: volumeId, kind: .volume),
                    convergencePhase: await reconciler.convergencePhase(for: volumeId, kind: .volume),
                    lastError: await reconciler.lastError(for: volumeId, kind: .volume),
                    failedGeneration: await reconciler.failedGeneration(for: volumeId, kind: .volume)
                ))
            reported.insert(volumeId)
        }

        for (volumeId, _) in await reconciler.inFlightWorkloads(kind: .volume) where !reported.contains(volumeId) {
            guard let uuid = UUID(uuidString: volumeId) else { continue }
            observed.append(
                ObservedVolumeState(
                    volumeId: uuid,
                    present: false,
                    observedGeneration: await reconciler.observedGeneration(for: volumeId, kind: .volume),
                    convergencePhase: await reconciler.convergencePhase(for: volumeId, kind: .volume)
                        ?? "converging",
                    lastError: await reconciler.lastError(for: volumeId, kind: .volume),
                    failedGeneration: await reconciler.failedGeneration(for: volumeId, kind: .volume)
                ))
            reported.insert(volumeId)
        }

        for (volumeId, failure) in await reconciler.failedConvergences(kind: .volume)
        where !reported.contains(volumeId) {
            guard let uuid = UUID(uuidString: volumeId) else { continue }
            observed.append(
                ObservedVolumeState(
                    volumeId: uuid,
                    present: false,
                    observedGeneration: await reconciler.observedGeneration(for: volumeId, kind: .volume),
                    convergencePhase: nil,
                    lastError: failure.error,
                    failedGeneration: failure.generation
                ))
        }

        return observed
    }
}
