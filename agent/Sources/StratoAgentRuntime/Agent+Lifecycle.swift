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

/// Owns agent startup, graceful shutdown, and lifetime orchestration.
extension Agent {
    /// Returns the effective agent ID (assigned UUID if registered, initial ID otherwise)
    var effectiveAgentID: String {
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
        await applyManifestLoad(manifestStore.load())
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
                let ipBinaryPath = SandboxJailerResolver.resolveIPBinaryPath(isExecutable: isExecutable)
                let sysctlBinaryPath = NetworkResolverDefaults.resolveSysctlBinaryPath(
                    isExecutable: isExecutable)
                // The resolver is OVN-only by construction: it terminates on a
                // per-network OVN `localport`, which does not exist under
                // user-mode networking. Resolved here rather than at
                // startup so `resolverBinaryPath` is nil on every path that
                // cannot run it, and `resolverCapable` follows from one check.
                let discoveredResolverBinaryPath =
                    (resolverConfig?.enabled ?? true)
                    ? NetworkResolverDefaults.resolveBinaryPath(
                        configured: resolverConfig?.corednsBinaryPath, isExecutable: isExecutable)
                    : nil
                // A resolver is only a real capability when the host can also
                // build its isolated host-side foot. `ip` has no `sysctl`
                // subcommand; the isolation settings require procps's binary.
                resolverBinaryPath =
                    ipBinaryPath != nil && sysctlBinaryPath != nil
                    ? discoveredResolverBinaryPath : nil
                let resolverSupervisor = resolverBinaryPath.flatMap { binaryPath -> ResolverSupervisor? in
                    // All three binaries are required. CoreDNS runs in the host
                    // namespace and needs no `ip` to start, but it binds
                    // addresses that `ip` is what puts on the interface — so
                    // without it there is nothing for the resolver to answer on.
                    guard let ipBinaryPath, sysctlBinaryPath != nil else { return nil }
                    return ResolverSupervisor(
                        root: resolverConfig?.effectiveConfigDirectory
                            ?? NetworkResolverDefaults.configDirectory,
                        host: ResolverProcessHost(
                            binaryPath: binaryPath, ipBinaryPath: ipBinaryPath, logger: logger),
                        logger: logger)
                }
                self.resolverSupervisor = resolverSupervisor
                networkService = NetworkServiceLinux(
                    nbConnection: ovnNorthbound, nbTLS: ovnNorthboundTLS, chassisConfig: ovnChassisConfig,
                    uplink: ovnUplink, dynamicRouting: ovnDynamicRouting,
                    ipBinaryPath: ipBinaryPath,
                    tcBinaryPath: SandboxJailerResolver.resolveTCBinaryPath(isExecutable: isExecutable),
                    sysctlBinaryPath: sysctlBinaryPath,
                    linkLocalServiceRatePPS: resolverConfig?.effectiveRateLimitPPS
                        ?? NetworkResolverDefaults.rateLimitPPS,
                    resolverSupervisor: resolverSupervisor,
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
        let cephImageSource = imageCacheService
        let cephLogger = logger
        self.storageBackends = StorageBackendRegistry(
            local: storageBackend,
            makeCeph: { configuration in
                CephRBDStorageBackend(
                    logger: cephLogger, configuration: configuration,
                    imageSource: cephImageSource)
            })

        if isSimulationMode {
            // One mock backend per hypervisor type, so the agent is eligible for
            // both QEMU and Firecracker placements. The mock tracks specs and
            // reports real reservations, so placements deplete the agent's
            // advertised capacity like a real host.
            //
            // Deliberately not gated on Linux, unlike the real drivers: a
            // simulated agent models a Linux fleet whatever host it runs on —
            // it reports overlay networking on macOS for the same reason — so
            // a macOS dev box can scale-test Firecracker placement too.
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
            // `.qemu` means libvirtd now — there is no second driver to choose
            // between (STR-136). Nothing gates checkpoints away from it either:
            // `LibvirtService` realizes a capture as a libvirt system checkpoint
            // (STR-134). The preconditions that make that work — a qcow2 NVRAM
            // varstore and libvirt >= 11.5 — belong to the domain builder, the
            // varstore `createVM` materializes (STR-188) and the host preflight,
            // and a node failing the version floor stops advertising `.qemu` at
            // all rather than advertising a checkpoint it cannot take.
            #if os(Linux)
            logger.info(
                "Initializing libvirt hypervisor service", metadata: ["uri": .string(LibvirtProbe.systemURI)])
            let libvirt = LibvirtService(
                logger: logger, storage: storageBackend,
                vmStoragePath: vmStoragePath, firmware: firmware,
                hardwareAccelerationEnabled: hardwareAccelerationEnabled,
                memoryOverheadBytes: qemuMemoryOverheadBytes)
            libvirtService = libvirt
            hypervisorServices[.qemu] = libvirt
            #else
            // A deliberate, temporary regression (STR-136): the QEMU driver is
            // libvirt, and libvirt is Linux-only. A native
            // Virtualization.framework driver is separate work. Said plainly so
            // a mock cannot be mistaken for a hypervisor — and the host reports
            // `.qemu` as unavailable to match (`HypervisorProbe.qemuReport`), so
            // nothing is ever scheduled onto it.
            logger.warning(
                "No hypervisor on this platform: registering a MOCK QEMU backend",
                metadata: [
                    "detail": .string(
                        "this host cannot run VMs — the QEMU driver is libvirtd, which is Linux-only")
                ])
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
                diskRealizer: KRBDDiskRealizer(),
                imageSource: imageCacheService,
                vmStoragePath: vmStoragePath,
                firecrackerBinaryPath: firecrackerBinaryPath,
                socketDirectory: firecrackerSocketDir,
                firecrackerClient: firecrackerClient,
                metadataProvider: { [metadataStore, metadataServiceEnabled] vmId in
                    guard metadataServiceEnabled else { return nil }
                    return await metadataStore.metadata(for: vmId)
                }
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
                let jailerConfig = try SandboxJailerConfig(
                    jailerBinaryPath: sandboxJailerBinaryPath,
                    chrootBaseDir: sandboxJailerChrootDir,
                    uidBase: sandboxJailerUidBase,
                    ipBinaryPath: SandboxJailerResolver.resolveIPBinaryPath(isExecutable: isExecutable),
                    tcBinaryPath: SandboxJailerResolver.resolveTCBinaryPath(isExecutable: isExecutable))
                sandboxJailerConfig = jailerConfig
                let jailUIDRangeCheck = HostPreflight.checkSandboxJailerUIDRange(
                    sandboxJailerUIDRangeInputs())
                if sandboxJailerMode == .required, !jailUIDRangeCheck.passed {
                    sandboxJailerUIDRangeBlockedReason =
                        jailUIDRangeCheck.detail
                        ?? "the configured sandbox jail uid/gid range is not isolated"
                }
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
                    if !jailUIDRangeCheck.passed, sandboxJailerMode == .auto {
                        // Auto keeps its advisory semantics: retain the other
                        // jailer barriers instead of dropping the whole jail,
                        // while stating plainly that UID isolation is weak.
                        logger.warning(
                            "Sandbox jail uid/gid range overlaps a host identity; UID-BASED FILESYSTEM ISOLATION IS NOT TRUSTWORTHY. Reserve a clean range or set sandbox_jailer_mode = \"required\" to refuse creates.",
                            metadata: [
                                "reason": .string(
                                    jailUIDRangeCheck.detail
                                        ?? "the configured range overlaps a host identity")
                            ])
                    }
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
                    jailUIDAllocator: sandboxJailUIDs,
                    legacyJailerUIDBase: legacySandboxJailerUidBase,
                    jailNewSandboxes: jailNewSandboxes,
                    jailerBlockedReason: sandboxJailCreationBlockedReason,
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
        }
        startSandboxPumps()

        // Hypervisor backends that push lifecycle transitions instead of only
        // answering status queries (STR-135). Started here because the driver
        // registry is complete by this point, and before registration because
        // nothing is sent until there is an assigned agent id anyway.
        await startLifecycleObservation()

        // The reconciler drives desired-state syncs onto the shared per-VM
        // lanes; all hypervisor side effects go through this agent (the
        // actuator), so it must exist before the message consumer starts.
        reconciler = Reconciler(
            actuator: self, queue: messageQueue, logger: logger, teardownGuard: teardownGuard,
            metadataStore: metadataStore)

        await startMetadataService()

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

        // This starts with an immediate sample but never awaits it: registration,
        // heartbeats, and reconciliation consume only the last completed cache.
        startResourceTelemetryObservation()
        try await startDependencyObservation()

        // Begin draining inbound frames before the connection opens so the registration
        // response (and any early frames) are processed in order.
        startMessageConsumer()

        logger.info("Connecting to control plane", metadata: ["url": .string(webSocketURL)])
        websocketClient = WebSocketClient(
            url: webSocketURL, agent: self, logger: logger, tlsConfiguration: tlsConfiguration,
            spiffePinning: controlPlanePinning,
            inboundContinuation: inboundContinuation)

        guard let client = websocketClient else {
            throw AgentError.registrationFailed("WebSocket client was not initialized")
        }
        guard try await establishInitialControlPlaneConnection(client) else { return }

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

    /// Establishes the first registered socket without treating a transient
    /// control-plane outage as a fatal agent startup error.
    func establishInitialControlPlaneConnection(_ client: WebSocketClient) async throws -> Bool {
        var delaySeconds = 1.0
        let maxDelaySeconds = 30.0

        while !shutdownRequested {
            _ = reconnectState.consumeStartupConnectionLoss()
            do {
                let generation = try await client.connect()
                try await registerWithControlPlane()
                guard
                    await restoreConnectionScopedState(generation: generation, attempt: nil),
                    !reconnectState.consumeStartupConnectionLoss()
                else {
                    throw AgentError.registrationFailed(
                        "control-plane connection closed during startup registration")
                }
                return true
            } catch AgentError.registrationRejected(let reason) {
                throw AgentError.registrationRejected(reason)
            } catch {
                guard !shutdownRequested else { return false }
                logger.warning(
                    "Initial control-plane registration failed; retrying with backoff: \(error)")
                await client.disconnect()
                _ = reconnectState.consumeStartupConnectionLoss()
                let jitter = Double.random(in: 0...(delaySeconds * 0.3))
                do {
                    try await Task.sleep(for: .seconds(delaySeconds + jitter))
                } catch {
                    return false
                }
                delaySeconds = min(delaySeconds * 2, maxDelaySeconds)
            }
        }
        return false
    }

    /// Wakes start() out of its run-forever suspension after an unrecoverable
    /// failure (set `terminalError` first). stop() deliberately does NOT use
    /// this: it resumes the continuation only after teardown completes, so the
    /// process doesn't exit mid-cleanup.
    func signalShutdown() {
        shutdownRequested = true
        isRunning = false
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    func stop() async {
        logger.info("Stopping agent")
        shutdownRequested = true
        isRunning = false

        // Before anything else that can block: the listeners are separate
        // processes, and one left running would keep answering guests with
        // nobody supervising it. They also exit on their own when this process
        // dies (their control stream closes), so this is belt and braces.
        await metadataPersistTrigger?.stop()
        metadataPersistTrigger = nil
        await metadataServers?.shutdown()
        metadataServers = nil

        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectState.finishLoop()

        networkConnectTask?.cancel()
        networkConnectTask = nil

        dependencyObservationTask?.cancel()
        dependencyObservationTask = nil
        dependencyManager = nil

        resourceTelemetryTask?.cancel()
        resourceTelemetryTask = nil

        // Stop the per-network resolvers (STR-40). A draining host must not keep
        // a CoreDNS answering for networks whose guests have moved elsewhere:
        // the localport is instantiated on every chassis, so a stale process
        // here would answer a query from a guest that is still local — with
        // zone data this agent stopped converging.
        await resolverSupervisor?.shutdown()
        resolverSupervisor = nil

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

        // End VM exec channels before stopping their event pump. Closing a
        // channel before exec_exit is also the guest-side process-group kill.
        await vmExecSessionManager.closeAll(reason: "agent stopping")
        guestExecSessions.removeAll()

        // Stop the sandbox exec/log pumps the same way.
        await sandboxRuntime?.controlPlaneDisconnected()
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

        // Stop the lifecycle pumps and their trigger before the backends they
        // drain, so nothing is still asking for a report while the drivers are
        // being torn down.
        for task in lifecyclePumpTasks.values { task.cancel() }
        lifecyclePumpTasks.removeAll()
        await observedStateTrigger?.stop()
        observedStateTrigger = nil

        // Then the backends themselves. Budgeted because both steps talk to a
        // hypervisor and a wedged daemon must not hold up shutdown, and budgeted
        // **per backend** rather than over the sweep: one wedged driver would
        // otherwise eat the budget its peers still need to release theirs.
        // Abandoning is safe because the process is exiting.
        for (type, service) in hypervisorServices {
            do {
                try await StageBudget.run(
                    seconds: 5, stage: "hypervisor-shutdown", onTimeout: .abandon
                ) {
                    await service.stopObservingLifecycle()
                    await service.shutdown()
                }
            } catch {
                logger.warning(
                    "Hypervisor shutdown exceeded its budget",
                    metadata: ["hypervisor": .string(type.rawValue)])
            }
        }

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
        // for the next incarnation to recover as orphans. The vsock
        // allocations go with them for the same reason, and come back from the
        // manifest on the next load — dropping them here rather than leaving
        // them behind keeps "what the allocator holds" tied to "what the
        // in-memory records say", which is the invariant that makes a stale
        // allocation a bug rather than a matter of taste.
        managedVMs.removeAll()
        orphanedVMs.removeAll()
        managedSandboxes.removeAll()
        orphanedSandboxes.removeAll()
        vsockCIDs = VsockCIDAllocator()
        sandboxJailUIDs = SandboxJailUIDAllocator(uidBase: sandboxJailerUidBase)

        logger.info("Agent stopped")

        // Unblock start(), which parks on this continuation for the agent's
        // lifetime, so the process can exit cleanly.
        if let continuation = shutdownContinuation {
            shutdownContinuation = nil
            continuation.resume()
        }
    }
}
