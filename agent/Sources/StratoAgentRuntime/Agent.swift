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
        case .spiffeConfigurationError(let message):
            return "SPIFFE configuration error: \(message)"
        }
    }
}

actor Agent {
    struct GuestExecSessionRoute: Sendable {
        let resourceKind: GuestResourceKind
        let sessionKind: GuestExecSessionKind
    }

    let initialAgentID: String  // ID used for registration (hostname or CLI arg)
    var assignedAgentID: String?  // UUID assigned by control plane after registration
    // The URL to dial. It carries no credential — the agent authenticates with
    // its SPIFFE X.509 SVID over mTLS — only the agent's `name`.
    let webSocketURL: String
    let logger: Logger

    /// The HTTP(S) base of the control plane, derived from the dialed
    /// WebSocket URL: query off first (the `name` parameter would otherwise
    /// trail every request), scheme swapped to HTTP, `/agent/ws` suffix
    /// dropped. Relative image-download paths resolve against this base and
    /// are fetched over SVID mTLS (issue #493) — the same Envoy listener that
    /// carries the WebSocket.
    var controlPlaneHTTPBase: String {
        (WebSocketURLs.removingQuery(from: webSocketURL) ?? webSocketURL)
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "/agent/ws", with: "")
    }

    var websocketClient: WebSocketClient?
    // Registry of hypervisor drivers keyed by backend type, populated once in
    // start(). This registry and `getHypervisorService(for:)` are the only
    // places message handling may reach the concrete services — everything
    // else goes through the `HypervisorService` protocol, so adding a backend
    // means one new registration here (plus the enum case and its data tables
    // in HypervisorTypes.swift), not new switch sites.
    var hypervisorServices: [HypervisorType: any HypervisorService] = [:]
    var networkService: (any NetworkServiceProtocol)?
    var imageCacheService: ImageCacheService?
    var storageBackend: (any StorageBackend)?
    var storageBackends: StorageBackendRegistry?
    var consoleSocketManager: ConsoleSocketManager?
    var reconnectTask: Task<Void, Never>?
    var reconnectState = ControlPlaneReconnectState()
    var interactiveSessionFence = ControlPlaneInteractiveSessionFence()
    var isRunning = false
    // Set once a graceful shutdown has been requested (e.g. by a signal
    // handler calling stop()). Guards start() against parking if stop() ran
    // during startup, which would otherwise hang the process on exit.
    var shutdownRequested = false
    // Resumed by stop() to unblock start(), which parks here for the agent's
    // lifetime instead of busy-sleeping.
    var shutdownContinuation: CheckedContinuation<Void, Never>?
    var registrationContinuation: CheckedContinuation<String, Error>?
    // Bound to `registrationContinuation`: cancelled the moment the continuation
    // is resolved so a resolved registration never leaves a 30s timer dangling.
    var registrationTimeoutTask: Task<Void, Never>?
    // Incremented per registration attempt so a timeout fired by a superseded
    // attempt can be told apart from — and can't fail — the current one.
    var registrationGeneration: UInt64 = 0
    let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

    // Ordered inbound-message pipeline. The WebSocket client yields decoded frames into
    // `inboundContinuation` in arrival order; `messageConsumerTask` drains the stream and
    // routes each frame onto a per-resource serial lane in `messageQueue`, so operations on
    // the same VM/volume are applied in the order the control plane sent them (issue #179).
    nonisolated let inboundMessages: AsyncStream<ControlPlaneInboundFrame>
    nonisolated let inboundContinuation: AsyncStream<ControlPlaneInboundFrame>.Continuation
    let messageQueue = SerialTaskQueue()
    var messageConsumerTask: Task<Void, Never>?

    // Reconciliation phase 2 (issue #260): converges hypervisor reality toward
    // the control plane's desired-state syncs. Work items run on per-VM serial
    // lanes, so two items can never interleave operations on one VM.
    var reconciler: Reconciler?
    // What this host's link-local metadata service serves its guests (STR-52),
    // written by the reconciler from each sync's `DesiredVMState.metadata`.
    // Owned here rather than by the reconciler because the guest-facing
    // listener will read the same instance.
    let metadataStore = MetadataStore()
    // The durable copy of that store (STR-56), so a restarted agent keeps
    // answering its guests even while the control plane is unreachable.
    let metadataSnapshotStore: MetadataSnapshotStore
    // One guest-facing listener per network this host serves metadata on.
    var metadataServers: MetadataServerSupervisor?
    // Debounces the durable write: a 100-VM sync applies 100 records and must
    // still cost one file write.
    var metadataPersistTrigger: CoalescingTrigger?
    let metadataServiceEnabled: Bool
    let metadataHopLimit: Int
    // Whether the control plane we registered with speaks state sync (wire
    // protocol >= 2). Gates observed-state reports so an old control plane
    // isn't sent envelopes it logs as unknown.

    // Durable, backend-agnostic record of the VMs this agent owns, keyed by vmId.
    // `managedVMs` are actively managed by this process; `orphanedVMs` were managed
    // by a previous incarnation — their hypervisor processes may still be running,
    // so they stay routable to the right backend and their reservations keep
    // counting against host capacity until they are deleted or re-created. Both
    // sets are persisted via `manifestStore` so routing survives restarts.
    let manifestStore: VMManifestStore
    var managedVMs: [String: VMManifestEntry] = [:]
    var orphanedVMs: [String: VMManifestEntry] = [:]

    // Set when the manifest could not be read at all (STR-138), which means
    // this host's workloads are unknown — not that there are none. The agent
    // quarantines itself: it advertises no available capacity, converges
    // nothing, never writes over the file it could not read, and reports the
    // condition on every observed-state report so an operator sees it in the
    // UI rather than in one log line on the node. Cleared only by a later read
    // that actually succeeds (retried on the heartbeat, so a storage volume
    // that mounted late recovers without a restart).
    var manifestReadFailure: ManifestReadFailure?
    // Entries that exist but this build cannot route (an unrecognized
    // hypervisor type after a rollback, an undecodable spec). They keep
    // reserving capacity, block a re-create of their id, and are re-persisted
    // verbatim so rolling forward again restores them intact.
    var quarantinedWorkloads: [String: QuarantinedManifestEntry] = [:]

    // This host's vsock context-ID namespace (STR-72). In memory, but not a
    // cache: the durable copy is `VMManifestEntry.vsockCID`, which is re-read
    // into here on every manifest load — including the quarantined entries,
    // whose workloads may still be running on the CIDs they hold. A CID is
    // allocated when a VM that needs one is created and released when its
    // manifest entry goes, so the two never drift.
    var vsockCIDs = VsockCIDAllocator()

    // Sandbox workload tracking (issue #417): same manifest contract as VMs,
    // kept in separate maps so the VM paths never have to filter by kind.
    // `sandboxRuntime` is the driver seam (issue #421): the Firecracker
    // runtime on Linux hosts with a guest image, the mock runtime in
    // simulation mode (issue #470), nil otherwise. With no runtime the sandbox
    // capability stays off and only orphaned entries — written by a runtime-
    // bearing incarnation, then inherited across a downgrade/restart — can
    // appear; they keep reserving capacity and can be deleted (manifest-only),
    // but cannot be re-adopted.
    var sandboxRuntime: (any SandboxRuntimeService)?
    var managedSandboxes: [String: VMManifestEntry] = [:]
    var orphanedSandboxes: [String: VMManifestEntry] = [:]

    // QEMU VM exec sessions use the same guest protocol as sandboxes but reach
    // it through the host kernel's AF_VSOCK transport (STR-82).
    let vmExecSessionManager: VMExecSessionManager
    var guestExecSessions: [String: GuestExecSessionRoute] = [:]
    var recordedResultSendInProgress = false
    var lastOfferedRecordedResultSessionId: String?

    // Virtual size per volume, so the reconciler can tell a volume that needs
    // growing from one that is already the size the sync asks for (STR-148).
    // In memory only, and deliberately: it is a cache of something the storage
    // backend can always re-derive, and paying one `qemu-img info` per volume
    // once per agent lifetime is cheaper than persisting a second source of
    // truth that could drift from the disk.
    var volumeSizes: [String: Int64] = [:]
    /// Host-local provisioned bytes, distinct from the physical bytes written
    /// into sparse images. This is populated from each local backend image's
    /// virtual size and raised as soon as a create or grow succeeds.
    var volumeCommittedSizes: [String: Int64] = [:]

    // Snapshot artifacts this host holds (STR-150), across all three families.
    //
    // Durable, unlike `volumeSizes`, because almost none of what it holds can be
    // re-derived: a Firecracker checkpoint's fork-layout version and CPU
    // template are not recoverable from its files at all, and a qcow2 internal
    // snapshot's footprint costs a subprocess per artifact per report. The
    // control plane learns every one of these facts from the observed report,
    // so they are recorded once, when the only party that can measure them
    // does.
    //
    // The one exception is a volume snapshot's footprint, which is a `stat` of a
    // plain file the agent named — cheap enough to redo per report, and it has
    // to be, since an overlay grows after capture (STR-181). That measurement
    // lives on the report path (`SnapshotFootprint.reported`) and never comes back
    // here: this stays the memory of the capture.
    //
    // `snapshotInventoryUnreadable` is the artifact counterpart of
    // `manifestReadFailure` and does the same job: an empty inventory is
    // authoritative downstream — omission from a full list is how a deletion is
    // confirmed — so a host that could not read the file reports *no* list
    // rather than an empty one, and never writes over what it could not read.
    let snapshotRecordStore: SnapshotRecordStore
    var snapshotRecords: [UUID: SnapshotRecord] = [:]
    var snapshotInventoryUnreadable = false

    // Sandbox exec/attach bridging and workload log shipping (issue #423).
    // The runtime's callbacks yield into these streams *synchronously*, so
    // per-session event order and per-sandbox line order survive the hop out
    // of the runtime; two pump tasks drain them into outbound WebSocket
    // messages one at a time (mirroring the ordered inbound pipeline above).
    nonisolated let sandboxExecEvents: AsyncStream<(String, GuestResourceKind, SandboxExecEvent)>
    nonisolated let sandboxExecEventsContinuation:
        AsyncStream<(String, GuestResourceKind, SandboxExecEvent)>.Continuation
    nonisolated let sandboxLogLines: AsyncStream<(String, String, String)>
    nonisolated let sandboxLogLinesContinuation: AsyncStream<(String, String, String)>.Continuation
    var sandboxExecPumpTask: Task<Void, Never>?
    var sandboxLogPumpTask: Task<Void, Never>?
    // Hypervisor lifecycle transitions (STR-135): one pump per backend that
    // pushes them, all feeding a single trigger that turns bursts into
    // observed-state reports. The trigger is what keeps a host-wide power cycle
    // — stopped, started, resumed, per VM — from becoming one full report per
    // event, and what guarantees two reports are never assembling at once.
    var lifecyclePumpTasks: [HypervisorType: Task<Void, Never>] = [:]
    var observedStateTrigger: CoalescingTrigger?
    // Set when a manifest write failed (disk full, permissions); the write is
    // retried on every heartbeat until it succeeds, so a transient failure only
    // leaves the on-disk manifest stale for a bounded window.
    var manifestPersistFailed = false
    // Last successful observation of each hypervisor, reported when a live query
    // exceeds its budget. Liveness must not depend on hypervisor progress: a
    // stuck hypervisor call used to block the heartbeat, so the control plane
    // read a busy agent as a dead one and failed its in-flight work (issue #516).
    // Bumped when an observed-state report starts assembling. A report that
    // overran its budget was abandoned mid-flight, so it must not transmit
    // afterwards: reports carry full-list semantics and the control plane
    // applies them in receive order, so a late one would overwrite a newer
    // report's view with stale observations (issue #516).
    var observedReportEpoch: UInt64 = 0

    // Last-known QEMU guest-agent info per VM (issue #563), refreshed off the
    // hot path by a throttled slow poll and read verbatim into each
    // `ObservedVMState`. Keeping the probe out of `sendObservedStateReport`
    // means a qga round-trip (which routinely times out for a guest with no
    // agent) never delays the report itself. Wholesale-replaced each refresh, so
    // entries for gone or no-longer-running VMs prune themselves.
    var guestInfoCache: [String: GuestInfo] = [:]
    // Last-known balloon memory stats per VM (issue #567), maintained by the
    // same slow poll with the same lifecycle as `guestInfoCache`.
    var memoryStatsCache: [String: VMMemoryStats] = [:]
    /// When the guest-info cache was last refreshed, to throttle probing to the
    /// slow-poll cadence regardless of how often reports/heartbeats fire.
    var lastGuestInfoRefresh: ContinuousClock.Instant?
    /// Minimum spacing between guest-info refreshes.
    static let guestInfoRefreshInterval: Duration = .seconds(30)

    let networkMode: NetworkMode?
    // Chassis-level OVN settings (ovn-remote/encap external_ids) the network
    // service bootstraps onto the local OVS at connect time.
    let ovnChassisConfig: OVNChassisConfig
    let ovnUplink: OVNUplinkConfig?
    // OVN native dynamic routing (issue #344): BGP advertisement of floating
    // IPs / connected routes via FRR on the egress host.
    let ovnDynamicRouting: OVNDynamicRoutingConfig?
    // Per-network DNS resolver settings (STR-40). Nil means the defaults, which
    // is deliberately "on": the feature is an opt-out on the *network*, so a
    // host whose config says nothing about it is one that should run it.
    let resolverConfig: NetworkResolverConfig?
    // The CoreDNS this host will run, resolved once at network-service setup.
    // Nil means the host cannot answer on a resolver address at all — no
    // binary, the feature disabled here, or user-mode networking — which is
    // exactly what `AgentRegisterMessage.resolverCapable` reports.
    var resolverBinaryPath: String?
    // Owns the host's single CoreDNS, which serves every resolver-enabled
    // network this host has a local NIC on. Held here as well as inside the
    // network service so shutdown can stop it: a draining host must not keep
    // answering for networks it no longer serves.
    var resolverSupervisor: ResolverSupervisor?
    let ovnNorthbound: String?
    // TLS material for an ssl: ovn_northbound endpoint (nil = tcp/unix).
    let ovnNorthboundTLS: OVNNorthboundTLSConfig?
    // The networking backend actually selected at startup (config value plus
    // platform fallbacks). Drives the typed networking report at registration:
    // a Linux agent configured for user-mode networking must not claim
    // OVN/VM-to-VM support.
    var effectiveNetworkMode: NetworkMode = .user
    // Whether the selected network service is currently connected. An OVN
    // agent whose OVN/OVS connection failed must report no overlay networking,
    // or the scheduler would place VM-to-VM workloads on a backend that will
    // throw notConnected. A failed connection is retried in the background
    // (`networkConnectTask`) and again at each registration, so a fixed host
    // recovers eligibility without a restart.
    var networkServiceConnected = false
    // Background retry loop for a network service that failed to connect.
    var networkConnectTask: Task<Void, Never>?
    // Periodic dependency inspection is deliberately independent of the
    // heartbeat task: a slow systemd/virsh/OVS probe may make its observation
    // late, but can never make a live agent miss liveness reports.
    var dependencyManager: NodeDependencyManager?
    var dependencyObservationTask: Task<Void, Never>?
    // Host and per-workload pressure samples are refreshed on their own
    // detached utility loop. Heartbeats and reconciliation only read these
    // caches, so procfs/cgroup latency is never on either liveness path.
    var resourceTelemetryTask: Task<Void, Never>?
    var hostResourceTelemetry: HostResourceTelemetry?
    var workloadResourceTelemetry: [String: WorkloadResourceTelemetry] = [:]
    let installMode: AgentInstallMode
    let imageCachePath: String?
    // Byte budgets for the image caches; nil means unbounded (see
    // image_cache_max_size_gb / sandbox_image_cache_max_size_gb).
    let imageCacheMaxSizeBytes: Int64?
    let sandboxImageCachePath: String?
    let sandboxImageCacheMaxSizeBytes: Int64?
    let vmStoragePath: String
    // Root of the managed-volume tree for the filesystem storage backend and
    // the host preflight's writability probe.
    let volumeStoragePath: String
    // Operator-configured EDK2 firmware paths (issue #565): the split
    // CODE/VARS pairs and the legacy monolithic image.
    let firmware: FirmwareOverrides
    // The QEMU driver, kept typed as well as in `hypervisorServices` so the
    // registration path can hand it what only the host preflight knows: whether
    // this host's libvirt can back a guest vTPM. Nil off Linux, where the
    // registered `.qemu` backend is a mock.
    var libvirtService: LibvirtService?
    let firecrackerBinaryPath: String
    let firecrackerSocketDir: String
    // Where the sandbox guest base image (issue #419) is installed; its
    // presence gates the sandbox-runtime capability advertised at
    // registration (issue #415).
    let sandboxGuestImagePath: String?
    // Sandbox jailer policy (issue #425): resolved once at start() into
    // either a SandboxJailerConfig for the runtime or, when mode is
    // `required` and the host can't satisfy it, a blocked-reason that keeps
    // the sandbox capability dark at every registration.
    let sandboxJailerMode: SandboxJailerMode
    let sandboxJailerBinaryPath: String
    let sandboxJailerChrootDir: String
    let sandboxJailerUidBase: UInt32
    /// Base used only to reconstruct manifests written before jailUID was
    /// persisted. This remains the old default when the current allocation
    /// default moves, unless the operator explicitly configured a base.
    let legacySandboxJailerUidBase: UInt32
    var sandboxJailerBlockedReason: String?
    /// Live host-range failure under `required`, refreshed by preflight on
    /// every registration and checked again on the create path.
    var sandboxJailerUIDRangeBlockedReason: String?
    /// A legacy manifest entry had no persisted UID and its existing jail
    /// ownership could not be inspected. Guessing would reserve the wrong
    /// identity, so every new create stays blocked until a later manifest
    /// reload can prove the old assignment.
    var sandboxJailUIDRecoveryBlockedReason: String?
    var sandboxJailCreationBlockedReason: String? {
        sandboxJailerBlockedReason
            ?? sandboxJailerUIDRangeBlockedReason
            ?? sandboxJailUIDRecoveryBlockedReason
    }
    // The resolved jail layout, built unconditionally at start() — even an
    // unjailed agent needs it to tear down jailed leftovers from a previous
    // life. Nil only when this build/host has no sandbox runtime at all.
    var sandboxJailerConfig: SandboxJailerConfig?
    // Whether *new* sandboxes get the jailer barrier. A sandbox NIC lives in
    // the jail's network namespace, so without the barrier there is nowhere to
    // put it and networked specs are refused (issue STR-100).
    var sandboxJailNewSandboxes = false
    /// Bootstrap copy populated from the manifest before the Firecracker
    /// runtime exists. The runtime receives this complete namespace and owns
    /// subsequent sandbox/template leases.
    var sandboxJailUIDs: SandboxJailUIDAllocator
    // Warm start (issue #426): provision sandboxes from per-image template
    // snapshots when possible. Default on; warm failures cold-boot.
    let sandboxWarmStart: Bool
    let sandboxWarmCacheMaxSizeBytes: Int64?
    let hypervisorType: HypervisorType
    let hardwareAccelerationEnabled: Bool
    let qemuMemoryOverheadBytes: Int64

    // Cross-VM reconciliation lanes are concurrent. This ledger closes the
    // stale-snapshot race between reading host inventory and committing the
    // manifest entry that makes a successful growth visible to later reads.
    var capacityAdmissionLedger = HostCapacityAdmissionLedger()
    var capacityManifestRevision: UInt64 = 0
    var bootCapacityClaims: [String: HostCapacityClaim] = [:]
    /// Managed identities whose historical VM-side bytes could not be adopted
    /// on this sync. Creation must fail closed for these IDs: materializing the
    /// source image would silently replace the guest's changed boot disk.
    var volumeAdoptionFailures: [String: String] = [:]
    /// Authoritative volume desires from the latest sync. VM boot uses this
    /// rather than `VMSpec.diskBytes`, which is a scheduler reservation and can
    /// lag an independent managed boot-volume resize (STR-242).
    var desiredVolumeStates: [String: DesiredVolumeState] = [:]
    /// The authoritative per-VM volume sequence from the latest VMSpec. Its
    /// `bootOrder` integers are informational; attachment reconciliation uses
    /// this sequence instead of sorting them again (STR-308).
    var desiredVMVolumeSpecs: [String: [VolumeSpec]] = [:]
    /// Previous live libvirt counter sample per volume. Kept only long enough
    /// to turn monotonic counters into the rate sent with observed state; it is
    /// not convergence state and deliberately does not survive a restart.
    var volumeIOCounterSamples: [String: (sample: VolumeIOCounterSample, sampledAt: ContinuousClock.Instant)] = [:]

    // Simulation ("dummy agent") mode: the agent speaks the full control-plane
    // protocol but drives a no-op mock hypervisor with no real
    // networking/storage, and reports the configured fake host capacity instead
    // of probing the machine. Lets a fleet of dummies scale-test a control plane
    // far larger than the compute available to run real VMs. Nil/disabled means
    // a normal agent.
    let simulation: SimulationConfig?
    var isSimulationMode: Bool { simulation?.enabled ?? false }
    // The observed-state report reads this cache without starting subprocesses.
    // Registration forces a scan; heartbeats refresh it on a bounded cadence.
    let storageDeviceInventory: StorageDeviceInventoryCache

    // SPIFFE/SPIRE support
    let spiffeConfig: SPIFFEConfig?
    var svidManager: SVIDManager?

    // How much of this host one sync's confirmed teardowns may remove (STR-98).
    let teardownGuard: TeardownGuard

    // Desired-state transport (STR-146): the long-poll loop, started once
    // registration confirms the control plane.
    let desiredStateFullRefetchInterval: Duration
    var desiredStatePoller: DesiredStatePoller<ContinuousClock>?

    // Set when a failure is unrecoverable (e.g. the agent's identity was
    // rejected); start() rethrows it so the process exits non-zero instead
    // of idling disconnected.
    var terminalError: Error?
    // Set after a successful self-update binary swap (issue #432): stop() is
    // about to run and the process must exit with
    // `AgentUpdater.restartExitCode` so the supervisor (Restart=on-failure)
    // starts the new binary. Read by launchAgent once start() returns.
    var updateRestartPending = false
    // Declarative auto-update state (issue #434). `autoUpdateStatus` is the
    // blocked/failed reason carried on observed-state reports so the control
    // plane's rollout can tell "waiting on a precondition" from "the update
    // itself failed". `attemptedAutoUpdateArtifacts` remembers artifacts
    // already tried this process lifetime: retrying a failed artifact on
    // every sync would loop downloads (or, for an artifact whose binary
    // reports the wrong version, restart-loop the agent), and the control
    // plane halts the rollout on the reported failure anyway.
    var autoUpdateStatus: ObservedAgentUpdateStatus?
    var attemptedAutoUpdateArtifacts: Set<String> = []

    init(
        agentID: String,
        webSocketURL: String,
        networkMode: NetworkMode?,
        ovnChassisConfig: OVNChassisConfig = OVNChassisConfig(),
        ovnUplink: OVNUplinkConfig? = nil,
        ovnDynamicRouting: OVNDynamicRoutingConfig? = nil,
        resolverConfig: NetworkResolverConfig? = nil,
        ovnNorthbound: String? = nil,
        ovnNorthboundTLS: OVNNorthboundTLSConfig? = nil,
        logger: Logger,
        imageCachePath: String? = nil,
        imageCacheMaxSizeBytes: Int64? = nil,
        sandboxImageCachePath: String? = nil,
        sandboxImageCacheMaxSizeBytes: Int64? = nil,
        vmStoragePath: String,
        volumeStoragePath: String = FileSystemStorageBackend.defaultStoragePath,
        firmware: FirmwareOverrides = FirmwareOverrides(),
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        firecrackerSocketDir: String = "/tmp/firecracker",
        sandboxGuestImagePath: String? = nil,
        sandboxJailerMode: SandboxJailerMode = .auto,
        sandboxJailerBinaryPath: String = "/usr/local/bin/jailer",
        sandboxJailerChrootDir: String = "/var/lib/strato/vms/jailer",
        sandboxJailerUidBase: UInt32 = AgentConfig.defaultSandboxJailerUidBase,
        legacySandboxJailerUidBase: UInt32? = nil,
        sandboxWarmStart: Bool = true,
        sandboxWarmCacheMaxSizeBytes: Int64? = nil,
        hypervisorType: HypervisorType = .qemu,
        hardwareAccelerationEnabled: Bool = true,
        qemuMemoryOverheadBytes: Int64 = Int64(AgentConfig.defaultQEMUMemoryOverheadMB) * 1024 * 1024,
        simulation: SimulationConfig? = nil,
        installMode: AgentInstallMode = .detect(),
        spiffeConfig: SPIFFEConfig? = nil,
        teardownGuard: TeardownGuard = TeardownGuard(),
        desiredStateFullRefetchInterval: Duration = DesiredStatePoller<ContinuousClock>.defaultFullRefetchInterval,
        metadataServiceEnabled: Bool = true,
        metadataHopLimit: Int = 1
    ) {
        self.initialAgentID = agentID
        self.webSocketURL = webSocketURL
        self.networkMode = networkMode
        self.ovnChassisConfig = ovnChassisConfig
        self.ovnUplink = ovnUplink
        self.ovnDynamicRouting = ovnDynamicRouting
        self.resolverConfig = resolverConfig
        self.ovnNorthbound = ovnNorthbound
        self.ovnNorthboundTLS = ovnNorthboundTLS
        self.logger = logger
        self.imageCachePath = imageCachePath
        self.imageCacheMaxSizeBytes = imageCacheMaxSizeBytes
        self.sandboxImageCachePath = sandboxImageCachePath
        self.sandboxImageCacheMaxSizeBytes = sandboxImageCacheMaxSizeBytes
        self.vmStoragePath = vmStoragePath
        self.volumeStoragePath = volumeStoragePath
        self.firmware = firmware
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.firecrackerSocketDir = firecrackerSocketDir
        self.sandboxGuestImagePath = sandboxGuestImagePath
        self.sandboxJailerMode = sandboxJailerMode
        self.sandboxJailerBinaryPath = sandboxJailerBinaryPath
        self.sandboxJailerChrootDir = sandboxJailerChrootDir
        self.sandboxJailerUidBase = sandboxJailerUidBase
        self.legacySandboxJailerUidBase = legacySandboxJailerUidBase ?? sandboxJailerUidBase
        self.sandboxJailUIDs = SandboxJailUIDAllocator(uidBase: sandboxJailerUidBase)
        self.sandboxWarmStart = sandboxWarmStart
        self.sandboxWarmCacheMaxSizeBytes = sandboxWarmCacheMaxSizeBytes
        self.hypervisorType = hypervisorType
        self.hardwareAccelerationEnabled = hardwareAccelerationEnabled
        self.qemuMemoryOverheadBytes = qemuMemoryOverheadBytes
        self.simulation = simulation
        if simulation?.enabled == true {
            self.storageDeviceInventory = StorageDeviceInventoryCache(observer: { nil })
        } else {
            let storageDeviceProbe = BlockDeviceInventoryProbe()
            self.storageDeviceInventory = StorageDeviceInventoryCache(
                observer: { await storageDeviceProbe.observe() })
        }
        self.installMode = installMode
        self.spiffeConfig = spiffeConfig
        self.teardownGuard = teardownGuard
        self.desiredStateFullRefetchInterval = desiredStateFullRefetchInterval
        self.manifestStore = VMManifestStore(
            path: (vmStoragePath as NSString).appendingPathComponent("vm-manifest.json"),
            logger: logger
        )
        self.snapshotRecordStore = SnapshotRecordStore(
            path: (vmStoragePath as NSString).appendingPathComponent("snapshot-records.json"),
            logger: logger
        )
        // Beside the VM manifest, because it answers the same question about
        // the same workloads and shares its lifetime (STR-56).
        self.metadataSnapshotStore = MetadataSnapshotStore(
            path: (vmStoragePath as NSString).appendingPathComponent("instance-metadata.json"),
            logger: logger
        )
        self.metadataServiceEnabled = metadataServiceEnabled
        self.metadataHopLimit = metadataHopLimit
        self.vmExecSessionManager = VMExecSessionManager(logger: logger)

        let (stream, continuation) = AsyncStream.makeStream(of: ControlPlaneInboundFrame.self)
        self.inboundMessages = stream
        self.inboundContinuation = continuation

        let (execEvents, execContinuation) = AsyncStream.makeStream(
            of: (String, GuestResourceKind, SandboxExecEvent).self)
        self.sandboxExecEvents = execEvents
        self.sandboxExecEventsContinuation = execContinuation

        let (logLines, logContinuation) = AsyncStream.makeStream(of: (String, String, String).self)
        self.sandboxLogLines = logLines
        self.sandboxLogLinesContinuation = logContinuation
    }
}
