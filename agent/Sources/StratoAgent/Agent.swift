import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import StratoShared
import StratoAgentCore

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
    private var qemuService: QEMUService?
    #if os(Linux)
    private var firecrackerService: FirecrackerService?
    #endif
    private var networkService: (any NetworkServiceProtocol)?
    private var imageCacheService: ImageCacheService?
    private var volumeService: VolumeService?
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

    // Track which hypervisor type is used for each VM
    private var vmHypervisorMap: [String: HypervisorType] = [:]

    private let networkMode: NetworkMode?
    // The networking backend actually selected at startup (config value plus
    // platform fallbacks). Drives the networking capability advertised at
    // registration: a Linux agent configured for user-mode networking must not
    // claim OVN/VM-to-VM support.
    private var effectiveNetworkMode: NetworkMode = .user
    // Whether the selected network service connected successfully at startup.
    // An OVN agent whose OVN/OVS connection failed must not advertise
    // ovn_networking, or the scheduler would place VM-to-VM workloads on a
    // backend that will throw notConnected.
    private var networkServiceConnected = false
    private let imageCachePath: String?
    private let vmStoragePath: String
    private let qemuBinaryPath: String
    private let firmwarePath: String?
    private let firecrackerBinaryPath: String
    private let firecrackerSocketDir: String
    private let hypervisorType: HypervisorType

    // SPIFFE/SPIRE support
    private let spiffeConfig: SPIFFEConfig?
    private var svidManager: SVIDManager?

    // Join state persistence (rotated reconnect token survives restarts)
    private let stateStore: (any AgentStateStore)?
    // Set when a failure is unrecoverable (e.g. the reconnect token was
    // rejected); start() rethrows it so the process exits non-zero instead
    // of idling disconnected.
    private var terminalError: Error?

    init(
        agentID: String,
        webSocketURL: String,
        registrationToken: String? = nil,
        qemuSocketDir: String,
        networkMode: NetworkMode?,
        isRegistrationMode: Bool,
        logger: Logger,
        imageCachePath: String? = nil,
        vmStoragePath: String,
        qemuBinaryPath: String,
        firmwarePath: String? = nil,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        firecrackerSocketDir: String = "/tmp/firecracker",
        hypervisorType: HypervisorType = .qemu,
        spiffeConfig: SPIFFEConfig? = nil,
        stateStore: (any AgentStateStore)? = nil
    ) {
        self.initialAgentID = agentID
        self.webSocketURL = webSocketURL
        self.currentWebSocketURL = webSocketURL
        self.currentRegistrationToken = registrationToken
        self.qemuSocketDir = qemuSocketDir
        self.networkMode = networkMode
        self.isRegistrationMode = isRegistrationMode
        self.logger = logger
        self.imageCachePath = imageCachePath
        self.vmStoragePath = vmStoragePath
        self.qemuBinaryPath = qemuBinaryPath
        self.firmwarePath = firmwarePath
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.firecrackerSocketDir = firecrackerSocketDir
        self.hypervisorType = hypervisorType
        self.spiffeConfig = spiffeConfig
        self.stateStore = stateStore

        let (stream, continuation) = AsyncStream.makeStream(of: MessageEnvelope.self)
        self.inboundMessages = stream
        self.inboundContinuation = continuation
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
        
        logger.info("Initializing network service")

        // Initialize network service based on config, falling back to platform defaults
        let selectedMode = networkMode ?? {
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
            networkService = NetworkServiceLinux(logger: logger)
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

        do {
            if let service = networkService {
                try await service.connect()
                networkServiceConnected = true
                logger.info("Network service connected successfully")
            }
        } catch {
            logger.warning("Failed to connect to network service: \(error.localizedDescription)")
            logger.warning("VM networking will be limited")
        }
        
        // Initialize image cache service
        logger.info("Initializing image cache service")
        imageCacheService = ImageCacheService(
            logger: logger,
            cachePath: imageCachePath,
            controlPlaneURL: webSocketURL.replacingOccurrences(of: "ws://", with: "http://")
                .replacingOccurrences(of: "wss://", with: "https://")
                .replacingOccurrences(of: "/agent/ws", with: "")
        )

        logger.info("Initializing volume service")
        volumeService = VolumeService(
            logger: logger,
            imageCacheService: imageCacheService
        )

        logger.info("Initializing QEMU service")
        qemuService = QEMUService(logger: logger, networkService: networkService, imageCacheService: imageCacheService, vmStoragePath: vmStoragePath, qemuBinaryPath: qemuBinaryPath, firmwarePath: firmwarePath)

        #if os(Linux)
        logger.info("Initializing Firecracker service (Linux only)")
        firecrackerService = FirecrackerService(
            logger: logger,
            networkService: networkService,
            imageCacheService: imageCacheService,
            vmStoragePath: vmStoragePath,
            firecrackerBinaryPath: firecrackerBinaryPath,
            socketDirectory: firecrackerSocketDir
        )
        #endif

        logger.info("Initializing console socket manager")
        consoleSocketManager = ConsoleSocketManager(logger: logger, eventLoopGroup: eventLoopGroup)
        await consoleSocketManager?.setOnConsoleData { [weak self] vmId, sessionId, data in
            await self?.sendConsoleData(vmId: vmId, sessionId: sessionId, data: data)
        }
        
        // Initialize SPIFFE/mTLS if enabled
        var tlsConfiguration: TLSConfiguration?
        if let spiffe = spiffeConfig, spiffe.enabled {
            logger.info("Initializing SPIFFE authentication", metadata: [
                "trustDomain": .string(spiffe.trustDomain ?? SPIFFEConfig.defaultTrustDomain),
                "sourceType": .string(spiffe.sourceType ?? "files")
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
        websocketClient = WebSocketClient(url: currentWebSocketURL, agent: self, logger: logger, tlsConfiguration: tlsConfiguration, registrationToken: currentRegistrationToken, inboundContinuation: inboundContinuation)

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

        // Fail any in-flight registration wait so a caller parked on it (and its
        // timeout timer) doesn't linger past shutdown.
        if let continuation = takeRegistrationContinuation() {
            continuation.resume(throwing: AgentError.registrationSuperseded)
        }

        // Stop draining inbound frames; finishing the stream ends the consumer loop.
        inboundContinuation.finish()
        messageConsumerTask?.cancel()
        messageConsumerTask = nil

        // Unregister from control plane
        do {
            try await unregisterFromControlPlane()
        } catch {
            logger.error("Failed to unregister from control plane: \(error)")
        }
        
        if let client = websocketClient {
            await client.disconnect()
        }
        websocketClient = nil
        qemuService = nil
        #if os(Linux)
        firecrackerService = nil
        #endif

        if let service = networkService {
            await service.disconnect()
        }
        networkService = nil

        // Stop SVID manager
        if let manager = svidManager {
            await manager.stop()
        }
        svidManager = nil

        // Clear VM hypervisor mapping
        vmHypervisorMap.removeAll()

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
                  let bundlePath = config.trustBundlePath else {
                throw AgentError.spiffeConfigurationError(
                    "File-based SPIFFE requires certificate_path, private_key_path, and trust_bundle_path"
                )
            }

            logger.info("Using file-based SPIFFE client", metadata: [
                "certificatePath": .string(certPath),
                "spiffeID": .string(spiffeID.uri)
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

            logger.info("Using Workload API SPIFFE client", metadata: [
                "socketPath": .string(socketPath),
                "spiffeID": .string(spiffeID.uri)
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
        // Probe on every registration (initial and reconnect) so the control
        // plane sees the host as it is now, not as it was at process start —
        // e.g. Firecracker installed or /dev/kvm permissions fixed since then.
        let hypervisors = HypervisorProbe.probeAll(
            qemuBinaryPath: qemuBinaryPath,
            firecrackerBinaryPath: firecrackerBinaryPath
        )
        let networkCapability = currentNetworkCapability()
        let capabilities = getAgentCapabilities(hypervisors: hypervisors, networkCapability: networkCapability)

        let message = AgentRegisterMessage(
            agentId: initialAgentID,
            hostname: ProcessInfo.processInfo.hostName,
            version: "1.0.0",
            capabilities: capabilities,
            resources: resources,
            hypervisorType: hypervisorType,
            architecture: CPUArchitecture.current,
            hypervisors: hypervisors,
            networkCapability: networkCapability
        )

        if let client = websocketClient {
            try await client.sendMessage(message)
        }
        logger.info("Registration message sent to control plane, waiting for response...")

        // Wait for registration response with timeout
        let assignedId = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            self.armRegistrationWait(continuation)
        }

        self.assignedAgentID = assignedId
        logger.info("Registration complete, assigned ID: \(assignedId)")
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
            logger.warning("Control plane wire protocol version differs from agent", metadata: [
                "controlPlaneProtocolVersion": .stringConvertible(controlPlaneProtocolVersion),
                "agentProtocolVersion": .stringConvertible(WireProtocol.currentVersion)
            ])
        }

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
            logger.error("Failed to persist join state to \(store.location): \(error). The agent stays connected, but a restart will need a new join token.")
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
            // Only an explicit invalid_token code is a genuine credential
            // rejection (terminal — retrying the same token can never work).
            // Anything else, including envelopes from control planes that
            // predate the code field, is treated as transient so the reconnect
            // loop keeps backing off instead of exiting.
            if message.code == ErrorMessage.ErrorCode.invalidToken {
                continuation.resume(throwing: AgentError.registrationRejected(message.error))
            } else {
                continuation.resume(throwing: AgentError.registrationFailed(message.error))
            }
            return
        }

        logger.error("Control plane reported an error: \(message.error)\(detailSuffix)", metadata: [
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
    private func getAgentCapabilities(hypervisors: [HypervisorSupport], networkCapability: NetworkCapability?) -> [String] {
        var capabilities = ["vm_management"]

        for hypervisor in hypervisors {
            if hypervisor.available {
                capabilities.append(hypervisor.type.rawValue)
            } else if hypervisor.type == .qemu {
                // Error, not warning: without QEMU the agent is unusable for
                // most placements, and the scheduler will only report
                // "unsupported hypervisor" — this log points at the cause.
                logger.error("QEMU unusable; not advertising qemu capability", metadata: [
                    "reason": .string(hypervisor.unavailabilityReason ?? "unknown"),
                    "qemuBinaryPath": .string(qemuBinaryPath)
                ])
            } else {
                #if os(Linux)
                // Not worth a log on platforms where the backend can never
                // exist (e.g. Firecracker on macOS).
                logger.warning("\(hypervisor.type.displayName) unusable; not advertising \(hypervisor.type.rawValue) capability", metadata: [
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
            break // backend selected but not connected; advertise nothing
        }

        if !HypervisorType.allCases.contains(where: { capabilities.contains($0.rawValue) }) {
            logger.error("No usable hypervisor backend on this host; the agent will register but never be eligible for VM placement. Check qemu_binary_path (and firecracker_binary_path on Linux) in the agent configuration.", metadata: [
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
                return // cancelled (agent stopping)
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
                logger.error("If the token expired or was revoked, create a new registration token in the Strato UI (Agents → Create Registration Token) and run: strato-agent join '<registration-url>'")
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
    }
    
    private func getAgentResources() async -> AgentResources {
        // Host capacity, probed live from the machine the agent runs on.
        let totalCPU = HostResources.logicalCoreCount
        let totalMemory = HostResources.physicalMemoryBytes

        // Resources committed to VMs currently managed on this host. We report
        // available = total - reserved (1:1, no overcommit) so the scheduler treats
        // CPU/memory as hard constraints; overcommit ratios can be layered on later.
        var reservedCPU = 0
        var reservedMemory: Int64 = 0

        for service in hypervisorServices {
            let reserved = await service.reservedResources()
            reservedCPU += reserved.vcpus
            reservedMemory += reserved.memoryBytes
        }

        let availableCPU = max(0, totalCPU - reservedCPU)
        let availableMemory = max(0, totalMemory - reservedMemory)

        // VM disks are created directly on the storage filesystem, so query it live
        // rather than tracking reservations — this naturally accounts for existing disks.
        let disk = HostResources.diskCapacity(forPath: vmStoragePath)
        if disk == nil {
            logger.warning("Unable to determine disk capacity for VM storage path", metadata: [
                "path": .string(vmStoragePath)
            ])
        }

        return AgentResources(
            totalCPU: totalCPU,
            availableCPU: availableCPU,
            totalMemory: totalMemory,
            availableMemory: availableMemory,
            totalDisk: disk?.total ?? 0,
            availableDisk: disk?.free ?? 0
        )
    }
    
    private func getRunningVMList() async -> [String] {
        var vmList: [String] = []

        for service in hypervisorServices {
            let vms = await service.listVMs()
            vmList.append(contentsOf: vms)
        }

        return vmList
    }

    /// All hypervisor backends this agent is running. Together with
    /// `getHypervisorService(for:)`, this is the only place message handling
    /// may reach the concrete services — everything else goes through the
    /// `HypervisorService` protocol so new backends get honest behavior.
    private var hypervisorServices: [any HypervisorService] {
        var services: [any HypervisorService] = []
        if let qemu = qemuService {
            services.append(qemu)
        }
        #if os(Linux)
        if let firecracker = firecrackerService {
            services.append(firecracker)
        }
        #endif
        return services
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
        logger.debug("Handling message from control plane", metadata: [
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
            case .vmPause:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMPause(message)
            case .vmResume:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMResume(message)
            case .vmDelete:
                let message = try envelope.decode(as: VMOperationMessage.self)
                await handleVMDelete(message)
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
                logger.debug("Received success response from control plane", metadata: [
                    "requestId": .string(message.requestId),
                    "message": .string(message.message ?? "")
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
    
    /// Get the hypervisor service for a VM based on its type
    private func getHypervisorService(for hypervisorType: HypervisorType) -> (any HypervisorService)? {
        switch hypervisorType {
        case .qemu:
            return qemuService
        case .firecracker:
            #if os(Linux)
            return firecrackerService
            #else
            // No silent fallback to QEMU: the scheduler should never place a
            // Firecracker VM here, so surface the mismatch as an error instead
            // of booting the VM under a different hypervisor than requested.
            logger.error("Firecracker is only available on Linux; rejecting request for unsupported hypervisor")
            return nil
            #endif
        }
    }

    /// Get the hypervisor service for an existing VM
    private func getHypervisorServiceForVM(vmId: String) -> (any HypervisorService)? {
        guard let hypervisorType = vmHypervisorMap[vmId] else {
            logger.warning("No hypervisor type recorded for VM, defaulting to QEMU", metadata: ["vmId": .string(vmId)])
            return qemuService
        }
        return getHypervisorService(for: hypervisorType)
    }

    private func handleVMCreate(_ message: VMCreateMessage) async {
        let vmId = message.vmData.id.uuidString
        let hypervisorType = message.vmData.hypervisorType

        logger.info("Creating VM", metadata: [
            "vmId": .string(vmId),
            "hypervisorType": .string(hypervisorType.rawValue)
        ])
        await sendVMLog(vmId: vmId, level: .info, eventType: .operation, message: "Starting VM creation with hypervisor: \(hypervisorType.rawValue)", operation: "create")

        // Log image info if provided
        if let imageInfo = message.imageInfo {
            logger.info("VM creation includes image info", metadata: [
                "vmId": .string(vmId),
                "imageId": .string(imageInfo.imageId.uuidString),
                "filename": .string(imageInfo.filename)
            ])
            await sendVMLog(vmId: vmId, level: .info, eventType: .info, message: "Using image: \(imageInfo.filename)", operation: "create")
        }

        guard let service = getHypervisorService(for: hypervisorType) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for type: \(hypervisorType.rawValue)")
            await sendVMLog(vmId: vmId, level: .error, eventType: .error, message: "Hypervisor service not available for type: \(hypervisorType.rawValue)", operation: "create")
            return
        }

        do {
            try await service.createVM(
                vmId: vmId,
                spec: message.vmSpec,
                imageInfo: message.imageInfo
            )
            // Record the hypervisor type for this VM
            vmHypervisorMap[vmId] = hypervisorType
            await sendSuccess(for: message.requestId, message: "VM created successfully")
            await sendVMLog(vmId: vmId, level: .info, eventType: .statusChange, message: "VM created successfully", operation: "create", newStatus: .created)
            logger.info("VM created successfully", metadata: ["vmId": .string(vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to create VM: \(error.localizedDescription)")
            await sendVMLog(vmId: vmId, level: .error, eventType: .error, message: "Failed to create VM: \(error.localizedDescription)", operation: "create")
            logger.error("Failed to create VM", metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMBoot(_ message: VMOperationMessage) async {
        logger.info("Booting VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM boot", operation: "boot")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available", operation: "boot")
            return
        }

        do {
            try await service.bootVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM booted successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .running)
            await sendVMLog(vmId: message.vmId, level: .info, eventType: .statusChange, message: "VM booted successfully", operation: "boot", newStatus: .running)
            logger.info("VM booted successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to boot VM: \(error.localizedDescription)")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Failed to boot VM: \(error.localizedDescription)", operation: "boot")
            logger.error("Failed to boot VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleVMShutdown(_ message: VMOperationMessage) async {
        logger.info("Shutting down VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM shutdown", operation: "shutdown")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available", operation: "shutdown")
            return
        }

        do {
            try await service.shutdownVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM shut down successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .shutdown)
            await sendVMLog(vmId: message.vmId, level: .info, eventType: .statusChange, message: "VM shut down successfully", operation: "shutdown", newStatus: .shutdown)
            logger.info("VM shut down successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to shutdown VM: \(error.localizedDescription)")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Failed to shutdown VM: \(error.localizedDescription)", operation: "shutdown")
            logger.error("Failed to shutdown VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
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
            logger.error("Failed to reboot VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMPause(_ message: VMOperationMessage) async {
        logger.info("Pausing VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM pause", operation: "pause")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available", operation: "pause")
            return
        }

        do {
            try await service.pauseVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM paused successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .paused)
            await sendVMLog(vmId: message.vmId, level: .info, eventType: .statusChange, message: "VM paused successfully", operation: "pause", newStatus: .paused)
            logger.info("VM paused successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to pause VM: \(error.localizedDescription)")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Failed to pause VM: \(error.localizedDescription)", operation: "pause")
            logger.error("Failed to pause VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMResume(_ message: VMOperationMessage) async {
        logger.info("Resuming VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM resume", operation: "resume")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available", operation: "resume")
            return
        }

        do {
            try await service.resumeVM(vmId: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM resumed successfully")
            await sendStatusUpdate(vmId: message.vmId, status: .running)
            await sendVMLog(vmId: message.vmId, level: .info, eventType: .statusChange, message: "VM resumed successfully", operation: "resume", newStatus: .running)
            logger.info("VM resumed successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to resume VM: \(error.localizedDescription)")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Failed to resume VM: \(error.localizedDescription)", operation: "resume")
            logger.error("Failed to resume VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    private func handleVMDelete(_ message: VMOperationMessage) async {
        logger.info("Deleting VM", metadata: ["vmId": .string(message.vmId)])
        await sendVMLog(vmId: message.vmId, level: .info, eventType: .operation, message: "Starting VM deletion", operation: "delete")

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Hypervisor service not available", operation: "delete")
            return
        }

        do {
            try await service.deleteVM(vmId: message.vmId)
            // Clean up the hypervisor mapping
            vmHypervisorMap.removeValue(forKey: message.vmId)
            await sendSuccess(for: message.requestId, message: "VM deleted successfully")
            await sendVMLog(vmId: message.vmId, level: .info, eventType: .operation, message: "VM deleted successfully", operation: "delete")
            logger.info("VM deleted successfully", metadata: ["vmId": .string(message.vmId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to delete VM: \(error.localizedDescription)")
            await sendVMLog(vmId: message.vmId, level: .error, eventType: .error, message: "Failed to delete VM: \(error.localizedDescription)", operation: "delete")
            logger.error("Failed to delete VM", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
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
            logger.error("Failed to get VM info", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
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
            logger.info("VM status retrieved successfully", metadata: ["vmId": .string(message.vmId), "status": .string(status.rawValue)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to get VM status: \(error.localizedDescription)")
            logger.error("Failed to get VM status", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
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
            logger.error("Failed to create network", metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
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
            logger.error("Failed to delete network", metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
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
                logger.info("Network info retrieved successfully", metadata: ["networkName": .string(message.networkName)])
            } else {
                await sendError(for: message.requestId, error: "Network not found: \(message.networkName)")
                logger.warning("Network not found", metadata: ["networkName": .string(message.networkName)])
            }
        } catch {
            await sendError(for: message.requestId, error: "Failed to get network info: \(error.localizedDescription)")
            logger.error("Failed to get network info", metadata: ["networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
        }
    }
    
    private func handleNetworkAttach(_ message: NetworkAttachMessage) async {
        logger.info("Attaching VM to network", metadata: ["vmId": .string(message.vmId), "networkName": .string(message.networkName)])
        
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
            logger.info("VM attached to network successfully", metadata: ["vmId": .string(message.vmId), "networkName": .string(message.networkName)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to attach VM to network: \(error.localizedDescription)")
            logger.error("Failed to attach VM to network", metadata: ["vmId": .string(message.vmId), "networkName": .string(message.networkName), "error": .string(error.localizedDescription)])
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
            await sendError(for: message.requestId, error: "Failed to detach VM from network: \(error.localizedDescription)")
            logger.error("Failed to detach VM from network", metadata: ["vmId": .string(message.vmId), "error": .string(error.localizedDescription)])
        }
    }

    // MARK: - Console Message Handlers

    private func handleConsoleConnect(_ message: ConsoleConnectMessage) async {
        logger.info("Console connect request received", metadata: [
            "vmId": .string(message.vmId),
            "sessionId": .string(message.sessionId),
            "requestId": .string(message.requestId)
        ])

        guard let service = getHypervisorServiceForVM(vmId: message.vmId) else {
            logger.error("Hypervisor service not available for console connect", metadata: ["vmId": .string(message.vmId)])
            await sendError(for: message.requestId, error: "Hypervisor service not available for VM")
            return
        }

        // Try serial socket first, then fall back to virtio-console if connect fails.
        logger.debug("Looking up console endpoint", metadata: ["vmId": .string(message.vmId)])
        let endpoint: ConsoleEndpoint?
        do {
            endpoint = try await service.consoleEndpoint(vmId: message.vmId)
        } catch {
            logger.error("Console not available", metadata: [
                "vmId": .string(message.vmId),
                "error": .string(error.localizedDescription)
            ])
            await sendError(for: message.requestId, error: "Console not available for VM \(message.vmId): \(error.localizedDescription)")
            return
        }

        let serialPath = endpoint?.serialSocketPath
        let consolePath = endpoint?.consoleSocketPath

        guard serialPath != nil || consolePath != nil else {
            logger.error("No console socket found (tried serial and virtio-console)", metadata: ["vmId": .string(message.vmId)])
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
            logger.info("Cleaning up existing console sessions for VM", metadata: [
                "vmId": .string(message.vmId),
                "sessionCount": .stringConvertible(existingSessions.count)
            ])
            await consoleManager.disconnectAllForVM(vmId: message.vmId)
        }

        var connectedPath: String?
        var lastError: Error?

        if let serialPath = serialPath {
            do {
                try await consoleManager.connect(vmId: message.vmId, sessionId: message.sessionId, socketPath: serialPath)
                connectedPath = serialPath
                logger.debug("Connected to serial console socket", metadata: ["socketPath": .string(serialPath)])
            } catch {
                lastError = error
                logger.warning("Failed to connect to serial socket, will try virtio-console", metadata: [
                    "vmId": .string(message.vmId),
                    "sessionId": .string(message.sessionId),
                    "error": .string(error.localizedDescription)
                ])
            }
        }

        if connectedPath == nil, let consolePath = consolePath {
            do {
                try await consoleManager.connect(vmId: message.vmId, sessionId: message.sessionId, socketPath: consolePath)
                connectedPath = consolePath
                logger.debug("Connected to virtio-console socket", metadata: ["socketPath": .string(consolePath)])
            } catch {
                lastError = error
            }
        }

        guard connectedPath != nil else {
            let errorMessage = "Failed to connect to console: \(lastError?.localizedDescription ?? "unknown error")"
            await sendError(for: message.requestId, error: errorMessage)
            logger.error("Failed to connect to console", metadata: [
                "vmId": .string(message.vmId),
                "sessionId": .string(message.sessionId),
                "error": .string(lastError?.localizedDescription ?? "unknown")
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

        logger.info("Console connected", metadata: [
            "vmId": .string(message.vmId),
            "sessionId": .string(message.sessionId),
            "socketPath": .string(connectedPath ?? "unknown")
        ])
    }

    private func handleConsoleDisconnect(_ message: ConsoleDisconnectMessage) async {
        logger.info("Console disconnect request", metadata: [
            "vmId": .string(message.vmId),
            "sessionId": .string(message.sessionId)
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

        logger.info("Console disconnected", metadata: [
            "vmId": .string(message.vmId),
            "sessionId": .string(message.sessionId)
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
            logger.error("Failed to write to console", metadata: [
                "sessionId": .string(message.sessionId),
                "error": .string(error.localizedDescription)
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

    // MARK: - Volume Message Handlers

    private func handleVolumeCreate(_ message: VolumeCreateMessage) async {
        logger.info("Creating volume", metadata: [
            "volumeId": .string(message.volumeId),
            "size": .stringConvertible(message.size),
            "format": .string(message.format)
        ])

        guard let volumeService = volumeService else {
            await sendError(for: message.requestId, error: "Volume service not available")
            return
        }

        do {
            let volumePath: String
            if let imageInfo = message.sourceImageInfo {
                // Create volume from image
                volumePath = try await volumeService.createVolumeFromImage(volumeId: message.volumeId, imageInfo: imageInfo)
            } else {
                // Create empty volume
                volumePath = try await volumeService.createVolume(volumeId: message.volumeId, size: message.size, format: message.format)
            }

            let response = VolumeStatusResponse(
                volumeId: message.volumeId,
                status: "available",
                storagePath: volumePath
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume created successfully", data: data)
            logger.info("Volume created successfully", metadata: [
                "volumeId": .string(message.volumeId),
                "path": .string(volumePath)
            ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to create volume: \(error.localizedDescription)")
            logger.error("Failed to create volume", metadata: [
                "volumeId": .string(message.volumeId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    private func handleVolumeDelete(_ message: VolumeDeleteMessage) async {
        logger.info("Deleting volume", metadata: [
            "volumeId": .string(message.volumeId)
        ])

        guard let volumeService = volumeService else {
            await sendError(for: message.requestId, error: "Volume service not available")
            return
        }

        do {
            try await volumeService.deleteVolume(volumeId: message.volumeId)
            await sendSuccess(for: message.requestId, message: "Volume deleted successfully")
            logger.info("Volume deleted successfully", metadata: ["volumeId": .string(message.volumeId)])
        } catch {
            await sendError(for: message.requestId, error: "Failed to delete volume: \(error.localizedDescription)")
            logger.error("Failed to delete volume", metadata: [
                "volumeId": .string(message.volumeId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    private func handleVolumeAttach(_ message: VolumeAttachMessage) async {
        logger.info("Attaching volume to VM (hot-plug)", metadata: [
            "volumeId": .string(message.volumeId),
            "vmId": .string(message.vmId),
            "deviceName": .string(message.deviceName),
            "volumePath": .string(message.volumePath)
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
            logger.info("Volume attached successfully (hot-plug)", metadata: [
                "volumeId": .string(message.volumeId),
                "vmId": .string(message.vmId),
                "deviceName": .string(message.deviceName)
            ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to attach volume: \(error.localizedDescription)")
            logger.error("Failed to attach volume (hot-plug)", metadata: [
                "volumeId": .string(message.volumeId),
                "vmId": .string(message.vmId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    private func handleVolumeDetach(_ message: VolumeDetachMessage) async {
        logger.info("Detaching volume from VM (hot-unplug)", metadata: [
            "volumeId": .string(message.volumeId),
            "vmId": .string(message.vmId),
            "deviceName": .string(message.deviceName)
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
            logger.info("Volume detached successfully (hot-unplug)", metadata: [
                "volumeId": .string(message.volumeId),
                "vmId": .string(message.vmId)
            ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to detach volume: \(error.localizedDescription)")
            logger.error("Failed to detach volume (hot-unplug)", metadata: [
                "volumeId": .string(message.volumeId),
                "vmId": .string(message.vmId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    private func handleVolumeResize(_ message: VolumeResizeMessage) async {
        logger.info("Resizing volume", metadata: [
            "volumeId": .string(message.volumeId),
            "newSize": .stringConvertible(message.newSize)
        ])

        guard let volumeService = volumeService else {
            await sendError(for: message.requestId, error: "Volume service not available")
            return
        }

        do {
            try await volumeService.resizeVolume(volumePath: message.volumePath, newSize: message.newSize)

            let response = VolumeStatusResponse(
                volumeId: message.volumeId,
                status: "available",
                storagePath: message.volumePath
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume resized successfully", data: data)
            logger.info("Volume resized successfully", metadata: [
                "volumeId": .string(message.volumeId),
                "newSize": .stringConvertible(message.newSize)
            ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to resize volume: \(error.localizedDescription)")
            logger.error("Failed to resize volume", metadata: [
                "volumeId": .string(message.volumeId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    private func handleVolumeSnapshot(_ message: VolumeSnapshotMessage) async {
        logger.info("Creating volume snapshot", metadata: [
            "volumeId": .string(message.volumeId),
            "snapshotId": .string(message.snapshotId)
        ])

        guard let volumeService = volumeService else {
            await sendError(for: message.requestId, error: "Volume service not available")
            return
        }

        do {
            let snapshotPath = try await volumeService.createSnapshot(
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
            logger.info("Volume snapshot created successfully", metadata: [
                "volumeId": .string(message.volumeId),
                "snapshotId": .string(message.snapshotId),
                "path": .string(snapshotPath)
            ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to create snapshot: \(error.localizedDescription)")
            logger.error("Failed to create snapshot", metadata: [
                "volumeId": .string(message.volumeId),
                "snapshotId": .string(message.snapshotId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    private func handleVolumeClone(_ message: VolumeCloneMessage) async {
        logger.info("Cloning volume", metadata: [
            "sourceVolumeId": .string(message.sourceVolumeId),
            "targetVolumeId": .string(message.targetVolumeId)
        ])

        guard let volumeService = volumeService else {
            await sendError(for: message.requestId, error: "Volume service not available")
            return
        }

        do {
            let targetPath = try await volumeService.cloneVolume(
                sourceVolumeId: message.sourceVolumeId,
                sourcePath: message.sourceVolumePath,
                targetVolumeId: message.targetVolumeId
            )

            let response = VolumeStatusResponse(
                volumeId: message.targetVolumeId,
                status: "available",
                storagePath: targetPath
            )
            let data = try AnyCodableValue(response)
            await sendSuccess(for: message.requestId, message: "Volume cloned successfully", data: data)
            logger.info("Volume cloned successfully", metadata: [
                "sourceVolumeId": .string(message.sourceVolumeId),
                "targetVolumeId": .string(message.targetVolumeId),
                "targetPath": .string(targetPath)
            ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to clone volume: \(error.localizedDescription)")
            logger.error("Failed to clone volume", metadata: [
                "sourceVolumeId": .string(message.sourceVolumeId),
                "targetVolumeId": .string(message.targetVolumeId),
                "error": .string(error.localizedDescription)
            ])
        }
    }

    private func handleVolumeInfo(_ message: VolumeInfoMessage) async {
        logger.info("Getting volume info", metadata: [
            "volumeId": .string(message.volumeId)
        ])

        guard let volumeService = volumeService else {
            await sendError(for: message.requestId, error: "Volume service not available")
            return
        }

        do {
            let info = try await volumeService.getVolumeInfo(volumePath: message.volumePath)

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
            logger.info("Volume info retrieved successfully", metadata: [
                "volumeId": .string(message.volumeId)
            ])
        } catch {
            await sendError(for: message.requestId, error: "Failed to get volume info: \(error.localizedDescription)")
            logger.error("Failed to get volume info", metadata: [
                "volumeId": .string(message.volumeId),
                "error": .string(error.localizedDescription)
            ])
        }
    }
}
