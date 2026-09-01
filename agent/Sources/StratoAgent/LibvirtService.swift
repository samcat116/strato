import Foundation
import Libvirt
import Logging
import NIOCore
import StratoAgentCore
import StratoShared

enum DomainNetworkDetachConvergence {
    static func run(
        observe: () async throws -> DomainNetworkDetachPlan,
        detach: (DomainNetworkDetachScope) async throws -> Void
    ) async throws -> Bool {
        var didDetach = false
        // A restart can repopulate live XML from config between steps, so a
        // plan is valid for one detach only.
        while let scope = try await observe().scopes.first {
            didDetach = true
            try await detach(scope)
        }
        return didDetach
    }
}

/// The QEMU backend, driven through **libvirtd** (issue #902).
///
/// The only driver `HypervisorType.qemu` has: the agent used to spawn
/// `qemu-system-*` itself and drive it over QMP, and that driver — along with
/// the QMP sockets, the guest-agent transport and the swtpm supervision that
/// existed only to serve it — was deleted in STR-136.
///
/// ## Why this is so much smaller than the driver it replaced
///
/// A process driver's `activeVMs`, `vmSpecs`, `vmConfigs`, spawn sizing,
/// awaiting-first-start flags, console socket maps, pending sets and respawn
/// path are all bookkeeping for an *ephemeral process*: the agent spawned it,
/// so only the agent knows what it spawned, and anything it forgets is
/// unrecoverable. libvirtd is a durable store. Domains survive the agent, so
/// this driver **queries** rather than mirrors, and:
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
/// - re-adoption is `connectListAllDomains` plus a state read: libvirtd owns the
///   monitor and survives the agent, so orphan re-adoption is a query rather
///   than a mechanism.
/// - libvirt owns swtpm, so the agent supervises none of it, and whether a
///   vTPM is possible at all is libvirt's answer to give
///   (`virsh domcapabilities`, via `DomainCapabilities`) rather than a binary
///   the agent looks for. The UEFI varstore is the one artifact that came
///   back: libvirt will seed one but not convert it, and Strato's has to be
///   qcow2 for checkpoints, so `createVM` writes it before defining the domain
///   (STR-188).
///
/// The two caches below (`lastKnownVMIds`, `lastKnownReservationInventory`) are the only
/// retained state, they hold *the last answer libvirtd gave* rather than a model
/// of it, and neither is keyed by VM id. Treat any new dictionary keyed by VM id
/// as a smell worth justifying in review.
///
/// ## The domain document is authoritative, so every change is written to it
///
/// `createVM` defines a domain, and the *next boot reads that definition* rather
/// than the spec. That single fact shapes hot-plug, resize and everything else
/// that mutates a VM in place (STR-134): every such change is sent with
/// `LibvirtDomain.affectLiveAndConfig`, so it lands on the running guest *and*
/// in the persistent definition. The deleted process-QEMU driver could leave
/// its definition alone because it respawned a VM from a stored configuration
/// the agent kept in step; that is not true here — the next boot reads
/// libvirt's definition — so a live-only change is a change that silently
/// un-happens at the guest's next power cycle.
///
/// It used to follow from that that **the hot-plug slots and size ceilings a VM
/// will ever have are fixed when it is created** — the document reserves
/// `DomainXMLBuilder.spareHotplugPorts` empty PCIe root ports, numbered past
/// every port the domain's own devices will occupy (STR-192), plus whatever
/// virtio-mem region and `<vcpu>` maximum the spec asked for, and nothing ever
/// rewrote any of it. That was a real capability difference from the process
/// driver, which re-spawned from the current spec and so widened all three on
/// any restart.
///
/// `redefineVM` is where that difference goes (STR-187). It is the **one** other
/// place the document is written, it runs on a stopped domain only, and it
/// widens exactly those three ceilings — leaving every other element of the
/// document as libvirt wrote it. So the remedy for all of them is now "stop and
/// start the VM", which is what `attachDisk` and `resizeMemory` say when they
/// hit one.
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
actor LibvirtService: HypervisorService {
    private let logger: Logger
    private let storage: (any StorageBackend)?
    private let vmStoragePath: String
    /// The daemon this host manages VMs through.
    private let uri: String
    /// Operator-configured EDK2 firmware paths (issue #565). Empty is the
    /// normal case and falls through to this platform's candidate pairs — see
    /// `resolveFirmware`.
    private let firmware: FirmwareOverrides
    /// Seeds each VM's UEFI variable store before its domain is defined, in the
    /// qcow2 form checkpoints require. libvirt would do this from an
    /// `<nvram template=…>` but cannot change the template's format on the way,
    /// which is what makes it the agent's job (STR-188).
    private let varstore: UEFIVarstore
    /// Whether libvirt on this host can back a guest vTPM. libvirt runs swtpm
    /// itself, but a host whose daemon reports no emulator backend never
    /// advertises the TPM capability, so a spec asking for one here means the
    /// placement gate was bypassed and the create must fail loudly.
    ///
    /// Set from the registration path, which is where the answer arrives
    /// (`LibvirtProbe.probeTPM` via the host preflight), and re-set on every
    /// reconnect. **Nil until then, and nil is refused** — the ordering that
    /// makes a placement impossible before the first registration is a temporal
    /// invariant spanning two files with nothing enforcing it, and the entire
    /// point of this flag is to be the check that holds when something else
    /// did not. A permissive default would make it the check that holds only
    /// when nothing went wrong.
    private var tpmSupported: Bool?
    /// KVM on Linux, HVF on macOS; when false, domains run under TCG.
    private let hardwareAccelerationEnabled: Bool
    private let memoryOverheadBytes: Int64
    private let memoryControllerAvailable: Bool

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
    /// Both exist because for host inventory the empty answer is actively
    /// harmful rather than merely uninformative. An empty VM list claims every
    /// VM on this host is gone, which is how an inventory consumer will read it,
    /// and zero reservations advertise capacity the host does not have and
    /// invite the scheduler to over-place it. The reservation caller's manifest
    /// fallback previously covered only a query that *timed out*, so a libvirtd
    /// error has to remain explicit too. `listVMs()` preserves the same
    /// unknown-versus-empty distinction at the driver boundary even though the
    /// current heartbeat no longer carries that inventory. What neither cache
    /// can cover — the sweep that has never once succeeded — is why both methods
    /// return optionals (STR-196). The never-answered and staleness decisions
    /// belong to `LastKnownInventory`, in a package tests can import, because
    /// this target has none.
    private var lastKnownVMIds = LastKnownInventory<[String]>(
        staleThreshold: LibvirtService.staleInventoryThreshold)
    private var lastKnownReservationInventory = LastKnownInventory<HypervisorReservationInventory>(
        staleThreshold: LibvirtService.staleInventoryThreshold)

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

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil,
        vmStoragePath: String,
        uri: String = LibvirtProbe.systemURI,
        firmware: FirmwareOverrides = FirmwareOverrides(),
        hardwareAccelerationEnabled: Bool = true,
        memoryOverheadBytes: Int64 = Int64(AgentConfig.defaultQEMUMemoryOverheadMB) * 1024 * 1024,
        memoryControllerAvailable: Bool = HostMemoryController.isAvailable(),
        varstore: UEFIVarstore? = nil
    ) {
        self.logger = logger
        self.storage = storage
        self.vmStoragePath = vmStoragePath
        self.uri = uri
        self.firmware = firmware
        self.varstore = varstore ?? UEFIVarstore(logger: logger)
        self.hardwareAccelerationEnabled = hardwareAccelerationEnabled
        self.memoryOverheadBytes = max(0, memoryOverheadBytes)
        self.memoryControllerAvailable = memoryControllerAvailable
        (self.lifecycleStream, self.lifecycleContinuation) = AsyncStream.makeStream(
            of: VMLifecycleChange.self, bufferingPolicy: .bufferingNewest(64))
        logger.info("libvirt hypervisor service initialized", metadata: ["uri": .string(uri)])
        if !memoryControllerAvailable {
            logger.warning(
                "cgroup v2 memory controller is unavailable; QEMU process memory ceilings are disabled on this host")
        }
    }

    /// Records what libvirt said about backing a guest vTPM. Called from the
    /// registration path, which probes the daemon on the same cadence as every
    /// other host capability, so a host that gains swtpm starts accepting vTPM
    /// VMs on the next reconnect rather than after an agent restart. Until the
    /// first call, `createVM` refuses a vTPM spec rather than assuming one way
    /// or the other.
    func setTPMSupported(_ supported: Bool) {
        tpmSupported = supported
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
    /// `.cancelAndWait`: these are commands, and abandoning one lets it land after the
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
                metadata: ["strato.vm.id": .string(vmId), "stage": .string(stage)])
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
    /// next full desired-state payload, which is the case this feature exists for.
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
                "libvirt lifecycle subscription failed; VM state will fall back to full desired-state refetches",
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
            "libvirtd is not delivering lifecycle events; observed VM state on this host is only as fresh as full desired-state refetches",
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
        metadata: InstanceMetadata? = nil,
        vsockCID: UInt32? = nil
    ) async throws {
        try await perform("create", vmId: vmId) {
            logger.info("Creating libvirt domain", metadata: ["strato.vm.id": .string(vmId)])

            let machine = spec.effectiveMachine
            // The agent never advertises the TPM capability where libvirt
            // reports no emulator backend, so reaching here means the placement
            // gate was bypassed. libvirt would fail the domain start with a
            // message about the backend; these name the actual remedy.
            if machine.tpm {
                switch tpmSupported {
                case true:
                    break
                case false:
                    throw HypervisorServiceError.invalidConfiguration(
                        "VM \(vmId) requires a TPM 2.0 but libvirt at \(uri) reports no emulated TPM backend. "
                            + "libvirt starts and supervises swtpm per domain, so install it (Debian/Ubuntu: "
                            + "`apt install swtpm swtpm-tools`) and restart libvirtd, which caches its "
                            + "capabilities.")
                case nil:
                    throw HypervisorServiceError.invalidConfiguration(
                        "VM \(vmId) requires a TPM 2.0, but this host has not finished registering and does "
                            + "not yet know whether libvirt at \(uri) can back one. Retrying is safe: the "
                            + "answer arrives with the next registration.")
                }
            }

            let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
            let disks = try await resolveDisks(vmId: vmId, spec: spec, imageInfo: imageInfo)
            try makeVMDirectory(vmDirectory, vmId: vmId)

            // Before the document is built, not merely before it is defined:
            // what the builder emits for a resolved pair is an nvram element
            // with no `template`, which is a promise that this file is already
            // there (STR-188).
            let firmwareSet = resolveFirmware(spec: spec, machine: machine)
            try await materializeVarstore(firmwareSet, vmId: vmId, vmDirectory: vmDirectory)

            // Guest provisioning. The seed ISO must carry the control plane's
            // hostname, because the same value is what the VM's DNS zone is
            // assembled from (STR-177).
            var cloudInitISOPath: String?
            let isoPath = VMDirectoryLayout.cloudInitISO(vmDirectory: vmDirectory)
            if await CloudInitProvisioner(logger: logger).makeNoCloudISO(
                at: isoPath, vmId: vmId, hostname: metadata?.hostname,
                sshAuthorizedKeys: spec.sshAuthorizedKeys, userData: spec.userData,
                metadataSource: spec.metadataSource,
                noCloudSeedToken: metadata?.noCloudSeedToken,
                networkAttachments: networkAttachments)
            {
                cloudInitISOPath = isoPath
            }

            let input = DomainXMLInput(
                vmId: vmId,
                vmDirectory: vmDirectory,
                spec: spec,
                disks: disks,
                cloudInitISOPath: cloudInitISOPath,
                networks: networkAttachments,
                architecture: .current,
                accelerator: accelerator,
                firmware: firmwareSet,
                vsockCID: vsockCID,
                memoryHardLimitBytes: memoryControllerAvailable
                    ? QEMUMemoryCeiling.bytes(
                        guestMemoryBytes: spec.memoryBytes, overheadBytes: memoryOverheadBytes)
                    : nil)
            let xml = try DomainXMLBuilder.build(input)

            // A VM with enough devices of its own to reach the root-port ceiling
            // gets fewer spare ports than the builder would like to give it, and
            // possibly none. `redefineVM` tops the spares up before every boot,
            // but it cannot lift the ceiling this VM has already reached — so
            // this shortfall really is for that VM's whole life, and this is the
            // one moment it can be said out loud. Left unsaid, its only other
            // symptom is the bare "No more available PCI slots" on some later
            // attach, which is indistinguishable from the bug STR-192 fixed.
            let spares = DomainXMLBuilder.reservedHotplugPortCount(input)
            if spares < DomainXMLBuilder.spareHotplugPorts {
                logger.warning(
                    "VM has fewer spare PCIe root ports than usual, and a boot cannot win them back",
                    metadata: [
                        "strato.vm.id": .string(vmId),
                        "sparePorts": .stringConvertible(spares),
                        "usualSparePorts": .stringConvertible(DomainXMLBuilder.spareHotplugPorts),
                        "detail": .string(
                            "this VM declares enough PCI devices (\(disks.count) disks, "
                                + "\(networkAttachments.count) NICs) to crowd the root complex, so it can accept "
                                + "at most \(spares) hot-plugged device(s) at a time; attach further "
                                + "volumes with the VM stopped"),
                    ])
            }

            // Not `domainCreateXML`: that defines *and starts* a transient
            // domain, which would boot every fresh VM once (the next periodic
            // sync then shuts it down again) and leave nothing behind for an
            // agent restart to adopt.
            _ = try await call("libvirt-define", vmId: vmId, seconds: StageBudget.hypervisorSpawnSeconds) {
                client, deadline in
                try await client.domainDefineXML(xml: xml, deadline: deadline)
            }

            logger.info("libvirt domain defined", metadata: ["strato.vm.id": .string(vmId)])
        }
    }

    /// Rewrites a stopped domain's definition so it can satisfy `spec`
    /// (STR-187) — see `DomainRedefinition` for what that means and, more to the
    /// point, for what it deliberately leaves alone.
    ///
    /// This is the one place the domain document is written a second time, and
    /// the two conditions guarding it are why that is safe. It runs **only on an
    /// inactive domain**, because the ports it counts are the ones libvirt's own
    /// address allocator assigned and a running domain's document describes a
    /// guest that is already holding them; and it defines **only a document that
    /// differs**, so the ordinary boot of an unchanged VM costs one `dumpxml` and
    /// nothing else.
    ///
    /// A domain that has gone missing or come up between the state read and the
    /// define is not a failure to report: nothing has been changed, the boot that
    /// follows will reach the same daemon, and its error is the one worth
    /// surfacing. The caller treats everything here as best effort for the same
    /// reason — a VM that boots at the ceiling it already had is the status quo,
    /// while a VM that does not boot is a regression.
    func redefineVM(vmId: String, spec: VMSpec) async throws {
        try await perform("redefine", vmId: vmId) {
            let dom = try await domain(vmId)
            guard !LibvirtDomain.holdsResources(rawState: try await state(of: dom, vmId: vmId)) else {
                return
            }

            let widening = try DomainRedefinition.widening(
                forInactiveDomainXML: try await inactiveDomainXML(dom, vmId: vmId),
                spec: spec, architecture: .current)
            for refusal in widening.refusals {
                logger.warning(
                    "This VM's definition could not be widened to what its spec asks for",
                    metadata: ["strato.vm.id": .string(vmId), "detail": .string(refusal)])
            }
            guard let xml = widening.xml else { return }

            logger.info(
                "Widening the domain definition before boot",
                metadata: [
                    "strato.vm.id": .string(vmId),
                    "addedHotplugPorts": .stringConvertible(widening.addedHotplugPorts),
                    "memoryCeilingBytes": widening.memoryCeilingBytes.map {
                        .stringConvertible($0)
                    } ?? .string("unchanged"),
                    "vcpuCeiling": widening.vcpuCeiling.map {
                        .stringConvertible($0)
                    } ?? .string("unchanged"),
                ])
            _ = try await call("libvirt-redefine", vmId: vmId, seconds: StageBudget.hypervisorSpawnSeconds) {
                client, deadline in
                try await client.domainDefineXML(xml: xml, deadline: deadline)
            }
        }
    }

    /// Migrates the persistent bootstrap state of IMDS VMs created by an older
    /// agent. The seed is rebuilt from current desired state so its local
    /// network document no longer tries to rename an already-active interface,
    /// and the inactive domain gains the SMBIOS hint that selects NoCloudNet.
    ///
    /// This is required boot convergence, not part of the best-effort resource
    /// widening above. A failed migration must keep the VM stopped: otherwise a
    /// successful QEMU start could conceal a cloud-init datasource failure.
    func convergeGuestBootstrap(
        vmId: String, spec: VMSpec,
        networkAttachments: [ResolvedNetworkAttachment], metadata: InstanceMetadata?
    ) async throws {
        guard spec.metadataSource == .imds else { return }

        try await perform("guest-bootstrap", vmId: vmId) {
            guard let token = metadata?.noCloudSeedToken else {
                throw HypervisorServiceError.invalidConfiguration(
                    "IMDS VM \(vmId) has no NoCloud seed capability in desired metadata")
            }

            let dom = try await domain(vmId)
            guard !LibvirtDomain.holdsResources(rawState: try await state(of: dom, vmId: vmId)) else {
                return
            }

            let repairedXML = try DomainRedefinition.addingIMDSBootstrapHint(
                toInactiveDomainXML: try await inactiveDomainXML(dom, vmId: vmId),
                metadataSource: spec.metadataSource,
                architecture: .current)

            let vmDirectory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
            let isoPath = VMDirectoryLayout.cloudInitISO(vmDirectory: vmDirectory)
            let refreshed = await CloudInitProvisioner(logger: logger).makeNoCloudISO(
                at: isoPath, vmId: vmId, hostname: metadata?.hostname,
                sshAuthorizedKeys: spec.sshAuthorizedKeys, userData: spec.userData,
                metadataSource: spec.metadataSource, noCloudSeedToken: token,
                networkAttachments: networkAttachments)
            guard refreshed else {
                throw HypervisorServiceError.diskError(
                    "could not refresh the IMDS bootstrap seed for VM \(vmId)")
            }

            guard let repairedXML else { return }
            logger.info(
                "Adding the IMDS NoCloud datasource hint before boot",
                metadata: ["strato.vm.id": .string(vmId)])
            _ = try await call(
                "libvirt-redefine", vmId: vmId, seconds: StageBudget.hypervisorSpawnSeconds
            ) { client, deadline in
                try await client.domainDefineXML(xml: repairedXML, deadline: deadline)
            }
        }
    }

    /// Required boot-time convergence, separate from best-effort widening.
    /// The inactive definition is the source the next QEMU process reads.
    func ensureMemoryCeiling(vmId: String, spec: VMSpec) async throws {
        do {
            try await perform("memory-ceiling", vmId: vmId) {
                let dom = try await domain(vmId)
                let desired =
                    memoryControllerAvailable
                    ? QEMUMemoryCeiling.bytes(
                        guestMemoryBytes: spec.memoryBytes, overheadBytes: memoryOverheadBytes)
                    : nil
                guard
                    let xml = try DomainMemoryTuning.updatingHardLimit(
                        in: try await inactiveDomainXML(dom, vmId: vmId), bytes: desired)
                else { return }
                _ = try await call(
                    "libvirt-memory-ceiling-define", vmId: vmId,
                    seconds: StageBudget.hypervisorSpawnSeconds
                ) { client, deadline in
                    try await client.domainDefineXML(xml: xml, deadline: deadline)
                }
            }
        } catch  where !memoryControllerAvailable {
            // Graceful degradation is deliberate on unsupported hosts. A stale
            // hard limit may remain in the definition, but this host cannot
            // enforce one and the boot must not be held behind its removal.
            logger.warning(
                "Could not remove a stale QEMU memory ceiling on a host without cgroup memory support",
                metadata: ["strato.vm.id": .string(vmId), "error": .string(error.localizedDescription)])
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
                    metadata: ["strato.vm.id": .string(vmId)])
                return
            }

            // QEMU cannot bind a chardev over a socket file a previous,
            // SIGKILLed process left behind, and libvirt does not unlink them
            // for us — the paths are ours, named in the document. Only ever
            // reached with the domain inactive, so no live console is cut.
            clearStaleSockets(vmId: vmId)

            logger.info("Starting libvirt domain", metadata: ["strato.vm.id": .string(vmId)])
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
            logger.info("libvirt domain started", metadata: ["strato.vm.id": .string(vmId)])
        }
    }

    /// Asks the guest to power off, escalating to a destroy if it does not.
    ///
    /// The escalation is not optional: `shutdownFlags` is a *request* the guest
    /// is free to ignore, and without a bound a VM whose guest has no ACPI
    /// handler never converges on its `shutdown` desired state. This is the
    /// same 60s envelope the agent has always given a guest to power itself off
    /// before termination is forced.
    func shutdownVM(vmId: String) async throws {
        try await perform("shutdown", vmId: vmId) {
            let dom = try await domain(vmId)
            guard LibvirtDomain.holdsResources(rawState: try await state(of: dom, vmId: vmId)) else {
                logger.info(
                    "libvirt domain is already inactive; treating shutdown as a no-op",
                    metadata: ["strato.vm.id": .string(vmId)])
                return
            }

            logger.info("Shutting down libvirt domain", metadata: ["strato.vm.id": .string(vmId)])
            do {
                try await call("libvirt-shutdown", vmId: vmId) { client, deadline in
                    // `SHUTDOWN_DEFAULT`, so libvirt tries the guest agent
                    // before the ACPI power button: a verified shutdown,
                    // without the agent having to speak qga itself.
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
                    "strato.vm.id": .string(vmId),
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
            logger.info("Rebooting libvirt domain", metadata: ["strato.vm.id": .string(vmId)])
            do {
                try await call("libvirt-reboot", vmId: vmId) { client, deadline in
                    try await client.domainReboot(dom: dom, flags: 0, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isOperationInvalid(error) {
                guard try await satisfied(dom, vmId: vmId, by: { !LibvirtDomain.holdsResources(rawState: $0) })
                else { throw error }
                logger.info(
                    "libvirt domain is already down; the reboot is superseded by the boot that follows",
                    metadata: ["strato.vm.id": .string(vmId)])
            }
        }
    }

    func pauseVM(vmId: String) async throws {
        try await perform("pause", vmId: vmId) {
            let dom = try await domain(vmId)
            logger.info("Pausing libvirt domain", metadata: ["strato.vm.id": .string(vmId)])
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
            logger.info("Resuming libvirt domain", metadata: ["strato.vm.id": .string(vmId)])
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
            logger.info("Deleting libvirt domain", metadata: ["strato.vm.id": .string(vmId)])
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
                    metadata: ["strato.vm.id": .string(vmId)])
            }

            // Safe now: either the domain is gone or the calls above threw, so
            // nothing can still be running from the disk this unlinks.
            await reclaimVMDirectory(vmId: vmId)
            logger.info("libvirt domain deleted", metadata: ["strato.vm.id": .string(vmId)])
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
                    metadata: ["strato.vm.id": .string(vmId)])
                return
            }
        } catch let error where LibvirtFailure.isDomainMissing(error) {
            // No domain at all — nothing is running from these files.
        } catch {
            logger.error(
                "Could not confirm the domain is inactive; leaving its files for manual cleanup",
                metadata: ["strato.vm.id": .string(vmId), "error": .string(error.localizedDescription)])
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
            logger.warning(
                "libvirt status query timed out; reporting unknown", metadata: ["strato.vm.id": .string(vmId)])
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
            if memoryControllerAvailable, (status == .running || status == .paused) {
                let layout = try DomainMemoryInventory.memoryLayout(
                    inDomainXML: try await domainXML(dom, vmId: vmId))
                let granted = layout.bootBytes + (layout.virtioMem?.requestedBytes ?? 0)
                try await setMemoryCeiling(
                    dom, vmId: vmId, guestMemoryBytes: granted,
                    flags: LibvirtDomain.affectLiveAndConfig)
            }
            logger.info(
                "Adopted libvirt domain",
                metadata: ["strato.vm.id": .string(vmId), "status": .string(status.rawValue)])
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

    /// Every Strato domain libvirtd knows about, running or not — or nil if the
    /// daemon could not be read and this driver has never had an answer to
    /// serve.
    ///
    /// Includes stopped domains deliberately: a defined-but-off VM holds its
    /// disks and its placement, and omitting it from an inventory says it is
    /// gone. For exactly that reason the failure path never manufactures `[]`,
    /// which says the same thing about every domain at once.
    func listVMs() async -> [String]? {
        do {
            let ids = try await call(
                "libvirt-list", vmId: Self.hostScope, seconds: StageBudget.statusQuerySeconds
            ) {
                client, deadline in
                try await client.connectListAllDomains(
                    needResults: 1, flags: LibvirtDomain.listAllDomains, deadline: deadline
                ).domains.map(\.name)
            }.filter(LibvirtDomain.isStratoDomainName)
            lastKnownVMIds.record(ids)
            return ids
        } catch {
            return stale(lastKnownVMIds, "the VM list", error)
        }
    }

    /// vCPUs and memory committed to the domains on this host — or nil if the
    /// daemon could not be read and this driver has never had an answer to
    /// serve.
    ///
    /// Nil rather than `(0, 0)` because the two are indistinguishable once they
    /// reach the scheduler, and STR-190 is what that cost: a decoder broken from
    /// the first sweep synthesized a zero here, the agent's manifest fallback
    /// never fired, and the node advertised its full capacity while running VMs.
    ///
    /// A query, not mirrored state — which is the point. `maxMem` is used
    /// rather than the live `memory` figure for two reasons: `memory` is the
    /// *current balloon setting*, so an inflated balloon would make a VM look
    /// like it had handed its grant back to the host when it has not; and where
    /// a spec asks for hot-plug headroom, the domain can grow into that
    /// headroom at any moment, so reserving it is the correct answer rather
    /// than a conservative one. For the overwhelmingly common VM with no
    /// headroom the two are the same number.
    func reservationInventory() async -> HypervisorReservationInventory? {
        do {
            // One `call`, not one per domain: the whole sweep shares a budget so
            // a host with many VMs cannot spend N budgets inside one heartbeat.
            let inventory = try await call(
                "libvirt-reservations", vmId: Self.hostScope, seconds: StageBudget.statusQuerySeconds
            ) { client, deadline in
                let domains = try await client.connectListAllDomains(
                    needResults: 1, flags: LibvirtDomain.listAllDomains, deadline: deadline
                ).domains.filter { LibvirtDomain.isStratoDomainName($0.name) }

                // Concurrently, not in sequence: the reads are independent and
                // already share one absolute deadline, so serializing them turns
                // a host's domain count into `N x RTT` inside a budget sized for
                // a single query — on a busy host, reliably unfinishable.
                let workloads = try await withThrowingTaskGroup(
                    of: (String, HostReservation).self
                ) { group in
                    for dom in domains {
                        group.addTask {
                            let info = try await client.domainGetInfo(dom: dom, deadline: deadline)
                            let reservation = LibvirtDomain.reservation(from: info)
                            return (
                                dom.name,
                                HostReservation(
                                    cpus: reservation.vcpus,
                                    memoryBytes: reservation.memoryBytes)
                            )
                        }
                    }
                    var reservations: [String: HostReservation] = [:]
                    reservations.reserveCapacity(domains.count)
                    for try await (name, reservation) in group {
                        reservations[name] = reservation
                    }
                    return reservations
                }
                let reservation = workloads.values.reduce(HostReservation()) { total, workload in
                    total.addingSaturating(workload)
                }
                return HypervisorReservationInventory(
                    reservation: reservation,
                    workloadReservations: workloads)
            }
            lastKnownReservationInventory.record(inventory)
            return inventory
        } catch {
            return stale(lastKnownReservationInventory, "host reservation inventory", error)
        }
    }

    func reservedResources() async -> (vcpus: Int, memoryBytes: Int64)? {
        guard let inventory = await reservationInventory() else { return nil }
        return (inventory.reservation.cpus, inventory.reservation.memoryBytes)
    }

    /// Serves a cached inventory answer after a live query failed, escalating
    /// the log as it ages.
    ///
    /// Serving the last answer beats serving an empty one — an empty VM list
    /// claims every VM here is gone, which is how an inventory consumer will
    /// read it, and zero reservations invite the scheduler to over-place the
    /// host. What deserved a bound is the *indefiniteness*: without one, "these
    /// are this second's figures" and "these are from an hour ago" differ only
    /// by a log line nobody reads, while the host goes on looking healthy. Past
    /// the threshold this says so at error level on every heartbeat.
    ///
    /// For reservations, the nil this returns when the driver has never answered
    /// travels to the agent, which substitutes its durable manifest (STR-196).
    /// For a VM-list caller it remains an explicit unknown. What it must never
    /// become is `[]` or `(0, 0)` here: those are claims about the host, and a
    /// sweep that has never once succeeded has no standing to make one.
    private func stale<T: Sendable>(
        _ inventory: LastKnownInventory<T>, _ what: String, _ error: any Error
    ) -> T? {
        switch inventory.fallback() {
        case .neverAnswered:
            logger.error(
                "Could not read \(what) from libvirt, and have never had an answer to fall back on",
                metadata: ["error": .string(error.localizedDescription)])
            return nil
        case .lastKnown(let value, let age, let badlyStale):
            let metadata: Logger.Metadata = [
                "error": .string(error.localizedDescription),
                "ageSeconds": .stringConvertible(age.components.seconds),
            ]
            if badlyStale {
                logger.error(
                    """
                    Still reporting \(what) from a libvirt answer that is now badly out of date; \
                    this host's advertised capacity and VM list cannot be trusted
                    """,
                    metadata: metadata)
            } else {
                logger.warning(
                    "Could not read \(what) from libvirt; reporting the last known answer", metadata: metadata)
            }
            return value
        }
    }

    // MARK: - Guest observation

    /// The guest agent's view — hostname and configured interfaces (issue #563)
    /// — asked of libvirtd rather than of the VM's `qga.sock` directly.
    ///
    /// Same source, same channel: libvirt talks to the guest agent over the
    /// `org.qemu.guest_agent.0` device the domain document binds, so what
    /// reaches the control plane does not change with the driver. What goes is
    /// the transport — the framing, the `guest-sync-delimited` resync and the
    /// one-client-at-a-time socket a direct qga client has to manage are
    /// libvirtd's problem now, and it multiplexes.
    ///
    /// Nil is the normal "no usable agent" answer — a guest with none
    /// installed, one still booting, a VM this host does not have — and never
    /// an error, since nothing converges on guest info.
    func guestInfo(vmId: String) async -> GuestInfo? {
        guard let dom = try? await domain(vmId) else { return nil }
        // Independent, so one failing does not cost the other: either answering
        // is a positive liveness signal, and `LibvirtGuestInfo.parse` reports
        // whichever came back.
        async let hostnameParams = optionalGuestQuery(vmId: vmId, stage: "libvirt-guest-info") {
            client, deadline in
            try await client.domainGetGuestInfo(
                dom: dom, types: LibvirtDomain.guestInfoHostname, flags: 0, deadline: deadline)
        }
        async let interfaces = optionalGuestQuery(vmId: vmId, stage: "libvirt-interface-addresses") {
            client, deadline in
            try await client.domainInterfaceAddresses(
                dom: dom, source: LibvirtDomain.interfaceAddressesFromAgent, flags: 0,
                deadline: deadline)
        }
        return LibvirtGuestInfo.parse(
            hostnameParams: await hostnameParams, interfaces: await interfaces)
    }

    /// Runs one guest-agent query, turning every failure into nil.
    ///
    /// Bounded by `guestAgentSeconds` like the qga path it replaces, and
    /// deliberately blind to *why* it failed: an unreachable agent, a guest
    /// that has none, and a daemon that answered with an error are all "no
    /// information this poll", and the slow-poll loop has nowhere to put a
    /// distinction between them.
    private func optionalGuestQuery<T: Sendable>(
        vmId: String, stage: String,
        _ operation: @escaping @Sendable (LibvirtClient, NIODeadline) async throws -> T
    ) async -> T? {
        do {
            return try await call(stage, vmId: vmId, seconds: StageBudget.guestAgentSeconds, operation)
        } catch {
            if !LibvirtFailure.isGuestAgentUnavailable(error) {
                logger.debug(
                    "Guest observation query failed",
                    metadata: [
                        "strato.vm.id": .string(vmId), "stage": .string(stage),
                        "error": .string(error.localizedDescription),
                    ])
            }
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
    /// rebuild anything. Its boot reads the domain document, and the only thing
    /// that ever rewrites that is `redefineVM`, which deliberately touches no
    /// device the VM already has (STR-187) — so an attachment that is only
    /// recorded is realized on no boot, ever.
    ///
    /// Answering true routes every attach to `attachDisk`, which writes the
    /// disk into the domain document as well as into the running guest. The
    /// alternative — recording the attachment and waiting for a boot to realize
    /// it — converges the volume, shows it attached in the UI, and leaves the
    /// guest without it forever.
    func hasLiveSession(vmId: String) async -> Bool {
        (try? await domain(vmId)) != nil
    }

    // MARK: - Disk hot-plug

    // MARK: - Network hot-plug

    func attachNetworkInterface(
        vmId: String, spec: NetworkSpec, attachment: ResolvedNetworkAttachment
    ) async throws {
        try await perform("attach-network", vmId: vmId) {
            guard let configuredMAC = spec.macAddress, let mac = MACAddress(configuredMAC) else {
                throw HypervisorServiceError.invalidConfiguration(
                    "VM network hot-plug requires a valid stable unicast MAC address")
            }
            let macAddress = mac.description
            let dom = try await domain(vmId)
            let present = try DomainNetworkInventory.macAddresses(
                inDomainXML: try await domainXML(dom, vmId: vmId))
            guard !present.contains(macAddress) else {
                logger.info(
                    "Network interface is already present; treating the attach as a no-op",
                    metadata: ["strato.vm.id": .string(vmId), "mac": .string(macAddress)])
                return
            }
            let flags = try await deviceFlags(dom, vmId: vmId)
            let xml = try DomainDeviceXML.hotplugNetwork(attachment)
            do {
                try await call("libvirt-attach-network", vmId: vmId) { client, deadline in
                    try await client.domainAttachDeviceFlags(
                        dom: dom, xml: xml, flags: flags, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isPCISlotsExhausted(error) {
                let label = spec.deviceName ?? "network interface"
                throw HypervisorServiceError.invalidConfiguration(
                    "VM \(vmId) has no free PCIe root port to attach \(label). A running domain's ports "
                        + "cannot be added to, so this will not succeed on retry: stop and start the VM, "
                        + "which redefines it with fresh spare ports, or attach the interface while it is stopped.")
            }
        }
    }

    func detachNetworkInterface(vmId: String, spec: NetworkSpec) async throws {
        try await perform("detach-network", vmId: vmId) {
            guard let configuredMAC = spec.macAddress, let mac = MACAddress(configuredMAC) else {
                throw HypervisorServiceError.invalidConfiguration(
                    "VM network hot-unplug requires a valid stable unicast MAC address")
            }
            let macAddress = mac.description
            let dom = try await domain(vmId)
            let didDetach = try await DomainNetworkDetachConvergence.run {
                let isLive = LibvirtDomain.holdsResources(
                    rawState: try await state(of: dom, vmId: vmId))
                let liveDomainXML = isLive ? try await domainXML(dom, vmId: vmId) : nil
                let persistentDomainXML = try await inactiveDomainXML(dom, vmId: vmId)
                return try DomainNetworkDetachPlan(
                    macAddress: macAddress,
                    liveDomainXML: liveDomainXML,
                    inactiveDomainXML: persistentDomainXML)
            } detach: { scope in
                let stage: String
                let flags: UInt32
                switch scope {
                case .live:
                    stage = "libvirt-detach-network-live"
                    flags = LibvirtDomain.affectLive
                case .config:
                    stage = "libvirt-detach-network-config"
                    flags = LibvirtDomain.affectConfig
                }
                let xml = DomainDeviceXML.detachNetwork(macAddress: macAddress)
                try await call(stage, vmId: vmId) { client, deadline in
                    try await client.domainDetachDeviceFlags(
                        dom: dom, xml: xml, flags: flags, deadline: deadline)
                }
                try await waitForNetworkInterfaceAbsent(
                    macAddress: macAddress, scope: scope, dom: dom, vmId: vmId)
            }
            if !didDetach {
                logger.info(
                    "Network interface is already absent from live and persistent definitions; treating the detach as a no-op",
                    metadata: ["strato.vm.id": .string(vmId), "mac": .string(macAddress)])
            }
        }
    }

    /// Plugs `volumeId` into the VM's domain, live and in its definition.
    ///
    /// The guest device name is chosen here rather than taken from
    /// `deviceName`: that is a control-plane label ("disk1") which nothing
    /// constrains to be unique or to look like a device, and the same reasoning
    /// keeps `DomainXMLBuilder.targetDeviceName` from trusting it at create
    /// time. Asking the domain which names it has taken is the only answer that
    /// cannot collide.
    ///
    /// Idempotent: a volume whose serial the domain already carries has nothing
    /// to do. That matters because attaches are level-triggered and replayed —
    /// without it a redelivered sync would give the guest the same disk twice
    /// under two names.
    func attachDisk(
        vmId: String, volumeId: String, attachment: DiskAttachment, deviceName: String,
        readonly: Bool
    ) async throws {
        try await perform("attach-disk", vmId: vmId) {
            let dom = try await domain(vmId)
            let disks = try await domainDisks(dom, vmId: vmId)
            if let existing = DomainDiskInventory.disk(forVolume: volumeId, in: disks) {
                logger.info(
                    "Volume is already attached to this domain; treating the attach as a no-op",
                    metadata: [
                        "strato.vm.id": .string(vmId), "volumeId": .string(volumeId),
                        "target": .string(existing.target),
                    ])
                return
            }

            let target = DomainDiskInventory.nextTargetDevice(after: disks)
            let xml = DomainDeviceXML.hotplugDisk(
                attachment: attachment, target: target, readonly: readonly, volumeId: volumeId)
            let flags = try await deviceFlags(dom, vmId: vmId)

            logger.info(
                "Attaching disk to libvirt domain",
                metadata: [
                    "strato.vm.id": .string(vmId), "volumeId": .string(volumeId),
                    "deviceName": .string(deviceName), "target": .string(target),
                    "attachment": .string(String(describing: attachment)),
                    "readonly": .stringConvertible(readonly),
                ])
            do {
                try await call("libvirt-attach-disk", vmId: vmId) { client, deadline in
                    try await client.domainAttachDeviceFlags(
                        dom: dom, xml: xml, flags: flags, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isPCISlotsExhausted(error) {
                // libvirt's own text is accurate and completely unactionable:
                // it names a full root complex without saying that the complex
                // cannot be grown under a running guest, so the natural response
                // — retry, or free something — is wasted. The remedy is a power
                // cycle, and it is one only because `redefineVM` tops the spare
                // ports back up before every boot (STR-187); before that the
                // only remedy was recreating the VM. Every VM defined before
                // STR-192 reserved no usable spares at all, so this is the
                // fleet's error until each of those has been stopped once.
                throw HypervisorServiceError.invalidConfiguration(
                    "VM \(vmId) has no free PCIe root port to attach volume \(volumeId) into. A running "
                        + "domain's ports cannot be added to, so this will not succeed on retry: stop and start "
                        + "the VM, which redefines it with fresh spare ports, or attach the volume while it is "
                        + "stopped.")
            }
            logger.info(
                "Disk attached",
                metadata: [
                    "strato.vm.id": .string(vmId), "volumeId": .string(volumeId), "target": .string(target),
                ])
        }
    }

    /// Unplugs `volumeId` from the VM's domain, live and in its definition.
    ///
    /// Resolved by the serial the disk carries — the volume id, unique by
    /// construction — and never by `deviceName`, for the reason STR-129 gives:
    /// a device name is a per-VM label two volumes can share, and unplugging
    /// "whichever one answers to it" pulls a live disk out from under a guest.
    ///
    /// A serial no disk carries is a **success**: detaches are level-triggered
    /// and replayed, so a request whose post-condition already holds has to
    /// converge rather than fail forever. The one case that hides behind that —
    /// a domain defined before serials existed, whose create-time volumes are
    /// unidentifiable — is called out in the log instead, because nothing here
    /// can fix it and the remedy is to recreate the VM.
    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        try await perform("detach-disk", vmId: vmId) {
            let dom = try await domain(vmId)
            let disks = try await domainDisks(dom, vmId: vmId)
            guard let disk = DomainDiskInventory.disk(forVolume: volumeId, in: disks) else {
                let anonymous = disks.filter { $0.serial == nil }.map(\.target)
                if anonymous.isEmpty {
                    logger.info(
                        "No disk on this domain carries the volume; treating the detach as a no-op",
                        metadata: ["strato.vm.id": .string(vmId), "volumeId": .string(volumeId)])
                } else {
                    logger.warning(
                        """
                        No disk on this domain carries the volume, and the domain has disks with no serial \
                        at all — if one of those is this volume it was attached before STR-134 and cannot be \
                        identified; recreate the VM to detach it
                        """,
                        metadata: [
                            "strato.vm.id": .string(vmId), "volumeId": .string(volumeId),
                            "unidentifiedTargets": .string(anonymous.joined(separator: ",")),
                        ])
                }
                return
            }

            let flags = try await deviceFlags(dom, vmId: vmId)
            logger.info(
                "Detaching disk from libvirt domain",
                metadata: [
                    "strato.vm.id": .string(vmId), "volumeId": .string(volumeId),
                    "deviceName": .string(deviceName), "target": .string(disk.target),
                ])
            try await call("libvirt-detach-disk", vmId: vmId) { client, deadline in
                try await client.domainDetachDeviceFlags(
                    dom: dom, xml: DomainDeviceXML.detachDisk(disk), flags: flags, deadline: deadline)
            }
            logger.info(
                "Disk detached",
                metadata: [
                    "strato.vm.id": .string(vmId), "volumeId": .string(volumeId),
                    "target": .string(disk.target),
                ])
        }
    }

    // MARK: - Online resize (issue #568)

    /// Converges a VM's vCPU count and memory size on `spec`, within the
    /// headroom the *domain* was defined with.
    ///
    /// The QEMU driver's `SpawnSizing`/`vmSpawnSizing` have no counterpart:
    /// that bookkeeping exists because a spawned process's `maxcpus`/`maxmem`
    /// are only knowable to whoever spawned it, while here the ceiling is in
    /// the domain's own `<vcpu>` and `<maxMemory>` — read back off the domain
    /// rather than predicted. A memory target *above* that ceiling is the one
    /// case libvirt does not report, because nothing reaches libvirt at all:
    /// virtio-mem's `<requested>` clamps to the region, so `resizeMemory` raises
    /// it here instead, naming the boot that would fix it.
    ///
    /// Semantics are the QEMU path's, with the persistent-domain correction
    /// this driver requires. A live change that succeeds must also reach
    /// `CONFIG`, because the next boot reads libvirt's definition rather than
    /// respawning from the agent's recorded spec. So:
    ///
    /// - **vCPU growth** applies live and to the definition.
    /// - **vCPU shrink** is rejected on a running domain. Guest support for
    ///   unplug is unreliable, and a config-only write is not an online resize.
    /// - **Memory** moves through the virtio-mem device's `<requested>` where
    ///   the VM has one, live and in the definition; a VM with no device gets
    ///   its new size written to the definition alone.
    /// - **The balloon target** is best-effort and live only: it is a request
    ///   the guest may ignore, and `domainMemoryStats`' `actualBalloon` on the
    ///   next poll is what says whether memory came back.
    func resizeVM(vmId: String, spec: VMSpec) async throws {
        try await perform("resize", vmId: vmId) {
            let dom = try await domain(vmId)
            let info = try await call(
                "libvirt-domain-info", vmId: vmId, seconds: StageBudget.statusQuerySeconds
            ) { client, deadline in
                try await client.domainGetInfo(dom: dom, deadline: deadline)
            }
            let layout = try DomainMemoryInventory.memoryLayout(
                inDomainXML: try await domainXML(dom, vmId: vmId))
            // The reconciler also plans an offline vCPU shrink. State still
            // decides the flags: `AFFECT_LIVE` against an inactive domain is
            // `VIR_ERR_OPERATION_INVALID`.
            let live = LibvirtDomain.holdsResources(rawState: try await state(of: dom, vmId: vmId))
            let currentGuestMemory = layout.bootBytes + (layout.virtioMem?.requestedBytes ?? 0)
            let targetGuestMemory =
                layout.virtioMem.flatMap { _ in
                    layout.requestedBytes(forTotal: spec.memoryBytes)
                }.map { layout.bootBytes + $0 } ?? spec.memoryBytes
            // Without virtio-mem, a live memory resize is persistent-only. Its
            // live QEMU process keeps its old limit until that definition boots.
            let ceilingFlags =
                live && layout.virtioMem != nil
                ? LibvirtDomain.affectLiveAndConfig : LibvirtDomain.affectConfig

            if memoryControllerAvailable, spec.memoryBytes > currentGuestMemory {
                try await setMemoryCeiling(
                    dom, vmId: vmId, guestMemoryBytes: targetGuestMemory, flags: ceilingFlags)
            }

            try await resizeCPUs(
                dom, vmId: vmId, spec: spec, currentCPUs: Int(info.nrVirtCpu), live: live)
            try await resizeMemory(dom, vmId: vmId, spec: spec, layout: layout, live: live)
            if memoryControllerAvailable, spec.memoryBytes < currentGuestMemory {
                try await setMemoryCeiling(
                    dom, vmId: vmId, guestMemoryBytes: targetGuestMemory, flags: ceilingFlags)
            }
            if live {
                await applyBalloonTarget(dom, vmId: vmId, spec: spec, layout: layout)
            }
        }
    }

    private func setMemoryCeiling(
        _ dom: Domain, vmId: String, guestMemoryBytes: Int64, flags: UInt32
    ) async throws {
        let hardLimit = QEMUMemoryCeiling.kibibytes(
            guestMemoryBytes: guestMemoryBytes, overheadBytes: memoryOverheadBytes)
        try await call("libvirt-memory-ceiling", vmId: vmId) { client, deadline in
            try await client.domainSetMemoryParameters(
                dom: dom,
                params: [TypedParam(field: "hard_limit", value: .ullong(hardLimit))],
                flags: flags,
                deadline: deadline)
        }
    }

    private func resizeCPUs(
        _ dom: Domain, vmId: String, spec: VMSpec, currentCPUs: Int, live: Bool
    ) async throws {
        guard
            let flags = try LibvirtDomain.vcpuResizeFlags(
                current: currentCPUs, target: spec.cpus, domainIsLive: live)
        else { return }
        let growing = spec.cpus > currentCPUs
        try await call("libvirt-resize-cpus", vmId: vmId) { client, deadline in
            try await client.domainSetVCPUSFlags(
                dom: dom, nvcpus: UInt32(clamping: spec.cpus), flags: flags, deadline: deadline)
        }
        logger.info(
            live
                ? "Hot-added vCPUs"
                : "vCPU \(growing ? "grow" : "shrink") written to the stopped domain definition",
            metadata: [
                "strato.vm.id": .string(vmId), "from": .stringConvertible(currentCPUs),
                "to": .stringConvertible(spec.cpus),
            ])
    }

    private func resizeMemory(
        _ dom: Domain, vmId: String, spec: VMSpec, layout: DomainMemoryLayout, live: Bool
    ) async throws {
        guard let requested = layout.requestedBytes(forTotal: spec.memoryBytes),
            let virtioMem = layout.virtioMem
        else {
            // No memory device: nothing can move on the live guest, so the new
            // size is written to the definition for the next boot to read.
            try await setDefinedMemory(dom, vmId: vmId, bytes: spec.memoryBytes, layout: layout)
            return
        }

        // Past the ceiling this domain was defined with, `requestedBytes` clamps
        // to the whole region, which makes "at the ceiling" and "beyond it" the
        // same answer — so the shortfall is asked for separately, and it is the
        // one thing here the caller can act on: a power cycle rewrites the
        // region (`redefineVM`, STR-187). The arithmetic is
        // `DomainMemoryLayout`'s so that it can be tested; only the sentence is
        // this driver's.
        //
        // The vCPU half of the resize has already been applied and committed by
        // the time this throws. That is correct level-triggered behaviour — a
        // partial convergence is not one to undo — but it does mean an operator
        // reads "cannot reach N bytes" on a VM whose CPU count did move.
        if let shortfall = layout.shortfall(forTotal: spec.memoryBytes) {
            throw HypervisorServiceError.invalidConfiguration(
                "VM \(vmId) cannot reach \(spec.memoryBytes) bytes: its domain was defined with a ceiling of "
                    + "\(layout.maximumBytes) bytes, \(shortfall) short, and a virtio-mem region is fixed "
                    + "until the definition is rewritten. \(live ? "Stop and start" : "Start") the VM — a "
                    + "boot redefines it with the headroom its current size range asks for.")
        }
        guard requested != virtioMem.requestedBytes else { return }

        let xml = try DomainDeviceXML.memoryDevice(virtioMem, requestedBytes: requested)
        let flags = live ? LibvirtDomain.affectLiveAndConfig : LibvirtDomain.affectConfig
        try await call("libvirt-resize-memory", vmId: vmId) { client, deadline in
            try await client.domainUpdateDeviceFlags(
                dom: dom, xml: xml, flags: flags, deadline: deadline)
        }

        // The plugged region is only half of what the next boot reads. libvirt
        // starts a domain at its initial memory, plugs the device's persisted
        // `<requested>` in on top, and then — because `cur_balloon` differs
        // from the total — drives the balloon to the persisted
        // `<currentMemory>`, which for a VM defined with headroom is still its
        // *boot* size. Without this write a VM grown to 6 GiB comes back from a
        // power cycle with 6 GiB plugged and the balloon squeezing it to 2, and
        // the reconciler sees the spec it recorded as already applied.
        //
        // This is not the hazard `applyBalloonTarget` refuses below. There,
        // `<currentMemory>` *is* the boot size, because a VM with no memory
        // device has nowhere else to put one; here the boot size lives in
        // `<memory>` minus the device, so writing the allocation cannot change
        // what the VM boots with.
        try await setDefinedAllocation(dom, vmId: vmId, bytes: spec.memoryBytes)

        logger.info(
            "Requested virtio-mem resize",
            metadata: [
                "strato.vm.id": .string(vmId), "targetBytes": .stringConvertible(spec.memoryBytes),
                "requestedSize": .stringConvertible(requested),
            ])
    }

    /// Writes the domain's persistent allocation (`<currentMemory>`, libvirt's
    /// `cur_balloon`) without touching its ceiling.
    private func setDefinedAllocation(_ dom: Domain, vmId: String, bytes: Int64) async throws {
        try await call("libvirt-resize-allocation", vmId: vmId) { client, deadline in
            try await client.domainSetMemoryFlags(
                dom: dom, memory: UInt64(clamping: (bytes + 1023) / 1024),
                flags: LibvirtDomain.affectConfig, deadline: deadline)
        }
    }

    /// Writes a new memory size into the domain definition only.
    ///
    /// Reached exactly for a VM defined with no hot-plug headroom, where the
    /// ceiling and the allocation are the same number — `bootBytes` derives
    /// from `<memory>` minus the memory devices, and there are none — so both
    /// have to move. The order is the load-bearing part: libvirt validates the
    /// pair on every write and refuses an allocation above the ceiling, so the
    /// ceiling goes up first when growing and comes down last when shrinking.
    /// The other way round fails a request that is perfectly valid as a whole,
    /// with a message about a bound the caller never asked to cross.
    private func setDefinedMemory(
        _ dom: Domain, vmId: String, bytes: Int64, layout: DomainMemoryLayout
    ) async throws {
        guard bytes != layout.maximumBytes else { return }

        func setMaximum() async throws {
            try await call("libvirt-resize-max-memory", vmId: vmId) { client, deadline in
                try await client.domainSetMemoryFlags(
                    dom: dom, memory: UInt64(clamping: (bytes + 1023) / 1024),
                    flags: LibvirtDomain.affectConfig | LibvirtDomain.affectMaximum,
                    deadline: deadline)
            }
        }

        if bytes > layout.maximumBytes {
            try await setMaximum()
            try await setDefinedAllocation(dom, vmId: vmId, bytes: bytes)
        } else {
            try await setDefinedAllocation(dom, vmId: vmId, bytes: bytes)
            try await setMaximum()
        }
        logger.info(
            "Memory resize written to the domain definition; it lands at the next boot",
            metadata: [
                "strato.vm.id": .string(vmId), "fromBytes": .stringConvertible(layout.bootBytes),
                "toBytes": .stringConvertible(bytes),
            ])
    }

    /// Drives the guest's balloon to `spec.balloonTargetBytes`, or back to its
    /// full grant when the spec carries no target (issue #567 phase 2).
    ///
    /// Never fatal to the caller: a
    /// guest that ignores the request is not a convergence failure the agent
    /// can act on, and a VM created before the balloon device existed has
    /// nothing to drive. Live only, and for a VM with no memory device that is
    /// load-bearing: there `<currentMemory>` in the definition *is* the boot
    /// size — `<memory>` minus no devices — so writing a balloon target to it
    /// would quietly change what the VM boots with. (A VM with headroom keeps
    /// its boot size in `<memory>` minus the device instead, which is why
    /// `resizeMemory` can persist that VM's allocation without the same risk.)
    ///
    /// Clamped to `layout.maximumBytes`, which is the ceiling as the **live**
    /// domain has it: `layout` is read before the resize, and the only thing
    /// that could have moved the ceiling since is `setDefinedMemory`, which
    /// writes `CONFIG` alone and so cannot have raised the live one. Asking the
    /// balloon for a size the running guest cannot hold would fail every resize
    /// of a no-headroom VM with a warning about a bound the operator did not
    /// set — so the pre-resize reading is the correct one here, not a stale one.
    private func applyBalloonTarget(
        _ dom: Domain, vmId: String, spec: VMSpec, layout: DomainMemoryLayout
    ) async {
        let target = min(
            spec.balloonTargetBytes ?? spec.memoryBytes, spec.memoryBytes, layout.maximumBytes)
        do {
            try await call("libvirt-balloon-target", vmId: vmId) { client, deadline in
                try await client.domainSetMemory(
                    dom: dom, memory: UInt64(clamping: (target + 1023) / 1024), deadline: deadline)
            }
            logger.info(
                "Requested balloon target",
                metadata: ["strato.vm.id": .string(vmId), "targetBytes": .stringConvertible(target)])
        } catch {
            logger.warning(
                "Balloon target could not be applied",
                metadata: [
                    "strato.vm.id": .string(vmId), "targetBytes": .stringConvertible(target),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    // MARK: - Full-VM checkpoints (issue #564)

    /// Captures guest RAM, device state and the disks at one instant as a
    /// libvirt **system checkpoint** — an internal snapshot inside the VM's own
    /// qcow2 files, with the guest left running.
    ///
    /// The block-node selection a QMP-driven capture has to compute has no
    /// counterpart: naming no disks in the document lets libvirt capture every
    /// disk it can, which is the selection those rules arrived at. Two host
    /// preconditions make this work at all, and both are established elsewhere
    /// — a qcow2 NVRAM varstore (`DomainXMLBuilder`) and libvirt ≥ 11.5
    /// (`LibvirtProbe.minimumVersion`, gating). See `DomainSnapshotXML`.
    func checkpointVM(vmId: String, snapshotId: String) async throws -> VMCheckpointReport {
        try await perform("checkpoint", vmId: vmId) {
            let dom = try await domain(vmId)
            let name = VMSnapshotTag.tag(for: snapshotId)
            let running = LibvirtDomain.isRunningOrPaused(rawState: try await state(of: dom, vmId: vmId))

            logger.info(
                "Checkpointing libvirt domain",
                metadata: [
                    "strato.vm.id": .string(vmId), "snapshotId": .string(snapshotId), "name": .string(name),
                    "includesMemory": .stringConvertible(running),
                ])

            do {
                // The budget scales with guest RAM, so it uses the checkpoint
                // envelope rather than the control-call one, and
                // `.cancelAndWait`: a save job abandoned mid-write would leave
                // a half-written snapshot a retry could mistake for a
                // checkpoint.
                _ = try await call(
                    "libvirt-snapshot-create", vmId: vmId, seconds: StageBudget.checkpointSeconds
                ) { client, deadline in
                    try await client.domainSnapshotCreateXML(
                        dom: dom,
                        xmlDesc: DomainSnapshotXML.document(name: name, includesMemory: running),
                        flags: 0, deadline: deadline)
                }
            } catch {
                // A create whose reply was lost after the snapshot landed would
                // otherwise fail on every retry, and STR-150 will keep retrying
                // — a capture is read while the artifact is absent from the
                // host. Asking the daemon whether the checkpoint exists turns
                // that into a fact.
                guard await snapshotExists(dom, vmId: vmId, name: name) else { throw error }
                logger.warning(
                    "Checkpoint create failed but the checkpoint is present; treating it as captured",
                    metadata: [
                        "strato.vm.id": .string(vmId), "snapshotId": .string(snapshotId),
                        "error": .string(error.localizedDescription),
                    ])
            }

            let report = await checkpointReport(dom, vmId: vmId, name: name)
            logger.info(
                "libvirt domain checkpoint captured",
                metadata: [
                    "strato.vm.id": .string(vmId), "snapshotId": .string(snapshotId),
                    "vmStateSizeBytes": .string(report.vmStateSizeBytes.map(String.init) ?? "unknown"),
                ])
            return report
        }
    }

    /// Loads one of the VM's checkpoints back into it and leaves it running.
    ///
    /// Simpler than the QEMU path, which has to respawn a process that exited
    /// before it has anywhere to load into: reverting a `SHUTOFF` domain to a
    /// system checkpoint starts it, so "checkpoint → stop → restart the agent →
    /// restore" needs nothing remembered here either.
    func restoreVM(vmId: String, snapshotId: String) async throws {
        try await perform("restore", vmId: vmId) {
            let dom = try await domain(vmId)
            let name = VMSnapshotTag.tag(for: snapshotId)
            logger.info(
                "Restoring libvirt domain from checkpoint",
                metadata: ["strato.vm.id": .string(vmId), "snapshotId": .string(snapshotId)])

            let snapshot: DomainSnapshot
            do {
                snapshot = try await lookupSnapshot(dom, vmId: vmId, name: name)
            } catch let error where LibvirtFailure.isSnapshotMissing(error) {
                throw HypervisorServiceError.invalidConfiguration(
                    "VM \(vmId) has no checkpoint \(snapshotId); it was deleted, or captured on another host")
            }

            try await call("libvirt-snapshot-revert", vmId: vmId, seconds: StageBudget.checkpointSeconds) {
                client, deadline in
                try await client.domainRevertToSnapshot(
                    snap: snapshot, flags: LibvirtDomain.snapshotRevertRunning, deadline: deadline)
            }
            logger.info(
                "libvirt domain restored from checkpoint",
                metadata: ["strato.vm.id": .string(vmId), "snapshotId": .string(snapshotId)])
        }
    }

    /// Removes a checkpoint's stored state.
    ///
    /// Idempotent, like the QEMU path: a checkpoint that is already gone is a
    /// success, since the post-condition holds either way. Unlike the QEMU path
    /// this works on a **stopped** VM — libvirt deletes an internal snapshot
    /// through the disks rather than through a live monitor — so a delete no
    /// longer waits for the operator to start the VM again.
    func deleteVMCheckpoint(vmId: String, snapshotId: String) async throws {
        try await perform("delete-checkpoint", vmId: vmId) {
            let name = VMSnapshotTag.tag(for: snapshotId)
            do {
                let dom = try await domain(vmId)
                let snapshot = try await lookupSnapshot(dom, vmId: vmId, name: name)
                try await call(
                    "libvirt-snapshot-delete", vmId: vmId, seconds: StageBudget.checkpointSeconds
                ) { client, deadline in
                    try await client.domainSnapshotDelete(snap: snapshot, flags: 0, deadline: deadline)
                }
            } catch let error where LibvirtFailure.isSnapshotMissing(error) || LibvirtFailure.isDomainMissing(error) {
                // No snapshot, or no domain to hold one: the checkpoint lives
                // inside the VM's own disks, so either way it is gone.
                logger.info(
                    "Checkpoint is already absent; delete is a no-op",
                    metadata: ["strato.vm.id": .string(vmId), "snapshotId": .string(snapshotId)])
                return
            }
            logger.info(
                "libvirt domain checkpoint deleted",
                metadata: ["strato.vm.id": .string(vmId), "snapshotId": .string(snapshotId)])
        }
    }

    // MARK: - Helpers

    /// How long a guest gets to power itself off before the domain is
    /// destroyed.
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

    /// The domain's current document.
    ///
    /// `flags: 0` asks for the *live* configuration of a running domain and the
    /// persistent one of an inactive domain — in both cases the description the
    /// next command will act against. Network detach deliberately reads this
    /// separately from `inactiveDomainXML` because those views may be split.
    private func domainXML(_ dom: Domain, vmId: String) async throws -> String {
        try await call("libvirt-dumpxml", vmId: vmId, seconds: StageBudget.statusQuerySeconds) {
            client, deadline in
            try await client.domainGetXMLDesc(dom: dom, flags: 0, deadline: deadline)
        }
    }

    /// The domain's **persistent** definition, whatever state it is in.
    ///
    /// `flags: 0` above answers with the live configuration of a running domain,
    /// which is the right description for a command about to act on that guest.
    /// A redefine is the opposite question — what the *next boot* will read — and
    /// asking for it explicitly is what keeps the answer from depending on a
    /// domain state that could change between the read and the define.
    private func inactiveDomainXML(_ dom: Domain, vmId: String) async throws -> String {
        try await call("libvirt-dumpxml-inactive", vmId: vmId, seconds: StageBudget.statusQuerySeconds) {
            client, deadline in
            try await client.domainGetXMLDesc(
                dom: dom, flags: LibvirtDomain.xmlInactive, deadline: deadline)
        }
    }

    /// A detach RPC is acceptance, not convergence. In particular, QEMU can
    /// still hold the TAP after libvirt has changed the persistent definition.
    /// Do not let the reconciler tear host networking down until readback says
    /// the addressed definition no longer contains the NIC.
    private func waitForNetworkInterfaceAbsent(
        macAddress: String,
        scope: DomainNetworkDetachScope,
        dom: Domain,
        vmId: String
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(StageBudget.hypervisorControlSeconds)
        while ContinuousClock.now < deadline {
            if scope == .live {
                let isLive = LibvirtDomain.holdsResources(
                    rawState: try await state(of: dom, vmId: vmId))
                if !isLive { return }
            }
            let xml: String
            switch scope {
            case .live:
                xml = try await domainXML(dom, vmId: vmId)
            case .config:
                xml = try await inactiveDomainXML(dom, vmId: vmId)
            }
            if try !DomainNetworkInventory.macAddresses(inDomainXML: xml)
                .contains(macAddress)
            {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let definition = scope == .live ? "live" : "persistent"
        throw HypervisorServiceError.timeout(
            "network interface \(macAddress) remained in VM \(vmId)'s \(definition) domain XML after detach")
    }

    private func domainDisks(_ dom: Domain, vmId: String) async throws -> [DomainDisk] {
        try DomainDiskInventory.disks(inDomainXML: try await domainXML(dom, vmId: vmId))
    }

    /// The flags a combined device change should carry for this domain.
    ///
    /// `LIVE|CONFIG` for a domain that is up, `CONFIG` alone for one that is
    /// not: libvirt answers `VIR_ERR_OPERATION_INVALID` to a request that says
    /// it affects the live guest of an inactive domain. Both branches write the
    /// definition, which is the half that survives a power cycle. Network
    /// detach does not use this helper: it converges each flag independently so
    /// a half-applied operation is replayable.
    private func deviceFlags(_ dom: Domain, vmId: String) async throws -> UInt32 {
        LibvirtDomain.holdsResources(rawState: try await state(of: dom, vmId: vmId))
            ? LibvirtDomain.affectLiveAndConfig : LibvirtDomain.affectConfig
    }

    private func lookupSnapshot(_ dom: Domain, vmId: String, name: String) async throws -> DomainSnapshot {
        try await call("libvirt-snapshot-lookup", vmId: vmId, seconds: StageBudget.statusQuerySeconds) {
            client, deadline in
            try await client.domainSnapshotLookupByName(
                dom: dom, name: name, flags: 0, deadline: deadline)
        }
    }

    /// Whether the domain has a snapshot by that name, used to tell a create
    /// that really failed from one whose reply was lost. A lookup that fails
    /// for any *other* reason answers false, so the original error is the one
    /// reported.
    private func snapshotExists(_ dom: Domain, vmId: String, name: String) async -> Bool {
        do {
            _ = try await lookupSnapshot(dom, vmId: vmId, name: name)
            return true
        } catch {
            return false
        }
    }

    /// What a captured checkpoint recorded, for the control plane's snapshot
    /// row.
    ///
    /// Every field is best-effort and the whole thing is non-throwing on
    /// purpose: the checkpoint already exists at this point, and reporting it
    /// as failed because a follow-up query did not answer would leave an
    /// artifact on the host that no row describes.
    private func checkpointReport(_ dom: Domain, vmId: String, name: String) async -> VMCheckpointReport {
        let stats = try? await call(
            "libvirt-job-stats", vmId: vmId, seconds: StageBudget.statusQuerySeconds,
            { client, deadline in
                try await client.domainGetJobStats(
                    dom: dom, flags: LibvirtDomain.jobStatsCompleted, deadline: deadline)
            })

        let snapshotXML: String?
        if let snapshot = try? await lookupSnapshot(dom, vmId: vmId, name: name) {
            snapshotXML = try? await call(
                "libvirt-snapshot-dumpxml", vmId: vmId, seconds: StageBudget.statusQuerySeconds,
                { client, deadline in
                    try await client.domainSnapshotGetXMLDesc(
                        snap: snapshot, flags: 0, deadline: deadline)
                })
        } else {
            snapshotXML = nil
        }

        let packedVersion = try? await call(
            "libvirt-hypervisor-version", vmId: vmId, seconds: StageBudget.statusQuerySeconds,
            { client, deadline in
                try await client.connectGetVersion(deadline: deadline)
            })

        return VMCheckpointReport(
            vmStateSizeBytes: stats.flatMap { DomainSnapshotXML.vmStateSizeBytes(fromJobStats: $0.params) },
            deviceNodes: snapshotXML.map(DomainSnapshotXML.deviceNodes(inSnapshotXML:)) ?? [],
            hypervisorVersion: packedVersion.flatMap(DomainSnapshotXML.hypervisorVersion(packed:)))
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

    /// The firmware set to name explicitly, or nil to let libvirt autoselect.
    ///
    /// Naming it is the normal case (STR-188): autoselection cannot produce the
    /// qcow2 varstore VM checkpoints need on any host whose EDK2 descriptors
    /// declare a raw nvram template, which is every host Debian and Ubuntu
    /// ship. `FirmwareResolver.domainFirmware` carries the reasoning; this is
    /// only where its verdict is logged, because an autoselect fallback is the
    /// one outcome whose consequences land later, on a define this method
    /// cannot see.
    private func resolveFirmware(spec: VMSpec, machine: MachineProfile) -> FirmwareSet? {
        guard case .disk(let perVMPath) = spec.boot else { return nil }
        switch FirmwareResolver.domainFirmware(
            secureBoot: machine.secureBoot, perVMPath: perVMPath, overrides: firmware)
        {
        case .explicit(let set):
            return set
        case .autoselect(let unresolved):
            logger.warning(
                "No UEFI firmware resolved on this host; falling back to libvirt's own autoselection",
                metadata: [
                    "reason": .string(unresolved.description),
                    "detail": .string(
                        "the domain will ask for a qcow2 variable store, which libvirt can only satisfy from a "
                            + "descriptor that declares one — the define fails with \"Unable to find 'efi' "
                            + "firmware that is compatible with the current configuration\" where none does. "
                            + "Set firmware_code_path and firmware_vars_template in the agent configuration to "
                            + "name this host's EDK2 build."),
                ])
            return nil
        }
    }

    /// Seeds the VM's UEFI variable store, for the firmware sets whose document
    /// names one.
    ///
    /// Sequenced before the define rather than left to libvirt because libvirt
    /// will not convert a raw VARS template into the qcow2 varstore checkpoints
    /// require; `UEFIVarstore` explains the bind in full. Failing the create is
    /// deliberate — without the file the define still succeeds and only the
    /// *boot* fails, with an error naming a format rather than the VM.
    private func materializeVarstore(
        _ firmwareSet: FirmwareSet?, vmId: String, vmDirectory: String
    ) async throws {
        guard case .pflash(_, let varsTemplate) = firmwareSet else { return }
        let path = VMDirectoryLayout.nvram(vmDirectory: vmDirectory)
        let varstore = self.varstore
        do {
            _ = try await StageBudget.run(
                seconds: StageBudget.varstoreMaterializationSeconds, stage: "UEFI varstore materialization"
            ) {
                try await varstore.materialize(at: path, from: varsTemplate)
            }
        } catch let error as UEFIVarstoreError {
            // Rethrown as itself, not wrapped: it is a `ClassifiableError` and
            // preserves the distinction between a stable varstore failure and
            // blocked destination ENOSPC. Its message already names the
            // varstore path, which carries the VM id, and `perform` logs the id.
            throw error
        } catch {
            throw HypervisorServiceError.diskError(
                "could not create the UEFI variable store for VM \(vmId) at \(path): \(error)")
        }
    }

    /// The VM's disks, in the order the domain document will present them.
    ///
    /// Every disk comes from a managed volume reference. Image bytes are
    /// materialized by the volume reconciler before VM creation; the
    /// hypervisor never invents a second, path-only boot disk.
    private func resolveDisks(vmId: String, spec: VMSpec, imageInfo _: ImageInfo?) async throws -> [ResolvedDisk] {
        var disks: [ResolvedDisk] = []
        var seen: [DiskAttachment] = []
        for volume in spec.volumes {
            guard let attachment = volume.attachment else {
                throw HypervisorServiceError.diskError(
                    "managed volume \(volume.volumeId) for VM \(vmId) has no realized disk attachment")
            }
            guard !seen.contains(attachment) else {
                throw HypervisorServiceError.diskError(
                    "managed volumes for VM \(vmId) resolve to the same disk attachment \(attachment)")
            }
            seen.append(attachment)
            // Checked here rather than left to libvirt: a define accepts a
            // missing local source and only the *start* fails. Native RBD has
            // no local path to probe and is deliberately left to libvirt.
            switch attachment {
            case .file(let path, _), .blockDevice(let path):
                guard FileManager.default.fileExists(atPath: path) else {
                    throw HypervisorServiceError.diskError(
                        "volume \(volume.volumeId) for VM \(vmId) has no source at \(path) on this host")
                }
            case .rbd:
                break
            }
            disks.append(
                ResolvedDisk(
                    attachment: attachment, readonly: volume.readonly,
                    bootOrder: volume.bootOrder,
                    // Written into the document as `<serial>`, so a detach can
                    // resolve this disk by managed identity after a restart.
                    volumeId: volume.volumeId.uuidString))
        }

        if disks.isEmpty {
            throw HypervisorServiceError.diskError(
                "no managed volumes resolved for VM \(vmId)")
        }
        return disks
    }
}
