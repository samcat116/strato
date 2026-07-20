import Fluent
import Vapor
import StratoShared

final class VM: Model, @unchecked Sendable {
    static let schema = "vms"

    @ID(key: .id)
    var id: UUID?

    // Basic VM metadata
    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    @Field(key: "image")
    var image: String

    // VM status and hypervisor tracking
    @Enum(key: "status")
    var status: VMStatus

    @OptionalField(key: "hypervisor_id")
    var hypervisorId: String?

    // When `status` last changed. Used by the reconciliation sweep to detect VMs
    // stuck in a transitional state past a timeout.
    @OptionalField(key: "status_changed_at")
    var statusChangedAt: Date?

    // Desired/observed state split (reconciliation phase 2, issue #260).
    // `desiredStatus` is the goal written by API mutations; `status` above is
    // purely observed. `generation` bumps on every desired change and
    // `observedGeneration` records the last generation the owning agent
    // confirmed converging to.
    @Enum(key: "desired_status")
    var desiredStatus: DesiredVMStatus

    @Field(key: "generation")
    var generation: Int64

    @Field(key: "observed_generation")
    var observedGeneration: Int64

    // Observed guest-agent (qga) state (issue #563). Purely informational and
    // best-effort: nil until the agent's guest-info poll first sees a
    // responsive qga on this VM. `qgaAvailable` records the positive liveness
    // signal; `observedHostname` is the guest OS's own hostname.
    @OptionalField(key: "qga_available")
    var qgaAvailable: Bool?

    @OptionalField(key: "observed_hostname")
    var observedHostname: String?

    @Enum(key: "hypervisor_type")
    var hypervisorType: HypervisorType

    // Project and environment tracking
    @Parent(key: "project_id")
    var project: Project

    @Field(key: "environment")
    var environment: String

    // Optional reference to the Image used to create this VM (new image system)
    @OptionalParent(key: "image_id")
    var sourceImage: Image?

    // Volumes attached to this VM (QEMU only - requires eager loading with .with(\.$volumes))
    @Children(for: \.$vm)
    var volumes: [Volume]

    // Network interfaces attached to this VM (requires eager loading with .with(\.$networkInterfaces))
    @Children(for: \.$vm)
    var networkInterfaces: [VMNetworkInterface]

    // CPU configuration
    @Field(key: "cpu")
    var cpu: Int  // boot_vcpus

    @Field(key: "max_cpu")
    var maxCpu: Int  // max_vcpus

    // Memory configuration (in bytes)
    @Field(key: "memory")
    var memory: Int64

    @Field(key: "hugepages")
    var hugepages: Bool

    @Field(key: "shared_memory")
    var sharedMemory: Bool

    // Disk configuration
    @Field(key: "disk")
    var disk: Int64

    @OptionalField(key: "disk_path")
    var diskPath: String?

    @Field(key: "readonly_disk")
    var readonlyDisk: Bool

    // Payload configuration (kernel, initramfs, etc.)
    @OptionalField(key: "kernel_path")
    var kernelPath: String?

    @OptionalField(key: "initramfs_path")
    var initramfsPath: String?

    @OptionalField(key: "cmdline")
    var cmdline: String?

    // SSH public key authorized for the guest's default user via cloud-init.
    @OptionalField(key: "ssh_public_key")
    var sshPublicKey: String?

    // Caller-supplied cloud-init user data (any format cloud-init dispatches
    // on: #cloud-config, #! scripts, #include, MIME multipart, ...), stored
    // verbatim and passed to the agent in the VM spec.
    @OptionalField(key: "user_data")
    var userData: String?

    @OptionalField(key: "firmware_path")
    var firmwarePath: String?

    // Console configuration
    @Enum(key: "console_mode")
    var consoleMode: ConsoleMode

    @Enum(key: "serial_mode")
    var serialMode: ConsoleMode

    @OptionalField(key: "console_socket")
    var consoleSocket: String?

    @OptionalField(key: "serial_socket")
    var serialSocket: String?

    // Timestamps
    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        name: String,
        description: String,
        image: String,
        projectID: UUID,
        environment: String,
        cpu: Int,
        memory: Int64,
        disk: Int64,
        status: VMStatus = .created,
        hypervisorType: HypervisorType = .qemu,
        maxCpu: Int? = nil,
        hugepages: Bool = false,
        sharedMemory: Bool = false,
        readonlyDisk: Bool = false,
        consoleMode: ConsoleMode = .pty,
        serialMode: ConsoleMode = .pty
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.image = image
        self.$project.id = projectID
        self.environment = environment
        self.cpu = cpu
        self.maxCpu = maxCpu ?? cpu
        self.memory = memory
        self.disk = disk
        self.status = status
        self.desiredStatus = .shutdown
        self.generation = 0
        self.observedGeneration = 0
        self.hypervisorType = hypervisorType
        self.hugepages = hugepages
        self.sharedMemory = sharedMemory
        self.readonlyDisk = readonlyDisk
        self.consoleMode = consoleMode
        self.serialMode = serialMode
    }
}

extension VM: Content {}

// MARK: - Computed Properties

extension VM {
    var isRunning: Bool {
        return status == .running
    }

    var canStart: Bool {
        // `.error` is included so an operator can recover a VM whose state could not
        // be confirmed (e.g. a lost or timed-out start).
        return status == .created || status == .shutdown || status == .error
    }

    var canStop: Bool {
        return status == .running || status == .paused
    }

    /// Updates the VM status and stamps the change time for the reconciliation sweep.
    /// Does not persist — call `save(on:)` afterwards.
    func setStatus(_ newStatus: VMStatus, at date: Date = Date()) {
        status = newStatus
        statusChangedAt = date
    }

    /// Records a new desired state and bumps the generation so agents treat it
    /// as newer than anything they have applied. Does not persist — call
    /// `save(on:)` afterwards.
    func setDesiredStatus(_ newDesired: DesiredVMStatus) {
        desiredStatus = newDesired
        generation += 1
    }

    /// Realigns desired state with observed reality after a failed operation,
    /// bumping the generation. Without this, the unachieved intent lingers —
    /// e.g. a delete that failed on a pre-state-sync agent leaves
    /// `desired_status = .absent`, which a later sync (say, after the agent
    /// upgrades to the state-sync protocol) would replay destructively without
    /// any new user action. Returns whether anything changed; does not persist.
    @discardableResult
    func revertDesiredToObserved() -> Bool {
        let resting: DesiredVMStatus
        switch status {
        case .running, .starting:
            resting = .running
        case .paused:
            resting = .paused
        case .created, .shutdown, .stopping, .error, .unknown:
            resting = .shutdown
        }
        guard desiredStatus != resting else { return false }
        setDesiredStatus(resting)
        return true
    }

    var canPause: Bool {
        return status == .running
    }

    var canResume: Bool {
        return status == .paused
    }
}

// MARK: - Response DTO

struct InterfaceAddressResponse: Content {
    let family: String
    let address: String
    let prefixLength: Int
    let gateway: String?

    init(from address: VMInterfaceAddress) {
        self.family = address.family
        self.address = address.address
        self.prefixLength = address.prefixLength
        self.gateway = address.gateway
    }
}

/// One address the guest actually configured on a NIC, as reported by the QEMU
/// guest agent (issue #563). Distinct from `InterfaceAddressResponse` (the
/// allocated address): no gateway, and `prefixLength` is optional since qga
/// does not always supply one.
struct ObservedInterfaceAddressResponse: Content {
    let family: String
    let address: String
    let prefixLength: Int?

    init(from address: VMInterfaceObservedAddress) {
        self.family = address.family
        self.address = address.address
        self.prefixLength = address.prefixLength
    }
}

struct NetworkInterfaceResponse: Content {
    let id: UUID?
    let network: String
    let macAddress: String
    let addresses: [InterfaceAddressResponse]
    /// Guest-reported addresses (issue #563), distinct from the allocated
    /// `addresses`. Empty until a guest agent reports them.
    let observedAddresses: [ObservedInterfaceAddressResponse]
    let mtu: Int?
    let deviceName: String
    let orderIndex: Int

    init(from nic: VMNetworkInterface) {
        self.id = nic.id
        self.network = nic.network
        self.macAddress = nic.macAddress
        // ipv4-first for a stable, familiar ordering.
        self.addresses = (nic.$addresses.value ?? [])
            .sorted { ($0.family, $0.address) < ($1.family, $1.address) }
            .map(InterfaceAddressResponse.init)
        // `.value ?? []` tolerates callers that didn't eager-load the children.
        self.observedAddresses = (nic.$observedAddresses.value ?? [])
            .sorted { ($0.family, $0.address) < ($1.family, $1.address) }
            .map(ObservedInterfaceAddressResponse.init)
        self.mtu = nic.mtu
        self.deviceName = nic.deviceName
        self.orderIndex = nic.orderIndex
    }
}

struct VMDetailResponse: Content {
    let id: UUID?
    let name: String
    let description: String
    let image: String
    let imageId: UUID?
    let projectId: UUID?
    let status: VMStatus
    let hypervisorId: String?
    let cpu: Int
    let maxCpu: Int
    let memory: Int64
    let memoryFormatted: String
    let disk: Int64
    let diskFormatted: String
    let networkInterfaces: [NetworkInterfaceResponse]
    /// Observed guest-agent view (issue #563). `qgaAvailable` is nil until the
    /// agent's slow poll first sees a responsive qga; `observedHostname` is the
    /// guest OS's own hostname when it reported one.
    let qgaAvailable: Bool?
    let observedHostname: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(from vm: VM) {
        self.id = vm.id
        self.name = vm.name
        self.description = vm.description
        self.image = vm.image
        self.imageId = vm.$sourceImage.id
        self.projectId = vm.$project.id
        self.status = vm.status
        self.hypervisorId = vm.hypervisorId
        self.cpu = vm.cpu
        self.maxCpu = vm.maxCpu
        self.memory = vm.memory
        self.memoryFormatted = VMDetailResponse.formatSize(vm.memory)
        self.disk = vm.disk
        self.diskFormatted = VMDetailResponse.formatSize(vm.disk)
        // `.value ?? []` tolerates callers that didn't eager-load the children;
        // sorted to match the deterministic ordering agents receive in the spec.
        self.networkInterfaces = (vm.$networkInterfaces.value ?? [])
            .sorted { ($0.orderIndex, $0.deviceName) < ($1.orderIndex, $1.deviceName) }
            .map(NetworkInterfaceResponse.init)
        self.qgaAvailable = vm.qgaAvailable
        self.observedHostname = vm.observedHostname
        self.createdAt = vm.createdAt
        self.updatedAt = vm.updatedAt
    }

    static func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1024.0 / 1024.0 / 1024.0
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1024.0 / 1024.0
        if mb >= 1.0 {
            return String(format: "%.2f MB", mb)
        }
        let kb = Double(bytes) / 1024.0
        return String(format: "%.2f KB", kb)
    }
}
