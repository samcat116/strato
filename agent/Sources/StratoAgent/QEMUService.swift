import Foundation
import Logging
import StratoShared
import StratoAgentCore

// QEMUService is the QEMU/KVM/HVF backend. It is compiled only when SwiftQEMU is
// available; when it is not (e.g. its system dependencies are missing at build
// time), the agent falls back to `MockHypervisorService` instead of interleaving
// mock branches through this production code.
#if canImport(SwiftQEMU)
import SwiftQEMU

actor QEMUService: HypervisorService {
    private let logger: Logger
    private let storage: (any StorageBackend)?
    private let vmStoragePath: String
    private let qemuBinaryPath: String
    /// Operator-configured EDK2 firmware paths (issue #565).
    private let firmware: FirmwareOverrides
    /// Runs each vTPM VM's swtpm, or nil on a host without swtpm — such a host
    /// never advertises the TPM capability, so a spec asking for one here means
    /// the placement gate was bypassed and the create must fail loudly.
    private let swtpm: SwtpmSupervisor?
    /// Whether to back VMs with hardware acceleration (KVM on Linux, HVF on
    /// macOS). Resolved from `enable_kvm`/`enable_hvf` config; when false, VMs
    /// run under TCG emulation.
    private let hardwareAccelerationEnabled: Bool

    // HypervisorService protocol requirement
    public let hypervisorType: HypervisorType = .qemu

    // Handles are `QEMUManager` for VMs spawned by this process and
    // `AdoptedQEMUVM` for orphans re-adopted over their deterministic QMP
    // socket after an agent restart (see AdoptedQEMUVM.swift).
    private var activeVMs: [String: any QEMUVMHandle] = [:]
    private var vmSpecs: [String: VMSpec] = [:]
    // The exact configuration each VM's process was spawned from, kept so a
    // VM whose guest powered off (QEMU exits with it) can be respawned by
    // bootVM. Absent for re-adopted VMs, which were spawned by a previous
    // agent incarnation.
    private var vmConfigs: [String: QEMUConfiguration] = [:]
    // What each running process was actually spawned with (issue #568). A
    // resize can only move within the headroom baked into the QEMU command
    // line, and `vmSpecs` tracks the *current* sizing (it feeds scheduler
    // reservations), so the spawn-time bounds are kept separately rather than
    // inferred from a spec that resizes mutate.
    private var vmSpawnSizing: [String: SpawnSizing] = [:]
    private var vmConsoleSocketPaths: [String: String] = [:]
    private var vmSerialSocketPaths: [String: String] = [:]
    private var pendingVMs: Set<String> = []  // Track VMs being created (to handle concurrent boot requests)

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil, vmStoragePath: String, qemuBinaryPath: String,
        firmware: FirmwareOverrides = FirmwareOverrides(), swtpmBinaryPath: String? = nil,
        hardwareAccelerationEnabled: Bool = true
    ) {
        self.logger = logger
        self.storage = storage
        self.vmStoragePath = vmStoragePath
        self.qemuBinaryPath = qemuBinaryPath
        self.firmware = firmware
        self.swtpm = swtpmBinaryPath.map { SwtpmSupervisor(binaryPath: $0, logger: logger) }
        self.hardwareAccelerationEnabled = hardwareAccelerationEnabled

        #if os(Linux)
        logger.info("QEMU service initialized with KVM acceleration support")
        #elseif os(macOS)
        logger.info("QEMU service initialized with Hypervisor.framework (HVF) acceleration support")
        #else
        logger.info("QEMU service initialized with SwiftQEMU support")
        #endif
    }

    // MARK: - VM Lifecycle Operations

    /// Creates a VM from a hypervisor-neutral spec with optional image info for disk caching.
    ///
    /// Idempotent: a VM already managed under this id is left untouched. A
    /// resent or replayed create must never spawn a second QEMU process
    /// against the same disk paths (issue #260).
    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil,
        networkAttachments: [ResolvedNetworkAttachment] = []
    ) async throws {
        if activeVMs[vmId] != nil {
            logger.info(
                "VM already exists, treating create as a no-op",
                metadata: ["vmId": .string(vmId)])
            return
        }
        guard !pendingVMs.contains(vmId) else {
            logger.info(
                "VM creation already in progress, treating create as a no-op",
                metadata: ["vmId": .string(vmId)])
            return
        }

        // Mark VM as pending to handle concurrent boot requests
        pendingVMs.insert(vmId)
        defer { pendingVMs.remove(vmId) }

        logger.info("Creating QEMU VM", metadata: ["vmId": .string(vmId)])

        // Realize the VM's disks. The boot disk is materialized here from the cached
        // image when imageInfo is provided; otherwise the spec's volume references
        // (with agent-reported paths) are used.
        var disks: [ResolvedDisk] = []
        if let imageInfo = imageInfo, let storage = storage {
            logger.info(
                "Materializing boot disk from image",
                metadata: [
                    "vmId": .string(vmId),
                    "imageId": .string(imageInfo.imageId.uuidString),
                ])

            do {
                // The storage layer downloads/caches the image and converts it
                // to qcow2 when the source format differs. This stage gets its
                // own generous budget — multi-GB downloads are legitimate and
                // must not be squeezed into the process-spawn envelope.
                // Explicitly `.cancelAndWait`: materialization writes through
                // a deterministic staging path and clears any partial it finds,
                // so abandoning a slow attempt would let a retry delete its
                // output mid-write and publish a truncated disk.
                let attachment = try await StageBudget.run(
                    seconds: StageBudget.imageMaterializationSeconds,
                    stage: "image materialization",
                    onTimeout: .cancelAndWait
                ) { [storage] in
                    try await storage.materializeDisk(
                        at: "\(self.vmStoragePath)/\(vmId)/disk.qcow2",
                        from: imageInfo,
                        format: .qcow2,
                        artifactKind: .diskImage
                    )
                }
                disks = [ResolvedDisk(path: attachment.path, format: attachment.format, readonly: false)]
            } catch {
                logger.error(
                    "Failed to materialize boot disk from image, falling back to spec volumes",
                    metadata: [
                        "vmId": .string(vmId),
                        "error": .string(error.localizedDescription),
                    ])
                // Continue with the spec's volume references
            }
        }

        if disks.isEmpty {
            disks = spec.volumes.compactMap { volume in
                volume.storagePath.map {
                    ResolvedDisk(path: $0, format: DiskFormat(volumePath: $0), readonly: volume.readonly)
                }
            }

            // Create disk images from base if they don't exist
            for disk in disks {
                let diskPath = disk.path
                let fileManager = FileManager.default

                if !fileManager.fileExists(atPath: diskPath) {
                    logger.info(
                        "Disk image does not exist, creating from base",
                        metadata: [
                            "diskPath": .string(diskPath),
                            "vmId": .string(vmId),
                        ])

                    // Determine base disk path from the disk path
                    // Disk path format: /images/<template>/UUID.qcow2
                    // Base disk: /images/<template>/disk.qcow2
                    let diskURL = URL(fileURLWithPath: diskPath)
                    let templateDir = diskURL.deletingLastPathComponent().path
                    let baseDiskPath = "\(templateDir)/disk.qcow2"

                    if fileManager.fileExists(atPath: baseDiskPath) {
                        do {
                            try fileManager.copyItem(atPath: baseDiskPath, toPath: diskPath)
                            logger.info(
                                "Disk image created successfully",
                                metadata: [
                                    "from": .string(baseDiskPath),
                                    "to": .string(diskPath),
                                ])
                        } catch {
                            logger.error(
                                "Failed to create disk image: \(error)",
                                metadata: [
                                    "from": .string(baseDiskPath),
                                    "to": .string(diskPath),
                                ])
                            throw QEMUServiceError.diskCreationFailed(
                                "Failed to copy base disk: \(error.localizedDescription)")
                        }
                    } else {
                        logger.error("Base disk not found", metadata: ["baseDiskPath": .string(baseDiskPath)])
                        throw QEMUServiceError.diskCreationFailed("Base disk not found at \(baseDiskPath)")
                    }
                } else {
                    logger.debug("Disk image already exists", metadata: ["diskPath": .string(diskPath)])
                }
            }
        }

        // A disk-boot VM with no disks can only produce an unbootable shell —
        // e.g. the image download failed (or the sync carried no usable
        // imageInfo) and the spec had no volume references to fall back on.
        // Fail the create with the real problem instead of "converging" to a
        // diskless VM that reports success.
        if disks.isEmpty, case .disk = spec.boot {
            throw QEMUServiceError.diskCreationFailed(
                "no disks resolved for disk-boot VM \(vmId): image materialization failed or the spec carried no volumes"
            )
        }

        let qemuManager = QEMUManager(qemuPath: qemuBinaryPath, logger: logger)

        // Translate the neutral spec into QEMU's native configuration. Network
        // attachments were already realized by the agent's NetworkOrchestrator.
        let qemuConfig = try await convertToQEMUConfiguration(
            spec, disks: disks, networkAttachments: networkAttachments, vmId: vmId)

        // Spawn the process under its own stage budget — QMP connection can
        // hang indefinitely, but this stage no longer shares its envelope with
        // the image download above.
        logger.info(
            "Starting QEMU VM creation",
            metadata: [
                "vmId": .string(vmId),
                "spawnBudgetSeconds": .stringConvertible(StageBudget.hypervisorSpawnSeconds),
            ])
        do {
            try await qemuManager.createVM(
                config: qemuConfig, timeout: TimeInterval(StageBudget.hypervisorSpawnSeconds))
        } catch {
            logger.error(
                "QEMU VM creation failed",
                metadata: [
                    "vmId": .string(vmId),
                    "error": .string(error.localizedDescription),
                ])
            // Clean up the QEMU process if it's still running
            try? await qemuManager.destroy()
            throw error
        }

        activeVMs[vmId] = qemuManager
        vmSpecs[vmId] = spec
        vmSpawnSizing[vmId] = Self.spawnSizing(for: spec)
        vmConfigs[vmId] = qemuConfig

        logger.info("QEMU VM created successfully", metadata: ["vmId": .string(vmId)])
    }

    func bootVM(vmId: String) async throws {
        // Wait for VM to be ready - it may still be creating (downloading image, etc.)
        var retries = 0
        let maxRetries = 120  // 60 seconds total (120 * 0.5s) - creation can take a while
        var vm: (any QEMUVMHandle)?

        while retries < maxRetries {
            // Check if VM is ready
            if let foundVM = activeVMs[vmId] {
                vm = foundVM
                break
            }

            // If VM is being created, wait for it
            if pendingVMs.contains(vmId) {
                logger.debug(
                    "VM is being created, waiting...",
                    metadata: ["vmId": .string(vmId), "retry": .stringConvertible(retries)])
                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                retries += 1
                continue
            }

            // VM not found and not pending - fail fast
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found and not being created")
        }

        guard let vm = vm else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) creation timed out after \(maxRetries / 2) seconds")
        }

        logger.info("Booting QEMU VM", metadata: ["vmId": .string(vmId)])

        // Start VM execution
        do {
            try await controlled("qmp-start", vmId: vmId) {
                try await vm.start()
            }
        } catch {
            // A budget timeout is ambiguous — the guest may be perfectly alive
            // behind a wedged control channel — so it must not fall into the
            // respawn below, which tears the process down. Respawn is for a
            // channel that is *known* dead, which is what a real start error
            // reports.
            if case HypervisorServiceError.timeout = error { throw error }
            // A guest that powered off took its QEMU process with it, so the
            // control channel is dead and `cont` cannot revive it. Respawn the
            // process from the configuration the VM was created with (its disks
            // persist on this host) and resume that. Without a stored config
            // (re-adopted VM from a previous agent incarnation) the original
            // error stands. A false positive is safe: QEMU's image locking
            // refuses a second process on the same disk.
            guard let config = vmConfigs[vmId] else { throw error }
            logger.info(
                "VM control channel is dead; respawning QEMU process",
                metadata: ["vmId": .string(vmId), "startError": .string(error.localizedDescription)])
            try? await vm.destroy()
            // The stored configuration points at this VM's swtpm socket, and a
            // guest that powered off may have outlived its swtpm. Restarting it
            // here is safe and idempotent: the TPM's state directory persists,
            // so the respawned guest sees the same TPM it had (issue #565).
            if vmSpecs[vmId]?.effectiveMachine.tpm == true, let swtpm {
                let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
                try await swtpm.ensureRunning(vmDirectory: vmDir, vmId: vmId)
            }
            let manager = QEMUManager(qemuPath: qemuBinaryPath, logger: logger)
            try await manager.createVM(
                config: config, timeout: TimeInterval(StageBudget.hypervisorSpawnSeconds))
            activeVMs[vmId] = manager
            try await controlled("qmp-start-respawned", vmId: vmId) {
                try await manager.start()
            }
        }

        logger.info("QEMU VM booted successfully", metadata: ["vmId": .string(vmId)])
    }

    func shutdownVM(vmId: String) async throws {
        guard let vm = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Shutting down QEMU VM", metadata: ["vmId": .string(vmId)])

        // Verified shutdown first: qga's `guest-shutdown` tells the guest OS to
        // power off directly, and its success confirms the guest actually heard
        // us — unlike a fire-and-forget ACPI powerdown (issue #563). The QEMU
        // process still exits when the guest powers off, so the reconciler
        // observes `.shutdown` the same way. When qga is absent or unresponsive
        // within its short budget, fall through to the universal ACPI path.
        if await requestGuestShutdown(vmId: vmId) {
            logger.info("QEMU VM shutdown initiated via guest agent", metadata: ["vmId": .string(vmId)])
            return
        }

        // Graceful ACPI shutdown. Longer budget than the other control calls:
        // the adopted-VM path polls for up to 30s before forcing termination.
        try await controlled("qmp-shutdown", vmId: vmId, seconds: 60) {
            try await vm.shutdown()
        }

        logger.info("QEMU VM shutdown completed", metadata: ["vmId": .string(vmId)])
    }

    func rebootVM(vmId: String) async throws {
        guard let vm = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Rebooting QEMU VM", metadata: ["vmId": .string(vmId)])

        // System reset
        try await controlled("qmp-reset", vmId: vmId) {
            try await vm.reset()
        }

        logger.info("QEMU VM reboot initiated", metadata: ["vmId": .string(vmId)])
    }

    func pauseVM(vmId: String) async throws {
        guard let vm = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Pausing QEMU VM", metadata: ["vmId": .string(vmId)])

        // Pause VM
        try await controlled("qmp-pause", vmId: vmId) {
            try await vm.pause()
        }

        logger.info("QEMU VM paused", metadata: ["vmId": .string(vmId)])
    }

    func resumeVM(vmId: String) async throws {
        guard let vm = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Resuming QEMU VM", metadata: ["vmId": .string(vmId)])

        // Resume VM
        try await controlled("qmp-resume", vmId: vmId) {
            try await vm.start()
        }

        logger.info("QEMU VM resumed", metadata: ["vmId": .string(vmId)])
    }

    func deleteVM(vmId: String) async throws {
        guard let qemuManager = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info("Deleting QEMU VM", metadata: ["vmId": .string(vmId)])

        // Destroy VM (network attachments are torn down by the agent's
        // NetworkOrchestrator after this returns)
        try await controlled("qmp-destroy", vmId: vmId) {
            try await qemuManager.destroy()
        }

        // Stop the VM's swtpm, if it has one. Unconditional rather than gated
        // on the spec's machine profile: a re-adopted VM has no spec here, and
        // stopping is a no-op when no swtpm is running.
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        await swtpm?.stop(vmDirectory: vmDir, vmId: vmId)

        // Clean up VM resources
        activeVMs.removeValue(forKey: vmId)
        vmSpecs.removeValue(forKey: vmId)
        vmSpawnSizing.removeValue(forKey: vmId)
        vmConfigs.removeValue(forKey: vmId)

        // Clean up console socket
        if let socketPath = vmConsoleSocketPaths.removeValue(forKey: vmId) {
            try? FileManager.default.removeItem(atPath: socketPath)
            logger.debug("Removed console socket: \(socketPath)")
        }

        // Clean up serial socket
        if let socketPath = vmSerialSocketPaths.removeValue(forKey: vmId) {
            try? FileManager.default.removeItem(atPath: socketPath)
            logger.debug("Removed serial socket: \(socketPath)")
        }

        // Clean up the deterministic re-adoption QMP socket
        try? FileManager.default.removeItem(
            atPath: Self.adoptionSocketPath(vmStoragePath: vmStoragePath, vmId: vmId))

        // Clean up the deterministic guest-agent socket (issue #563)
        try? FileManager.default.removeItem(
            atPath: Self.qgaSocketPath(vmStoragePath: vmStoragePath, vmId: vmId))

        // Clean up the deterministic balloon-stats QMP socket (issue #567)
        try? FileManager.default.removeItem(
            atPath: Self.statsSocketPath(vmStoragePath: vmStoragePath, vmId: vmId))

        // Clean up the UEFI variable store and the TPM's state directory
        // (issue #565). Both are per-VM and meaningless once the VM is gone;
        // keeping the NVRAM would also make a later VM reusing this id inherit
        // a stranger's boot entries.
        try? FileManager.default.removeItem(
            atPath: Self.nvramPath(vmStoragePath: vmStoragePath, vmId: vmId))
        try? FileManager.default.removeItem(
            atPath: SwtpmSupervisor.stateDirectory(vmDirectory: vmDir))

        logger.info("QEMU VM deleted", metadata: ["vmId": .string(vmId)])
    }

    /// Returns the console socket path for a VM
    /// The path is computed deterministically from vmStoragePath and vmId
    /// Returns nil if the socket file doesn't exist (VM not running or not created)
    func getConsoleSocketPath(vmId: String) -> String? {
        // First check in-memory cache for VMs created this session
        if let cachedPath = vmConsoleSocketPaths[vmId] {
            // Verify socket file exists
            if FileManager.default.fileExists(atPath: cachedPath) {
                return cachedPath
            }
        }

        // Compute the expected path deterministically
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        let consoleSocketPath = (vmDir as NSString).appendingPathComponent("console.sock")

        // Check if the socket file exists (VM is running with console enabled)
        if FileManager.default.fileExists(atPath: consoleSocketPath) {
            logger.debug("Found console socket at computed path: \(consoleSocketPath)")
            return consoleSocketPath
        }

        logger.debug("Console socket not found at: \(consoleSocketPath)")
        return nil
    }

    /// Returns the serial console socket path for a VM
    /// The path is computed deterministically from vmStoragePath and vmId
    /// Returns nil if the socket file doesn't exist (VM not running or not created)
    func getSerialSocketPath(vmId: String) -> String? {
        // First check in-memory cache for VMs created this session
        if let cachedPath = vmSerialSocketPaths[vmId] {
            // Verify socket file exists
            if FileManager.default.fileExists(atPath: cachedPath) {
                return cachedPath
            }
        }

        // Compute the expected path deterministically
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        let serialSocketPath = (vmDir as NSString).appendingPathComponent("serial.sock")

        // Check if the socket file exists (VM is running with serial enabled)
        if FileManager.default.fileExists(atPath: serialSocketPath) {
            logger.debug("Found serial socket at computed path: \(serialSocketPath)")
            return serialSocketPath
        }

        logger.debug("Serial socket not found at: \(serialSocketPath)")
        return nil
    }

    /// Console access for QEMU VMs: the serial and/or virtio-console Unix sockets.
    /// Returns nil when neither socket exists (VM not running or console not enabled).
    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        let endpoint = ConsoleEndpoint(
            serialSocketPath: getSerialSocketPath(vmId: vmId),
            consoleSocketPath: getConsoleSocketPath(vmId: vmId)
        )
        return endpoint.isEmpty ? nil : endpoint
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        // Shut-down VMs stay in activeVMs until deleted, so an absent entry means
        // this service does not manage the VM at all (e.g. lost on agent restart).
        // Report that honestly instead of fabricating `.shutdown` — the control
        // plane relies on the distinction to preserve a reconciled `.error` state.
        guard let qemuManager = activeVMs[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        do {
            // Bound the QMP round-trip: a re-adopted VM can have a dead control
            // socket whose query never returns, and QEMUService is an actor
            // shared with console-endpoint lookups, so an unbounded wait here
            // stalls the console too. On timeout report `.unknown` rather than
            // fabricating `.shutdown` for a VM that is likely still running.
            let qemuStatus = try await StageBudget.run(
                seconds: StageBudget.statusQuerySeconds, stage: "qmp-status", onTimeout: .abandon
            ) {
                try await qemuManager.getStatus()
            }
            return Self.vmStatus(from: qemuStatus)
        } catch is StageBudgetError {
            logger.warning("VM status query timed out; reporting unknown", metadata: ["vmId": .string(vmId)])
            return .unknown
        } catch {
            logger.error("Failed to query VM status: \(error)")
            return .shutdown
        }
    }

    /// The single SwiftQEMU `QEMUVMStatus` → `VMStatus` mapping, shared by
    /// status queries and re-adoption so the two can never drift apart.
    static func vmStatus(from qemuStatus: QEMUVMStatus) -> VMStatus {
        switch qemuStatus {
        case .running:
            return .running
        case .paused:
            return .paused
        case .stopped, .shuttingDown:
            return .shutdown
        case .creating, .unknown:
            return .created
        }
    }

    func listVMs() async -> [String] {
        return Array(activeVMs.keys)
    }

    /// Run a hypervisor control-channel *command* under a time budget.
    ///
    /// Deliberately `.cancelAndWait`, not `.abandon`. These are commands, not
    /// reads: destroy, disk hot-plug, and the power-state transitions all
    /// mutate guest or host state, and the command is already on the wire when
    /// the budget expires. Abandoning one lets it land *after* the agent has
    /// reported failure and a retry has run — a late `destroy` completing after
    /// `deleteVM` threw leaves `activeVMs` pointing at a dead process, and a
    /// late `attach`/`detach` mutates a guest the agent has already re-planned
    /// around. Waiting for the unwind keeps "the agent gave up" and "the
    /// command took effect" from both being true.
    ///
    /// This terminates because the command itself is bounded a layer down:
    /// `QMPClient` gives every request its own deadline (samcat116/swift-qemu#8),
    /// so the operation returns an error rather than parking forever. The
    /// budget here is the outer belt-and-braces bound, and a stuck command is
    /// contained to its own VM's serial lane rather than the whole agent.
    private func controlled<T: Sendable>(
        _ stage: String,
        vmId: String,
        seconds: Int = StageBudget.hypervisorControlSeconds,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await StageBudget.run(
                seconds: seconds, stage: stage, onTimeout: .cancelAndWait, operation: operation)
        } catch let error as StageBudgetError {
            logger.error(
                "Hypervisor control call exceeded its budget",
                metadata: [
                    "vmId": .string(vmId),
                    "stage": .string(stage),
                ])
            throw HypervisorServiceError.timeout("\(stage) for VM \(vmId): \(error.localizedDescription)")
        }
    }

    // MARK: - Orphan Re-adoption (issue #260)

    /// The deterministic QMP socket every VM exposes for re-adoption.
    static func adoptionSocketPath(vmStoragePath: String, vmId: String) -> String {
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        return (vmDir as NSString).appendingPathComponent("qmp.sock")
    }

    // MARK: - QEMU guest agent (qga, issue #563)

    /// The deterministic QEMU-guest-agent socket every VM exposes. Derived only
    /// from vmStoragePath+vmId, so it works for re-adopted VMs too.
    static func qgaSocketPath(vmStoragePath: String, vmId: String) -> String {
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        return (vmDir as NSString).appendingPathComponent("qga.sock")
    }

    /// A `QGAClient` bound to `vmId`'s guest-agent socket, or nil when the
    /// socket does not exist yet (VM not running, or no qga channel). qga is
    /// unresponsive whenever the guest is not running the agent, so every call
    /// through the returned client must be bounded by a `StageBudget`.
    private func qgaClient(vmId: String) -> QGAClient? {
        let socketPath = Self.qgaSocketPath(vmStoragePath: vmStoragePath, vmId: vmId)
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let transport = NIOQGATransport(socketPath: socketPath, logger: logger)
        return QGAClient(transport: transport, logger: logger)
    }

    /// Asks the guest to power itself off through qga. Returns whether the guest
    /// agent actually answered (a *verified* shutdown initiation) — `false` when
    /// qga is absent or unresponsive within its short budget, which tells
    /// `shutdownVM` to fall back to the universal ACPI path.
    private func requestGuestShutdown(vmId: String) async -> Bool {
        guard let client = qgaClient(vmId: vmId) else { return false }
        do {
            try await StageBudget.run(
                seconds: StageBudget.guestAgentSeconds, stage: "qga-shutdown", onTimeout: .cancelAndWait
            ) {
                try await client.requestShutdown()
            }
            return true
        } catch {
            logger.debug(
                "Guest agent did not answer shutdown; falling back to ACPI",
                metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
            return false
        }
    }

    /// Freezes the attached guest's filesystems for an application-consistent
    /// snapshot. Returns whether a freeze was **attempted** against a responsive
    /// guest agent — the caller MUST `thawGuestFilesystems` whenever this is
    /// `true`, because `guest-fsfreeze-freeze` can leave the guest frozen even
    /// when its reply arrives *after* the budget (freezing flushes every guest
    /// filesystem and is legitimately slow under I/O load), and a frozen guest
    /// left un-thawed blocks all guest I/O. `false` (no qga socket, or the guest
    /// agent didn't answer a liveness ping) means nothing was frozen and the
    /// snapshot is crash-consistent — the pre-#563 behavior.
    func freezeGuestFilesystems(vmId: String) async -> Bool {
        guard let client = qgaClient(vmId: vmId) else { return false }

        // Confirm the guest agent is actually answering before freezing.
        // Otherwise a running-but-qga-less guest (its socket exists, but nothing
        // is listening) would pay a freeze-timeout *and* a thaw-timeout on every
        // snapshot. A ping is a quick sync round-trip.
        do {
            try await StageBudget.run(
                seconds: StageBudget.guestAgentSeconds, stage: "qga-ping", onTimeout: .cancelAndWait
            ) {
                try await client.ping()
            }
        } catch {
            logger.debug(
                "Guest agent not responding; snapshot will be crash-consistent",
                metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
            return false
        }

        // From here the guest may end up frozen even if the freeze reply is
        // late, so the caller must thaw regardless of the outcome below.
        do {
            let count = try await StageBudget.run(
                seconds: StageBudget.guestFreezeSeconds, stage: "qga-fsfreeze", onTimeout: .cancelAndWait
            ) {
                try await client.freezeFilesystems()
            }
            logger.info(
                "Froze guest filesystems for snapshot",
                metadata: ["vmId": .string(vmId), "frozen": .stringConvertible(count)])
        } catch {
            logger.warning(
                "Guest fs-freeze did not confirm within its budget; thawing regardless (snapshot may be crash-consistent)",
                metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
        }
        return true
    }

    /// Thaws the attached guest's filesystems after a snapshot. Safe (and
    /// intended) to call unconditionally once a freeze was attempted — a frozen
    /// guest is worse than a crash-consistent snapshot, and qga returns 0 when
    /// nothing is frozen — so a thaw failure is logged loudly.
    func thawGuestFilesystems(vmId: String) async {
        guard let client = qgaClient(vmId: vmId) else { return }
        do {
            let count = try await StageBudget.run(
                seconds: StageBudget.guestAgentSeconds, stage: "qga-fsthaw", onTimeout: .cancelAndWait
            ) {
                try await client.thawFilesystems()
            }
            logger.info(
                "Thawed guest filesystems after snapshot",
                metadata: ["vmId": .string(vmId), "thawed": .stringConvertible(count)])
        } catch {
            logger.error(
                "Guest fs-thaw failed; guest filesystems may remain frozen",
                metadata: ["vmId": .string(vmId), "error": .string(error.localizedDescription)])
        }
    }

    // MARK: - CPU/memory hot-add (issue #568)

    /// The QOM id of the hot-pluggable memory device, giving `qom-set` a
    /// deterministic `/machine/peripheral/<id>` path.
    static let virtioMemDeviceID = "memhp0"

    /// virtio-mem plugs memory in fixed-size blocks: the memory backend and
    /// every requested size must be a multiple of the device's block size,
    /// which QEMU derives from the guest's page size. Aligning to 512 MiB on
    /// arm64 — where 64 KiB-page guests push the block size that high — is
    /// safe on smaller-block hosts too, since block sizes are powers of two
    /// and a multiple of the larger is a multiple of the smaller.
    static var virtioMemBlockBytes: Int64 {
        #if arch(arm64)
        return 512 * 1024 * 1024
        #else
        return 2 * 1024 * 1024
        #endif
    }

    /// What a running QEMU process was spawned with, bounding what a resize
    /// can do to it without a restart.
    private struct SpawnSizing {
        let maxCpus: Int
        /// Boot memory: the floor a virtio-mem resize works up from, since
        /// only the hot-plugged region above it can be given back.
        let baseMemoryBytes: Int64
        /// Size of the hot-pluggable region, already block-aligned. Zero when
        /// the VM spawned without a virtio-mem device.
        let hotplugMemoryBytes: Int64

        var maxMemoryBytes: Int64 { baseMemoryBytes + hotplugMemoryBytes }
    }

    /// Adds the `-smp`/`-m` refinements and the virtio-mem device that make a
    /// VM resizable while it runs. No-op when the spec asks for no headroom.
    private func appendHotAddHeadroom(_ config: inout QEMUConfiguration, spec: VMSpec) {
        if spec.maxCpus > spec.cpus {
            // Restating `cpus` alongside `maxcpus` keeps the merged option set
            // unambiguous regardless of argument order.
            config.additionalArgs.append(contentsOf: [
                "-smp", "cpus=\(spec.cpus),maxcpus=\(spec.maxCpus)",
            ])
            logger.debug("Configuring vCPU hot-add headroom: \(spec.cpus) → \(spec.maxCpus)")
        }

        let hotplugBytes = Self.alignedHotplugMemory(spec: spec)
        guard hotplugBytes > 0 else { return }

        let maxMemoryMB = Int((spec.memoryBytes + hotplugBytes) / (1024 * 1024))
        // `slots` is the DIMM slot count, which QEMU requires alongside
        // `maxmem` even though virtio-mem consumes none of them.
        config.additionalArgs.append(contentsOf: [
            "-m", "\(config.memoryMB)M,slots=1,maxmem=\(maxMemoryMB)M",
            "-object", "memory-backend-ram,id=\(Self.virtioMemDeviceID)-backend,size=\(hotplugBytes)",
            "-device",
            "virtio-mem-pci,id=\(Self.virtioMemDeviceID),memdev=\(Self.virtioMemDeviceID)-backend,requested-size=0",
        ])
        logger.debug(
            "Configuring memory hot-add headroom: \(spec.memoryBytes) bytes + \(hotplugBytes) bytes virtio-mem")
    }

    /// The headroom a process spawned from `spec` actually carries — the same
    /// derivation `appendHotAddHeadroom` used to build its argument vector.
    private static func spawnSizing(for spec: VMSpec) -> SpawnSizing {
        SpawnSizing(
            maxCpus: max(spec.maxCpus, spec.cpus),
            baseMemoryBytes: spec.memoryBytes,
            hotplugMemoryBytes: alignedHotplugMemory(spec: spec))
    }

    /// The block-aligned hot-pluggable region a spec asks for, or 0 when the
    /// requested headroom is absent or smaller than a single virtio-mem block
    /// (in which case a device could never plug anything anyway).
    private static func alignedHotplugMemory(spec: VMSpec) -> Int64 {
        let requested = spec.maxMemoryBytes - spec.memoryBytes
        guard requested > 0 else { return 0 }
        return requested - (requested % virtioMemBlockBytes)
    }

    /// Converges a *running* VM's vCPU count and memory size on `spec`
    /// (issue #568), within the headroom its process was spawned with.
    ///
    /// Growth is applied online: vCPUs via `device_add` against the free
    /// hotplug slots, memory via the virtio-mem device's `requested-size`.
    /// Shrinking vCPUs is not attempted at all (guest support for unplug is
    /// unreliable) and memory shrinks only down to the boot size; either way
    /// the smaller figure takes effect at the next reboot, which is why this
    /// records `spec` as the VM's sizing regardless.
    ///
    /// Exceeding the spawned headroom is a permanent failure: no retry can
    /// widen a running process's `maxcpus`/`maxmem`.
    func resizeVM(vmId: String, spec: VMSpec) async throws {
        guard activeVMs[vmId] != nil, let sizing = vmSpawnSizing[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }
        let current = vmSpecs[vmId]

        guard spec.cpus <= sizing.maxCpus else {
            throw HypervisorServiceError.invalidConfiguration(
                "VM \(vmId) was started with maxcpus=\(sizing.maxCpus); "
                    + "growing to \(spec.cpus) vCPUs requires a restart")
        }
        guard spec.memoryBytes <= sizing.maxMemoryBytes else {
            throw HypervisorServiceError.invalidConfiguration(
                "VM \(vmId) was started with \(sizing.maxMemoryBytes) bytes of maximum memory; "
                    + "growing to \(spec.memoryBytes) bytes requires a restart")
        }

        if spec.cpus > (current?.cpus ?? spec.cpus) {
            let present = try await controlled("qmp-resize-cpus", vmId: vmId) {
                try await self.requireProbeClient(vmId: vmId).plugCPUs(target: spec.cpus)
            }
            logger.info(
                "Hot-added vCPUs",
                metadata: [
                    "vmId": .string(vmId),
                    "target": .stringConvertible(spec.cpus),
                    "present": .stringConvertible(present),
                ])
        } else if spec.cpus < (current?.cpus ?? spec.cpus) {
            logger.info(
                "vCPU shrink deferred to the next reboot; hot-remove is not attempted",
                metadata: ["vmId": .string(vmId), "target": .stringConvertible(spec.cpus)])
        }

        if spec.memoryBytes != current?.memoryBytes, sizing.hotplugMemoryBytes > 0 {
            // Only the region above boot memory is plug/unpluggable, and it
            // moves in whole blocks.
            let delta = max(spec.memoryBytes - sizing.baseMemoryBytes, 0)
            let requested = min(delta - (delta % Self.virtioMemBlockBytes), sizing.hotplugMemoryBytes)
            try await controlled("qmp-resize-memory", vmId: vmId) {
                try await self.requireProbeClient(vmId: vmId).setVirtioMemRequestedSize(
                    devicePath: "/machine/peripheral/\(Self.virtioMemDeviceID)", bytes: requested)
            }
            logger.info(
                "Requested virtio-mem resize",
                metadata: [
                    "vmId": .string(vmId),
                    "targetBytes": .stringConvertible(spec.memoryBytes),
                    "requestedSize": .stringConvertible(requested),
                ])
        } else if spec.memoryBytes != current?.memoryBytes {
            logger.info(
                "Memory resize deferred to the next reboot; VM has no virtio-mem device",
                metadata: ["vmId": .string(vmId), "targetBytes": .stringConvertible(spec.memoryBytes)])
        }

        vmSpecs[vmId] = spec
    }

    /// A probe client on the VM's dedicated stats monitor, which is also the
    /// only free QMP socket for hot-plug commands. Throws when the VM predates
    /// the socket (created before issue #567) rather than hanging on a connect.
    private func requireProbeClient(vmId: String) throws -> QMPProbeClient {
        let socketPath = Self.statsSocketPath(vmStoragePath: vmStoragePath, vmId: vmId)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw HypervisorServiceError.notSupported(
                "VM \(vmId) has no QMP stats monitor; restart it to pick up hot-plug support")
        }
        return QMPProbeClient(transport: NIOQGATransport(socketPath: socketPath, logger: logger), logger: logger)
    }

    // MARK: - Balloon memory stats (issue #567)

    /// The QOM id every VM's virtio-balloon device is attached under, giving
    /// the stats probe a deterministic `/machine/peripheral/<id>` path.
    static let balloonDeviceID = "balloon0"

    /// The deterministic QMP monitor socket dedicated to balloon-stats probes.
    /// A QMP server socket admits one client at a time, and the other two
    /// monitors are taken (QEMUManager holds its private one; re-adoption owns
    /// `qmp.sock`), so stats polling gets its own. Derived only from
    /// vmStoragePath+vmId, so it works for re-adopted VMs too.
    static func statsSocketPath(vmStoragePath: String, vmId: String) -> String {
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        return (vmDir as NSString).appendingPathComponent("qmp-stats.sock")
    }

    /// Polls the VM's balloon device for guest memory usage over the dedicated
    /// stats monitor. Returns nil for a VM this service does not manage, one
    /// without the stats socket (created before issue #567), one without the
    /// balloon device, or a guest whose virtio_balloon driver hasn't reported
    /// yet — all normal "no stats" outcomes, not errors.
    func memoryStats(vmId: String) async -> VMMemoryStats? {
        guard activeVMs[vmId] != nil else { return nil }
        let socketPath = Self.statsSocketPath(vmStoragePath: vmStoragePath, vmId: vmId)
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let transport = NIOQGATransport(socketPath: socketPath, logger: logger)
        let client = QMPProbeClient(transport: transport, logger: logger)
        do {
            return try await StageBudget.run(
                seconds: StageBudget.guestAgentSeconds, stage: "qmp-balloon-stats", onTimeout: .abandon
            ) {
                try await client.collectMemoryStats()
            }
        } catch {
            return nil
        }
    }

    /// Probes the guest agent for hostname and configured network interfaces.
    /// Returns nil for a VM this service does not manage, one with no qga
    /// socket, or a guest that did not answer within the short budget — all the
    /// normal "no usable qga" outcomes, not errors.
    func guestInfo(vmId: String) async -> GuestInfo? {
        guard activeVMs[vmId] != nil, let client = qgaClient(vmId: vmId) else { return nil }
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

    /// Re-adopts a VM whose QEMU process survived an agent restart by
    /// attaching to its deterministic QMP socket, and returns the observed
    /// status. Fails (leaving the VM orphaned) when the socket is missing —
    /// e.g. the VM predates deterministic sockets — or cannot be connected.
    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus {
        if activeVMs[vmId] != nil {
            // Already managed (e.g. a replayed sync raced re-adoption): adoption
            // is satisfied, just report the current status.
            return try await getVMStatus(vmId: vmId)
        }

        let socketPath = Self.adoptionSocketPath(vmStoragePath: vmStoragePath, vmId: vmId)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw HypervisorServiceError.adoptionTargetGone(
                "VM \(vmId) has no re-adoption QMP socket at \(socketPath) (created before deterministic sockets, or its process is gone)"
            )
        }

        logger.info(
            "Re-adopting orphaned QEMU VM",
            metadata: [
                "vmId": .string(vmId),
                "socket": .string(socketPath),
            ])

        let adopted = AdoptedQEMUVM(socketPath: socketPath, logger: logger)
        let qemuStatus: QEMUVMStatus
        do {
            // A stale socket can accept a connection and then never speak, in
            // which case the QMP greeting never arrives. Without a bound this
            // parks forever holding the reconcile lane (issue #516).
            qemuStatus = try await StageBudget.run(
                seconds: StageBudget.adoptionSeconds, stage: "qmp-adopt", onTimeout: .abandon
            ) {
                try await adopted.connect()
            }
        } catch is StageBudgetError {
            // Deliberately NOT `adoptionTargetGone`: that means "the process is
            // gone" and makes the caller re-create the VM from its manifest
            // spec. A timeout means the opposite — we could not tell either
            // way — and re-creating a VM whose QEMU is alive would materialize
            // over a running guest's disk. Report a transient timeout so the
            // next level-triggered sync retries adoption instead.
            logger.warning(
                "Re-adoption timed out; leaving the VM orphaned for the next sync",
                metadata: [
                    "vmId": .string(vmId),
                    "socket": .string(socketPath),
                ])
            throw HypervisorServiceError.timeout(
                "re-adopting VM \(vmId) over \(socketPath) exceeded \(StageBudget.adoptionSeconds)s")
        } catch {
            // A live QEMU always accepts connections on its QMP server socket,
            // so a refused/failed connect means the process is gone and the
            // socket file merely outlived it.
            throw HypervisorServiceError.adoptionTargetGone(
                "VM \(vmId) QMP socket at \(socketPath) is dead: \(error.localizedDescription)")
        }

        activeVMs[vmId] = adopted
        vmSpecs[vmId] = spec
        // The manifest spec is what the surviving process was spawned from,
        // so its headroom is the re-adopted VM's headroom too.
        vmSpawnSizing[vmId] = Self.spawnSizing(for: spec)

        return Self.vmStatus(from: qemuStatus)
    }

    /// Sum of vCPUs and memory (in bytes) reserved by all VMs this service is managing.
    /// Used to compute accurate available-resource figures for the scheduler.
    /// (VMs orphaned by an agent restart are accounted for by the Agent, which owns
    /// the durable manifest they are recovered from.)
    func reservedResources() -> (vcpus: Int, memoryBytes: Int64) {
        var vcpus = 0
        var memoryBytes: Int64 = 0
        for spec in vmSpecs.values {
            vcpus += spec.cpus
            memoryBytes += spec.memoryBytes
        }
        return (vcpus, memoryBytes)
    }

    // MARK: - Disk Hot-Plug Operations (Volume Support)

    /// Attaches a disk to a running VM using QMP hot-plug
    /// This uses QEMU's blockdev-add and device_add commands via SwiftQEMU
    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool = false)
        async throws
    {
        guard let manager = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info(
            "Attaching disk to VM via QMP hot-plug",
            metadata: [
                "vmId": .string(vmId),
                "volumeId": .string(volumeId),
                "deviceName": .string(deviceName),
                "volumePath": .string(volumePath),
                "readonly": .stringConvertible(readonly),
            ])

        do {
            try await controlled("qmp-attach-disk", vmId: vmId) {
                try await manager.attachDisk(path: volumePath, deviceName: deviceName, readOnly: readonly)
            }
            logger.info(
                "Disk attached successfully",
                metadata: [
                    "vmId": .string(vmId),
                    "volumeId": .string(volumeId),
                    "deviceName": .string(deviceName),
                ])
        } catch {
            logger.error(
                "Failed to attach disk via QMP hot-plug",
                metadata: [
                    "vmId": .string(vmId),
                    "volumeId": .string(volumeId),
                    "error": .string(String(describing: error)),
                ])
            throw QEMUServiceError.hotPlugFailed("Failed to attach disk: \(error)")
        }
    }

    /// Detaches a disk from a running VM using QMP hot-unplug
    /// This uses QEMU's device_del and blockdev-del commands via SwiftQEMU
    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        guard let manager = activeVMs[vmId] else {
            throw QEMUServiceError.vmNotFound("VM \(vmId) not found")
        }

        logger.info(
            "Detaching disk from VM via QMP hot-unplug",
            metadata: [
                "vmId": .string(vmId),
                "volumeId": .string(volumeId),
                "deviceName": .string(deviceName),
            ])

        do {
            try await controlled("qmp-detach-disk", vmId: vmId) {
                try await manager.detachDisk(deviceName: deviceName)
            }
            logger.info(
                "Disk detached successfully",
                metadata: [
                    "vmId": .string(vmId),
                    "volumeId": .string(volumeId),
                    "deviceName": .string(deviceName),
                ])
        } catch {
            logger.error(
                "Failed to detach disk via QMP hot-unplug",
                metadata: [
                    "vmId": .string(vmId),
                    "volumeId": .string(volumeId),
                    "error": .string(String(describing: error)),
                ])
            throw QEMUServiceError.hotPlugFailed("Failed to detach disk: \(error)")
        }
    }

    // MARK: - Private Configuration Methods

    // MARK: - Firmware and NVRAM (issue #565)

    /// The VM's persistent UEFI variable store. Copied from the firmware set's
    /// VARS template on first boot and kept thereafter, so boot entries the
    /// guest writes — and Secure Boot keys it enrolls — survive a respawn.
    static func nvramPath(vmStoragePath: String, vmId: String) -> String {
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        return (vmDir as NSString).appendingPathComponent("nvram.fd")
    }

    /// Copies the VARS template into the VM's directory if the VM has no
    /// variable store yet, and returns its path.
    ///
    /// Deliberately copy-if-absent rather than copy-always: overwriting on
    /// every respawn is exactly the bug the pflash layout exists to fix — it
    /// would reset the guest's boot order and wipe enrolled Secure Boot keys.
    /// An existing VM gains its NVRAM file the first time it respawns under
    /// this code.
    private func ensureNVRAM(vmId: String, from template: String) throws -> String {
        let path = Self.nvramPath(vmStoragePath: vmStoragePath, vmId: vmId)
        guard !FileManager.default.fileExists(atPath: path) else { return path }
        do {
            try FileManager.default.copyItem(atPath: template, toPath: path)
        } catch {
            throw QEMUServiceError.configurationError(
                "failed to initialize UEFI variable store for VM \(vmId) from \(template): "
                    + error.localizedDescription)
        }
        logger.info(
            "Initialized UEFI variable store",
            metadata: ["vmId": .string(vmId), "nvram": .string(path), "template": .string(template)])
        return path
    }

    /// A disk realized on this host: the agent-resolved path plus attach options.
    private struct ResolvedDisk {
        let path: String
        let format: DiskFormat
        let readonly: Bool
    }

    private func convertToQEMUConfiguration(
        _ spec: VMSpec, disks: [ResolvedDisk], networkAttachments: [ResolvedNetworkAttachment], vmId: String
    ) async throws
        -> QEMUConfiguration
    {
        var qemuConfig = QEMUConfiguration()
        let machine = spec.effectiveMachine

        // The VM directory holds the NVRAM store, the TPM state, and every
        // socket below, so it must exist before any of them are resolved. It
        // usually already does (disk materialization created it).
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: vmDir) {
            do {
                try fileManager.createDirectory(atPath: vmDir, withIntermediateDirectories: true, attributes: nil)
                logger.debug("Created VM directory: \(vmDir)")
            } catch {
                throw QEMUServiceError.configurationError(
                    "failed to create VM directory \(vmDir): \(error.localizedDescription)")
            }
        }

        // Determine boot mode: direct kernel boot or UEFI firmware boot
        let kernelBoot: (kernel: String, initramfs: String?, cmdline: String?)?
        // Per-VM firmware override from the spec (`self.firmware` is the
        // agent's own configuration).
        let specFirmware: String?
        switch spec.boot {
        case .directKernel(let kernel, let initramfs, let cmdline):
            kernelBoot = (kernel, initramfs, cmdline)
            specFirmware = nil
        case .disk(let perVMFirmware):
            kernelBoot = nil
            specFirmware = perVMFirmware
        }

        // Select the CPU model. `host` passes the physical CPU through and is
        // only valid with a hardware accelerator (KVM/HVF); QEMU rejects it under
        // TCG ("CPU model 'host' requires KVM or HVF"). When acceleration is
        // disabled we fall back to `max`, a TCG-safe model that exposes the most
        // features the emulator can provide.
        let cpuType = hardwareAccelerationEnabled ? "host" : "max"

        // Configure machine type based on architecture and boot mode.
        //
        // Secure Boot on x86 additionally needs SMM: the signed OVMF build
        // keeps the authenticated variable store writable only from System
        // Management Mode, so without `smm=on` the firmware cannot protect
        // `db`/`dbx` and Secure Boot is not actually enforced. ARM's `virt`
        // machine has no SMM and needs no equivalent.
        #if arch(arm64)
        // For ARM64 UEFI boot, we need gic-version=3 for EDK2 firmware compatibility
        qemuConfig.machineType = kernelBoot != nil ? "virt" : "virt,gic-version=3"
        qemuConfig.cpuType = cpuType
        logger.debug("Configuring ARM64 machine type: \(qemuConfig.machineType), cpu: \(cpuType)")
        #else
        qemuConfig.machineType = machine.secureBoot ? "q35,smm=on" : "q35"
        qemuConfig.cpuType = cpuType
        logger.debug("Configuring x86_64 machine type: \(qemuConfig.machineType), cpu: \(cpuType)")
        #endif

        // Configure CPU
        qemuConfig.cpuCount = spec.cpus
        logger.debug("Configuring CPU: \(spec.cpus) cores")

        // Configure Memory (convert bytes to MB)
        qemuConfig.memoryMB = Int(spec.memoryBytes / (1024 * 1024))
        logger.debug("Configuring memory: \(spec.memoryBytes) bytes (\(qemuConfig.memoryMB) MB)")

        // Hot-add headroom (issue #568). Both `-smp` and `-m` are merge-list
        // options in QEMU, so re-stating them here refines the bare
        // `-smp <n>` / `-m <mb>` SwiftQEMU emits rather than conflicting with
        // it. Only emitted when the spec actually asks for headroom: a VM
        // sized `maxCpus == cpus` and `maxMemoryBytes == memoryBytes` spawns
        // with exactly the argument vector it did before this feature, so the
        // overwhelmingly common case carries none of its risk.
        appendHotAddHeadroom(&qemuConfig, spec: spec)

        // Configure disks
        qemuConfig.disks = disks.map { disk in
            QEMUDisk(
                path: disk.path,
                format: disk.format.rawValue,
                interface: "virtio",
                readonly: disk.readonly
            )
        }

        // Configure networking: translate each resolved attachment into its
        // QEMU netdev form. The typed descriptor replaces the old
        // `tapInterface != "n/a"` sentinel branching.
        qemuConfig.networks = networkAttachments.map { nic in
            switch nic.attachment {
            case .tap(let interface):
                return QEMUNetwork(
                    backend: "tap",
                    model: "virtio-net-pci",
                    macAddress: nic.macAddress,
                    options: "ifname=\(interface),script=no,downscript=no"
                )
            case .userMode:
                return QEMUNetwork(
                    backend: "user",
                    model: "virtio-net-pci",
                    macAddress: nic.macAddress
                )
            }
        }

        // Configure boot mode: direct kernel boot or UEFI firmware boot
        if let kernelBoot {
            // Direct kernel boot
            qemuConfig.kernel = kernelBoot.kernel
            qemuConfig.initrd = kernelBoot.initramfs
            // Ensure serial console is in kernel args
            var cmdline = kernelBoot.cmdline ?? ""
            let consoleArgs = [
                "console=tty0",
                "console=ttyS0,115200",
                "console=ttyAMA0,115200",
                "console=hvc0",
            ]
            if cmdline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cmdline = consoleArgs.joined(separator: " ")
            } else {
                for arg in consoleArgs {
                    if !cmdline.contains(arg) {
                        cmdline.append(" \(arg)")
                    }
                }
            }
            qemuConfig.kernelArgs = cmdline
            logger.info(
                "Direct kernel boot configured",
                metadata: [
                    "kernel": .string(kernelBoot.kernel),
                    "cmdline": .string(cmdline),
                ])
        } else {
            // UEFI firmware boot (disk-based). The split CODE/VARS pair is
            // preferred over `-bios`: it gives the VM a writable variable store
            // that persists across respawns (issue #565), which UEFI boot
            // entries need on any guest and Secure Boot key enrollment needs on
            // Windows.
            let firmwareSet = try FirmwareResolver.resolve(
                secureBoot: machine.secureBoot,
                perVMPath: specFirmware,
                overrides: self.firmware)

            switch firmwareSet {
            case .pflash(let code, let varsTemplate):
                let nvram = try ensureNVRAM(vmId: vmId, from: varsTemplate)
                qemuConfig.additionalArgs.append(contentsOf: [
                    "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(code)",
                    "-drive", "if=pflash,format=raw,unit=1,file=\(nvram)",
                ])
                #if !arch(arm64)
                if machine.secureBoot {
                    // Pairs with `smm=on`: marks the varstore pflash as
                    // SMM-only, which is what stops a compromised guest from
                    // rewriting the Secure Boot databases.
                    qemuConfig.additionalArgs.append(contentsOf: [
                        "-global", "driver=cfi.pflash01,property=secure,value=on",
                    ])
                }
                #endif
                logger.info(
                    "UEFI firmware boot configured (pflash)",
                    metadata: [
                        "code": .string(code),
                        "nvram": .string(nvram),
                        "secureBoot": .stringConvertible(machine.secureBoot),
                        "vmId": .string(vmId),
                    ])
            case .monolithic(let path):
                // Legacy fallback: no writable varstore, so the guest's UEFI
                // variables reset on every respawn. Warned about rather than
                // silent, since it is a real (if pre-existing) limitation.
                qemuConfig.additionalArgs.append(contentsOf: ["-bios", path])
                logger.warning(
                    """
                    UEFI firmware boot configured with a monolithic image; the guest's UEFI variables \
                    (boot entries) will not persist across restarts. Install the split EDK2 build \
                    or set firmware_code_path/firmware_vars_template.
                    """,
                    metadata: [
                        "firmware": .string(path),
                        "vmId": .string(vmId),
                    ])
            }
        }

        // Emulated TPM 2.0 (issue #565). swtpm runs as a separate host process
        // holding the TPM's persistent state; QEMU talks to it over the control
        // socket. Started before QEMU and torn down in `deleteVM`.
        if machine.tpm {
            guard let swtpm else {
                throw QEMUServiceError.configurationError(
                    "VM \(vmId) requires a TPM 2.0 but this host has no swtpm binary. The agent does not "
                        + "advertise the TPM capability, so this VM should not have been placed here; install "
                        + "swtpm (Debian/Ubuntu: `apt install swtpm swtpm-tools`) or set swtpm_binary_path.")
            }
            let socketPath = try await swtpm.ensureRunning(vmDirectory: vmDir, vmId: vmId)
            // `tpm-tis` is the x86 TIS device; the ARM `virt` machine has no
            // ISA/LPC bus, so it takes the MMIO variant instead.
            #if arch(arm64)
            let tpmDevice = "tpm-tis-device"
            #else
            let tpmDevice = "tpm-tis"
            #endif
            qemuConfig.additionalArgs.append(contentsOf: [
                "-chardev", "socket,id=chrtpm,path=\(socketPath)",
                "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                "-device", "\(tpmDevice),tpmdev=tpm0",
            ])
            logger.info(
                "vTPM configured", metadata: ["vmId": .string(vmId), "swtpmSocket": .string(socketPath)])
        }

        // Enable hardware acceleration based on platform and the operator's
        // `enable_kvm`/`enable_hvf` preference. When disabled, QEMU falls back
        // to TCG emulation (slow, but useful for dev/test on unaccelerated hosts).
        #if os(Linux)
        // KVM on Linux
        qemuConfig.enableKVM = hardwareAccelerationEnabled
        if hardwareAccelerationEnabled {
            logger.debug("Enabling KVM acceleration")
        } else {
            logger.info("KVM acceleration disabled by configuration (enable_kvm=false); using TCG emulation")
        }
        #elseif os(macOS)
        // KVM is never available on macOS; Hypervisor.framework (HVF) is the accelerator.
        qemuConfig.enableKVM = false
        if hardwareAccelerationEnabled {
            qemuConfig.additionalArgs.append(contentsOf: ["-accel", "hvf"])
            logger.debug("Enabling Hypervisor.framework (HVF) acceleration")
        } else {
            logger.info("HVF acceleration disabled by configuration (enable_hvf=false); using TCG emulation")
        }
        #endif

        qemuConfig.noGraphic = true
        // Honor the create contract (`ReconcileStep.create`: ends "exists, not
        // running"): spawn with CPUs frozen (-S) and let bootVM issue the QMP
        // `cont`. Spawning live booted every fresh VM once, and the next
        // periodic sync shut it down again — the desired state for a new VM is
        // `shutdown` until it is explicitly started (issue #260).
        qemuConfig.startPaused = true

        // Configure virtio-console for VM console streaming
        // Use the VM's storage directory for the socket (user-writable)
        let consoleSocketPath = (vmDir as NSString).appendingPathComponent("console.sock")

        // Add virtio-serial device and virtconsole
        qemuConfig.additionalArgs.append(contentsOf: [
            "-device", "virtio-serial-pci,id=virtio-serial0",
            "-chardev", "socket,id=console0,path=\(consoleSocketPath),server=on,wait=off",
            "-device", "virtconsole,chardev=console0,id=virtconsole0",
        ])

        // QEMU guest agent channel on the same virtio-serial bus (issue #563).
        // The well-known port name `org.qemu.guest_agent.0` is where qga inside
        // the guest binds; the host end is a deterministic unix socket the agent
        // reconnects to for verified shutdown, fs-freeze snapshots, and guest IP
        // reporting — including for VMs re-adopted after an agent restart, since
        // the path derives only from vmStoragePath+vmId.
        let qgaSocketPath = Self.qgaSocketPath(vmStoragePath: vmStoragePath, vmId: vmId)
        try? FileManager.default.removeItem(atPath: qgaSocketPath)  // stale socket from a dead process
        qemuConfig.additionalArgs.append(contentsOf: [
            "-chardev", "socket,id=qga0,path=\(qgaSocketPath),server=on,wait=off",
            "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
        ])

        // Second QMP monitor at a deterministic path. QEMUManager's own QMP
        // socket lives at a random /tmp path that dies with this process's
        // memory, so orphan re-adoption after an agent restart reattaches via
        // this one instead (see AdoptedQEMUVM). QEMU supports multiple -qmp
        // monitors.
        let adoptionSocketPath = Self.adoptionSocketPath(vmStoragePath: vmStoragePath, vmId: vmId)
        try? FileManager.default.removeItem(atPath: adoptionSocketPath)  // stale socket from a dead process
        qemuConfig.additionalArgs.append(contentsOf: [
            "-qmp", "unix:\(adoptionSocketPath),server,wait=off",
        ])

        // virtio-balloon with free-page hinting (issue #567). Attached
        // unconditionally: the device is inert until a guest driver binds it,
        // and once one does, free-page hinting lets the host drop guest-freed
        // pages (shrinking host RSS) while `guest-stats` gives the agent real
        // memory usage to report. `deflate-on-oom` stays at its default (off).
        qemuConfig.additionalArgs.append(contentsOf: [
            "-device", "virtio-balloon-pci,id=\(Self.balloonDeviceID),free-page-hint=on",
        ])

        // Third QMP monitor, dedicated to balloon-stats probes (issue #567):
        // each QMP server socket admits one client at a time, and the two
        // above are taken by lifecycle control and re-adoption respectively.
        let statsSocketPath = Self.statsSocketPath(vmStoragePath: vmStoragePath, vmId: vmId)
        try? FileManager.default.removeItem(atPath: statsSocketPath)  // stale socket from a dead process
        qemuConfig.additionalArgs.append(contentsOf: [
            "-qmp", "unix:\(statsSocketPath),server,wait=off",
        ])

        // Store the socket path for later access
        vmConsoleSocketPaths[vmId] = consoleSocketPath
        logger.debug("Configured virtio-console socket at: \(consoleSocketPath)")

        // For disk-based boot, create cloud-init ISO to configure serial console
        // (and static NIC addressing when the control plane allocated it).
        // Cloud-init allows configuring the guest without modifying the disk image
        let cloudInitISOPath = (vmDir as NSString).appendingPathComponent("cloud-init.iso")
        if await CloudInitProvisioner(logger: logger).makeNoCloudISO(
            at: cloudInitISOPath, vmId: vmId, sshAuthorizedKeys: spec.sshAuthorizedKeys,
            userData: spec.userData,
            networkAttachments: networkAttachments)
        {
            qemuConfig.additionalArgs.append(contentsOf: [
                "-drive", "file=\(cloudInitISOPath),format=raw,if=virtio,readonly=on",
            ])
            logger.info("Cloud-init ISO attached for serial console configuration")
        }

        // Configure serial console socket (most Linux distros output to ttyS0 by default)
        let serialSocketPath = (vmDir as NSString).appendingPathComponent("serial.sock")
        qemuConfig.additionalArgs.append(contentsOf: [
            "-serial", "unix:\(serialSocketPath),server,nowait",
        ])
        vmSerialSocketPaths[vmId] = serialSocketPath
        logger.debug("Configured serial console socket at: \(serialSocketPath)")

        return qemuConfig
    }

}

// MARK: - QEMU Service Error Types

enum QEMUServiceError: Error, LocalizedError, Sendable {
    case vmNotFound(String)
    case vmNotCreated(String)
    case kvmNotAvailable
    case qemuNotInstalled
    case configurationError(String)
    case diskCreationFailed(String)
    case hotPlugFailed(String)

    var errorDescription: String? {
        switch self {
        case .vmNotFound(let message):
            return "QEMU VM not found: \(message)"
        case .vmNotCreated(let id):
            return "QEMU VM with ID \(id) is not created yet"
        case .kvmNotAvailable:
            return "KVM hardware virtualization is not available"
        case .qemuNotInstalled:
            return "QEMU is not installed on this system"
        case .configurationError(let message):
            return "QEMU configuration error: \(message)"
        case .diskCreationFailed(let message):
            return "Disk creation failed: \(message)"
        case .hotPlugFailed(let message):
            return "Hot-plug operation failed: \(message)"
        }
    }
}
#endif
