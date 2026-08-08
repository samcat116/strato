import Foundation
import Libvirt
import Logging
import NIOCore
import StratoAgentCore
import StratoShared

/// The QEMU backend driven through **libvirtd** rather than by spawning QEMU
/// directly (issue #902).
///
/// Registered in place of `QEMUService` on a node whose `qemu_driver` is
/// `libvirt`. It answers to the same `HypervisorType.qemu`: nothing on the wire
/// changes, the control plane's capability gating and scheduler are untouched,
/// and the agent alone decides how a QEMU placement is realized. Nodes roll
/// over one at a time.
///
/// ## Why this is so much smaller than `QEMUService`
///
/// `activeVMs`, `vmSpecs`, `vmConfigs`, `vmSpawnSizing`, `awaitingFirstStart`,
/// `vmConsoleSocketPaths`, `vmSerialSocketPaths`, `pendingVMs`, `respawn()` and
/// `indicatesDeadHypervisor()` are all bookkeeping for an *ephemeral process*:
/// the agent spawned it, so only the agent knows what it spawned, and anything
/// it forgets is unrecoverable. libvirtd is a durable store. Domains survive the
/// agent, so this driver **queries** rather than mirrors, and:
///
/// - creating is `domainDefineXML`, which leaves the domain `SHUTOFF` — the
///   `ReconcileStep.create` contract ("exists, not running") with none of the
///   `-S` plus `prelaunch`-versus-`paused` disambiguation `awaitingFirstStart`
///   exists for. Idempotency comes free: define is keyed by name and UUID, so a
///   replayed create updates rather than spawning a second machine.
/// - a guest that powers itself off leaves the domain `SHUTOFF` and restarts
///   with `domainCreate`. There is no respawn-from-stored-configuration path
///   at all.
/// - a guest that powers itself off is *announced* rather than discovered on
///   the next sweep — see "Lifecycle events" below.
/// - re-adoption is `connectListAllDomains` plus a state read. `AdoptedQEMUVM`
///   and the second deterministic QMP socket exist only because `QEMUManager`
///   cannot attach to a process it did not spawn; here orphan re-adoption stops
///   being a mechanism and becomes a query.
/// - libvirt owns swtpm and the UEFI varstore, so `SwtpmSupervisor` and the
///   copy-if-absent NVRAM templating have no counterpart here.
///
/// The two caches below (`lastKnownVMIds`, `lastKnownReservations`) are the only
/// retained state, they hold *the last answer libvirtd gave* rather than a model
/// of it, and neither is keyed by VM id. Treat any new dictionary keyed by VM id
/// as a smell worth justifying in review.
///
/// ## Lifecycle events
///
/// The driver holds a `withDomainEvents` subscription for as long as the agent
/// wants one (STR-135), and every Strato domain transition it sees becomes a
/// request for an observed-state report. Events are an **accelerant, not a
/// source of truth**: the report they schedule re-reads the host exactly as the
/// 20-second periodic one does, so a dropped event costs latency and nothing
/// else. That is what lets the subscription buffer be bounded and
/// `.dropOldest`, and it is why `getVMStatus` polling is untouched.
///
/// See `superviseLifecycleEvents` for the two consequences worth knowing before
/// reading it: the connection is now dialed *proactively* rather than on first
/// use, and `stopObservingLifecycle` is the first thing in this file that ever
/// closes it.
///
/// ## Not here yet
///
/// Disk hot-plug, online resize and checkpoints are STR-134; the calls below
/// throw `notSupported` or take the protocol's defaults.
///
/// The consequence worth stating plainly: **a volume can only reach a VM at
/// create time.** The domain document is written once by `createVM` and nothing
/// here rewrites it, so attaching to an existing VM is refused whether it is
/// running or stopped — see `hasLiveSession`, which exists in this driver to
/// make sure that refusal is reached rather than papered over by recording the
/// attachment. Checkpoint capture is kept away by capability instead: the agent
/// stops advertising `snapshot:vm_checkpoint` on a libvirt node, because since
/// STR-150 an artifact inherits its parent's host and a capture admitted here
/// could only degrade permanently.
actor LibvirtService: HypervisorService {
    private let logger: Logger
    private let storage: (any StorageBackend)?
    private let vmStoragePath: String
    /// The daemon this host manages VMs through.
    private let uri: String
    /// Operator-configured EDK2 firmware paths (issue #565). Empty is the
    /// normal case and means libvirt autoselects — see `resolveFirmware`.
    private let firmware: FirmwareOverrides
    /// Whether this host has swtpm at all. libvirt runs it, but a host without
    /// it never advertises the TPM capability, so a spec asking for one here
    /// means the placement gate was bypassed and the create must fail loudly.
    private let hasSwtpm: Bool
    /// KVM on Linux, HVF on macOS; when false, domains run under TCG.
    private let hardwareAccelerationEnabled: Bool

    let hypervisorType: HypervisorType = .qemu

    // The domain document binds a qga channel and a balloon on every VM.
    nonisolated let observesGuests = true

    /// The one connection, opened on first use. `LibvirtClient` never
    /// reconnects — once its channel dies every call on it throws — so a dead
    /// one is dropped here and the next call redials.
    private var client: LibvirtClient?
    /// The connect in flight, so N reconcile lanes arriving at once open one
    /// connection rather than N. Actor reentrancy is what makes this necessary:
    /// every caller suspends inside `connect`, so without it they all see a nil
    /// `client`.
    private var connecting: Task<LibvirtClient, any Error>?

    /// The last domain list libvirtd answered with, and the last reservations
    /// computed from it.
    ///
    /// Both exist because `listVMs()` and `reservedResources()` cannot express
    /// failure — and for both, the empty answer is actively harmful rather than
    /// merely uninformative. An empty VM list makes the control plane treat
    /// every VM on this host as lost, and zero reservations advertise capacity
    /// the host does not have and invite the scheduler to over-place it. The
    /// agent's own manifest fallback only covers a query that *times out*, so a
    /// libvirtd that answers with an error has to be covered here. Nil means
    /// this driver has never had an answer, which is the one case where empty
    /// is the truth.
    private var lastKnownVMIds: Cached<[String]>?
    private var lastKnownReservations: Cached<(vcpus: Int, memoryBytes: Int64)>?

    /// The lifecycle subscription's hand-off to the agent (STR-135), created in
    /// `init` so the stream exists before anyone attaches to it. `nonisolated`
    /// so reading it costs no hop onto this actor, exactly like
    /// `observesGuests`.
    ///
    /// Bounded, and bounded *again* on the libvirt side by
    /// `lifecycleEventBuffer`. Both drops are safe for the same reason: what
    /// travels here is a request to re-read the host, not the reading itself.
    private nonisolated let lifecycleStream: AsyncStream<VMLifecycleChange>
    private nonisolated let lifecycleContinuation: AsyncStream<VMLifecycleChange>.Continuation
    nonisolated var lifecycleChanges: AsyncStream<VMLifecycleChange>? { lifecycleStream }

    /// The supervisor holding the subscription, and the flag that tells it a
    /// stream that just ended was our own doing rather than a dead daemon.
    private var eventTask: Task<Void, Never>?
    private var stoppingObservation = false

    /// An answer libvirtd gave, with when it gave it — the timestamp being the
    /// only thing that distinguishes a fresh reading from an indefinitely stale
    /// one at the point it is served.
    private struct Cached<Value> {
        let value: Value
        let at: ContinuousClock.Instant

        init(_ value: Value) {
            self.value = value
            self.at = ContinuousClock.now
        }
    }

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil,
        vmStoragePath: String,
        uri: String = LibvirtProbe.systemURI,
        firmware: FirmwareOverrides = FirmwareOverrides(),
        hasSwtpm: Bool = false,
        hardwareAccelerationEnabled: Bool = true
    ) {
        self.logger = logger
        self.storage = storage
        self.vmStoragePath = vmStoragePath
        self.uri = uri
        self.firmware = firmware
        self.hasSwtpm = hasSwtpm
        self.hardwareAccelerationEnabled = hardwareAccelerationEnabled
        (self.lifecycleStream, self.lifecycleContinuation) = AsyncStream.makeStream(
            of: VMLifecycleChange.self, bufferingPolicy: .bufferingNewest(64))
        logger.info("libvirt hypervisor service initialized", metadata: ["uri": .string(uri)])
    }

    // MARK: - Connection

    /// The live connection, dialing one if there is none.
    ///
    /// Deliberately lazy rather than opened at agent start: whether libvirtd is
    /// reachable is the host preflight's question to answer (with remediation),
    /// and a driver that refused to construct would take the whole agent down
    /// over a daemon that may come up a second later.
    private func connection() async throws -> LibvirtClient {
        if let client { return client }

        let task: Task<LibvirtClient, any Error>
        if let connecting {
            task = connecting
        } else {
            task = Task { [uri, logger] in
                try await LibvirtClient.connect(to: uri, logger: logger)
            }
            connecting = task
        }

        do {
            let connected = try await task.value
            // Reentrancy again: another waiter may have recorded it already.
            if client == nil { client = connected }
            if connecting == task { connecting = nil }
            return connected
        } catch {
            if connecting == task { connecting = nil }
            throw error
        }
    }

    /// Drops `dead` if it is still the cached connection, so the next call
    /// redials. Guarded on identity because a slow call can fail long after a
    /// healthy replacement was already installed.
    private func invalidate(_ dead: LibvirtClient) {
        guard let client, client === dead else { return }
        logger.warning("libvirt connection lost; the next call will reconnect")
        self.client = nil
    }

    /// Runs one RPC under a stage budget, with the connection dropped if *it*
    /// was what failed.
    ///
    /// `.cancelAndWait`, matching `QEMUService.controlled` and for the same
    /// reason: these are commands, and abandoning one lets it land after the
    /// agent has reported failure and a retry has run. It terminates because
    /// the call carries a deadline of its own — the second parameter — so the
    /// RPC gives up on the wire rather than parking forever.
    ///
    /// Errors come back **untranslated**: callers distinguish "no such domain"
    /// and "libvirt refused given the domain's state" from real failures, and
    /// that distinction is gone once it is a `HypervisorServiceError`.
    private func call<T: Sendable>(
        _ stage: String,
        vmId: String,
        seconds: Int = StageBudget.hypervisorControlSeconds,
        _ operation: @escaping @Sendable (LibvirtClient, NIODeadline) async throws -> T
    ) async throws -> T {
        let client = try await connection()
        let deadline = NIODeadline.now() + .seconds(Int64(seconds))
        do {
            return try await StageBudget.run(
                seconds: seconds, stage: stage, onTimeout: .cancelAndWait
            ) {
                try await operation(client, deadline)
            }
        } catch let error as StageBudgetError {
            logger.error(
                "libvirt call exceeded its budget",
                metadata: ["vmId": .string(vmId), "stage": .string(stage)])
            throw HypervisorServiceError.timeout("\(stage) for VM \(vmId): \(error.localizedDescription)")
        } catch {
            if LibvirtFailure.isConnectionLost(error) { invalidate(client) }
            throw error
        }
    }

    /// Maps whatever escapes `body` onto the hypervisor error vocabulary, so
    /// libvirt's own message reaches the reconciler's `lastError` and the UI.
    private func perform<T>(
        _ operation: String, vmId: String, _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch {
            throw LibvirtFailure.hypervisorError(error, vmId: vmId, operation: operation)
        }
    }

    // MARK: - Lifecycle events

    /// The libvirt-side buffer for the lifecycle subscription (STR-135).
    ///
    /// `.dropOldest` is not a preference. What comes out of this subscription
    /// is a request to re-read the host, and a full re-reading answers every
    /// request that preceded it — so the newest transitions are the only ones
    /// that describe the present, and under this policy correctness never
    /// depends on the number at all. `.dropNewest` inverts exactly that: a
    /// burst would fill the buffer and then discard the transition that just
    /// happened, leaving a guest's self-initiated power-off invisible until the
    /// next periodic sync, which is the case this whole feature exists for.
    private static let lifecycleEventBuffer: EventBufferPolicy = .dropOldest(256)

    /// Backoff bounds for re-establishing the subscription, matching
    /// `DesiredStatePoller` so a host whose daemon is down produces one
    /// recognizable retry cadence rather than two. No jitter: every agent dials
    /// its own local libvirtd, so there is no herd to spread.
    private static let initialEventBackoff: Duration = .seconds(1)
    private static let maximumEventBackoff: Duration = .seconds(30)

    /// How often a continuing outage is escalated back to `warning`. One line
    /// every ten attempts, which at the capped backoff is roughly one every
    /// five minutes.
    private static let outageReminderEvery = 10

    func startObservingLifecycle() async {
        guard eventTask == nil, !stoppingObservation else { return }
        eventTask = Task { [weak self] in
            await self?.superviseLifecycleEvents()
        }
    }

    func stopObservingLifecycle() async {
        stoppingObservation = true
        eventTask?.cancel()
        // Waited out rather than abandoned, so teardown does not race a dial
        // that is about to install a connection nothing will ever close. The
        // caller bounds this: a wedged daemon must not hold up shutdown.
        await eventTask?.value
        eventTask = nil
        lifecycleContinuation.finish()
    }

    /// Closes the one connection this driver holds.
    ///
    /// The first and only place that happens — nothing did before, which was a
    /// real (if quiet) leak on agent shutdown. It lives here rather than in
    /// `stopObservingLifecycle` because the connection is not the
    /// subscription's: every call path in this file shares it, and ending a
    /// subscription is no reason to take it away from them.
    ///
    /// Cancel-then-close looks careless and is not. `stopObservingLifecycle`
    /// has already cancelled the drain, so `withDomainEvents` unwound and ran
    /// its own teardown: the local sink deregistration always lands, and only
    /// the wire-level `connectDomainEventCallbackDeregisterAny` may be skipped
    /// on an already-cancelled task. The `CONNECT_CLOSE` here finishes the job,
    /// because the server-side registration is scoped to the connection and
    /// dies with it. Racing a stop signal against the drain inside a task group
    /// would buy one best-effort RPC on a path that drops the socket a
    /// millisecond later; it is not worth the machinery.
    ///
    /// If the caller's budget abandons this, the connection stays open — which
    /// is the very leak above, bounded to a process that is exiting anyway.
    func shutdown() async {
        guard let client else { return }
        self.client = nil
        try? await client.close()
    }

    /// Holds a lifecycle subscription for as long as the agent wants one,
    /// re-establishing it across daemon restarts.
    ///
    /// This is the one place the driver dials libvirtd without being asked to
    /// do work, which is a real change from the lazy connection the rest of the
    /// file describes: on a libvirt node the agent now holds a connection from
    /// start, even with no VMs on the host. That costs one Unix socket and a
    /// five-second keepalive, and it cannot take the agent down — the loop only
    /// logs, so a daemon that never comes up never reaches `Agent.start()` and
    /// never fails a reconcile. The host preflight remains the place an
    /// unreachable libvirtd is *reported*, which is why nothing here logs at
    /// `error`.
    private func superviseLifecycleEvents() async {
        var backoff = Self.initialEventBackoff
        // Attempts since the last subscription that *held*. A failed dial and a
        // subscription that died in its first half-minute count the same,
        // because to an operator they are the same thing: libvirtd is not
        // currently able to tell this host what its guests are doing. Counting
        // only the former would let a flapping daemon retry forever in silence.
        var attempts = 0
        var troubleStarted: ContinuousClock.Instant?

        while !Task.isCancelled && !stoppingObservation {
            do {
                let client = try await connection()
                if attempts > 0 {
                    logger.info(
                        "libvirt lifecycle subscription re-established",
                        metadata: [
                            "attempts": .stringConvertible(attempts),
                            "outageSeconds": .stringConvertible(
                                troubleStarted.map { (ContinuousClock.now - $0).components.seconds } ?? 0),
                        ])
                }
                let subscribedAt = ContinuousClock.now

                try await client.withDomainEvents(
                    DomainLifecycleEvent.self, bufferPolicy: Self.lifecycleEventBuffer
                ) { [lifecycleContinuation, logger] events in
                    await Self.drain(events, into: lifecycleContinuation, logger: logger)
                }

                // The drain only returns when the event stream finished, and
                // while we are still running nothing finishes it but the
                // connection dying — the sink's own `finish` discards the error
                // that says so, so this is inferred rather than read.
                guard !Task.isCancelled && !stoppingObservation else { break }
                invalidate(client)

                // Health is measured in *duration held*, never in the
                // registration merely succeeding: a connection that dies
                // between the dial and the register makes this loop spin, and
                // that is precisely the case the backoff is here to damp.
                if ContinuousClock.now - subscribedAt >= Self.maximumEventBackoff {
                    attempts = 0
                    troubleStarted = nil
                    backoff = Self.initialEventBackoff
                } else {
                    attempts += 1
                    if troubleStarted == nil { troubleStarted = ContinuousClock.now }
                    logShortLivedSubscription(attempt: attempts, since: troubleStarted)
                }
            } catch {
                attempts += 1
                if troubleStarted == nil { troubleStarted = ContinuousClock.now }
                logSubscriptionFailure(error, attempt: attempts, since: troubleStarted)
            }

            guard !Task.isCancelled && !stoppingObservation else { break }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, Self.maximumEventBackoff)
        }
    }

    /// Yields every Strato domain transition into the agent's stream.
    ///
    /// `nonisolated static` on purpose. `withDomainEvents`'s body parameter is
    /// not `@Sendable`, so a closure written inside this actor would be
    /// *isolated to it*, and every resumption of the loop below would be a hop
    /// onto the actor every RPC for every VM on this host passes through.
    /// Actors do not block, so that is not a correctness problem — it is a cost
    /// one, and the trap it opens is worse than the cost: calling `getVMStatus`
    /// (or anything else through `call`) from in here would interleave a
    /// round trip per event into that same queue, over the same connection the
    /// events arrive on, turning an event storm into a status-query storm.
    /// Keeping this free of the actor makes that mistake impossible to make by
    /// accident.
    private nonisolated static func drain(
        _ events: LibvirtEvents<DomainLifecycleEvent>,
        into continuation: AsyncStream<VMLifecycleChange>.Continuation,
        logger: Logger
    ) async {
        // Yielded here, inside the scope, rather than before the call: the
        // registration has already landed by the time this body runs, so
        // nothing that happens between this re-reading and the subscription can
        // fall in the gap. Yielding it outside would leave exactly that window
        // unaccounted for, which is the window a libvirtd restart creates.
        continuation.yield(.resynchronize(reason: "libvirt event subscription established"))

        for await event in events {
            // A co-tenant's domain churning on the same libvirtd is not this
            // agent's business and must not drive its reports.
            guard LibvirtDomain.isStratoDomainName(event.domain.name) else { continue }
            continuation.yield(
                .vm(
                    id: event.domain.name,
                    reason: LibvirtDomain.lifecycleEventLabel(forRawEvent: event.event)))
        }
        logger.debug("libvirt lifecycle event stream ended")
    }

    /// An attempt that failed before a subscription existed at all.
    ///
    /// Deliberately quiet after the first, via `remindOfOutage`.
    private func logSubscriptionFailure(
        _ error: any Error, attempt: Int, since troubleStarted: ContinuousClock.Instant?
    ) {
        if attempt == 1 {
            logger.warning(
                "libvirt lifecycle subscription failed; VM state will fall back to the periodic sync",
                metadata: ["error": .string("\(error)")])
        } else if !remindOfOutage(attempt: attempt, since: troubleStarted) {
            logger.debug(
                "libvirt lifecycle subscription retry failed",
                metadata: [
                    "attempt": .stringConvertible(attempt),
                    "error": .string("\(error)"),
                ])
        }
    }

    /// A subscription that was established and then did not survive long
    /// enough to be called healthy — a daemon that is up but restarting, or a
    /// connection dying between the dial and the registration landing.
    private func logShortLivedSubscription(attempt: Int, since troubleStarted: ContinuousClock.Instant?) {
        if attempt == 1 {
            logger.warning("libvirt lifecycle subscription dropped almost immediately; retrying")
        } else if !remindOfOutage(attempt: attempt, since: troubleStarted) {
            logger.debug(
                "libvirt lifecycle subscription dropped again",
                metadata: ["attempt": .stringConvertible(attempt)])
        }
    }

    /// One operator-actionable line every `outageReminderEvery` attempts, which
    /// at the capped backoff is roughly one every five minutes. Returns whether
    /// it logged, so callers can fall back to `debug`.
    ///
    /// A host configured for libvirt whose daemon is not running retries
    /// forever, so an unconditional line would be two a minute for the life of
    /// the process. And never `error`: `LibvirtProbe`'s preflight already says
    /// an unreachable libvirtd is a problem and says what to do about it, and a
    /// second, more frequent voice repeating it devalues both.
    private func remindOfOutage(attempt: Int, since troubleStarted: ContinuousClock.Instant?) -> Bool {
        guard attempt % Self.outageReminderEvery == 0 else { return false }
        let minutes = troubleStarted.map { (ContinuousClock.now - $0).components.seconds / 60 } ?? 0
        logger.warning(
            "libvirtd is not delivering lifecycle events; observed VM state on this host is only as fresh as the periodic sync",
            metadata: [
                "minutes": .stringConvertible(minutes),
                "attempts": .stringConvertible(attempt),
            ])
        return true
    }

    // MARK: - Domain lookup

    /// The domain for `vmId`. `DomainXMLBuilder` writes the VM id into
    /// `<name>` unconditionally (and `<uuid>` only when it parses), so the name
    /// is the one identifier every Strato domain carries.
    private func domain(_ vmId: String) async throws -> Domain {
        try await call("libvirt-lookup", vmId: vmId, seconds: StageBudget.statusQuerySeconds) {
            client, deadline in
            try await client.domainLookupByName(name: vmId, deadline: deadline)
        }
    }

    /// The domain's raw `virDomainState`.
    private func state(of dom: Domain, vmId: String) async throws -> Int32 {
        try await call("libvirt-state", vmId: vmId, seconds: StageBudget.statusQuerySeconds) {
            client, deadline in
            try await client.domainGetState(dom: dom, flags: 0, deadline: deadline).state
        }
    }

    /// Re-reads the domain after libvirt refused a command with
    /// `VIR_ERR_OPERATION_INVALID` and reports whether the post-condition holds
    /// anyway.
    ///
    /// That code is how libvirt says "domain is already running" and "domain is
    /// not running" — a command whose goal is already met — but it also covers
    /// refusals that are real, and the message text is not a contract. Asking
    /// the daemon for the state instead turns a guess into a fact.
    private func satisfied(
        _ dom: Domain, vmId: String, by predicate: (Int32) -> Bool
    ) async throws -> Bool {
        predicate(try await state(of: dom, vmId: vmId))
    }

    // MARK: - VM lifecycle

    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil,
        networkAttachments: [ResolvedNetworkAttachment] = [],
        metadata: InstanceMetadata? = nil
    ) async throws {
        try await perform("create", vmId: vmId) {
            logger.info("Creating libvirt domain", metadata: ["vmId": .string(vmId)])

            let machine = spec.effectiveMachine
            // The agent never advertises the TPM capability without swtpm, so
            // reaching here means the placement gate was bypassed. libvirt would
            // fail the domain start with a message about the emulator backend;
            // this one names the actual remedy.
            if machine.tpm && !hasSwtpm {
                throw HypervisorServiceError.invalidConfiguration(
                    "VM \(vmId) requires a TPM 2.0 but this host has no swtpm binary. libvirt starts and "
                        + "supervises swtpm per domain, so install it (Debian/Ubuntu: `apt install swtpm "
                        + "swtpm-tools`) or set swtpm_binary_path.")
            }

            let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
            let disks = try await resolveDisks(vmId: vmId, spec: spec, imageInfo: imageInfo)
            try makeVMDirectory(vmDirectory, vmId: vmId)

            // Guest provisioning. The seed ISO must carry the control plane's
            // hostname, because the same value is what the VM's DNS zone is
            // assembled from (STR-177).
            var cloudInitISOPath: String?
            let isoPath = VMDirectoryLayout.cloudInitISO(vmDirectory: vmDirectory)
            if await CloudInitProvisioner(logger: logger).makeNoCloudISO(
                at: isoPath, vmId: vmId, hostname: metadata?.hostname,
                sshAuthorizedKeys: spec.sshAuthorizedKeys, userData: spec.userData,
                networkAttachments: networkAttachments)
            {
                cloudInitISOPath = isoPath
            }

            let xml = try DomainXMLBuilder.build(
                DomainXMLInput(
                    vmId: vmId,
                    vmDirectory: vmDirectory,
                    spec: spec,
                    disks: disks,
                    cloudInitISOPath: cloudInitISOPath,
                    networks: networkAttachments,
                    architecture: .current,
                    accelerator: accelerator,
                    firmware: try resolveFirmware(spec: spec, machine: machine)))

            // Not `domainCreateXML`: that defines *and starts* a transient
            // domain, which would boot every fresh VM once (the next periodic
            // sync then shuts it down again) and leave nothing behind for an
            // agent restart to adopt.
            _ = try await call("libvirt-define", vmId: vmId, seconds: StageBudget.hypervisorSpawnSeconds) {
                client, deadline in
                try await client.domainDefineXML(xml: xml, deadline: deadline)
            }

            logger.info("libvirt domain defined", metadata: ["vmId": .string(vmId)])
        }
    }

    func bootVM(vmId: String) async throws {
        try await perform("boot", vmId: vmId) {
            let dom = try await domain(vmId)
            // `isRunningOrPaused`, not the negation of `holdsResources`: this
            // branch *skips the boot*, so a state this build cannot read has to
            // fall through and attempt the start. Reading it as "active" would
            // report success on a VM that never came up.
            guard !LibvirtDomain.isRunningOrPaused(rawState: try await state(of: dom, vmId: vmId)) else {
                logger.info(
                    "libvirt domain is already running; treating boot as a no-op",
                    metadata: ["vmId": .string(vmId)])
                return
            }

            // QEMU cannot bind a chardev over a socket file a previous,
            // SIGKILLed process left behind, and libvirt does not unlink them
            // for us — the paths are ours, named in the document. Only ever
            // reached with the domain inactive, so no live console is cut.
            clearStaleSockets(vmId: vmId)

            logger.info("Starting libvirt domain", metadata: ["vmId": .string(vmId)])
            do {
                _ = try await call("libvirt-create", vmId: vmId, seconds: StageBudget.hypervisorSpawnSeconds) {
                    client, deadline in
                    try await client.domainCreateWithFlags(
                        dom: dom, flags: LibvirtDomain.startFlags, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isOperationInvalid(error) {
                // Lost a race with something else starting the domain. Same
                // polarity as the guard above: only a guest we can see running
                // counts as this request being satisfied.
                guard try await satisfied(dom, vmId: vmId, by: LibvirtDomain.isRunningOrPaused(rawState:))
                else { throw error }
            }
            logger.info("libvirt domain started", metadata: ["vmId": .string(vmId)])
        }
    }

    /// Asks the guest to power off, escalating to a destroy if it does not.
    ///
    /// The escalation is not optional: `shutdownFlags` is a *request* the guest
    /// is free to ignore, and without a bound a VM whose guest has no ACPI
    /// handler never converges on its `shutdown` desired state. This is the
    /// same 60s envelope `QEMUService.shutdownVM` gives the adopted-VM path,
    /// which polls before forcing termination for exactly this reason.
    func shutdownVM(vmId: String) async throws {
        try await perform("shutdown", vmId: vmId) {
            let dom = try await domain(vmId)
            guard LibvirtDomain.holdsResources(rawState: try await state(of: dom, vmId: vmId)) else {
                logger.info(
                    "libvirt domain is already inactive; treating shutdown as a no-op",
                    metadata: ["vmId": .string(vmId)])
                return
            }

            logger.info("Shutting down libvirt domain", metadata: ["vmId": .string(vmId)])
            do {
                try await call("libvirt-shutdown", vmId: vmId) { client, deadline in
                    // `SHUTDOWN_DEFAULT`, so libvirt tries the guest agent
                    // before the ACPI power button — the verified shutdown
                    // `QEMUService` reaches for qga to get, without the agent
                    // having to speak qga itself.
                    try await client.domainShutdownFlags(
                        dom: dom, flags: LibvirtDomain.shutdownFlags, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isOperationInvalid(error) {
                guard try await satisfied(dom, vmId: vmId, by: { !LibvirtDomain.holdsResources(rawState: $0) })
                else { throw error }
                return
            }

            if await waitForInactive(dom, vmId: vmId, seconds: Self.gracefulShutdownSeconds) { return }

            logger.warning(
                "Guest did not power off within its budget; destroying the domain",
                metadata: [
                    "vmId": .string(vmId),
                    "budgetSeconds": .stringConvertible(Self.gracefulShutdownSeconds),
                ])
            try await destroy(dom, vmId: vmId)
        }
    }

    /// Reboots the guest, treating a domain that is already down as satisfying
    /// the request.
    ///
    /// That is not leniency, it is STR-151's semantics: a reboot is an edge
    /// nonce, consumed by being *performed or superseded*, and a stop or a boot
    /// supersedes it. `virDomainReboot` answers `VIR_ERR_OPERATION_INVALID` on
    /// an inactive domain, so a reboot that lands in the window just after the
    /// guest powered itself off would otherwise fail the lane and strand the
    /// nonce — while the reconciler is about to boot the VM anyway, which is
    /// the very thing the request wanted.
    func rebootVM(vmId: String) async throws {
        try await perform("reboot", vmId: vmId) {
            let dom = try await domain(vmId)
            logger.info("Rebooting libvirt domain", metadata: ["vmId": .string(vmId)])
            do {
                try await call("libvirt-reboot", vmId: vmId) { client, deadline in
                    try await client.domainReboot(dom: dom, flags: 0, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isOperationInvalid(error) {
                guard try await satisfied(dom, vmId: vmId, by: { !LibvirtDomain.holdsResources(rawState: $0) })
                else { throw error }
                logger.info(
                    "libvirt domain is already down; the reboot is superseded by the boot that follows",
                    metadata: ["vmId": .string(vmId)])
            }
        }
    }

    func pauseVM(vmId: String) async throws {
        try await perform("pause", vmId: vmId) {
            let dom = try await domain(vmId)
            logger.info("Pausing libvirt domain", metadata: ["vmId": .string(vmId)])
            do {
                try await call("libvirt-suspend", vmId: vmId) { client, deadline in
                    try await client.domainSuspend(dom: dom, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isOperationInvalid(error) {
                guard
                    try await satisfied(
                        dom, vmId: vmId, by: { LibvirtDomain.vmStatus(forRawState: $0) == .paused })
                else { throw error }
            }
        }
    }

    func resumeVM(vmId: String) async throws {
        try await perform("resume", vmId: vmId) {
            let dom = try await domain(vmId)
            logger.info("Resuming libvirt domain", metadata: ["vmId": .string(vmId)])
            do {
                try await call("libvirt-resume", vmId: vmId) { client, deadline in
                    try await client.domainResume(dom: dom, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isOperationInvalid(error) {
                guard
                    try await satisfied(
                        dom, vmId: vmId, by: { LibvirtDomain.vmStatus(forRawState: $0) == .running })
                else { throw error }
            }
        }
    }

    /// Tears the domain down and removes its definition, then reclaims what it
    /// left on disk.
    ///
    /// A domain libvirtd has never heard of is a **success**, not a failure: a
    /// delete is replayable and level-triggered, and the files are still ours to
    /// reclaim either way. That is the same conclusion `destroyWithoutSession`
    /// reaches on the QEMU path from much weaker evidence (a socket file's
    /// presence); here the daemon simply answers the question.
    func deleteVM(vmId: String) async throws {
        try await perform("delete", vmId: vmId) {
            logger.info("Deleting libvirt domain", metadata: ["vmId": .string(vmId)])
            do {
                let dom = try await domain(vmId)
                try await destroy(dom, vmId: vmId)
                try await call("libvirt-undefine", vmId: vmId) { client, deadline in
                    try await client.domainUndefineFlags(
                        dom: dom, flags: LibvirtDomain.undefineFlags, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isDomainMissing(error) {
                logger.info(
                    "libvirt has no domain for this VM; deleting what it left on this host",
                    metadata: ["vmId": .string(vmId)])
            }

            // Safe now: either the domain is gone or the calls above threw, so
            // nothing can still be running from the disk this unlinks.
            await reclaimVMDirectory(vmId: vmId)
            logger.info("libvirt domain deleted", metadata: ["vmId": .string(vmId)])
        }
    }

    /// See `HypervisorService.reclaimVMDirectory`. `deleteVM` finishes through
    /// here too, so what a libvirt VM leaves on the host has one description.
    ///
    /// Unlike the QEMU path there is no swtpm to stop: libvirt owns its
    /// lifetime, and the vTPM's state directory — which lives under
    /// `/var/lib/libvirt/swtpm/`, not here — is reclaimed by the undefine's
    /// `TPM` flag.
    func reclaimVMDirectory(vmId: String) async {
        // The caller's evidence is that nothing is running. Confirm it against
        // the daemon rather than trusting it, because what follows unlinks the
        // disk a live guest would still be writing to. A daemon that cannot
        // answer is treated as "still running": the manual-cleanup contract is
        // the safe end of that trade.
        do {
            let dom = try await domain(vmId)
            guard !LibvirtDomain.holdsResources(rawState: try await state(of: dom, vmId: vmId)) else {
                logger.error(
                    "Refusing to reclaim the directory of a VM whose domain is still active",
                    metadata: ["vmId": .string(vmId)])
                return
            }
        } catch let error where LibvirtFailure.isDomainMissing(error) {
            // No domain at all — nothing is running from these files.
        } catch {
            logger.error(
                "Could not confirm the domain is inactive; leaving its files for manual cleanup",
                metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
            return
        }

        VMDirectoryLayout.removeDirectory(vmStoragePath: vmStoragePath, vmId: vmId, logger: logger)
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        // A domain libvirtd does not have means this host does not manage the
        // VM. Reported honestly rather than as `.shutdown`, because the control
        // plane relies on the distinction to preserve a reconciled `.error`.
        do {
            let dom = try await domain(vmId)
            return LibvirtDomain.vmStatus(forRawState: try await state(of: dom, vmId: vmId))
        } catch let error where LibvirtFailure.isDomainMissing(error) {
            throw HypervisorServiceError.vmNotFound(vmId)
        } catch let error as HypervisorServiceError {
            // A budget overrun: the domain is likely fine behind a slow daemon,
            // so report `.unknown` rather than fabricating a power state.
            guard case .timeout = error else { throw error }
            logger.warning("libvirt status query timed out; reporting unknown", metadata: ["vmId": .string(vmId)])
            return .unknown
        } catch {
            throw LibvirtFailure.hypervisorError(error, vmId: vmId, operation: "status")
        }
    }

    /// Re-adopts a VM whose domain outlived the agent.
    ///
    /// There is nothing to reconnect: libvirtd kept the domain, so adoption is
    /// a lookup and a state read. A domain that is *gone* raises
    /// `adoptionTargetGone`, which `Agent.adoptVM` answers by re-creating from
    /// the manifest spec — a define over the VM's existing disks, which is
    /// exactly the right recovery.
    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus {
        do {
            let dom = try await domain(vmId)
            let status = LibvirtDomain.vmStatus(forRawState: try await state(of: dom, vmId: vmId))
            logger.info(
                "Adopted libvirt domain",
                metadata: ["vmId": .string(vmId), "status": .string(status.rawValue)])
            return status
        } catch let error where LibvirtFailure.isDomainMissing(error) {
            throw HypervisorServiceError.adoptionTargetGone(
                "libvirt has no domain named \(vmId); its definition is gone")
        } catch {
            throw LibvirtFailure.hypervisorError(error, vmId: vmId, operation: "adopt")
        }
    }

    // MARK: - Console

    /// The sockets the domain document bound, so `ConsoleSocketManager` and the
    /// noVNC relay need no libvirt knowledge at all. libvirt honours the paths
    /// rather than relocating them under its own runtime directory, which is
    /// what makes that true.
    ///
    /// Existence of the file is the authority: libvirtd creates them when the
    /// domain starts, and a headless VM never has a VNC socket at all — it
    /// cannot gain one without being recreated, since the display device is
    /// fixed in the domain definition.
    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
        let endpoint = ConsoleEndpoint(
            serialSocketPath: existingPath(VMDirectoryLayout.serialSocket(vmDirectory: vmDirectory)),
            consoleSocketPath: existingPath(VMDirectoryLayout.consoleSocket(vmDirectory: vmDirectory)),
            vncSocketPath: existingPath(QEMUGraphicsDevice.socketPath(vmDirectory: vmDirectory)))
        return endpoint.isEmpty ? nil : endpoint
    }

    // MARK: - Host inventory

    /// Every Strato domain libvirtd knows about, running or not.
    ///
    /// Includes stopped domains deliberately: a defined-but-off VM holds its
    /// disks and its placement, and omitting it would make the control plane
    /// treat it as lost.
    func listVMs() async -> [String] {
        do {
            let ids = try await call(
                "libvirt-list", vmId: Self.hostScope, seconds: StageBudget.statusQuerySeconds
            ) {
                client, deadline in
                try await client.connectListAllDomains(
                    needResults: 1, flags: LibvirtDomain.listAllDomains, deadline: deadline
                ).domains.map(\.name)
            }.filter(LibvirtDomain.isStratoDomainName)
            lastKnownVMIds = Cached(ids)
            return ids
        } catch {
            return stale(lastKnownVMIds, "the VM list", error) ?? []
        }
    }

    /// vCPUs and memory committed to the domains on this host.
    ///
    /// A query, not mirrored state — which is the point. `maxMem` is used
    /// rather than the live `memory` figure for two reasons: `memory` is the
    /// *current balloon setting*, so an inflated balloon would make a VM look
    /// like it had handed its grant back to the host when it has not; and where
    /// a spec asks for hot-plug headroom, the domain can grow into that
    /// headroom at any moment, so reserving it is the correct answer rather
    /// than a conservative one. For the overwhelmingly common VM with no
    /// headroom the two are the same number.
    func reservedResources() async -> (vcpus: Int, memoryBytes: Int64) {
        do {
            // One `call`, not one per domain: the whole sweep shares a budget so
            // a host with many VMs cannot spend N budgets inside one heartbeat.
            let reserved = try await call(
                "libvirt-reservations", vmId: Self.hostScope, seconds: StageBudget.statusQuerySeconds
            ) { client, deadline in
                let domains = try await client.connectListAllDomains(
                    needResults: 1, flags: LibvirtDomain.listAllDomains, deadline: deadline
                ).domains.filter { LibvirtDomain.isStratoDomainName($0.name) }

                // Concurrently, not in sequence: the reads are independent and
                // already share one absolute deadline, so serializing them turns
                // a host's domain count into `N x RTT` inside a budget sized for
                // a single query — on a busy host, reliably unfinishable.
                return try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
                    for dom in domains {
                        group.addTask {
                            let info = try await client.domainGetInfo(dom: dom, deadline: deadline)
                            // `maxMem`, in KiB.
                            return (Int(info.nrVirtCpu), Int64(clamping: info.maxMem) * 1024)
                        }
                    }
                    var vcpus = 0
                    var memoryBytes: Int64 = 0
                    for try await (domVCPUs, domMemory) in group {
                        vcpus += domVCPUs
                        memoryBytes += domMemory
                    }
                    return (vcpus: vcpus, memoryBytes: memoryBytes)
                }
            }
            lastKnownReservations = Cached(reserved)
            return reserved
        } catch {
            return stale(lastKnownReservations, "host reservations", error) ?? (vcpus: 0, memoryBytes: 0)
        }
    }

    /// Serves a cached inventory answer after a live query failed, escalating
    /// the log as it ages.
    ///
    /// Serving the last answer beats serving an empty one — an empty VM list
    /// makes the control plane mark every VM here lost, and zero reservations
    /// invite the scheduler to over-place the host. What deserved a bound is the
    /// *indefiniteness*: without one, "these are this second's figures" and
    /// "these are from an hour ago" differ only by a log line nobody reads,
    /// while the host goes on looking healthy. Past the threshold this says so
    /// at error level on every heartbeat.
    private func stale<T>(_ cached: Cached<T>?, _ what: String, _ error: any Error) -> T? {
        guard let cached else {
            logger.error(
                "Could not read \(what) from libvirt, and have never had an answer to fall back on",
                metadata: ["error": .string(error.localizedDescription)])
            return nil
        }
        let age = ContinuousClock.now - cached.at
        let metadata: Logger.Metadata = [
            "error": .string(error.localizedDescription),
            "ageSeconds": .stringConvertible(age.components.seconds),
        ]
        if age > Self.staleInventoryThreshold {
            logger.error(
                """
                Still reporting \(what) from a libvirt answer that is now badly out of date; \
                this host's advertised capacity and VM list cannot be trusted
                """,
                metadata: metadata)
        } else {
            logger.warning("Could not read \(what) from libvirt; reporting the last known answer", metadata: metadata)
        }
        return cached.value
    }

    // MARK: - Guest observation

    /// The guest agent's view, over the `org.qemu.guest_agent.0` channel the
    /// domain document binds. Identical mechanism to the QEMU path — same
    /// socket path, same client — because the channel is a QEMU device either
    /// way; only who launched QEMU differs.
    func guestInfo(vmId: String) async -> GuestInfo? {
        let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
        let socketPath = VMDirectoryLayout.guestAgentSocket(vmDirectory: vmDirectory)
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let client = QGAClient(
            transport: NIOQGATransport(socketPath: socketPath, logger: logger), logger: logger)
        do {
            return try await StageBudget.run(
                seconds: StageBudget.guestAgentSeconds, stage: "qga-guest-info", onTimeout: .abandon
            ) {
                try await client.collectGuestInfo()
            }
        } catch {
            return nil
        }
    }

    /// Balloon statistics, read from libvirt rather than a dedicated QMP
    /// monitor. The three-monitor layout the QEMU path needs — one for
    /// lifecycle, one for re-adoption, one for stats, because a QMP server
    /// socket admits one client at a time — has no counterpart here: libvirt
    /// owns the monitor and multiplexes.
    ///
    /// Nil for a guest whose virtio_balloon driver has not reported, which is a
    /// normal "no stats" outcome and never an error.
    func memoryStats(vmId: String) async -> VMMemoryStats? {
        do {
            let dom = try await domain(vmId)
            let stats = try await call(
                "libvirt-memory-stats", vmId: vmId, seconds: StageBudget.guestAgentSeconds
            ) { client, deadline in
                try await client.domainMemoryStats(
                    dom: dom, maxStats: LibvirtDomain.memoryStatSlots, flags: 0, deadline: deadline)
            }
            return LibvirtMemoryStats.parse(stats)
        } catch {
            return nil
        }
    }

    /// True for any domain libvirtd has, running or not.
    ///
    /// This reads as a lie about "live session" and is not: the *question* the
    /// volume reconciler asks with it is whether recording an attachment is
    /// enough to realize it. The protocol documents the false branch as "is
    /// already realized by having been recorded, since the spawn path rebuilds
    /// a VM's disk set from the recorded volumes" — and this driver does not
    /// rebuild anything. `createVM` writes the domain document once and never
    /// runs again for a domain that exists, so an attachment that is only
    /// recorded is realized on no boot, ever.
    ///
    /// Answering true routes every attach to `attachDisk` below, which refuses
    /// loudly and degrades the volume until STR-134. That is worse to look at
    /// and strictly better to have: the alternative converges the volume, shows
    /// it attached in the UI, and leaves the guest without it forever.
    func hasLiveSession(vmId: String) async -> Bool {
        (try? await domain(vmId)) != nil
    }

    // MARK: - Deferred to STR-134

    /// - Note: this refuses for a *stopped* VM too, which the QEMU driver would
    ///   have satisfied by recording. See `hasLiveSession`: recording alone is
    ///   not realization here, so refusing is the only answer that does not
    ///   quietly lose the disk.
    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool)
        async throws
    {
        throw HypervisorServiceError.notSupported(
            "the libvirt driver cannot attach a volume to an existing VM yet (STR-134): VM \(vmId)'s domain "
                + "document is written once at create, so volume \(volumeId) has to be part of the VM's spec "
                + "when it is created")
    }

    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        throw HypervisorServiceError.notSupported(
            "the libvirt driver cannot detach a volume from an existing VM yet (STR-134): VM \(vmId)'s domain "
                + "document is written once at create, so volume \(volumeId) cannot be removed from it")
    }

    // MARK: - Helpers

    /// How long a guest gets to power itself off before the domain is
    /// destroyed. Matches the budget `QEMUService.shutdownVM` gives its own
    /// poll-then-force path.
    private static let gracefulShutdownSeconds = 60

    /// Stands in for a VM id in the log metadata of the two calls that are
    /// about the host rather than one VM.
    private static let hostScope = "(host)"

    /// How stale a cached inventory answer may get before the log stops calling
    /// it a hiccup. Several heartbeat intervals: one failed sweep is noise, but
    /// a host that has not answered in minutes is advertising fiction.
    private static let staleInventoryThreshold: Duration = .seconds(300)

    private var accelerator: DomainAccelerator {
        guard hardwareAccelerationEnabled else { return .tcg }
        #if os(Linux)
        return .kvm
        #else
        return .hvf
        #endif
    }

    /// Destroys the domain, treating an already-inactive one as success.
    ///
    /// Both callers reach here as an *escalation* — a guest that ignored its
    /// whole shutdown budget, or a delete tearing the VM down for good — so the
    /// flags must be the ones that can force. See `LibvirtDomain.destroyFlags`
    /// for why that is `DEFAULT` and emphatically not `GRACEFUL`.
    private func destroy(_ dom: Domain, vmId: String) async throws {
        do {
            try await call("libvirt-destroy", vmId: vmId) { client, deadline in
                try await client.domainDestroyFlags(
                    dom: dom, flags: LibvirtDomain.destroyFlags, deadline: deadline)
            }
        } catch let error where LibvirtFailure.isOperationInvalid(error) {
            guard try await satisfied(dom, vmId: vmId, by: { !LibvirtDomain.holdsResources(rawState: $0) })
            else { throw error }
        }
    }

    /// Polls until the domain is inactive, returning whether it got there
    /// within `seconds`. A read that fails is not an answer, so it ends the
    /// wait and lets the caller escalate.
    private func waitForInactive(_ dom: Domain, vmId: String, seconds: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            guard let raw = try? await state(of: dom, vmId: vmId) else { return false }
            if !LibvirtDomain.holdsResources(rawState: raw) { return true }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return false
            }
        }
        return false
    }

    private func existingPath(_ path: String) -> String? {
        FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Removes socket files a previous, unclean QEMU left behind. QEMU cannot
    /// bind over one, and the paths are ours (the document names them), so
    /// nothing else unlinks them.
    private func clearStaleSockets(vmId: String) {
        let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
        for path in [
            VMDirectoryLayout.serialSocket(vmDirectory: vmDirectory),
            VMDirectoryLayout.consoleSocket(vmDirectory: vmDirectory),
            VMDirectoryLayout.guestAgentSocket(vmDirectory: vmDirectory),
            QEMUGraphicsDevice.socketPath(vmDirectory: vmDirectory),
        ] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func makeVMDirectory(_ path: String, vmId: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw HypervisorServiceError.diskError(
                "failed to create VM directory \(path) for VM \(vmId): \(error.localizedDescription)")
        }
    }

    /// The firmware set to name explicitly, or **nil to let libvirt choose**.
    ///
    /// Nil is the normal case and the whole reason the host preflight checks
    /// `/usr/share/qemu/firmware`: `<os firmware='efi'>` plus the Secure Boot
    /// feature flags lets libvirt rank its installed descriptors and pick a
    /// matching CODE/VARS pair, seeding the varstore itself. `FirmwareResolver`
    /// is consulted only when the operator named paths or the spec carries a
    /// per-VM firmware, because it falls back to *its own* platform candidate
    /// list — which would quietly take the choice away from libvirt on every
    /// VM.
    private func resolveFirmware(spec: VMSpec, machine: MachineProfile) throws -> FirmwareSet? {
        guard case .disk(let perVMPath) = spec.boot else { return nil }
        guard firmware.hasExplicitPaths || perVMPath != nil else { return nil }
        do {
            return try FirmwareResolver.resolve(
                secureBoot: machine.secureBoot, perVMPath: perVMPath, overrides: firmware)
        } catch {
            throw HypervisorServiceError.invalidConfiguration(
                "firmware for VM could not be resolved: \(error)")
        }
    }

    /// The VM's disks, in the order the domain document will present them.
    ///
    /// The boot disk is materialized from the cached image when the sync
    /// carried one; otherwise the spec's volume references (with agent-reported
    /// paths) are used. Either way every volume the agent has recorded as
    /// attached is realized, deduped against the boot disk in case the boot
    /// volume is also listed.
    private func resolveDisks(vmId: String, spec: VMSpec, imageInfo: ImageInfo?) async throws -> [ResolvedDisk] {
        var disks: [ResolvedDisk] = []

        if let imageInfo, let storage {
            logger.info(
                "Materializing boot disk from image",
                metadata: ["vmId": .string(vmId), "imageId": .string(imageInfo.imageId.uuidString)])
            do {
                // Its own generous budget: multi-GB downloads are legitimate
                // and must not be squeezed into the define envelope.
                // `.cancelAndWait` because materialization writes through a
                // deterministic staging path and clears any partial it finds,
                // so abandoning a slow attempt would let a retry delete its
                // output mid-write and publish a truncated disk.
                let attachment = try await StageBudget.run(
                    seconds: StageBudget.imageMaterializationSeconds,
                    stage: "image materialization", onTimeout: .cancelAndWait
                ) { [vmStoragePath] in
                    try await storage.materializeDisk(
                        at: "\(vmStoragePath)/\(vmId)/disk.qcow2", from: imageInfo, format: .qcow2,
                        artifactKind: .diskImage)
                }
                // Flagged as a boot disk, which it is by construction — the
                // image is what this VM boots from. Not cosmetic: `<boot order>`
                // is emitted for every disk that carries the flag, so leaving
                // this one unflagged would let a *data* volume the operator
                // happened to attach with a `bootOrder` become the domain's only
                // boot entry, and the guest would boot the wrong disk. The value
                // itself is only a flag; `DomainXMLBuilder.derivedBootOrders`
                // numbers positionally, and this disk is first.
                disks.append(
                    ResolvedDisk(path: attachment.path, format: attachment.format, bootOrder: 0))
            } catch {
                logger.error(
                    "Failed to materialize boot disk from image, falling back to spec volumes",
                    metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
            }
        }

        var seen = Set(disks.map(\.path))
        for volume in spec.volumes {
            guard let path = volume.storagePath, seen.insert(path).inserted else { continue }
            // Checked here rather than left to libvirt: a define accepts a
            // source file that does not exist and only the *start* fails, so
            // without this a create reports success and the boot that follows
            // fails with an error naming a path but not the volume behind it.
            guard FileManager.default.fileExists(atPath: path) else {
                throw HypervisorServiceError.diskError(
                    "volume \(volume.volumeId?.uuidString ?? volume.deviceName.rawValue) for VM \(vmId) has no "
                        + "file at "
                        + "\(path) on this host")
            }
            disks.append(
                ResolvedDisk(
                    path: path, format: DiskFormat(volumePath: path), readonly: volume.readonly,
                    bootOrder: volume.bootOrder))
        }

        // A disk-boot VM with no disks can only produce an unbootable shell —
        // the image download failed (or the sync carried no usable imageInfo)
        // and the spec had no volume references to fall back on. Fail the create
        // with the real problem instead of "converging" to a diskless VM.
        if disks.isEmpty, case .disk = spec.boot {
            throw HypervisorServiceError.diskError(
                "no disks resolved for disk-boot VM \(vmId): image materialization failed or the spec carried "
                    + "no volumes")
        }
        return disks
    }
}
