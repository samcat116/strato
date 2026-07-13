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

    // HypervisorService protocol requirement
    public let hypervisorType: HypervisorType = .firecracker

    // Track running VMs
    private var firecrackerClient: FirecrackerClient?
    private var vmManagers: [String: FirecrackerManager] = [:]
    private var vmSpecs: [String: VMSpec] = [:]

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil,
        imageSource: (any ImageSource)? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker",
        firecrackerClient: FirecrackerClient? = nil
    ) {
        self.logger = logger
        self.storage = storage
        self.imageSource = imageSource
        self.vmStoragePath = vmStoragePath
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.socketDirectory = socketDirectory
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
        networkAttachments: [ResolvedNetworkAttachment] = []
    ) async throws {
        logger.info("Creating Firecracker VM", metadata: ["vmId": .string(vmId)])

        // Boot parameters start from the spec's direct-kernel fields (legacy
        // pre-provisioned host paths). When the image supplies kernel/rootfs
        // artifacts, they take precedence and are resolved to agent-local cache
        // paths below — the control plane can't know host paths.
        var kernelPath: String?
        var initramfsPath: String?
        var cmdline: String?
        if case .directKernel(let specKernel, let specInitramfs, let specCmdline) = spec.boot {
            kernelPath = specKernel.isEmpty ? nil : specKernel
            initramfsPath = specInitramfs
            cmdline = specCmdline
        }

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

        // Realize kernel/rootfs from the image's artifact set when present.
        var rootDrive: (id: String, path: String, readOnly: Bool)?
        if let imageInfo = imageInfo, let storage = storage {
            logger.info(
                "Realizing boot artifacts from image",
                metadata: [
                    "vmId": .string(vmId),
                    "imageId": .string(imageInfo.imageId.uuidString),
                ])

            do {
                // Direct-kernel boot artifacts (kernel, optional initramfs) are
                // opaque blobs fetched into the cache as-is. When the image
                // supplies its own kernel it fully owns the direct-kernel boot:
                // drop any stale spec initramfs so the image kernel is never
                // paired with a legacy/nonexistent initrd, then use the image's
                // initramfs only if it provides one.
                if imageInfo.artifact(ofKind: .kernel) != nil, let imageSource = imageSource {
                    kernelPath = try await imageSource.localImagePath(for: imageInfo, kind: .kernel)
                    if imageInfo.artifact(ofKind: .initramfs) != nil {
                        initramfsPath = try await imageSource.localImagePath(for: imageInfo, kind: .initramfs)
                    } else {
                        initramfsPath = nil
                    }
                }

                // Firecracker attaches drives as raw block devices. The storage
                // layer converts the artifact (e.g. a qcow2 rootfs) to raw during
                // materialization; a plain copy of a qcow2 file would hand the
                // guest an unbootable rootfs. Prefer a dedicated rootfs artifact,
                // falling back to the primary disk image for legacy images.
                let rootfsKind: ArtifactKind = imageInfo.artifact(ofKind: .rootfs) != nil ? .rootfs : .diskImage
                let attachment = try await storage.materializeDisk(
                    at: "\(vmStoragePath)/\(vmId)/rootfs.raw",
                    from: imageInfo,
                    format: .raw,
                    artifactKind: rootfsKind
                )
                rootDrive = (id: "rootfs", path: attachment.path, readOnly: false)
            } catch {
                // Realizing the image's boot artifacts is all-or-nothing: a
                // fetched kernel without its matching rootfs would boot the guest
                // against the wrong or no root filesystem. Fail the create rather
                // than falling through to the legacy spec-volume path.
                logger.error(
                    "Failed to realize boot artifacts from image",
                    metadata: [
                        "vmId": .string(vmId),
                        "error": .string(error.localizedDescription),
                    ])
                throw error
            }
        }

        if rootDrive == nil,
            let volume = spec.volumes.first,
            let storagePath = volume.storagePath
        {
            rootDrive = (id: volume.deviceName, path: storagePath, readOnly: volume.readonly)
        }

        // Firecracker cannot boot without a kernel — from the image or the spec.
        guard let kernelPath = kernelPath, !kernelPath.isEmpty else {
            throw HypervisorServiceError.invalidConfiguration(
                "Firecracker requires direct kernel boot - no kernel artifact or kernel path available")
        }

        // Create Firecracker VM
        let manager = try await client.createVM(vmId: vmId)

        // Configure machine
        let machineConfig = MachineConfig(
            vcpuCount: spec.cpus,
            memSizeMib: Int(spec.memoryBytes / (1024 * 1024))
        )
        try await manager.configureMachine(machineConfig)

        // Configure boot source (qualified: StratoShared also declares a BootSource)
        let bootSource = SwiftFirecracker.BootSource(
            kernelImagePath: kernelPath,
            initrdPath: initramfsPath,
            bootArgs: cmdline ?? "console=ttyS0 reboot=k panic=1 pci=off"
        )
        try await manager.configureBootSource(bootSource)

        // Configure root drive
        if let rootDrive {
            let drive = Drive.rootDrive(
                id: rootDrive.id,
                path: rootDrive.path,
                readOnly: rootDrive.readOnly
            )
            try await manager.configureDrive(drive)
        }

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

        // Store references
        vmManagers[vmId] = manager
        vmSpecs[vmId] = spec

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
        // by the agent's NetworkOrchestrator after this returns)
        if let client = firecrackerClient {
            try await client.destroyVM(vmId: vmId)
        }

        // Clean up local state
        vmManagers.removeValue(forKey: vmId)
        vmSpecs.removeValue(forKey: vmId)

        logger.info("Firecracker VM deleted", metadata: ["vmId": .string(vmId)])
    }

    func getVMInfo(vmId: String) async throws -> VmInfo {
        guard let manager = vmManagers[vmId],
            let spec = vmSpecs[vmId]
        else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }

        let instanceInfo = try await manager.getInstanceInfo()

        return VmInfo(
            spec: spec,
            state: instanceInfo.state.rawValue,
            memoryActualSize: spec.memoryBytes
        )
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        // An absent entry means this service does not manage the VM at all; report
        // that honestly instead of fabricating `.shutdown` (see QEMUService).
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

    func listVMs() async -> [String] {
        return Array(vmManagers.keys)
    }

    /// Sum of vCPUs and memory (in bytes) reserved by all VMs this service is managing.
    /// Used to compute accurate available-resource figures for the scheduler.
    func reservedResources() -> (vcpus: Int, memoryBytes: Int64) {
        var vcpus = 0
        var memoryBytes: Int64 = 0
        for spec in vmSpecs.values {
            vcpus += spec.cpus
            memoryBytes += spec.memoryBytes
        }
        return (vcpus, memoryBytes)
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

        return Self.vmStatus(from: info.state)
    }

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

#else
// Stub implementation for non-Linux platforms
// Firecracker is only available on Linux

/// Stub FirecrackerService for non-Linux platforms
/// Always throws an error since Firecracker is Linux-only
actor FirecrackerService: HypervisorService {
    public let hypervisorType: HypervisorType = .firecracker

    init(
        logger: Logger,
        storage: (any StorageBackend)? = nil,
        vmStoragePath: String,
        firecrackerBinaryPath: String = "/usr/bin/firecracker",
        socketDirectory: String = "/tmp/firecracker"
    ) {
        // No-op for non-Linux
    }

    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo? = nil,
        networkAttachments: [ResolvedNetworkAttachment] = []
    ) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func bootVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func shutdownVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func rebootVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func pauseVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func resumeVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func deleteVM(vmId: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func getVMInfo(vmId: String) async throws -> VmInfo {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func listVMs() async -> [String] {
        return []
    }

    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func attachDisk(vmId: String, volumeId: String, volumePath: String, deviceName: String, readonly: Bool) async throws
    {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        throw HypervisorServiceError.notSupported("Firecracker is only available on Linux")
    }

    func reservedResources() -> (vcpus: Int, memoryBytes: Int64) {
        return (0, 0)
    }
}
#endif
