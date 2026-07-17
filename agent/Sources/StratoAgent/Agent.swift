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
#endif

enum AgentError: Error, LocalizedError {
    case registrationTimeout
    /// The control plane explicitly rejected our credentials (`invalid_token`
    /// code) — retrying with the same token can never succeed.
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
    private let webSocketURL: String
    // The token-free URL to dial. The registration token is carried separately (see
    // `currentRegistrationToken`) so it never appears in the request URL.
    private var currentWebSocketURL: String
    // The single-use registration token to present in the Authorization header.
    // Registration tokens are consumed on connect, so the control plane returns a fresh
    // one on each successful registration and this tracks it for the reconnect loop.
    private var currentRegistrationToken: String?
    private let qemuSocketDir: String
    private let isRegistrationMode: Bool
    private let logger: Logger

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

    // Sandbox workload tracking (issue #417): same manifest contract as VMs,
    // kept in separate maps so the VM paths never have to filter by kind. The
    // runtime driver (issue #421) is not built yet, so `sandboxRuntime` stays
    // nil and `managedSandboxes` empty; only orphaned entries — written by a
    // newer incarnation, then inherited across a downgrade/restart — can
    // appear. They keep reserving capacity and can be deleted (manifest-only),
    // but cannot be re-adopted until the runtime lands.
    private var sandboxRuntime: (any SandboxRuntimeService)?
    private var managedSandboxes: [String: VMManifestEntry] = [:]
    private var orphanedSandboxes: [String: VMManifestEntry] = [:]

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

    private let networkMode: NetworkMode?
    // Chassis-level OVN settings (ovn-remote/encap external_ids) the network
    // service bootstraps onto the local OVS at connect time.
    private let ovnChassisConfig: OVNChassisConfig
    private let ovnUplink: OVNUplinkConfig?
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
    private let vmStoragePath: String
    private let qemuBinaryPath: String
    private let firmwarePath: String?
    private let firecrackerBinaryPath: String
    private let firecrackerSocketDir: String
    // Where the sandbox guest base image (issue #419) is installed; its
    // presence gates the sandbox-runtime capability advertised at
    // registration (issue #415).
    private let sandboxGuestImagePath: String?
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

    // Join state persistence (rotated reconnect token survives restarts)
    private let stateStore: (any AgentStateStore)?
    // Set when a failure is unrecoverable (e.g. the reconnect token was
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
        registrationToken: String? = nil,
        qemuSocketDir: String,
        networkMode: NetworkMode?,
        ovnChassisConfig: OVNChassisConfig = OVNChassisConfig(),
        ovnUplink: OVNUplinkConfig? = nil,
        ovnNorthbound: String? = nil,
        ovnNorthboundTLS: OVNNorthboundTLSConfig? = nil,
        isRegistrationMode: Bool,
        logger: Logger,
        imageCachePath: String? = nil,
        vmStoragePath: String,
        qemuBinaryPath: String,
        firmwarePath: String? = nil,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        firecrackerSocketDir: String = "/tmp/firecracker",
        sandboxGuestImagePath: String? = nil,
        hypervisorType: HypervisorType = .qemu,
        hardwareAccelerationEnabled: Bool = true,
        simulation: SimulationConfig? = nil,
        spiffeConfig: SPIFFEConfig? = nil,
        stateStore: (any AgentStateStore)? = nil
    ) {
        self.initialAgentID = agentID
        self.webSocketURL = webSocketURL
        self.currentWebSocketURL = webSocketURL
        self.currentRegistrationToken = registrationToken
        self.qemuSocketDir = qemuSocketDir
        self.networkMode = networkMode
        self.ovnChassisConfig = ovnChassisConfig
        self.ovnUplink = ovnUplink
        self.ovnNorthbound = ovnNorthbound
        self.ovnNorthboundTLS = ovnNorthboundTLS
        self.isRegistrationMode = isRegistrationMode
        self.logger = logger
        self.imageCachePath = imageCachePath
        self.vmStoragePath = vmStoragePath
        self.qemuBinaryPath = qemuBinaryPath
        self.firmwarePath = firmwarePath
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.firecrackerSocketDir = firecrackerSocketDir
        self.sandboxGuestImagePath = sandboxGuestImagePath
        self.hypervisorType = hypervisorType
        self.hardwareAccelerationEnabled = hardwareAccelerationEnabled
        self.simulation = simulation
        self.spiffeConfig = spiffeConfig
        self.stateStore = stateStore
        self.manifestStore = VMManifestStore(
            path: (vmStoragePath as NSString).appendingPathComponent("vm-manifest.json"),
            legacyQEMUManifestPath: (vmStoragePath as NSString).appendingPathComponent("qemu-manifest.json"),
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
        let previousManifest = manifestStore.load()
        if !previousManifest.isEmpty {
            orphanedVMs = previousManifest.filter { $0.value.kind == .vm }
            orphanedSandboxes = previousManifest.filter { $0.value.kind == .sandbox }
            logger.warning(
                "Found \(previousManifest.count) workload(s) managed before restart; their processes are now unmanaged but their resources stay reserved",
                metadata: [
                    "workloadIds": .string(previousManifest.keys.sorted().joined(separator: ","))
                ])
        }

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
                networkService = NetworkServiceLinux(
                    nbConnection: ovnNorthbound, nbTLS: ovnNorthboundTLS, chassisConfig: ovnChassisConfig,
                    uplink: ovnUplink, logger: logger)
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
            storageBackend = MockStorageBackend(logger: logger)
        } else {
            logger.info("Initializing image cache service")
            imageCacheService = ImageCacheService(
                logger: logger,
                cachePath: imageCachePath,
                controlPlaneURL: webSocketURL.replacingOccurrences(of: "ws://", with: "http://")
                    .replacingOccurrences(of: "wss://", with: "https://")
                    .replacingOccurrences(of: "/agent/ws", with: "")
            )

            logger.info("Initializing storage backend")
            storageBackend = FileSystemStorageBackend(
                logger: logger,
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
        } else {
            logger.info("Initializing QEMU service")
            #if canImport(SwiftQEMU)
            hypervisorServices[.qemu] = QEMUService(
                logger: logger, storage: storageBackend,
                vmStoragePath: vmStoragePath, qemuBinaryPath: qemuBinaryPath, firmwarePath: firmwarePath,
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
                logger.info("Initializing sandbox runtime (Linux only)")
                sandboxRuntime = FirecrackerSandboxRuntime(
                    logger: logger,
                    client: firecrackerClient,
                    imageService: SandboxImageService(logger: logger),
                    socketDirectory: firecrackerSocketDir,
                    sandboxStoragePath: vmStoragePath,
                    guestImagePath: sandboxGuestImagePath
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
        reconciler = Reconciler(actuator: self, queue: messageQueue, logger: logger)

        logger.info("Initializing console socket manager")
        consoleSocketManager = ConsoleSocketManager(logger: logger, eventLoopGroup: eventLoopGroup)
        await consoleSocketManager?.setOnConsoleData { [weak self] vmId, sessionId, data in
            await self?.sendConsoleData(vmId: vmId, sessionId: sessionId, data: data)
        }

        // Initialize SPIFFE/mTLS if enabled
        var tlsConfiguration: TLSConfiguration?
        if let spiffe = spiffeConfig, spiffe.enabled {
            logger.info(
                "Initializing SPIFFE authentication",
                metadata: [
                    "trustDomain": .string(spiffe.trustDomain ?? SPIFFEConfig.defaultTrustDomain),
                    "sourceType": .string(spiffe.sourceType ?? "workload_api"),
                ])

            do {
                let spiffeClient = try createSPIFFEClient(config: spiffe)
                svidManager = SVIDManager(client: spiffeClient, logger: logger)
                try await svidManager?.start()

                // Get TLS configuration from SVID
                tlsConfiguration = try await svidManager?.getTLSConfiguration()
                logger.info("SPIFFE authentication initialized successfully")

                // Register for SVID rotation
                await svidManager?.onRotation { [weak self] _ in
                    guard let self = self else { return }
                    await self.handleSVIDRotation()
                }
            } catch {
                logger.error("Failed to initialize SPIFFE: \(error)")
                if webSocketURL.hasPrefix("wss://") {
                    throw AgentError.spiffeConfigurationError(
                        "SPIFFE is required for wss:// connections but failed to initialize: \(error)"
                    )
                }
                logger.warning("Continuing without SPIFFE authentication")
            }
        }

        // Begin draining inbound frames before the connection opens so the registration
        // response (and any early frames) are processed in order.
        startMessageConsumer()

        if isRegistrationMode {
            logger.info("Connecting for agent registration", metadata: ["url": .string(webSocketURL)])
        } else {
            logger.info("Connecting to control plane", metadata: ["url": .string(webSocketURL)])
        }
        websocketClient = WebSocketClient(
            url: currentWebSocketURL, agent: self, logger: logger, tlsConfiguration: tlsConfiguration,
            registrationToken: currentRegistrationToken, inboundContinuation: inboundContinuation)

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
        }
        websocketClient = nil
        hypervisorServices.removeAll()

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

    private func handleSVIDRotation() async {
        logger.info("SVID rotated, updating WebSocket TLS configuration")

        do {
            let newTLSConfig = try await svidManager?.getTLSConfiguration()
            if let client = websocketClient {
                await client.updateTLSConfiguration(newTLSConfig)
            }
            logger.info("WebSocket TLS configuration updated after SVID rotation")
        } catch {
            logger.error("Failed to update TLS configuration after SVID rotation: \(error)")
        }
    }

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
        if isSimulationMode {
            hypervisors = simulatedHypervisorSupport()
        } else {
            let preflight = runHostPreflight()
            logHostPreflight(preflight)
            hypervisors = preflight.gate(
                HypervisorProbe.probeAll(
                    qemuBinaryPath: qemuBinaryPath,
                    firecrackerBinaryPath: firecrackerBinaryPath
                ))
        }
        let networkCapability = currentNetworkCapability()
        var capabilities = getAgentCapabilities(hypervisors: hypervisors, networkCapability: networkCapability)

        // Sandbox runtime: probed on the same cadence, gated on Firecracker
        // (binary + KVM, folded into its probe) plus the guest base image
        // present on disk. The typed flag is what the scheduler keys sandbox
        // placement on (issue #415); the capability string is display-only.
        //
        // The host probe is necessary but not sufficient: this agent must also
        // actually hold a runtime to serve the workload. Simulation mode is the
        // case that separates them — it registers mock hypervisors (whose
        // Firecracker support reports available) but deliberately creates no
        // sandbox runtime, so on any Linux host that happens to have a guest
        // image installed the probe alone would advertise sandboxCapable and
        // every sandbox scheduled here would fail with runtimeUnavailable.
        // Never advertise what we cannot serve.
        let sandboxProbe = SandboxRuntimeProbe.probe(
            firecracker: hypervisors.first { $0.type == .firecracker },
            guestImagePath: sandboxGuestImagePath
        )
        let sandboxCapable = sandboxProbe.capable && sandboxRuntime != nil
        if sandboxCapable {
            capabilities.append(SandboxRuntimeProbe.capabilityName)
        } else {
            #if os(Linux)
            // Only worth a log where the runtime could ever exist.
            let reason =
                sandboxProbe.unavailabilityReason
                ?? (isSimulationMode
                    ? "simulation mode provides no sandbox runtime" : "sandbox runtime was not initialized")
            logger.info(
                "Sandbox runtime unavailable; not advertising sandbox capability",
                metadata: [
                    "reason": .string(reason)
                ])
            #endif
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
            operatingSystem: OperatingSystem.current,
            hostInfo: HostInfoProbe.gather()
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
        if controlPlaneProtocolVersion != WireProtocol.currentVersion {
            logger.warning(
                "Control plane wire protocol version differs from agent",
                metadata: [
                    "controlPlaneProtocolVersion": .stringConvertible(controlPlaneProtocolVersion),
                    "agentProtocolVersion": .stringConvertible(WireProtocol.currentVersion),
                ])
        }
        controlPlaneSupportsStateSync = WireProtocol.supportsStateSync(controlPlaneProtocolVersion)

        // Adopt the rotated reconnect token (if any) before resuming registration:
        // the token this connection presented was consumed by the control plane, so
        // the reconnect loop must dial with the fresh one to be accepted. The token
        // travels in the Authorization header, so rotation is just a value swap — the
        // dialed URL is unaffected.
        if let rotatedToken = response.reconnectToken {
            currentRegistrationToken = rotatedToken
            await websocketClient?.updateToken(rotatedToken)
            logger.info("Adopted rotated reconnect token from control plane")
            persistJoinState(response: response, reconnectToken: rotatedToken)
        }

        guard let continuation = takeRegistrationContinuation() else {
            logger.warning("Received registration response but no continuation waiting")
            return
        }
        continuation.resume(returning: response.agentId)
    }

    /// Persists the join state so a restarted agent can reconnect: the token
    /// this connection presented has just been consumed, so the rotated one is
    /// the only credential that will be accepted next time. Failure to persist
    /// is not fatal for the current run (the in-memory token still works), but
    /// is loud because a restart would then need a fresh join token.
    private func persistJoinState(response: AgentRegisterResponseMessage, reconnectToken: String) {
        guard let store = stateStore else { return }
        guard let bareURL = WebSocketURLs.removingQuery(from: currentWebSocketURL) else {
            logger.warning("Cannot derive control plane URL from \(currentWebSocketURL); join state not persisted")
            return
        }

        let state = AgentState(
            agentName: response.name,
            assignedAgentID: response.agentId,
            controlPlaneURL: bareURL,
            reconnectToken: reconnectToken
        )
        do {
            try store.save(state)
            logger.debug("Persisted join state", metadata: ["stateFile": .string(store.location)])
        } catch {
            logger.error(
                "Failed to persist join state to \(store.location): \(error). The agent stays connected, but a restart will need a new join token."
            )
        }
    }

    /// Handle an `error` envelope from the control plane.
    ///
    /// Previously these fell through to the `default` case and were logged as
    /// "unknown message type: error", discarding the real reason (e.g. "Invalid
    /// registration token"). Now the reason is surfaced.
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
        capabilities.append(MessageType.volumeSnapshotDelete.rawValue)

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

    /// Runs the host-readiness checks against this agent's resolved
    /// configuration. Called at every registration (initial and reconnect) so
    /// the reported capabilities always reflect the host as it is now.
    private func runHostPreflight() -> HostPreflight.Report {
        #if os(Linux)
        let firecrackerSocketDirectory: String? = firecrackerSocketDir
        #else
        let firecrackerSocketDirectory: String? = nil
        #endif

        // Mirror QEMUService's firmware resolution: explicit config first,
        // then the platform's default candidates for this architecture.
        #if arch(arm64)
        let resolvedFirmwarePath = firmwarePath ?? AgentConfig.defaultFirmwarePathARM64
        #else
        let resolvedFirmwarePath = firmwarePath ?? AgentConfig.defaultFirmwarePathX86_64
        #endif

        return HostPreflight.run(
            HostPreflight.Inputs(
                vmStoragePath: vmStoragePath,
                volumeStoragePath: FileSystemStorageBackend.defaultStoragePath,
                imageCachePath: imageCachePath ?? ImageCacheService.defaultCachePath,
                qemuImgPath: FileSystemStorageBackend.defaultQemuImgPath,
                firecrackerSocketDirectory: firecrackerSocketDirectory,
                firmwarePath: resolvedFirmwarePath,
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
            let message: Logger.Message = "Host preflight failed: \(failure.detail ?? failure.kind.rawValue)"
            let metadata: Logger.Metadata = ["check": .string(failure.kind.rawValue)]
            switch failure.severity {
            case .gating:
                logger.error(message, metadata: metadata)
            case .advisory:
                logger.warning(message, metadata: metadata)
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
                // The control plane explicitly rejected our credentials —
                // retrying with the same token can never succeed, so exit
                // with instructions instead of hammering a dead token. Under
                // systemd/docker restart policies this is also self-healing
                // for transient rejections: the restart re-reads the state
                // file and retries once with the same token.
                logger.error("Registration rejected by control plane: \(reason)")
                logger.error(
                    "If the token expired or was revoked, create a new registration token in the Strato UI (Agents → Create Registration Token) and run: strato-agent join '<registration-url>'"
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

        // On the same cadence, re-assert full observed state to a state-sync
        // control plane. The heartbeat keeps liveness/presence; the report is
        // the periodic correctness backstop for VM state (issue #260).
        if controlPlaneSupportsStateSync {
            await sendObservedStateReport()
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

        for service in hypervisorServices.values {
            let reserved = await service.reservedResources()
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

        let availableCPU = max(0, totalCPU - reservedCPU)
        let availableMemory = max(0, totalMemory - reservedMemory)

        // Disk. In simulation mode report the configured fake capacity (the real
        // filesystem is shared by every dummy and has nothing to do with the
        // sizes we're modeling). Otherwise query the storage filesystem live —
        // VM disks are created directly on it, so this naturally accounts for
        // existing disks without tracking reservations.
        let totalDisk: Int64
        let availableDisk: Int64
        if let simulation, simulation.enabled {
            totalDisk = simulation.resolvedDiskBytes
            availableDisk = simulation.resolvedDiskBytes
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
            availableDisk = disk?.free ?? 0
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

        for service in hypervisorServices.values {
            let vms = await service.listVMs()
            vmList.append(contentsOf: vms)
        }

        return vmList
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
            case .vmCreate:
                let message = try envelope.decode(as: VMCreateMessage.self)
                await handleVMCreate(message)
            case .vmBoot:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMBoot(message)
            case .vmShutdown:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMShutdown(message)
            case .vmReboot:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMReboot(message)
            case .agentUpdate:
                let message = try envelope.decode(as: AgentUpdateMessage.self)
                await handleAgentUpdate(message)
            case .vmPause:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMPause(message)
            case .vmResume:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMResume(message)
            case .vmDelete:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMDelete(message)
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
                    await networkService?.reconcileNetworks(
                        message.networks, authoritative: message.networksAuthoritative)
                }
                // Sandbox reconciliation is likewise gated on the sender: a
                // control plane older than the sandbox protocol (v5) omits
                // `sandboxes` (decoded as []), which must NOT be read as
                // "tear down all sandboxes" under full-list semantics.
                await reconciler?.apply(
                    message, includeSandboxes: WireProtocol.supportsSandboxSync(envelope.senderVersion))
                // Declarative agent self-update (issue #434), after the
                // reconciler so freshly enqueued work items are visible to the
                // precondition gate — the update only runs on a sync that
                // arrives with the lanes already drained.
                await handleDesiredAgentUpdate(message.desiredAgentUpdate)
            case .vmInfo:
                let message = try envelope.decode(as: VMInfoRequestMessage.self)
                await handleVMInfo(message)
            case .vmStatus:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMStatus(message)
            case .networkCreate:
                let message = try envelope.decode(as: NetworkCreateMessage.self)
                await handleNetworkCreate(message)
            case .networkDelete:
                let message = try envelope.decode(as: NetworkDeleteMessage.self)
                await handleNetworkDelete(message)
            case .networkList:
                let message = try envelope.decode(as: NetworkListMessage.self)
                await handleNetworkList(message)
            case .networkInfo:
                let message = try envelope.decode(as: NetworkInfoMessage.self)
                await handleNetworkInfo(message)
            case .networkAttach:
                let message = try envelope.decode(as: NetworkAttachMessage.self)
                await handleNetworkAttach(message)
            case .networkDetach:
                let message = try envelope.decode(as: NetworkDetachMessage.self)
                await handleNetworkDetach(message)
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
            // Volume operations
            case .volumeCreate:
                let message = try envelope.decode(as: VolumeCreateMessage.self)
                await handleVolumeCreate(message)
            case .volumeDelete:
                let message = try envelope.decode(as: VolumeDeleteMessage.self)
                await handleVolumeDelete(message)
            case .volumeAttach:
                let message = try envelope.decode(as: VolumeAttachMessage.self)
                await handleVolumeAttach(message)
            case .volumeDetach:
                let message = try envelope.decode(as: VolumeDetachMessage.self)
                await handleVolumeDetach(message)
            case .volumeResize:
                let message = try envelope.decode(as: VolumeResizeMessage.self)
                await handleVolumeResize(message)
            case .volumeSnapshot:
                let message = try envelope.decode(as: VolumeSnapshotMessage.self)
                await handleVolumeSnapshot(message)
            case .volumeSnapshotDelete:
                let message = try envelope.decode(as: VolumeSnapshotDeleteMessage.self)
                await handleVolumeSnapshotDelete(message)
            case .volumeClone:
                let message = try envelope.decode(as: VolumeCloneMessage.self)
                await handleVolumeClone(message)
            case .volumeInfo:
                let message = try envelope.decode(as: VolumeInfoMessage.self)
                await handleVolumeInfo(message)
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
        // One flat map for every workload kind; ids cannot collide across kinds
        // (both sides are UUIDs minted by the control plane), so the only real
        // collisions are orphaned-vs-active within a kind — active wins.
        var manifest = orphanedVMs.merging(managedVMs) { _, active in active }
        manifest.merge(orphanedSandboxes.merging(managedSandboxes) { _, active in active }) { _, sandbox in sandbox }
        manifestPersistFailed = !manifestStore.save(manifest)
    }

    private func handleVMCreate(_ message: VMCreateMessage) async {
        let vmId = message.vmData.id.uuidString
        let hypervisorType = message.vmData.hypervisorType

        logger.info(
            "Creating VM",
            metadata: [
                "vmId": .string(vmId),
                "hypervisorType": .string(hypervisorType.rawValue),
            ])
        await sendVMLog(
            vmId: vmId, level: .info, eventType: .operation,
            message: "Starting VM creation with hypervisor: \(hypervisorType.rawValue)", operation: "create")

        // Log image info if provided
        if let imageInfo = message.imageInfo {
            logger.info(
                "VM creation includes image info",
                metadata: [
                    "vmId": .string(vmId),
                    "imageId": .string(imageInfo.imageId.uuidString),
                    "filename": .string(imageInfo.filename),
                ])
            await sendVMLog(
                vmId: vmId, level: .info, eventType: .info, message: "Using image: \(imageInfo.filename)",
                operation: "create")
        }

        guard let service = getHypervisorService(for: hypervisorType) else {
            await sendError(
                for: message.requestId, error: "Hypervisor service not available for type: \(hypervisorType.rawValue)")
            await sendVMLog(
                vmId: vmId, level: .error, eventType: .error,
                message: "Hypervisor service not available for type: \(hypervisorType.rawValue)", operation: "create")
            return
        }

        // Realize the VM's NICs on this host before the driver runs; the driver
        // only translates the resolved attachments into its native config.
        let attachments: [ResolvedNetworkAttachment]
        do {
            attachments = try await networkOrchestrator.prepareAttachments(
                vmId: vmId, networks: message.vmSpec.networks)
        } catch {
            await sendError(
                for: message.requestId, error: "Failed to prepare VM networking: \(error.localizedDescription)")
            await sendVMLog(
                vmId: vmId, level: .error, eventType: .error,
                message: "Failed to prepare VM networking: \(error.localizedDescription)", operation: "create")
            logger.error(
                "Failed to prepare VM networking",
                metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
            return
        }

        do {
            try await service.createVM(
                vmId: vmId,
                spec: message.vmSpec,
                imageInfo: message.imageInfo,
                networkAttachments: attachments
            )
            // Record the owning backend in the durable manifest; a re-created VM
            // is actively managed again, so any orphan record is dropped.
            managedVMs[vmId] = VMManifestEntry(hypervisorType: hypervisorType, spec: message.vmSpec)
            orphanedVMs.removeValue(forKey: vmId)
            persistManifest()
            await sendSuccess(for: message.requestId, message: "VM created successfully")
            await sendVMLog(
                vmId: vmId, level: .info, eventType: .statusChange, message: "VM created successfully",
                operation: "create", newStatus: .created)
            logger.info("VM created successfully", metadata: ["vmId": .string(vmId)])
        } catch {
            // The driver never created the VM, so its NICs won't see a delete —
            // roll back their host-side resources here.
            await networkOrchestrator.teardownAttachments(vmId: vmId, count: attachments.count)
            await sendError(for: message.requestId, error: "Failed to create VM: \(error.localizedDescription)")
            await sendVMLog(
                vmId: vmId, level: .error, eventType: .error,
                message: "Failed to create VM: \(error.localizedDescription)", operation: "create")
            logger.error(
                "Failed to create VM", metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMBoot(_ message: VMOperationMessage) async {
        logger.info("Booting VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(
            vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM boot", operation: "boot")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available",
                operation: "boot")
            return
        }

        do {
            try await service.bootVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM booted successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .running)
            await sendVMLog(
                vmId: message.vmId, level: .info, eventType: .statusChange, message: "VM booted successfully",
                operation: "boot", newStatus: .running)
            logger.info("VM booted successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to boot VM: \(error.localizedDescription)")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error,
                message: "Failed to boot VM: \(error.localizedDescription)", operation: "boot")
            logger.error(
                "Failed to boot VM",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMShutdown(_ message: VMOperationMessage) async {
        logger.info("Shutting down VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(
            vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM shutdown",
            operation: "shutdown")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available",
                operation: "shutdown")
            return
        }

        do {
            try await service.shutdownVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM shut down successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .shutdown)
            await sendVMLog(
                vmId: message.vmId, level: .info, eventType: .statusChange, message: "VM shut down successfully",
                operation: "shutdown", newStatus: .shutdown)
            logger.info("VM shut down successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to shutdown VM: \(error.localizedDescription)")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error,
                message: "Failed to shutdown VM: \(error.localizedDescription)", operation: "shutdown")
            logger.error(
                "Failed to shutdown VM",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
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

    /// Operator-triggered self-update (issue #432): download, verify, and swap
    /// this process's own binary, then shut down and exit for the supervisor
    /// to restart the new build. The success reply is sent *after* the swap
    /// (so it reports the real outcome) but *before* the shutdown that closes
    /// the socket. Any failure leaves the running binary untouched and is
    /// reported as a correlated error.
    private func handleAgentUpdate(_ message: AgentUpdateMessage) async {
        logger.notice(
            "Received agent update command",
            metadata: [
                "targetVersion": .string(message.targetVersion),
                // Redacted: the URL's query string may be a presigned credential.
                "artifactURL": .string(message.redactedArtifactURL),
                "currentVersion": .string(BuildInfo.version),
            ])

        guard !updateRestartPending else {
            await sendError(
                for: message.requestId,
                error: "An update was already applied; the agent is restarting")
            return
        }

        let outcome: AgentUpdateOutcome
        do {
            let updater = AgentUpdater(logger: logger)
            outcome = try await updater.applyUpdate(
                artifactURL: message.artifactURL,
                sha256: message.sha256,
                artifactKind: message.artifactKind,
                tarballMember: message.tarballMember
            )
        } catch let error as AgentUpdateError {
            logger.error("Agent update failed", metadata: ["error": .string(error.description)])
            await sendError(for: message.requestId, error: "Agent update failed", details: error.description)
            return
        } catch {
            logger.error("Agent update failed", metadata: ["error": .string("\(error)")])
            await sendError(for: message.requestId, error: "Agent update failed", details: "\(error)")
            return
        }

        updateRestartPending = true
        await sendSuccess(
            for: message.requestId,
            message:
                "Binary updated to \(message.targetVersion) (previous preserved at \(outcome.previousBinaryPath)); restarting"
        )

        // Shut down from a separate task: this handler runs on the inbound
        // message pipeline, and stop() tears that pipeline down — stopping
        // inline would cancel ourselves mid-teardown. start() returns once
        // stop() completes and launchAgent exits with the restart code.
        logger.notice(
            "Agent update applied; shutting down for supervisor restart",
            metadata: ["binaryPath": .string(outcome.binaryPath)])
        Task {
            // Grace period before dropping the socket: the control plane
            // handles frames in independent tasks, so an immediate close can
            // still fail the awaiting update request as connectionLost before
            // the success reply's task resumes it. stop() also skips the
            // unregister message on this path for the same reason.
            try? await Task.sleep(for: .seconds(1))
            await self.stop()
        }
    }

    /// Declarative self-update (issue #434): converge on the desired agent
    /// build carried by the sync, through the same download/verify/swap/
    /// restart path as the operator-triggered update — but gated on local
    /// preconditions instead of an operator's `force`. Level-triggered: a
    /// blocked update is re-evaluated on every sync and the current reason is
    /// reported back on observed-state reports; a failed artifact is not
    /// retried within this process lifetime.
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
            let updater = AgentUpdater(logger: logger)
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
        // Same restart choreography as the operator-triggered path: stop()
        // from a separate task (this handler runs on the inbound pipeline
        // stop() tears down), then launchAgent exits with the restart code
        // for the supervisor. The new binary proves the update by
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

    private func handleVMPause(_ message: VMOperationMessage) async {
        logger.info("Pausing VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(
            vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM pause", operation: "pause")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available",
                operation: "pause")
            return
        }

        do {
            try await service.pauseVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM paused successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .paused)
            await sendVMLog(
                vmId: message.vmId, level: .info, eventType: .statusChange, message: "VM paused successfully",
                operation: "pause", newStatus: .paused)
            logger.info("VM paused successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to pause VM: \(error.localizedDescription)")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error,
                message: "Failed to pause VM: \(error.localizedDescription)", operation: "pause")
            logger.error(
                "Failed to pause VM",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMResume(_ message: VMOperationMessage) async {
        logger.info("Resuming VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(
            vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM resume", operation: "resume")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available",
                operation: "resume")
            return
        }

        do {
            try await service.resumeVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM resumed successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .running)
            await sendVMLog(
                vmId: message.vmId, level: .info, eventType: .statusChange, message: "VM resumed successfully",
                operation: "resume", newStatus: .running)
            logger.info("VM resumed successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to resume VM: \(error.localizedDescription)")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error,
                message: "Failed to resume VM: \(error.localizedDescription)", operation: "resume")
            logger.error(
                "Failed to resume VM",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMDelete(_ message: VMOperationMessage) async {
        logger.info("Deleting VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(
            vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM deletion",
            operation: "delete")

        // A VM orphaned by an agent restart has no live hypervisor session to tear
        // down. Deleting it releases its manifest entry and reservation so the
        // control plane can remove the record; any surviving hypervisor process
        // must be cleaned up manually (or via Option B re-adoption, #260).
        if managedVMs[message.vmId] == nil, let orphan = orphanedVMs.removeValue(forKey: message.vmId) {
            persistManifest()
            // Host-side network resources (OVN ports, TAP devices) are derived
            // from deterministic names, so they can be torn down even though no
            // hypervisor session survives. Best-effort by design.
            await networkOrchestrator.teardownAttachments(
                vmId: message.vmId, count: orphan.spec.networks.count)
            logger.warning(
                "Deleted orphaned VM from manifest; any surviving hypervisor process must be cleaned up manually",
                metadata: ["vmId": .string(message.vmId)])
            await sendSuccess(for: message.requestId, message: "VM deleted successfully")
            await sendVMLog(
                vmId: message.vmId, level: .info, eventType: .operation, message: "VM deleted successfully",
                operation: "delete")
            return
        }

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available",
                operation: "delete")
            return
        }

        do {
            let nicCount = managedVMs[message.vmId]?.spec.networks.count ?? 0
            try await service.deleteVM(vmId: message.vmId)
            // Tear down the VM's host-side network resources now that the
            // hypervisor session is gone (best-effort; never blocks deletion).
            await networkOrchestrator.teardownAttachments(vmId: message.vmId, count: nicCount)
            // Clean up the hypervisor mapping
            managedVMs.removeValue(forKey: message.vmId)
            persistManifest()
            await sendSuccess(for: message.requestId, message: "VM deleted successfully")
            await sendVMLog(
                vmId: message.vmId, level: .info, eventType: .operation, message: "VM deleted successfully",
                operation: "delete")
            logger.info("VM deleted successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to delete VM: \(error.localizedDescription)")
            await sendVMLog(
                vmId: message.vmId, level: .error, eventType: .error,
                message: "Failed to delete VM: \(error.localizedDescription)", operation: "delete")
            logger.error(
                "Failed to delete VM",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMInfo(_ message: VMInfoRequestMessage) async {
        logger.info("Getting VM info", metadata: ["vmId": .string(message.vmId)])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            return
        }

        do {
            let vmInfo = try await service.getVMInfo(vmId: message.vmId)
            let data = try AnyCodableValue(vmInfo)
            await sendSuccess(for: message.requestId, message: "VM info retrieved", data: data)
            logger.info("VM info retrieved successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to get VM info: \(error.localizedDescription)")
            logger.error(
                "Failed to get VM info",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMStatus(_ message: VMOperationMessage) async {
        logger.info("Getting VM status", metadata: ["vmId": .string(message.vmId)])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            return
        }

        do {
            let status = try await service.getVMStatus(vmId: message.vmId)
            let data = try AnyCodableValue(status)
            await sendSuccess(for: message.requestId, message: "VM status retrieved", data: data)
            logger.info(
                "VM status retrieved successfully",
                metadata: ["vmId": .string(message.vmId), "status": .string(status.rawValue)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to get VM status: \(error.localizedDescription)")
            logger.error(
                "Failed to get VM status",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
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

    private func sendStatusUpdate(vmId: String, status: VMStatus, details: String? = nil) async {
        let statusMessage = StatusUpdateMessage(vmId: vmId, status: status, details: details)
        do {
            try await websocketClient?.sendMessage(statusMessage)
        } catch {
            logger.error("Failed to send status update: \(error)")
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

    // MARK: - Network Message Handlers

    private func handleNetworkCreate(_ message: NetworkCreateMessage) async {
        logger.info("Creating network", metadata: ["networkName": .string(message.networkName)])

        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }

        do {
            let networkUUID = try await networkService.createLogicalNetwork(
                name: message.networkName,
                subnet: message.subnet,
                gateway: message.gateway
            )

            let networkInfo = NetworkInfo(
                name: message.networkName,
                uuid: networkUUID.uuidString,
                subnet: message.subnet,
                gateway: message.gateway,
                vlanId: message.vlanId,
                dhcpEnabled: message.dhcpEnabled,
                dnsServers: message.dnsServers
            )

            let data = try AnyCodableValue(networkInfo)
            await sendSuccess(for: message.requestId, message: "Network created successfully", data: data)
            logger.info("Network created successfully", metadata: ["networkName": .string(message.networkName)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to create network: \(error.localizedDescription)")
            logger.error(
                "Failed to create network",
                metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
        }
    }

    private func handleNetworkDelete(_ message: NetworkDeleteMessage) async {
        logger.info("Deleting network", metadata: ["networkName": .string(message.networkName)])

        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }

        do {
            try await networkService.deleteLogicalNetwork(name: message.networkName)
            await sendSuccess(for: message.requestId, message: "Network deleted successfully")
            logger.info("Network deleted successfully", metadata: ["networkName": .string(message.networkName)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to delete network: \(error.localizedDescription)")
            logger.error(
                "Failed to delete network",
                metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
        }
    }

    private func handleNetworkList(_ message: NetworkListMessage) async {
        logger.info("Listing networks")

        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }

        do {
            let networks = try await networkService.listLogicalNetworks()
            let data = try AnyCodableValue(networks)
            await sendSuccess(for: message.requestId, message: "Networks retrieved successfully", data: data)
            logger.info("Networks listed successfully", metadata: ["count": .stringConvertible(networks.count)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to list networks: \(error.localizedDescription)")
            logger.error("Failed to list networks", metadata: ["error": .string(error.localizedDescription)])
        }
    }

    private func handleNetworkInfo(_ message: NetworkInfoMessage) async {
        logger.info("Getting network info", metadata: ["networkName": .string(message.networkName)])

        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }

        do {
            let networks = try await networkService.listLogicalNetworks()
            if let network = networks.first(where: { $0.name == message.networkName }) {
                let data = try AnyCodableValue(network)
                await sendSuccess(for: message.requestId, message: "Network info retrieved successfully", data: data)
                logger.info(
                    "Network info retrieved successfully", metadata: ["networkName": .string(message.networkName)])
            } else {
                await sendError(for: message.requestId, error: "Network not found: \(message.networkName)")
                logger.warning("Network not found", metadata: ["networkName": .string(message.networkName)])
            }
        } catch {
            await sendError(for: message.requestId, error: "Failed to get network info: \(error.localizedDescription)")
            logger.error(
                "Failed to get network info",
                metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
        }
    }

    private func handleNetworkAttach(_ message: NetworkAttachMessage) async {
        logger.info(
            "Attaching VM to network",
            metadata: ["vmId": .string(message.vmId), "networkName": .string(message.networkName)])

        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }

        do {
            let networkInfo = try await networkService.attachVMToNetwork(
                vmId: message.vmId,
                networkName: message.networkName,
                macAddress: message.config?.macAddress
            )

            let data = try AnyCodableValue(networkInfo)
            await sendSuccess(for: message.requestId, message: "VM attached to network successfully", data: data)
            logger.info(
                "VM attached to network successfully",
                metadata: ["vmId": .string(message.vmId), "networkName": .string(message.networkName)])
        } catch {
            await sendError(
                for: message.requestId, error: "Failed to attach VM to network: \(error.localizedDescription)")
            logger.error(
                "Failed to attach VM to network",
                metadata: [
                    "vmId": .string(message.vmId), "networkName": .string(message.networkName),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleNetworkDetach(_ message: NetworkDetachMessage) async {
        logger.info("Detaching VM from network", metadata: ["vmId": .string(message.vmId)])

        guard let networkService = networkService else {
            await sendError(for: message.requestId, error: "Network service not available")
            return
        }

        do {
            try await networkService.detachVMFromNetwork(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM detached from network successfully")
            logger.info("VM detached from network successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(
                for: message.requestId, error: "Failed to detach VM from network: \(error.localizedDescription)")
            logger.error(
                "Failed to detach VM from network",
                metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    // MARK: - Console Message Handlers

    private func handleConsoleConnect(_ message: ConsoleConnectMessage) async {
        logger.info(
            "Console connect request received",
            metadata: [
                "vmId": .string(message.vmId),
                "sessionId": .string(message.sessionId),
                "requestId": .string(message.requestId),
            ])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            logger.error(
                "Hypervisor service not available for console connect", metadata: ["vmId": .string(message.vmId)])
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
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
            await sendError(
                for: message.requestId,
                error: "Console not available for VM \(message.vmId): \(error.localizedDescription)")
            return
        }

        let serialPath = endpoint?.serialSocketPath
        let consolePath = endpoint?.consoleSocketPath

        guard serialPath != nil || consolePath != nil else {
            logger.error(
                "No console socket found (tried serial and virtio-console)", metadata: ["vmId": .string(message.vmId)])
            await sendError(for: message.requestId, error: "Console socket not found for VM \(message.vmId)")
            return
        }

        guard let consoleManager = consoleSocketManager else {
            logger.error("Console manager not available")
            await sendError(for: message.requestId, error: "Console manager not available")
            return
        }

        // Clean up any existing sessions for this VM to prevent stale data routing
        let existingSessions = await consoleManager.getSessionsForVM(vmId: message.vmId)
        if !existingSessions.isEmpty {
            logger.info(
                "Cleaning up existing console sessions for VM",
                metadata: [
                    "vmId": .string(message.vmId),
                    "sessionCount": .stringConvertible(existingSessions.count),
                ])
            await consoleManager.disconnectAllForVM(vmId: message.vmId)
        }

        var connectedPath: String?
        var lastError: Error?

        if let serialPath = serialPath {
            do {
                try await consoleManager.connect(
                    vmId: message.vmId, sessionId: message.sessionId, socketPath: serialPath)
                connectedPath = serialPath
                logger.debug("Connected to serial console socket", metadata: ["socketPath": .string(serialPath)])
            } catch {
                lastError = error
                logger.warning(
                    "Failed to connect to serial socket, will try virtio-console",
                    metadata: [
                        "vmId": .string(message.vmId),
                        "sessionId": .string(message.sessionId),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        if connectedPath == nil, let consolePath = consolePath {
            do {
                try await consoleManager.connect(
                    vmId: message.vmId, sessionId: message.sessionId, socketPath: consolePath)
                connectedPath = consolePath
                logger.debug("Connected to virtio-console socket", metadata: ["socketPath": .string(consolePath)])
            } catch {
                lastError = error
            }
        }

        guard connectedPath != nil else {
            let errorMessage = "Failed to connect to console: \(lastError?.localizedDescription ?? "unknown error")"
            await sendError(for: message.requestId, error: errorMessage)
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

    // MARK: - Volume Message Handlers

    private func handleVolumeCreate(_ message: VolumeCreateMessage) async {
        logger.info(
            "Creating volume",
            metadata: [
                "volumeId": .string(message.volumeId),
                "size": .stringConvertible(message.size),
                "format": .string(message.format),
            ])

        guard let storageBackend = storageBackend else {
            await sendError(for: message.requestId, error: "Storage backend not available")
            return
        }

        guard let format = DiskFormat(rawValue: message.format) else {
            await sendError(for: message.requestId, error: "Unsupported volume format: \(message.format)")
            return
        }

        do {
            let attachment: DiskAttachment
            if let imageInfo = message.sourceImageInfo {
                // Create volume from image (format-conversion aware)
                attachment = try await storageBackend.createVolumeFromImage(
                    volumeId: message.volumeId, imageInfo: imageInfo, format: format)
            } else {
                // Create empty volume
                attachment = try await storageBackend.createVolume(
                    volumeId: message.volumeId, sizeBytes: message.size, format: format)
            }
            let volumePath = attachment.path

            let response = VolumeStatusResponse(
                volumeId: message.volumeId,
                status: "available",
                storagePath: volumePath
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume created successfully", data: data)
            logger.info(
                "Volume created successfully",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "path": .string(volumePath),
                ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to create volume: \(error.localizedDescription)")
            logger.error(
                "Failed to create volume",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleVolumeDelete(_ message: VolumeDeleteMessage) async {
        logger.info(
            "Deleting volume",
            metadata: [
                "volumeId": .string(message.volumeId)
            ])

        guard let storageBackend = storageBackend else {
            await sendError(for: message.requestId, error: "Storage backend not available")
            return
        }

        do {
            try await storageBackend.deleteVolume(volumeId: message.volumeId)
            await sendSuccess(for: message.requestId, message: "Volume deleted successfully")
            logger.info("Volume deleted successfully", metadata: ["volumeId": .string(message.volumeId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to delete volume: \(error.localizedDescription)")
            logger.error(
                "Failed to delete volume",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleVolumeAttach(_ message: VolumeAttachMessage) async {
        logger.info(
            "Attaching volume to VM (hot-plug)",
            metadata: [
                "volumeId": .string(message.volumeId),
                "vmId": .string(message.vmId),
                "deviceName": .string(message.deviceName),
                "volumePath": .string(message.volumePath),
            ])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            return
        }

        do {
            try await service.attachDisk(
                vmId: message.vmId,
                volumeId: message.volumeId,
                volumePath: message.volumePath,
                deviceName: message.deviceName,
                readonly: message.readonly
            )

            let response = VolumeStatusResponse(
                volumeId: message.volumeId,
                status: "attached",
                storagePath: message.volumePath
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume attached successfully", data: data)
            logger.info(
                "Volume attached successfully (hot-plug)",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "vmId": .string(message.vmId),
                    "deviceName": .string(message.deviceName),
                ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to attach volume: \(error.localizedDescription)")
            logger.error(
                "Failed to attach volume (hot-plug)",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "vmId": .string(message.vmId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleVolumeDetach(_ message: VolumeDetachMessage) async {
        logger.info(
            "Detaching volume from VM (hot-unplug)",
            metadata: [
                "volumeId": .string(message.volumeId),
                "vmId": .string(message.vmId),
                "deviceName": .string(message.deviceName),
            ])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            return
        }

        do {
            try await service.detachDisk(
                vmId: message.vmId,
                volumeId: message.volumeId,
                deviceName: message.deviceName
            )

            let response = VolumeStatusResponse(
                volumeId: message.volumeId,
                status: "available",
                storagePath: nil
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume detached successfully", data: data)
            logger.info(
                "Volume detached successfully (hot-unplug)",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "vmId": .string(message.vmId),
                ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to detach volume: \(error.localizedDescription)")
            logger.error(
                "Failed to detach volume (hot-unplug)",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "vmId": .string(message.vmId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleVolumeResize(_ message: VolumeResizeMessage) async {
        logger.info(
            "Resizing volume",
            metadata: [
                "volumeId": .string(message.volumeId),
                "newSize": .stringConvertible(message.newSize),
            ])

        guard let storageBackend = storageBackend else {
            await sendError(for: message.requestId, error: "Storage backend not available")
            return
        }

        do {
            try await storageBackend.resizeVolume(volumePath: message.volumePath, newSizeBytes: message.newSize)

            let response = VolumeStatusResponse(
                volumeId: message.volumeId,
                status: "available",
                storagePath: message.volumePath
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume resized successfully", data: data)
            logger.info(
                "Volume resized successfully",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "newSize": .stringConvertible(message.newSize),
                ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to resize volume: \(error.localizedDescription)")
            logger.error(
                "Failed to resize volume",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleVolumeSnapshot(_ message: VolumeSnapshotMessage) async {
        logger.info(
            "Creating volume snapshot",
            metadata: [
                "volumeId": .string(message.volumeId),
                "snapshotId": .string(message.snapshotId),
            ])

        guard let storageBackend = storageBackend else {
            await sendError(for: message.requestId, error: "Storage backend not available")
            return
        }

        do {
            let snapshotPath = try await storageBackend.createSnapshot(
                volumeId: message.volumeId,
                snapshotId: message.snapshotId,
                volumePath: message.volumePath
            )

            let response = VolumeStatusResponse(
                volumeId: message.volumeId,
                status: "available",
                storagePath: snapshotPath
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Snapshot created successfully", data: data)
            logger.info(
                "Volume snapshot created successfully",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "snapshotId": .string(message.snapshotId),
                    "path": .string(snapshotPath),
                ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to create snapshot: \(error.localizedDescription)")
            logger.error(
                "Failed to create snapshot",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "snapshotId": .string(message.snapshotId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleVolumeSnapshotDelete(_ message: VolumeSnapshotDeleteMessage) async {
        logger.info(
            "Deleting volume snapshot",
            metadata: [
                "volumeId": .string(message.volumeId),
                "snapshotId": .string(message.snapshotId),
            ])

        guard let storageBackend = storageBackend else {
            await sendError(for: message.requestId, error: "Storage backend not available")
            return
        }

        do {
            try await storageBackend.deleteSnapshot(volumeId: message.volumeId, snapshotId: message.snapshotId)
            await sendSuccess(for: message.requestId, message: "Snapshot deleted successfully")
            logger.info(
                "Volume snapshot deleted successfully",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "snapshotId": .string(message.snapshotId),
                ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to delete snapshot: \(error.localizedDescription)")
            logger.error(
                "Failed to delete snapshot",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "snapshotId": .string(message.snapshotId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleVolumeClone(_ message: VolumeCloneMessage) async {
        logger.info(
            "Cloning volume",
            metadata: [
                "sourceVolumeId": .string(message.sourceVolumeId),
                "targetVolumeId": .string(message.targetVolumeId),
            ])

        guard let storageBackend = storageBackend else {
            await sendError(for: message.requestId, error: "Storage backend not available")
            return
        }

        do {
            let targetPath = try await storageBackend.cloneVolume(
                sourceVolumeId: message.sourceVolumeId,
                sourcePath: message.sourceVolumePath,
                targetVolumeId: message.targetVolumeId
            ).path

            let response = VolumeStatusResponse(
                volumeId: message.targetVolumeId,
                status: "available",
                storagePath: targetPath
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume cloned successfully", data: data)
            logger.info(
                "Volume cloned successfully",
                metadata: [
                    "sourceVolumeId": .string(message.sourceVolumeId),
                    "targetVolumeId": .string(message.targetVolumeId),
                    "targetPath": .string(targetPath),
                ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to clone volume: \(error.localizedDescription)")
            logger.error(
                "Failed to clone volume",
                metadata: [
                    "sourceVolumeId": .string(message.sourceVolumeId),
                    "targetVolumeId": .string(message.targetVolumeId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    private func handleVolumeInfo(_ message: VolumeInfoMessage) async {
        logger.info(
            "Getting volume info",
            metadata: [
                "volumeId": .string(message.volumeId)
            ])

        guard let storageBackend = storageBackend else {
            await sendError(for: message.requestId, error: "Storage backend not available")
            return
        }

        do {
            let info = try await storageBackend.volumeInfo(volumePath: message.volumePath)

            let response = VolumeInfoResponse(
                volumeId: message.volumeId,
                actualSize: info.actualSize,
                virtualSize: info.virtualSize,
                format: info.format,
                dirty: info.dirty,
                encrypted: info.encrypted
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume info retrieved successfully", data: data)
            logger.info(
                "Volume info retrieved successfully",
                metadata: [
                    "volumeId": .string(message.volumeId)
                ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to get volume info: \(error.localizedDescription)")
            logger.error(
                "Failed to get volume info",
                metadata: [
                    "volumeId": .string(message.volumeId),
                    "error": .string(error.localizedDescription),
                ])
        }
    }
}

// MARK: - Reconciliation (issue #260)

/// Runtime side effects for the reconcile loop. VM items mirror the imperative
/// handlers (same manifest bookkeeping, same driver-registry routing) minus
/// the per-request response messaging: convergence outcomes are reported via
/// `ObservedStateReport` instead of success/error envelopes. Sandbox items
/// route to the sandbox runtime seam (issue #417; the driver itself is issue
/// #421) with the same manifest contract.
extension Agent: ReconcileActuator {
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
        return presence
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

    func perform(_ step: ReconcileStep, item: ReconcileWorkItem) async throws {
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
        case .shutdown:
            try await reconcileService(for: item.vmId).shutdownVM(vmId: item.vmId)
        case .delete:
            try await reconcileDelete(item)
        }
    }

    func convergenceDidChange() async {
        await sendObservedStateReport()
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
                networkAttachments: attachments)
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

    private func reconcileDelete(_ item: ReconcileWorkItem) async throws {
        // Orphan with no live session: try to re-adopt first so the surviving
        // hypervisor process is actually torn down instead of leaking. If the
        // session cannot be reattached (pre-deterministic-socket VM, dead
        // process), fall back to releasing the manifest entry — the same
        // manual-cleanup contract as the imperative path.
        if managedVMs[item.vmId] == nil, let entry = orphanedVMs[item.vmId] {
            if let service = getHypervisorService(for: entry.hypervisorType),
                (try? await service.adoptVM(vmId: item.vmId, spec: entry.spec)) != nil
            {
                managedVMs[item.vmId] = entry
            } else {
                orphanedVMs.removeValue(forKey: item.vmId)
                persistManifest()
                // Host-side network resources are derived from deterministic
                // names, so they can be torn down even with no live session.
                await networkOrchestrator.teardownAttachments(
                    vmId: item.vmId, count: entry.spec.networks.count)
                logger.warning(
                    "Deleted orphaned VM from manifest; any surviving hypervisor process must be cleaned up manually",
                    metadata: ["vmId": .string(item.vmId)])
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
        case .pause, .resume:
            // Not in the sandbox step vocabulary (v1); the planner never
            // emits these for sandbox items.
            throw SandboxRuntimeError.unsupportedStep(String(describing: step))
        }
    }

    private func sandboxReconcileCreate(_ item: ReconcileWorkItem) async throws {
        guard let desired = item.desiredSandbox else {
            throw HypervisorServiceError.invalidConfiguration("create work item without a desired entry")
        }
        let runtime = try requireSandboxRuntime()

        // v1 has no in-guest networking (the runtime rejects networked specs).
        // Fail here, before reserving host-side NICs, so an unsupported spec
        // surfaces the permanent `networkingUnsupported` reason immediately
        // instead of a transient network-prep failure that retries until the
        // operation budget expires.
        guard desired.spec.network == nil else {
            throw SandboxRuntimeError.networkingUnsupported
        }

        // Same contract as the VM path: the orchestrator realizes the
        // sandbox's NIC on this host before the runtime runs, and rolls it
        // back if the runtime never created the sandbox.
        let networks = desired.spec.network.map { [$0] } ?? []
        let attachments = try await networkOrchestrator.prepareAttachments(vmId: item.id, networks: networks)
        do {
            try await runtime.createSandbox(
                sandboxId: item.id, spec: desired.spec,
                registryCredential: desired.registryCredential, networkAttachments: attachments)
        } catch {
            await networkOrchestrator.teardownAttachments(vmId: item.id, count: attachments.count)
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
                    vmId: item.id, count: entry.sandboxSpec?.network != nil ? 1 : 0)
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
            vmId: item.id, count: entry.sandboxSpec?.network != nil ? 1 : 0)

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
                    failedGeneration: await reconciler.failedGeneration(for: vmId)
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
            agentUpdateStatus: autoUpdateStatus
        )
        do {
            try await websocketClient?.sendMessage(report)
        } catch {
            logger.error("Failed to send observed-state report: \(error)")
        }
    }

    /// Assemble the sandbox half of the observed-state report, mirroring the
    /// VM assembly section by section: managed sandboxes with their live
    /// status, still-orphaned ones, in-flight creates, and failed
    /// convergences with no runtime presence. Same full-list semantics — a
    /// sandbox absent from the report does not exist here.
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
}
