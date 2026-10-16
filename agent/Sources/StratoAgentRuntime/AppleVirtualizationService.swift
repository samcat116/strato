#if os(macOS)
import Foundation
import Logging
import StratoAgentCore
import StratoShared
import Virtualization

/// Native VMs belong to this process. After an agent exit the manifest's disks
/// survive, but the guest must cold-boot; no surviving VM is claimed adopted.
actor AppleVirtualizationService: HypervisorService {
    let hypervisorType: HypervisorType = .appleVirtualization
    private let vmStoragePath: String
    private let logger: Logger
    private let provisioner: CloudInitProvisioner
    private let host: AppleVirtualizationHost
    private var specs: [String: VMSpec] = [:]
    private var operations: Set<String> = []
    private var networks: [String: [ResolvedNetworkAttachment]] = [:]

    init(logger: Logger, vmStoragePath: String, shutdownGracePeriod: Duration = .seconds(30)) async {
        self.logger = logger
        self.vmStoragePath = vmStoragePath
        self.provisioner = CloudInitProvisioner(logger: logger)
        self.host = await AppleVirtualizationHost(shutdownGracePeriod: shutdownGracePeriod)
    }

    func support() async -> HypervisorSupport {
        await host.support()
    }

    private func begin(_ id: String) throws {
        guard operations.insert(id).inserted else {
            throw HypervisorServiceError.invalidConfiguration("VM \(id) already has an operation in flight")
        }
    }

    func createVM(
        vmId: String, spec: VMSpec, imageInfo: ImageInfo?,
        networkAttachments: [ResolvedNetworkAttachment], metadata: InstanceMetadata?, vsockCID: UInt32?
    ) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        guard UUID(uuidString: vmId) != nil else {
            throw HypervisorServiceError.invalidConfiguration("VM identity must be a UUID")
        }
        guard specs[vmId] == nil else { return }
        let plan = try AppleVirtualizationPlan(
            spec: spec, networks: networkAttachments, memoryBounds: await host.memoryBounds)
        let directory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
        try ManagedStatePermissions.prepareVMDirectory(at: directory)
        let iso = VMDirectoryLayout.cloudInitISO(vmDirectory: directory)
        _ = try await provisioner.makeNoCloudISO(
            at: iso, vmId: vmId, hostname: metadata?.hostname,
            sshAuthorizedKeys: spec.sshAuthorizedKeys, userData: spec.userData,
            networkAttachments: networkAttachments)
        try await host.create(id: vmId, plan: plan, directory: directory, seed: iso)
        specs[vmId] = spec
        networks[vmId] = networkAttachments
    }

    func convergeGuestBootstrap(
        vmId: String, spec: VMSpec,
        networkAttachments: [ResolvedNetworkAttachment], metadata: InstanceMetadata?
    ) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        let plan = try AppleVirtualizationPlan(
            spec: spec, networks: networkAttachments, memoryBounds: await host.memoryBounds)
        let directory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
        let iso = VMDirectoryLayout.cloudInitISO(vmDirectory: directory)
        let status = try await host.status(id: vmId)
        guard status == .shutdown || status == .created else {
            throw HypervisorServiceError.notSupported("reconfiguring a running Apple VM")
        }
        _ = try await provisioner.makeNoCloudISO(
            at: iso, vmId: vmId, hostname: metadata?.hostname,
            sshAuthorizedKeys: spec.sshAuthorizedKeys, userData: spec.userData,
            networkAttachments: networkAttachments)
        try await host.replace(id: vmId, plan: plan, directory: directory, seed: iso)
        specs[vmId] = spec
        networks[vmId] = networkAttachments
    }

    func bootVM(vmId: String) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        try await host.start(id: vmId)
    }

    func shutdownVM(vmId: String) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        try await host.shutdown(id: vmId)
    }

    func rebootVM(vmId: String) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        try await host.shutdown(id: vmId)
        try await host.start(id: vmId)
    }

    func pauseVM(vmId: String) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        try await host.pause(id: vmId)
    }

    func resumeVM(vmId: String) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        try await host.resume(id: vmId)
    }

    func deleteVM(vmId: String) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        try await host.remove(id: vmId)
        specs.removeValue(forKey: vmId)
        networks.removeValue(forKey: vmId)
        await reclaimVMDirectory(vmId: vmId)
    }

    func reclaimVMDirectory(vmId: String) async {
        VMDirectoryLayout.removeDirectory(vmStoragePath: vmStoragePath, vmId: vmId, logger: logger)
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        try await host.status(id: vmId)
    }

    func adoptVM(vmId: String, spec: VMSpec) async throws -> VMStatus {
        if specs[vmId] != nil { return try await host.status(id: vmId) }
        throw HypervisorServiceError.adoptionTargetGone("Apple VM exited with its owning agent process")
    }

    func consoleEndpoint(vmId: String) async throws -> ConsoleEndpoint? {
        throw HypervisorServiceError.notSupported("Apple Virtualization serial socket bridge")
    }

    func attachDisk(
        vmId: String, volumeId: String, attachment: DiskAttachment, deviceName: String,
        readonly: Bool, blockPolicy: AppliedBlockDevicePolicy?, orderedBootVolumeIds: [String],
        ioLimits: VolumeIOLimits?
    ) async throws {
        throw HypervisorServiceError.notSupported("Apple Virtualization disk hot-plug")
    }

    func detachDisk(vmId: String, volumeId: String, deviceName: String) async throws {
        throw HypervisorServiceError.notSupported("Apple Virtualization disk hot-unplug")
    }

    func resizeVM(vmId: String, spec: VMSpec) async throws {
        try begin(vmId)
        defer { operations.remove(vmId) }
        guard let current = specs[vmId], let attachments = networks[vmId] else {
            throw HypervisorServiceError.vmNotFound(vmId)
        }
        let next = current.withSizing(from: spec)
        let plan = try AppleVirtualizationPlan(spec: next, networks: attachments, memoryBounds: await host.memoryBounds)
        let directory = VMDirectoryLayout.directory(vmStoragePath: vmStoragePath, vmId: vmId)
        try await host.replace(
            id: vmId, plan: plan, directory: directory,
            seed: VMDirectoryLayout.cloudInitISO(vmDirectory: directory))
        specs[vmId] = next
    }

    func hasLiveSession(vmId: String) async -> Bool {
        await host.hasLiveSession(id: vmId)
    }

    func reservationInventory() async -> HypervisorReservationInventory? {
        let workloads = specs.mapValues {
            VMHostReservation.forSpec($0, hypervisorType: .appleVirtualization, architecture: .current)
        }
        return HypervisorReservationInventory(
            reservation: workloads.values.reduce(HostReservation()) { $0.addingSaturating($1) },
            workloadReservations: workloads)
    }

    func bootstrapWorkloadIDs() async -> Set<String>? {
        // VZVirtualMachine instances cannot outlive their creating process.
        Set(specs.keys)
    }

    func shutdown() async {
        for id in specs.keys {
            do { try await host.remove(id: id) } catch {
                logger.error("Could not stop Apple VM \(id) during agent shutdown: \(error)")
            }
        }
    }
}

/// VZVirtualMachine's default initializer requires every operation and callback
/// on the main dispatch queue. This boundary owns all framework objects; only
/// Sendable plans and observations cross back to the driver's actor.
@MainActor
final class AppleVirtualizationHost {
    private let shutdownGracePeriod: Duration

    init(shutdownGracePeriod: Duration = .seconds(30)) {
        self.shutdownGracePeriod = shutdownGracePeriod
    }

    private var machines: [String: VZVirtualMachine] = [:]
    private var started: Set<String> = []

    var memoryBounds: ClosedRange<Int64> {
        let minimum = Int64(clamping: VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        let maximum = Int64(clamping: VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        return minimum...maximum
    }

    func support() -> HypervisorSupport {
        var reason: String?
        if !VZVirtualMachine.isSupported {
            reason = "Virtualization.framework is unavailable on this Mac"
        } else {
            // validate() also checks this executable's virtualization entitlement.
            let config = VZVirtualMachineConfiguration()
            config.cpuCount = VZVirtualMachineConfiguration.minimumAllowedCPUCount
            config.memorySize = VZVirtualMachineConfiguration.minimumAllowedMemorySize
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("strato-vz-probe-\(UUID())")
            // This is disposable firmware state, never a workload or identity file.
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let loader = VZEFIBootLoader()
                loader.variableStore = try VZEFIVariableStore(
                    creatingVariableStoreAt: directory.appendingPathComponent("efi-vars.fd"))
                config.bootLoader = loader
                try config.validate()
            } catch {
                reason = "Virtualization.framework validation failed: \(error.localizedDescription)"
            }
        }
        return HypervisorSupport(
            type: .appleVirtualization, available: reason == nil, accelerated: reason == nil,
            unavailabilityReason: reason, supportsSnapshots: false, supportsVsock: false,
            supportsGuestExec: false, supportsVolumeIOLimits: false,
            minimumMemoryBytes: memoryBounds.lowerBound, maximumMemoryBytes: memoryBounds.upperBound)
    }

    func create(id: String, plan: AppleVirtualizationPlan, directory: String, seed: String) throws {
        guard machines[id] == nil else { return }
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = plan.spec.cpus
        config.memorySize = UInt64(plan.spec.memoryBytes)
        switch plan.spec.boot {
        case .disk:
            let loader = VZEFIBootLoader()
            let path = (directory as NSString).appendingPathComponent("efi-vars.fd")
            try ManagedStatePermissions.requireRegularOrMissing(at: path)
            if FileManager.default.fileExists(atPath: path) {
                loader.variableStore = VZEFIVariableStore(url: URL(fileURLWithPath: path))
            } else {
                loader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: path))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            config.bootLoader = loader
        case .directKernel(let kernel, let initramfs, let cmdline):
            let loader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernel))
            loader.initialRamdiskURL = initramfs.map { URL(fileURLWithPath: $0) }
            loader.commandLine = cmdline ?? "console=hvc0"
            config.bootLoader = loader
        }
        config.storageDevices = try plan.disks.map { disk in
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: disk.path), readOnly: disk.readonly,
                cachingMode: .cached, synchronizationMode: .full)
            return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        }
        config.storageDevices.append(
            VZVirtioBlockDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: seed), readOnly: true)))
        config.networkDevices = try plan.networks.map { network in
            let device = VZVirtioNetworkDeviceConfiguration()
            guard let mac = network.macAddress.flatMap(VZMACAddress.init(string:)) else {
                throw HypervisorServiceError.invalidConfiguration("Apple VM NIC needs a valid MAC address")
            }
            device.macAddress = mac
            device.attachment = VZNATNetworkDeviceAttachment()
            return device
        }
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        // A headless virtio console permits guests to boot with console=hvc0.
        // No user-visible socket is advertised until a streaming bridge exists.
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: nil)
        config.serialPorts = [serial]
        try config.validate()
        machines[id] = VZVirtualMachine(configuration: config)
    }

    func replace(id: String, plan: AppleVirtualizationPlan, directory: String, seed: String) throws {
        let vm = try machine(id)
        guard vm.state == .stopped else {
            throw HypervisorServiceError.notSupported("reconfiguring a running Apple VM")
        }
        machines.removeValue(forKey: id)
        do {
            try create(id: id, plan: plan, directory: directory, seed: seed)
        } catch {
            machines[id] = vm
            throw error
        }
    }

    private func machine(_ id: String) throws -> VZVirtualMachine {
        guard let machine = machines[id] else { throw HypervisorServiceError.vmNotFound(id) }
        return machine
    }

    func hasLiveSession(id: String) -> Bool {
        machines[id].map { $0.state != .stopped } ?? false
    }

    func status(id: String) throws -> VMStatus {
        switch try machine(id).state {
        case .stopped: return started.contains(id) ? .shutdown : .created
        case .running: return .running
        case .paused: return .paused
        case .starting, .resuming, .restoring: return .starting
        case .pausing, .saving: return .paused
        case .stopping: return .stopping
        case .error: return .error
        @unknown default: return .unknown
        }
    }

    func start(id: String) async throws {
        let vm = try machine(id)
        if vm.state == .running { return }
        guard vm.canStart else { throw HypervisorServiceError.invalidConfiguration("VM \(id) cannot start") }
        try await vm.start()
        started.insert(id)
    }

    func shutdown(id: String) async throws {
        let vm = try machine(id)
        if vm.state == .stopped { return }
        if vm.state == .paused { try await vm.resume() }
        guard vm.canRequestStop else {
            throw HypervisorServiceError.invalidConfiguration("VM \(id) cannot request shutdown")
        }
        try vm.requestStop()
        let deadline = ContinuousClock.now.advanced(by: shutdownGracePeriod)
        while vm.state != .stopped {
            if ContinuousClock.now >= deadline {
                // A guest may ignore the power-button request. Await the forced
                // stop so shutdown converges and reboot can safely start again.
                try Task.checkCancellation()
                try await vm.stop()
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func pause(id: String) async throws {
        let vm = try machine(id)
        if vm.state == .paused { return }
        try await vm.pause()
    }

    func resume(id: String) async throws {
        let vm = try machine(id)
        if vm.state == .running { return }
        try await vm.resume()
    }

    /// Only terminal machines can be discarded without a stop. A transitional
    /// machine that cannot stop yet must stay tracked so reconciliation retries.
    static func stopForRemoval(
        state: VZVirtualMachine.State, canStop: Bool, stop: @MainActor () async throws -> Void
    ) async throws {
        if state == .stopped || state == .error { return }
        guard canStop else {
            throw HypervisorServiceError.invalidConfiguration("Apple VM is transitioning and cannot stop yet")
        }
        try await stop()
    }

    func remove(id: String) async throws {
        guard let vm = machines[id] else { return }
        try await Self.stopForRemoval(state: vm.state, canStop: vm.canStop) { try await vm.stop() }
        machines.removeValue(forKey: id)
        started.remove(id)
    }
}
#endif
