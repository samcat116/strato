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
    private let configuredFirmwarePath: String?
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
    private var vmConsoleSocketPaths: [String: String] = [:]
    private var vmSerialSocketPaths: [String: String] = [:]
    private var pendingVMs: Set<String> = []  // Track VMs being created (to handle concurrent boot requests)

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil, vmStoragePath: String, qemuBinaryPath: String,
        firmwarePath: String? = nil, hardwareAccelerationEnabled: Bool = true
    ) {
        self.logger = logger
        self.storage = storage
        self.vmStoragePath = vmStoragePath
        self.qemuBinaryPath = qemuBinaryPath
        self.configuredFirmwarePath = firmwarePath
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
        let qemuConfig = await convertToQEMUConfiguration(
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

        // Graceful shutdown. Longer budget than the other control calls: the
        // adopted-VM path polls for up to 30s before forcing termination.
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

        // Clean up VM resources
        activeVMs.removeValue(forKey: vmId)
        vmSpecs.removeValue(forKey: vmId)
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

    /// Resolves the UEFI firmware path for the current architecture
    /// Priority: 1) Explicit per-VM firmware path, 2) Agent config file path, 3) Platform default
    /// Returns nil if no firmware is found
    private func resolveFirmwarePath(_ explicitPath: String?) -> String? {
        // 1. If explicit per-VM path provided, validate and return it
        if let path = explicitPath, !path.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                logger.debug("Using explicit per-VM firmware path: \(path)")
                return path
            }
            logger.warning("Specified per-VM firmware path does not exist: \(path), trying config file setting")
        }

        // 2. Check agent config file setting
        if let path = configuredFirmwarePath, !path.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                logger.debug("Using firmware path from config file: \(path)")
                return path
            }
            logger.warning("Config file firmware path does not exist: \(path), trying platform defaults")
        }

        // 3. Use architecture-specific platform default
        #if arch(arm64)
        let defaultPath = AgentConfig.defaultFirmwarePathARM64
        #else
        let defaultPath = AgentConfig.defaultFirmwarePathX86_64
        #endif

        guard let path = defaultPath else {
            logger.warning("No UEFI firmware found for this platform/architecture")
            return nil
        }

        logger.debug("Using platform default firmware path: \(path)")
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
    ) async
        -> QEMUConfiguration
    {
        var qemuConfig = QEMUConfiguration()

        // Determine boot mode: direct kernel boot or UEFI firmware boot
        let kernelBoot: (kernel: String, initramfs: String?, cmdline: String?)?
        let firmware: String?
        switch spec.boot {
        case .directKernel(let kernel, let initramfs, let cmdline):
            kernelBoot = (kernel, initramfs, cmdline)
            firmware = nil
        case .disk(let specFirmware):
            kernelBoot = nil
            firmware = specFirmware
        }

        // Select the CPU model. `host` passes the physical CPU through and is
        // only valid with a hardware accelerator (KVM/HVF); QEMU rejects it under
        // TCG ("CPU model 'host' requires KVM or HVF"). When acceleration is
        // disabled we fall back to `max`, a TCG-safe model that exposes the most
        // features the emulator can provide.
        let cpuType = hardwareAccelerationEnabled ? "host" : "max"

        // Configure machine type based on architecture and boot mode
        #if arch(arm64)
        // For ARM64 UEFI boot, we need gic-version=3 for EDK2 firmware compatibility
        qemuConfig.machineType = kernelBoot != nil ? "virt" : "virt,gic-version=3"
        qemuConfig.cpuType = cpuType
        logger.debug("Configuring ARM64 machine type: \(qemuConfig.machineType), cpu: \(cpuType)")
        #else
        qemuConfig.machineType = "q35"
        qemuConfig.cpuType = cpuType
        logger.debug("Configuring x86_64 machine type: q35, cpu: \(cpuType)")
        #endif

        // Configure CPU
        qemuConfig.cpuCount = spec.cpus
        logger.debug("Configuring CPU: \(spec.cpus) cores")

        // Configure Memory (convert bytes to MB)
        qemuConfig.memoryMB = Int(spec.memoryBytes / (1024 * 1024))
        logger.debug("Configuring memory: \(spec.memoryBytes) bytes (\(qemuConfig.memoryMB) MB)")

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
            // UEFI firmware boot (disk-based)
            // Resolve firmware path: explicit config > platform default
            if let firmwarePath = resolveFirmwarePath(firmware) {
                qemuConfig.additionalArgs.append(contentsOf: ["-bios", firmwarePath])
                logger.info(
                    "UEFI firmware boot configured",
                    metadata: [
                        "firmware": .string(firmwarePath),
                        "vmId": .string(vmId),
                    ])
            } else {
                // No firmware found - VM may fail to boot without UEFI firmware on ARM64
                logger.warning(
                    "No UEFI firmware configured - VM may fail to boot on ARM64",
                    metadata: [
                        "vmId": .string(vmId)
                    ])
            }
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
        let vmDir = (vmStoragePath as NSString).appendingPathComponent(vmId)
        let consoleSocketPath = (vmDir as NSString).appendingPathComponent("console.sock")

        // Create VM directory if it doesn't exist (should already exist from disk creation)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: vmDir) {
            do {
                try fileManager.createDirectory(atPath: vmDir, withIntermediateDirectories: true, attributes: nil)
                logger.debug("Created VM directory for console socket: \(vmDir)")
            } catch {
                logger.warning("Failed to create VM directory for console socket: \(error)")
            }
        }

        // Add virtio-serial device and virtconsole
        qemuConfig.additionalArgs.append(contentsOf: [
            "-device", "virtio-serial-pci,id=virtio-serial0",
            "-chardev", "socket,id=console0,path=\(consoleSocketPath),server=on,wait=off",
            "-device", "virtconsole,chardev=console0,id=virtconsole0",
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
