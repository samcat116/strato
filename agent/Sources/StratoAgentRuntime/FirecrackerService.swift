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
    private let diskRealizer: any FirecrackerDiskRealizing
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
    /// Host-only krbd mappings. The manifest and `vmSpecs` retain canonical
    /// `.rbd` coordinates; `/dev/rbdN` is never reported as volume identity.
    private var realizedDisks: [String: [FirecrackerRealizedDisk]] = [:]
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
        diskRealizer: (any FirecrackerDiskRealizing)? = nil,
        imageSource: (any ImageSource)? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker",
        firecrackerClient: FirecrackerClient? = nil,
        metadataProvider: (@Sendable (UUID) async -> InstanceMetadata?)? = nil
    ) {
        self.logger = logger
        self.storage = storage
        self.diskRealizer = diskRealizer ?? LocalFirecrackerDiskRealizer()
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
        // A failed re-adoption can leave a provisional reference to a durable
        // mapping while proving that the old VMM is gone. Keep it alive until
        // the replacement has acquired its own reference, then release exactly
        // the provisional one. A failed replacement retains it for retry/delete.
        let retainedDisks = realizedDisks.removeValue(forKey: vmId) ?? []
        do {
            try await createVM(
                vmId: vmId, spec: spec, bootArtifacts: bootArtifacts,
                networkAttachments: networkAttachments, metadata: metadata)
        } catch {
            if !retainedDisks.isEmpty {
                realizedDisks[vmId, default: []].append(contentsOf: retainedDisks)
            }
            throw error
        }
        try await releaseRetainedDisks(retainedDisks, vmId: vmId)
    }

    private func createVM(
        vmId: String, spec: VMSpec, bootArtifacts: FirecrackerBootArtifacts,
        networkAttachments: [ResolvedNetworkAttachment], metadata: InstanceMetadata?
    ) async throws {
        logger.info("Creating Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])

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
            let bootAttachment = bootVolume.attachment
        else {
            throw HypervisorServiceError.invalidConfiguration(
                "Firecracker VM \(vmId) has no realized managed boot volume")
        }
        let realizedBoot = try await diskRealizer.realize(
            bootAttachment, readOnly: bootVolume.readonly)
        // Track the canonical-to-host realization immediately. Any later
        // configuration failure must retain a failed unmap for delete/retry.
        realizedDisks[vmId, default: []].append(realizedBoot)
        let bootPath: String
        do {
            bootPath = try FirecrackerDiskAttachment.hostPath(for: realizedBoot.realized)
        } catch FirecrackerDiskAttachment.Error.nativeRBD {
            await releaseTrackedDiskAfterFailedCreate(realizedBoot, vmId: vmId)
            throw HypervisorServiceError.notSupported(
                "Firecracker cannot open a native RBD attachment; map it through krbd first")
        }
        guard FileManager.default.fileExists(atPath: bootPath) else {
            await releaseTrackedDiskAfterFailedCreate(realizedBoot, vmId: vmId)
            throw HypervisorServiceError.diskError(
                "boot volume \(bootVolume.volumeId) for VM \(vmId) has no file at \(bootPath) on this host")
        }
        let rootDrive = (
            id: bootVolume.volumeId.uuidString, path: bootPath, readOnly: bootVolume.readonly
        )

        var processWasSpawned = false
        do {
            // MMDS carries the complete cloud-init document. Firecracker's 50
            // KiB default API limit is smaller than Strato's accepted user
            // data before the surrounding EC2 tree is added, so raise this
            // VMM's finite limit before any API request can seed or later
            // refresh the snapshot. Process creation belongs inside the same
            // cleanup boundary as configuration: a spawn failure occurs after
            // krbd realization and must release that exact reference too.
            let manager = try await client.createVM(
                vmId: vmId,
                httpAPIMaxPayloadSize: FirecrackerMMDSInterfacePlan.payloadLimitBytes)
            processWasSpawned = true

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
            // A manager return proves `FirecrackerClient.createVM` spawned and
            // registered the process. No caller can clean it up through this
            // service yet because publication waits for full configuration.
            // If createVM itself threw, its own failure path owns any partial
            // process and there is no registered manager for us to destroy.
            if processWasSpawned {
                await discardPartialVMM(vmId: vmId, client: client)
            }
            await releaseTrackedDiskAfterFailedCreate(realizedBoot, vmId: vmId)
            throw error
        }

        logger.info("Firecracker VM created successfully", metadata: ["strato.vm.id": .string(vmId)])
    }

    func bootVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Booting Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])
        try await manager.start()
        logger.info("Firecracker VM booted successfully", metadata: ["strato.vm.id": .string(vmId)])
    }

    func shutdownVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Shutting down Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])
        // Firecracker doesn't have graceful shutdown, send Ctrl+Alt+Del or destroy
        try await manager.sendCtrlAltDel()
        logger.info("Shutdown signal sent to Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])
    }

    func rebootVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Rebooting Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])
        try await manager.sendCtrlAltDel()
        logger.info("Reboot signal sent to Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])
    }

    func pauseVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Pausing Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])
        try await manager.pause()
        logger.info("Firecracker VM paused", metadata: ["strato.vm.id": .string(vmId)])
    }

    func resumeVM(vmId: String) async throws {
        guard let manager = vmManagers[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        logger.info("Resuming Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])
        try await manager.resume()
        logger.info("Firecracker VM resumed", metadata: ["strato.vm.id": .string(vmId)])
    }

    func deleteVM(vmId: String) async throws {
        logger.info("Deleting Firecracker VM", metadata: ["strato.vm.id": .string(vmId)])

        // Destroy the VM through the client (network attachments are torn down
        // by the agent's NetworkOrchestrator after this returns).
        //
        // No client means this service has never created or adopted anything:
        // the Agent injects a shared one, and `createVM` builds it lazily
        // before it can materialize a rootfs. So there is no process to stop
        // and nothing of this VM's on disk — and in particular the removal
        // below must not run without a preceding teardown, since it would
        // unlink the rootfs of a VM that could still be executing it.
        if let client = firecrackerClient {
            if vmManagers[vmId] != nil {
                try await client.destroyVM(vmId: vmId)
            } else {
                try await destroyWithoutSession(vmId: vmId, client: client)
            }
        } else if vmManagers[vmId] != nil {
            throw HypervisorServiceError.hypervisorNotInstalled(firecrackerBinaryPath)
        } else {
            logger.info(
                "Firecracker VM had no process to tear down; continuing durable disk cleanup",
                metadata: ["strato.vm.id": .string(vmId)])
        }

        // The VMM is gone. Remove its control state before krbd cleanup so a
        // failed unmap can retry delete without trying to destroy the same
        // process twice. Keep realizedDisks until each release succeeds.
        vmManagers.removeValue(forKey: vmId)
        vmSpecs.removeValue(forKey: vmId)
        mmdsPayloads.removeValue(forKey: vmId)
        mmdsInterfaces.removeValue(forKey: vmId)
        try await releaseRealizedDisks(vmId: vmId)

        // Remove the VM's directory, which holds the rootfs materialized at
        // create. Same rule as the QEMU driver: one recursive removal rather
        // than a list of files that a later addition can fall off (#969),
        // reached only once the teardown above has returned without throwing.
        removeVMFiles(vmId: vmId)

        logger.info("Firecracker VM deleted", metadata: ["strato.vm.id": .string(vmId)])
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
                metadata: ["strato.vm.id": .string(vmId), "socket": .string(socketPath)])
            return
        }

        do {
            _ = try await client.adoptVM(vmId: vmId)
        } catch {
            logger.warning(
                "VM has no live Firecracker behind its API socket; deleting what it left on this host",
                metadata: [
                    "strato.vm.id": .string(vmId),
                    "socket": .string(socketPath),
                    "error": .string(error.localizedDescription),
                ])
            return
        }

        logger.warning(
            "Deleting a VM whose Firecracker is alive but had no manager on this agent",
            metadata: ["strato.vm.id": .string(vmId), "socket": .string(socketPath)])
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
                metadata: ["strato.vm.id": .string(vmId)])
            return
        }
        do {
            try await releaseRealizedDisks(vmId: vmId)
        } catch {
            logger.error(
                "Could not release a Firecracker VM's durable disk mappings; retaining its files for retry",
                metadata: [
                    "strato.vm.id": .string(vmId),
                    "error": .string(error.localizedDescription),
                ])
            return
        }
        removeVMFiles(vmId: vmId)
    }

    private func removeVMFiles(vmId: String) {
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

    func reservationInventory() -> HypervisorReservationInventory? {
        let reserved = vmSpecs.values.reservedResources
        return HypervisorReservationInventory(
            reservation: HostReservation(cpus: reserved.vcpus, memoryBytes: reserved.memoryBytes))
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
            try await adoptBootDiskIfNeeded(vmId: vmId, spec: spec)
            return try await getVMStatus(vmId: vmId)
        }

        // Acquire the durable disk realization first. When the deterministic
        // socket then proves the process is gone, orphan cleanup still has the
        // canonical-to-device reference it needs to unmap krbd safely.
        try await adoptBootDiskIfNeeded(vmId: vmId, spec: spec)

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
                "strato.vm.id": .string(vmId),
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

    private func adoptBootDiskIfNeeded(vmId: String, spec: VMSpec) async throws {
        guard realizedDisks[vmId] == nil else { return }
        guard let bootVolume = spec.volumes.first(where: { $0.bootOrder == 0 }),
            let bootAttachment = bootVolume.attachment
        else {
            throw HypervisorServiceError.invalidConfiguration(
                "Firecracker VM \(vmId) has no realized managed boot volume")
        }

        let realizedBoot = try await diskRealizer.adopt(
            bootAttachment, readOnly: bootVolume.readonly)
        realizedDisks[vmId] = [realizedBoot]
        let bootPath: String
        do {
            bootPath = try FirecrackerDiskAttachment.hostPath(for: realizedBoot.realized)
        } catch {
            await releaseTrackedDiskAfterFailedCreate(realizedBoot, vmId: vmId)
            throw HypervisorServiceError.diskError(
                "re-adopted boot volume \(bootVolume.volumeId) has no usable host block device")
        }
        guard FileManager.default.fileExists(atPath: bootPath) else {
            await releaseTrackedDiskAfterFailedCreate(realizedBoot, vmId: vmId)
            throw HypervisorServiceError.diskError(
                "re-adopted boot volume \(bootVolume.volumeId) is missing at \(bootPath)")
        }
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
            metadata: ["strato.vm.id": .string(vmId), "bytes": .stringConvertible(payload.count)])
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
            metadata: ["strato.vm.id": .string(vmId)])
        if let manager = vmManagers[vmId] {
            try await quiesceForReplacement(vmId: vmId, manager: manager, client: client)
            try await client.destroyVM(vmId: vmId)
            vmManagers.removeValue(forKey: vmId)
            vmSpecs.removeValue(forKey: vmId)
            mmdsPayloads.removeValue(forKey: vmId)
            mmdsInterfaces.removeValue(forKey: vmId)
        }

        // A replacement realizes the same canonical disk once more before it
        // is published. Retain the old reference until that succeeds so the
        // krbd mapping remains live throughout the handoff, then drop exactly
        // one reference. On failure, keep the old reference for delete/retry.
        let retainedDisks = realizedDisks.removeValue(forKey: vmId) ?? []
        do {
            try await createVM(
                vmId: vmId, spec: spec, bootArtifacts: bootArtifacts,
                networkAttachments: networkAttachments, metadata: metadata)
        } catch {
            if !retainedDisks.isEmpty {
                realizedDisks[vmId, default: []].append(contentsOf: retainedDisks)
            }
            throw error
        }
        try await releaseRetainedDisks(retainedDisks, vmId: vmId)
    }

    /// Releases references retained across a VMM replacement. A failed final
    /// unmap is put back under the VM so a later delete can retry it.
    private func releaseRetainedDisks(
        _ retained: [FirecrackerRealizedDisk], vmId: String
    ) async throws {
        for (index, disk) in retained.enumerated() {
            do {
                try await diskRealizer.release(disk)
            } catch {
                realizedDisks[vmId, default: []].append(contentsOf: retained[index...])
                throw error
            }
        }
    }

    /// Final deletion path. Remove one handle only after its underlying
    /// reference was released, so a failure retries the exact remaining set.
    private func releaseRealizedDisks(vmId: String) async throws {
        while let disk = realizedDisks[vmId]?.first {
            try await diskRealizer.release(disk)
            realizedDisks[vmId]?.removeFirst()
        }
        realizedDisks.removeValue(forKey: vmId)
    }

    /// Best-effort cleanup while preserving the primary create/adoption error.
    /// The mapping remains in `realizedDisks` on failure and is therefore not
    /// forgotten when reconciliation later deletes or replaces the VM.
    private func releaseTrackedDiskAfterFailedCreate(
        _ disk: FirecrackerRealizedDisk, vmId: String
    ) async {
        do {
            try await diskRealizer.release(disk)
            if let index = realizedDisks[vmId]?.firstIndex(of: disk) {
                realizedDisks[vmId]?.remove(at: index)
            }
            if realizedDisks[vmId]?.isEmpty == true {
                realizedDisks.removeValue(forKey: vmId)
            }
        } catch {
            logger.error(
                "Could not release a Firecracker disk after VM setup failed; retaining it for delete/retry",
                metadata: [
                    "strato.vm.id": .string(vmId),
                    "error": .string(error.localizedDescription),
                ])
        }
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
                metadata: ["strato.vm.id": .string(vmId)])
        } catch {
            if (try? await client.waitForVMExit(vmId: vmId, timeout: .milliseconds(0))) == true {
                logger.info(
                    "Firecracker VMM exited while quiescing for replacement",
                    metadata: ["strato.vm.id": .string(vmId)])
                return
            }
            if restorePauseOnFailure {
                do {
                    try await manager.pause()
                } catch {
                    logger.error(
                        "Could not restore paused state after Firecracker shutdown failed",
                        metadata: [
                            "strato.vm.id": .string(vmId),
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
                    "strato.vm.id": .string(vmId),
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
    func attachDisk(
        vmId: String, volumeId: String, attachment: DiskAttachment, deviceName: String,
        readonly: Bool, orderedBootVolumeIds: [String]
    ) async throws {
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
