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
/// ## The domain document is written once
///
/// `createVM` defines a domain and nothing here ever redefines it. That single
/// fact shapes hot-plug, resize and everything else that mutates a VM in place
/// (STR-134): every such change is sent with
/// `LibvirtDomain.affectLiveAndConfig`, so it lands on the running guest *and*
/// in the persistent definition. The QEMU driver can leave the definition alone
/// because it respawns a VM from a stored configuration the agent keeps in step
/// (`updateRecordedVolumes`) and because everything it "defers to the next
/// boot" is re-read from the spec at that boot. Neither is true here — the next
/// boot reads libvirt's definition — so a live-only change is a change that
/// silently un-happens at the guest's next power cycle.
///
/// Its one remaining cost: **the hot-plug slots and the memory headroom a VM
/// will ever have are fixed when it is created.** The document reserves
/// `DomainXMLBuilder.spareHotplugPorts` empty PCIe root ports and whatever
/// virtio-mem region the spec asked for; growing past either needs libvirt's
/// own error, not bookkeeping here.
///
/// ## Not here yet
///
/// Lifecycle events in place of status polling are STR-135.
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

    /// The guest agent's view — hostname and configured interfaces (issue #563)
    /// — asked of libvirtd rather than of the VM's `qga.sock` directly.
    ///
    /// Same source, same channel: libvirt talks to the guest agent over the
    /// `org.qemu.guest_agent.0` device the domain document binds, so what
    /// reaches the control plane does not change with the driver. What goes is
    /// the transport — the framing, the `guest-sync-delimited` resync and the
    /// one-client-at-a-time socket `QGAClient` exists to manage are libvirtd's
    /// problem now, and it multiplexes.
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
                        "vmId": .string(vmId), "stage": .string(stage),
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
    /// rebuild anything. `createVM` writes the domain document once and never
    /// runs again for a domain that exists, so an attachment that is only
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
    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool)
        async throws
    {
        try await perform("attach-disk", vmId: vmId) {
            let dom = try await domain(vmId)
            let disks = try await domainDisks(dom, vmId: vmId)
            if let existing = DomainDiskInventory.disk(forVolume: volumeId, in: disks) {
                logger.info(
                    "Volume is already attached to this domain; treating the attach as a no-op",
                    metadata: [
                        "vmId": .string(vmId), "volumeId": .string(volumeId),
                        "target": .string(existing.target),
                    ])
                return
            }

            let target = DomainDiskInventory.nextTargetDevice(after: disks)
            let xml = DomainDeviceXML.hotplugDisk(
                path: volumePath, format: DiskFormat(volumePath: volumePath), target: target,
                readonly: readonly, volumeId: volumeId)
            let flags = try await deviceFlags(dom, vmId: vmId)

            logger.info(
                "Attaching disk to libvirt domain",
                metadata: [
                    "vmId": .string(vmId), "volumeId": .string(volumeId),
                    "deviceName": .string(deviceName), "target": .string(target),
                    "volumePath": .string(volumePath), "readonly": .stringConvertible(readonly),
                ])
            try await call("libvirt-attach-disk", vmId: vmId) { client, deadline in
                try await client.domainAttachDeviceFlags(
                    dom: dom, xml: xml, flags: flags, deadline: deadline)
            }
            logger.info(
                "Disk attached",
                metadata: [
                    "vmId": .string(vmId), "volumeId": .string(volumeId), "target": .string(target),
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
                        metadata: ["vmId": .string(vmId), "volumeId": .string(volumeId)])
                } else {
                    logger.warning(
                        """
                        No disk on this domain carries the volume, and the domain has disks with no serial \
                        at all — if one of those is this volume it was attached before STR-134 and cannot be \
                        identified; recreate the VM to detach it
                        """,
                        metadata: [
                            "vmId": .string(vmId), "volumeId": .string(volumeId),
                            "unidentifiedTargets": .string(anonymous.joined(separator: ",")),
                        ])
                }
                return
            }

            let flags = try await deviceFlags(dom, vmId: vmId)
            logger.info(
                "Detaching disk from libvirt domain",
                metadata: [
                    "vmId": .string(vmId), "volumeId": .string(volumeId),
                    "deviceName": .string(deviceName), "target": .string(disk.target),
                ])
            try await call("libvirt-detach-disk", vmId: vmId) { client, deadline in
                try await client.domainDetachDeviceFlags(
                    dom: dom, xml: DomainDeviceXML.detachDisk(disk), flags: flags, deadline: deadline)
            }
            logger.info(
                "Disk detached",
                metadata: [
                    "vmId": .string(vmId), "volumeId": .string(volumeId),
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
    /// the domain's own `<vcpu>` and `<maxMemory>` and exceeding it is
    /// libvirt's error to report, not ours to predict.
    ///
    /// Semantics are the QEMU path's, with one correction that the driver
    /// forces. There, "deferred to the next reboot" works because the next boot
    /// respawns from the recorded spec; here the next boot reads libvirt's
    /// definition, so a deferred change that is not written to `CONFIG` never
    /// happens at all. So:
    ///
    /// - **vCPU growth** applies live and to the definition.
    /// - **vCPU shrink** is not attempted online — guest support for unplug is
    ///   unreliable — and is written to the definition alone, which is what
    ///   makes "it takes effect at the next reboot" true.
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
            // The reconciler only plans a resize for a running VM, but nothing
            // in the protocol says so, and `AFFECT_LIVE` against an inactive
            // domain is `VIR_ERR_OPERATION_INVALID` — so the state decides.
            let live = LibvirtDomain.holdsResources(rawState: try await state(of: dom, vmId: vmId))

            try await resizeCPUs(
                dom, vmId: vmId, spec: spec, currentCPUs: Int(info.nrVirtCpu), live: live)
            try await resizeMemory(dom, vmId: vmId, spec: spec, layout: layout, live: live)
            if live {
                await applyBalloonTarget(dom, vmId: vmId, spec: spec, layout: layout)
            }
        }
    }

    private func resizeCPUs(
        _ dom: Domain, vmId: String, spec: VMSpec, currentCPUs: Int, live: Bool
    ) async throws {
        guard spec.cpus != currentCPUs else { return }
        let growing = spec.cpus > currentCPUs && live
        let flags = growing ? LibvirtDomain.affectLiveAndConfig : LibvirtDomain.affectConfig
        try await call("libvirt-resize-cpus", vmId: vmId) { client, deadline in
            try await client.domainSetVCPUSFlags(
                dom: dom, nvcpus: UInt32(clamping: spec.cpus), flags: flags, deadline: deadline)
        }
        logger.info(
            growing
                ? "Hot-added vCPUs" : "vCPU shrink written to the domain definition; it lands at the next boot",
            metadata: [
                "vmId": .string(vmId), "from": .stringConvertible(currentCPUs),
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
        guard requested != virtioMem.requestedBytes else { return }

        let xml = DomainDeviceXML.memoryDevice(
            sizeBytes: virtioMem.sizeBytes, blockBytes: virtioMem.blockBytes,
            requestedBytes: requested)
        let flags = live ? LibvirtDomain.affectLiveAndConfig : LibvirtDomain.affectConfig
        try await call("libvirt-resize-memory", vmId: vmId) { client, deadline in
            try await client.domainUpdateDeviceFlags(
                dom: dom, xml: xml, flags: flags, deadline: deadline)
        }
        logger.info(
            "Requested virtio-mem resize",
            metadata: [
                "vmId": .string(vmId), "targetBytes": .stringConvertible(spec.memoryBytes),
                "requestedSize": .stringConvertible(requested),
            ])
    }

    /// Writes a new memory size into the domain definition only.
    ///
    /// Reached exactly for a VM defined with no hot-plug headroom, whose
    /// `<memory>` and `<currentMemory>` are therefore the same number and have
    /// to move together. The order is the load-bearing part: libvirt validates
    /// the pair on every write and refuses a current size above the maximum, so
    /// the ceiling goes up first when growing and comes down last when
    /// shrinking. Doing it the other way round fails a request that is
    /// perfectly valid as a whole, with a message about a bound the caller
    /// never asked to cross.
    private func setDefinedMemory(
        _ dom: Domain, vmId: String, bytes: Int64, layout: DomainMemoryLayout
    ) async throws {
        guard bytes != layout.bootBytes || bytes != layout.maximumBytes else { return }
        let kib = UInt64(clamping: (bytes + 1023) / 1024)

        func set(_ stage: String, maximum: Bool) async throws {
            let flags =
                maximum
                ? LibvirtDomain.affectConfig | LibvirtDomain.affectMaximum : LibvirtDomain.affectConfig
            try await call(stage, vmId: vmId) { client, deadline in
                try await client.domainSetMemoryFlags(
                    dom: dom, memory: kib, flags: flags, deadline: deadline)
            }
        }

        if bytes > layout.maximumBytes {
            try await set("libvirt-resize-max-memory", maximum: true)
            try await set("libvirt-resize-memory", maximum: false)
        } else {
            try await set("libvirt-resize-memory", maximum: false)
            try await set("libvirt-resize-max-memory", maximum: true)
        }
        logger.info(
            "Memory resize written to the domain definition; it lands at the next boot",
            metadata: [
                "vmId": .string(vmId), "fromBytes": .stringConvertible(layout.bootBytes),
                "toBytes": .stringConvertible(bytes),
            ])
    }

    /// Drives the guest's balloon to `spec.balloonTargetBytes`, or back to its
    /// full grant when the spec carries no target (issue #567 phase 2).
    ///
    /// Never fatal to the caller, matching `QEMUService.applyBalloonTarget`: a
    /// guest that ignores the request is not a convergence failure the agent
    /// can act on, and a VM created before the balloon device existed has
    /// nothing to drive. Live only — `<currentMemory>` in the definition is the
    /// boot size, and writing a balloon target there would quietly change what
    /// the VM boots with.
    ///
    /// Clamped to the domain's own maximum as well as to the spec's size: where
    /// a resize could only be written to the definition, the guest is still at
    /// its old size until it reboots, and asking the balloon for the new one
    /// would fail every resize with a warning about a bound the operator did
    /// not set.
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
                metadata: ["vmId": .string(vmId), "targetBytes": .stringConvertible(target)])
        } catch {
            logger.warning(
                "Balloon target could not be applied",
                metadata: [
                    "vmId": .string(vmId), "targetBytes": .stringConvertible(target),
                    "error": .string(error.localizedDescription),
                ])
        }
    }

    // MARK: - Full-VM checkpoints (issue #564)

    /// Captures guest RAM, device state and the disks at one instant as a
    /// libvirt **system checkpoint** — an internal snapshot inside the VM's own
    /// qcow2 files, with the guest left running.
    ///
    /// `VMCheckpointTargets`' block-node selection has no counterpart: naming
    /// no disks in the document lets libvirt capture every disk it can, which
    /// is the selection those rules spent their effort arriving at. Two host
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
                    "vmId": .string(vmId), "snapshotId": .string(snapshotId), "name": .string(name),
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
                        "vmId": .string(vmId), "snapshotId": .string(snapshotId),
                        "error": .string(error.localizedDescription),
                    ])
            }

            let report = await checkpointReport(dom, vmId: vmId, name: name)
            logger.info(
                "libvirt domain checkpoint captured",
                metadata: [
                    "vmId": .string(vmId), "snapshotId": .string(snapshotId),
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
                metadata: ["vmId": .string(vmId), "snapshotId": .string(snapshotId)])

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
                metadata: ["vmId": .string(vmId), "snapshotId": .string(snapshotId)])
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
                    metadata: ["vmId": .string(vmId), "snapshotId": .string(snapshotId)])
                return
            }
            logger.info(
                "libvirt domain checkpoint deleted",
                metadata: ["vmId": .string(vmId), "snapshotId": .string(snapshotId)])
        }
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

    /// The domain's current document.
    ///
    /// `flags: 0` asks for the *live* configuration of a running domain and the
    /// persistent one of an inactive domain — in both cases the description the
    /// next command will act against. The two cannot drift here, because every
    /// device change this driver makes carries `AFFECT_CONFIG`.
    private func domainXML(_ dom: Domain, vmId: String) async throws -> String {
        try await call("libvirt-dumpxml", vmId: vmId, seconds: StageBudget.statusQuerySeconds) {
            client, deadline in
            try await client.domainGetXMLDesc(dom: dom, flags: 0, deadline: deadline)
        }
    }

    private func domainDisks(_ dom: Domain, vmId: String) async throws -> [DomainDisk] {
        try DomainDiskInventory.disks(inDomainXML: try await domainXML(dom, vmId: vmId))
    }

    /// The flags a device change should carry for this domain.
    ///
    /// `LIVE|CONFIG` for a domain that is up, `CONFIG` alone for one that is
    /// not: libvirt answers `VIR_ERR_OPERATION_INVALID` to a request that says
    /// it affects the live guest of an inactive domain. Both branches write the
    /// definition, which is the half that survives a power cycle.
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
                    bootOrder: volume.bootOrder,
                    // Written into the document as `<serial>`, so a detach can
                    // resolve this disk without the agent remembering anything
                    // about it. A volume reference with no id is not one the
                    // control plane placed and has nothing to be named after.
                    volumeId: volume.volumeId?.uuidString))
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
