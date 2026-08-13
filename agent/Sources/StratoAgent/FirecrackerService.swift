import Foundation
import Logging
import StratoAgentCore
import StratoShared

#if os(Linux)
import SwiftFirecracker

/// Service for managing Firecracker microVMs on Linux
/// Implements HypervisorService protocol for consistent VM lifecycle management
actor FirecrackerService: HypervisorService {
    private let logger: Logger
    private let storage: (any StorageBackend)?
    private let imageSource: (any ImageSource)?
    private let vmStoragePath: String
    private let firecrackerBinaryPath: String
    private let socketDirectory: String
    /// Reads the generation-guarded metadata record at the instant MMDS is
    /// seeded. Nil in standalone tests, where createVM's argument is used.
    private let metadataProvider: (@Sendable (UUID) async -> InstanceMetadata?)?

    // HypervisorService protocol requirement
    public let hypervisorType: HypervisorType = .firecracker

    // Track running VMs
    private var firecrackerClient: FirecrackerClient?
    private var vmManagers: [String: FirecrackerManager] = [:]
    private var vmSpecs: [String: VMSpec] = [:]
    /// Exact pre-boot MMDS interface policy installed in each managed VMM.
    /// The VM-level metadata switch participates in this list even though it
    /// does not live in `VMSpec.networks`.
    private var mmdsInterfaces: [String: [String]] = [:]
    /// Last successfully installed MMDS snapshot. Avoids rewriting the VMM's
    /// store on every level-triggered sync when the document did not change.
    private var mmdsPayloads: [String: Data] = [:]

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil,
        imageSource: (any ImageSource)? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker",
        firecrackerClient: FirecrackerClient? = nil,
        metadataProvider: (@Sendable (UUID) async -> InstanceMetadata?)? = nil
    ) {
        self.logger = logger
        self.storage = storage
        self.imageSource = imageSource
        self.vmStoragePath = vmStoragePath
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.socketDirectory = socketDirectory
        self.metadataProvider = metadataProvider
        // A shared client (created by the Agent) lets VMs and sandboxes drive
        // Firecracker through one process registry and socket directory; when
        // absent (e.g. tests) it is created lazily on first use.
        self.firecrackerClient = firecrackerClient

        logger.info(
            "Firecracker service initialized",
            metadata: [
                "binaryPath": "\(firecrackerBinaryPath)",
                "socketDirectory": "\(socketDirectory)",
            ])
    }

    // MARK: - HypervisorService Protocol Implementation

    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil,
        networkAttachments: [ResolvedNetworkAttachment] = [],
        metadata: InstanceMetadata? = nil,
        // Firecracker's guest CID is private to its own process and its host
        // transport is a UDS, so it never consumes this host-global lease.
        vsockCID: UInt32? = nil
    ) async throws {
        let bootArtifacts = try await resolveBootArtifacts(spec: spec, imageInfo: imageInfo)
        try await createVM(
            vmId: vmId, spec: spec, bootArtifacts: bootArtifacts,
            networkAttachments: networkAttachments, metadata: metadata)
    }

    private func createVM(
        vmId: String, spec: VMSpec, bootArtifacts: FirecrackerBootArtifacts,
        networkAttachments: [ResolvedNetworkAttachment], metadata: InstanceMetadata?
    ) async throws {
        logger.info("Creating Firecracker VM", metadata: ["vmId": .string(vmId)])

        // Firecracker can only realize TAP attachments. Reject anything else up
        // front instead of silently launching the VM without its NICs.
        for nic in networkAttachments {
            guard case .tap = nic.attachment else {
                throw HypervisorServiceError.notSupported(
                    "Firecracker only supports tap network attachments; got \(nic.attachment) "
                        + "for network \(nic.network)")
            }
        }

        // Initialize client if needed
        if firecrackerClient == nil {
            firecrackerClient = FirecrackerClient(
                firecrackerBinaryPath: firecrackerBinaryPath,
                socketDirectory: socketDirectory,
                logger: logger
            )
        }

        guard let client = firecrackerClient else {
            throw HypervisorServiceError.hypervisorNotInstalled(firecrackerBinaryPath)
        }

        // The root filesystem is always the canonical managed boot volume. Its
        // image bytes are materialized by the volume reconciler; this driver
        // fetches only the direct-kernel artifacts it consumes itself.
        guard let bootVolume = spec.volumes.first(where: { $0.bootOrder == 0 }),
            let bootPath = bootVolume.storagePath
        else {
            throw HypervisorServiceError.invalidConfiguration(
                "Firecracker VM \(vmId) has no realized managed boot volume")
        }
        guard FileManager.default.fileExists(atPath: bootPath) else {
            throw HypervisorServiceError.diskError(
                "boot volume \(bootVolume.volumeId) for VM \(vmId) has no file at \(bootPath) on this host")
        }
        let rootDrive = (
            id: bootVolume.volumeId.uuidString, path: bootPath, readOnly: bootVolume.readonly
        )

        // MMDS carries the complete cloud-init document. Firecracker's 50 KiB
        // default API limit is smaller than Strato's accepted user data before
        // the surrounding EC2 tree is added, so raise this VMM's finite limit
        // before any API request can seed or later refresh the snapshot.
        let manager = try await client.createVM(
            vmId: vmId,
            httpAPIMaxPayloadSize: FirecrackerMMDSInterfacePlan.payloadLimitBytes)

        do {
            // Configure machine
            let machineConfig = MachineConfig(
                vcpuCount: spec.cpus,
                memSizeMib: Int(spec.memoryBytes / (1024 * 1024))
            )
            try await manager.configureMachine(machineConfig)

            // Configure boot source (qualified: StratoShared also declares a BootSource)
            let bootSource = SwiftFirecracker.BootSource(
                kernelImagePath: bootArtifacts.kernelPath,
                initrdPath: bootArtifacts.initramfsPath,
                bootArgs: bootArtifacts.cmdline ?? "console=ttyS0 reboot=k panic=1 pci=off"
            )
            try await manager.configureBootSource(bootSource)

            let drive = Drive.rootDrive(
                id: rootDrive.id,
                path: rootDrive.path,
                readOnly: rootDrive.readOnly
            )
            try await manager.configureDrive(drive)

            // Configure networking: one interface per resolved attachment (validated
            // above to be .tap)
            for (index, nic) in networkAttachments.enumerated() {
                guard case .tap(let tapName) = nic.attachment else { continue }
                let networkInterface = NetworkInterface.tap(
                    id: "eth\(index)",
                    tapName: tapName,
                    macAddress: nic.macAddress ?? ""
                )
                try await manager.configureNetwork(networkInterface)
            }

            // MMDS configuration is pre-boot state. Each Firecracker NIC must be
            // opted in explicitly; a VM may therefore expose metadata through one
            // interface while keeping another unable to reach the service. Seed
            // the EC2-shaped snapshot before `bootVM` starts the guest so cloud-init
            // cannot race the agent's first desired-state refresh.
            let configuredMMDSInterfaces = FirecrackerMMDSInterfacePlan.interfaceIDs(
                for: networkAttachments,
                metadataServiceEnabled: metadata?.isServiceEnabled ?? false)
            if !configuredMMDSInterfaces.isEmpty {
                try await manager.configureMMDS(
                    MMDSConfig(version: .v2, networkInterfaces: configuredMMDSInterfaces))
                // The desired item that scheduled this create can be an older
                // replay while MetadataStore already holds a newer generation.
                // Read through its guard at the last possible moment instead of
                // installing the replay's copy into the new VMM.
                let guardedMetadata: InstanceMetadata?
                if let metadataProvider, let id = UUID(uuidString: vmId) {
                    guardedMetadata = await metadataProvider(id)
                } else {
                    guardedMetadata = metadata
                }
                let payload = try Self.mmdsPayload(for: guardedMetadata)
                try await manager.setMMDSData(rawJSON: payload)
                mmdsPayloads[vmId] = payload
            }

            // Publish the manager only after every pre-boot API call succeeds.
            vmManagers[vmId] = manager
            vmSpecs[vmId] = spec
            mmdsInterfaces[vmId] = configuredMMDSInterfaces
        } catch {
            // `FirecrackerClient.createVM` has already spawned and registered
            // the process. No caller can clean it up through this service yet,
            // because the manager is intentionally unpublished until the full
            // configuration succeeds.
            await discardPartialVMM(vmId: vmId, client: client)
            throw error
        }

        logger.info("Firecracker VM created successfully", metadata: ["vmId": .string(vmId)])
    }

    func bootVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Booting Firecracker VM", metadata: ["vmId": .string(vmId)])
        try await manager.start()
        logger.info("Firecracker VM booted successfully", metadata: ["vmId": .string(vmId)])
    }

    func shutdownVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Shutting down Firecracker VM", metadata: ["vmId": .string(vmId)])
        // Firecracker doesn't have graceful shutdown, send Ctrl+Alt+Del or destroy
        try await manager.sendCtrlAltDel()
        logger.info("Shutdown signal sent to Firecracker VM", metadata: ["vmId": .string(vmId)])
    }

    func rebootVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Rebooting Firecracker VM", metadata: ["vmId": .string(vmId)])
        try await manager.sendCtrlAltDel()
        logger.info("Reboot signal sent to Firecracker VM", metadata: ["vmId": .string(vmId)])
    }

    func pauseVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Pausing Firecracker VM", metadata: ["vmId": .string(vmId)])
        try await manager.pause()
        logger.info("Firecracker VM paused", metadata: ["vmId": .string(vmId)])
    }

    func resumeVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Resuming Firecracker VM", metadata: ["vmId": .string(vmId)])
        try await manager.resume()
        logger.info("Firecracker VM resumed", metadata: ["vmId": .string(vmId)])
    }

    func deleteVM(vmId: String) async throws {
        logger.info("Deleting Firecracker VM", metadata: ["vmId": .string(vmId)])

        // Destroy the VM through the client (network attachments are torn down
        // by the agent's NetworkOrchestrator after this returns).
        //
        // No client means this service has never created or adopted anything:
        // the Agent injects a shared one, and `createVM` builds it lazily
        // before it can materialize a rootfs. So there is no process to stop
        // and nothing of this VM's on disk — and in particular the removal
        // below must not run without a preceding teardown, since it would
        // unlink the rootfs of a VM that could still be executing it.
        guard let client = firecrackerClient else {
            logger.info("Firecracker VM had nothing to tear down", metadata: ["vmId": .string(vmId)])
            return
        }
        if vmManagers[vmId] != nil {
            try await client.destroyVM(vmId: vmId)
        } else {
            try await destroyWithoutSession(vmId: vmId, client: client)
        }

        // Clean up local state
        vmManagers.removeValue(forKey: vmId)
        vmSpecs.removeValue(forKey: vmId)
        mmdsPayloads.removeValue(forKey: vmId)
        mmdsInterfaces.removeValue(forKey: vmId)

        // Remove the VM's directory, which holds the rootfs materialized at
        // create. Same rule as the QEMU driver: one recursive removal rather
        // than a list of files that a later addition can fall off (#969),
        // reached only once the teardown above has returned without throwing.
        await reclaimVMDirectory(vmId: vmId)

        logger.info("Firecracker VM deleted", metadata: ["vmId": .string(vmId)])
    }

    /// Leaves the host with no Firecracker process for `vmId` when this service
    /// holds no manager for it, so `deleteVM` can go on to reclaim its
    /// directory.
    ///
    /// The client throws `vmNotFound` for a VM it does not track, which used to
    /// abort the delete before its removal and leak the rootfs on every retry
    /// (STR-179). The deterministic API socket answers the question here:
    /// re-adoption over it registers the VM with the client (and verifies the
    /// pid it finds), so a successful one turns this back into an ordinary
    /// teardown, and a failure means there is no live VMM to tear down.
    private func destroyWithoutSession(vmId: String, client: FirecrackerClient) async throws {
        let socketPath = Self.adoptionSocketPath(socketDirectory: socketDirectory, vmId: vmId)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            logger.warning(
                "Deleting a Firecracker VM with no manager and no API socket; assuming nothing is left to tear down",
                metadata: ["vmId": .string(vmId), "socket": .string(socketPath)])
            return
        }

        do {
            _ = try await client.adoptVM(vmId: vmId)
        } catch {
            logger.warning(
                "VM has no live Firecracker behind its API socket; deleting what it left on this host",
                metadata: [
                    "vmId": .string(vmId),
                    "socket": .string(socketPath),
                    "error": .string(error.localizedDescription),
                ])
            return
        }

        logger.warning(
            "Deleting a VM whose Firecracker is alive but had no manager on this agent",
            metadata: ["vmId": .string(vmId), "socket": .string(socketPath)])
        try await client.destroyVM(vmId: vmId)
    }

    /// See `HypervisorService.reclaimVMDirectory`. Same state `deleteVM`
    /// removes: the directory holding the rootfs materialized at create, plus
    /// the API socket — which lives in the client's socket directory rather
    /// than under the VM's, so the recursive removal cannot reach it. A stale
    /// one left there is what makes a later `adoptVM` attempt a connect instead
    /// of reporting the socket missing.
    func reclaimVMDirectory(vmId: String) async {
        guard vmManagers[vmId] == nil else {
            // The caller's evidence contradicts what this service knows. Refuse
            // rather than unlink the rootfs of a VM it is still driving.
            logger.error(
                "Refusing to reclaim the directory of a VM with a live control session",
                metadata: ["vmId": .string(vmId)])
            return
        }
        VMDirectoryLayout.removeDirectory(vmStoragePath: vmStoragePath, vmId: vmId, logger: logger)
        try? FileManager.default.removeItem(
            atPath: Self.adoptionSocketPath(socketDirectory: socketDirectory, vmId: vmId))
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        // An absent entry means this service does not manage the VM at all; report
        // that honestly instead of fabricating `.shutdown`.
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        let instanceInfo = try await manager.getInstanceInfo()
        return Self.vmStatus(from: instanceInfo.state)
    }

    /// The single Firecracker `InstanceState` → `VMStatus` mapping, shared by
    /// status queries and re-adoption so the two can never drift apart.
    static func vmStatus(from state: InstanceState) -> VMStatus {
        switch state {
        case .running:
            return .running
        case .paused:
            return .paused
        case .notStarted:
            return .created
        }
    }

    /// Never nil, unlike `LibvirtService`: this driver mirrors every VM it
    /// manages in its own memory, so there is no query that can fail and no
    /// state in which it does not know what it holds. Nil is for a backend that
    /// had to ask something else and got no reply (STR-196).
    func listVMs() async -> [String]? {
        return Array(vmManagers.keys)
    }

    /// Sum of vCPUs and memory (in bytes) reserved by all VMs this service is managing.
    /// Used to compute accurate available-resource figures for the scheduler.
    ///
    /// Never nil, for the same reason as `listVMs()`: the specs are held here,
    /// so a zero from this driver is always a real zero.
    func reservedResources() -> (vcpus: Int, memoryBytes: Int64)? {
        vmSpecs.values.reservedResources
    }

    // MARK: - Orphan Re-adoption (issue #433)

    /// The deterministic Firecracker API socket every VM exposes for
    /// re-adoption, matching the path `FirecrackerClient` binds at spawn time.
    static func adoptionSocketPath(socketDirectory: String, vmId: String) -> String {
        FirecrackerClient.socketPath(socketDirectory: socketDirectory, vmId: vmId)
    }

    /// Re-adopts a VM whose Firecracker process survived an agent restart by
    /// reconnecting to its deterministic API socket, and returns the observed
    /// status. Fails (leaving the VM orphaned) when the socket is missing — e.g.
    /// the VM predates deterministic sockets — or cannot be connected because
    /// the process is gone.
    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus {
        if vmManagers[vmId] != nil {
            // Already managed (e.g. a replayed sync raced re-adoption): adoption
            // is satisfied, just report the current status.
            return try await getVMStatus(vmId: vmId)
        }

        let socketPath = Self.adoptionSocketPath(socketDirectory: socketDirectory, vmId: vmId)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw HypervisorServiceError.adoptionTargetGone(
                "VM \(vmId) has no re-adoption API socket at \(socketPath) (created before deterministic sockets, or its process is gone)"
            )
        }

        // The client may not have been created yet if re-adoption is the first
        // operation after a restart; mirror createVM's lazy initialization.
        if firecrackerClient == nil {
            firecrackerClient = FirecrackerClient(
                firecrackerBinaryPath: firecrackerBinaryPath,
                socketDirectory: socketDirectory,
                logger: logger
            )
        }
        guard let client = firecrackerClient else {
            throw HypervisorServiceError.hypervisorNotInstalled(firecrackerBinaryPath)
        }

        logger.info(
            "Re-adopting orphaned Firecracker VM",
            metadata: [
                "vmId": .string(vmId),
                "socket": .string(socketPath),
            ])

        let manager: FirecrackerManager
        let info: InstanceInfo
        do {
            (manager, info) = try await client.adoptVM(vmId: vmId)
        } catch {
            // A live Firecracker always accepts connections on its API socket,
            // so a refused/failed connect means the process is gone and the
            // socket file merely outlived it.
            throw HypervisorServiceError.adoptionTargetGone(
                "VM \(vmId) Firecracker API socket at \(socketPath) is dead: \(error.localizedDescription)")
        }

        vmManagers[vmId] = manager
        vmSpecs[vmId] = spec
        // Adopted manifests written before the exact policy field configured
        // MMDS from the network list. The agent's durable policy inventory is
        // authoritative for reconciliation; this fallback only suppresses
        // pointless data PUTs when no network could have been configured.
        mmdsInterfaces[vmId] = FirecrackerMMDSInterfacePlan.interfaceIDs(for: spec.networks)

        return Self.vmStatus(from: info.state)
    }

    /// Replaces the VMM-local MMDS snapshot for a managed VM. MMDS remains
    /// configured only on the NICs selected before boot; this live PUT updates
    /// the data behind those interfaces without rebuilding or restarting the
    /// guest.
    func refreshInstanceMetadata(vmId: String, metadata: InstanceMetadata?) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        guard !(mmdsInterfaces[vmId] ?? []).isEmpty else {
            return
        }

        let payload = try Self.mmdsPayload(for: metadata)
        guard mmdsPayloads[vmId] != payload else { return }
        try await manager.setMMDSData(rawJSON: payload)
        mmdsPayloads[vmId] = payload
        logger.info(
            "Refreshed Firecracker MMDS snapshot",
            metadata: ["vmId": .string(vmId), "bytes": .stringConvertible(payload.count)])
    }

    func restoreMetadataInterfaceInventory(vmId: String, interfaces: [String]) async {
        guard vmManagers[vmId] != nil else { return }
        mmdsInterfaces[vmId] = interfaces
    }

    /// Replaces only the Firecracker process. Managed disks and host-side TAPs
    /// remain in place; the new process is configured from the desired spec and
    /// receives the new MMDS interface allow-list before it is booted.
    func reconfigureMetadataInterfaces(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo?,
        networkAttachments: [ResolvedNetworkAttachment], metadata: InstanceMetadata?
    ) async throws {
        guard let client = firecrackerClient else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        // Resolve or download the replacement's kernel while the current VMM
        // is still healthy. A temporarily unavailable image must fail this
        // attempt without shutting down a guest that cannot yet be recreated.
        let bootArtifacts = try await resolveBootArtifacts(spec: spec, imageInfo: imageInfo)

        logger.info(
            "Replacing Firecracker VMM to reconfigure MMDS interfaces",
            metadata: ["vmId": .string(vmId)])
        if let manager = vmManagers[vmId] {
            try await quiesceForReplacement(vmId: vmId, manager: manager, client: client)
            try await client.destroyVM(vmId: vmId)
            vmManagers.removeValue(forKey: vmId)
            vmSpecs.removeValue(forKey: vmId)
            mmdsPayloads.removeValue(forKey: vmId)
            mmdsInterfaces.removeValue(forKey: vmId)
        }

        // A failed replacement has already removed the old manager. Its next
        // level-triggered retry must start here rather than failing vmNotFound.
        // createVM owns cleanup for any new process that fails configuration.
        try await createVM(
            vmId: vmId, spec: spec, bootArtifacts: bootArtifacts,
            networkAttachments: networkAttachments, metadata: metadata)
    }

    private func resolveBootArtifacts(
        spec: VMSpec, imageInfo: ImageInfo?
    ) async throws -> FirecrackerBootArtifacts {
        if let imageInfo {
            logger.info(
                "Realizing boot artifacts from image",
                metadata: ["imageId": .string(imageInfo.imageId.uuidString)])
        }
        do {
            return try await FirecrackerBootArtifactResolver.resolve(
                spec: spec, imageInfo: imageInfo, imageSource: imageSource)
        } catch {
            logger.error(
                "Failed to resolve Firecracker boot artifacts",
                metadata: ["error": .string(error.localizedDescription)])
            throw error
        }
    }

    /// Asks the guest to flush and shut down, then proves its VMM exited before
    /// the replacement is allowed to reopen the same managed disk. A paused
    /// guest must briefly resume to handle Ctrl+Alt+Del; if shutdown fails, put
    /// it back in its original paused state rather than leaving an unrelated
    /// policy edit with a power-state side effect.
    private func quiesceForReplacement(
        vmId: String, manager: FirecrackerManager, client: FirecrackerClient
    ) async throws {
        let initialState: InstanceState
        do {
            initialState = try await manager.getInstanceInfo().state
        } catch {
            // A retry may arrive after the guest completed shutdown but before
            // the previous attempt removed the client's process record.
            if try await client.waitForVMExit(vmId: vmId, timeout: .milliseconds(0)) {
                return
            }
            throw error
        }

        guard initialState != .notStarted else { return }
        let restorePauseOnFailure = initialState == .paused

        do {
            if restorePauseOnFailure {
                try await manager.resume()
            }
            try await manager.sendCtrlAltDel()
            guard
                try await client.waitForVMExit(
                    vmId: vmId, timeout: .seconds(Self.gracefulReplacementShutdownSeconds))
            else {
                throw HypervisorServiceError.timeout(
                    "waiting \(Self.gracefulReplacementShutdownSeconds)s for Firecracker guest \(vmId) "
                        + "to shut down before MMDS reconfiguration")
            }
            logger.info(
                "Firecracker guest shut down cleanly before VMM replacement",
                metadata: ["vmId": .string(vmId)])
        } catch {
            if (try? await client.waitForVMExit(vmId: vmId, timeout: .milliseconds(0))) == true {
                logger.info(
                    "Firecracker VMM exited while quiescing for replacement",
                    metadata: ["vmId": .string(vmId)])
                return
            }
            if restorePauseOnFailure {
                do {
                    try await manager.pause()
                } catch {
                    logger.error(
                        "Could not restore paused state after Firecracker shutdown failed",
                        metadata: [
                            "vmId": .string(vmId),
                            "error": .string(error.localizedDescription),
                        ])
                }
            }
            throw error
        }
    }

    /// Removes a process spawned by `createVM` before its manager became
    /// visible to the rest of the service. Preserve the configuration error as
    /// the operation's result, but log a cleanup failure loudly: in that case
    /// the client's process registry deliberately prevents a duplicate spawn.
    private func discardPartialVMM(vmId: String, client: FirecrackerClient) async {
        do {
            try await client.destroyVM(vmId: vmId)
        } catch {
            logger.error(
                "Failed to discard partially configured Firecracker VMM",
                metadata: [
                    "vmId": .string(vmId),
                    "error": .string(error.localizedDescription),
                ])
        }
        vmManagers.removeValue(forKey: vmId)
        vmSpecs.removeValue(forKey: vmId)
        mmdsPayloads.removeValue(forKey: vmId)
        mmdsInterfaces.removeValue(forKey: vmId)
    }

    private static func mmdsPayload(for metadata: InstanceMetadata?) throws -> Data {
        let document = metadata.map { EC2MetadataRenderer.mmdsDocument(for: $0) } ?? .object([:])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    /// Same guest-shutdown envelope as the QEMU/libvirt backend. Unlike VM
    /// deletion, MMDS policy reconciliation does not escalate to forced power
    /// loss: a timeout leaves the old VMM and its disk intact for a later retry.
    private static let gracefulReplacementShutdownSeconds = 60

    /// Firecracker exposes the guest serial console on the firecracker process's
    /// stdio, not a Unix socket, so socket-based console access is not available yet.
    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        guard vmManagers[vmId] != nil else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        throw HypervisorServiceError.notSupported("console access for Firecracker VMs")
    }

    /// Firecracker does not support hot-plugging drives into a running microVM.
    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool) async throws
    {
        guard vmManagers[vmId] != nil else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        throw HypervisorServiceError.notSupported("disk hot-plug for Firecracker VMs")
    }

    /// Firecracker does not support hot-unplugging drives from a running microVM.
    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        guard vmManagers[vmId] != nil else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        throw HypervisorServiceError.notSupported("disk hot-unplug for Firecracker VMs")
    }

}

#endif
