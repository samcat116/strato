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

    @OptionalField(key: "firmware_path")
    var firmwarePath: String?

    // Network configuration
    @OptionalField(key: "mac_address")
    var macAddress: String?

    @OptionalField(key: "ip_address")
    var ipAddress: String?

    @OptionalField(key: "network_mask")
    var networkMask: String?

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
        self.hypervisorType = hypervisorType
        self.hugepages = hugepages
        self.sharedMemory = sharedMemory
        self.readonlyDisk = readonlyDisk
        self.consoleMode = consoleMode
        self.serialMode = serialMode
    }
}

extension VM: Content {}

// MARK: - Shared Model Conversion

extension VM {
    func toVMData() -> VMData {
        return VMData(
            id: id ?? UUID(),
            name: name,
            description: description,
            image: image,
            status: status,
            hypervisorId: hypervisorId,
            hypervisorType: hypervisorType,
            cpu: cpu,
            maxCpu: maxCpu,
            memory: memory,
            hugepages: hugepages,
            sharedMemory: sharedMemory,
            disk: disk,
            diskPath: diskPath,
            readonlyDisk: readonlyDisk,
            kernelPath: kernelPath,
            initramfsPath: initramfsPath,
            cmdline: cmdline,
            firmwarePath: firmwarePath,
            macAddress: macAddress,
            ipAddress: ipAddress,
            networkMask: networkMask,
            consoleMode: consoleMode,
            serialMode: serialMode,
            consoleSocket: consoleSocket,
            serialSocket: serialSocket,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Computed Properties

extension VM {
    var memoryMB: Int {
        return Int(memory / 1024 / 1024)
    }

    var memoryGB: Double {
        return Double(memory) / 1024.0 / 1024.0 / 1024.0
    }

    var diskGB: Double {
        return Double(disk) / 1024.0 / 1024.0 / 1024.0
    }

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

    /// True when a fresh boot is the right action (as opposed to resuming from pause).
    var shouldBootOnStart: Bool {
        return status == .created || status == .shutdown || status == .error
    }

    /// Updates the VM status and stamps the change time for the reconciliation sweep.
    /// Does not persist — call `save(on:)` afterwards.
    func setStatus(_ newStatus: VMStatus, at date: Date = Date()) {
        status = newStatus
        statusChangedAt = date
    }

    var canPause: Bool {
        return status == .running
    }

    var canResume: Bool {
        return status == .paused
    }

    /// Generates a random MAC address with VMware OUI (00:0c:29)
    static func generateMACAddress() -> String {
        let randomBytes = (0..<3).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
        return "00:0c:29:\(randomBytes.joined(separator: ":"))"
    }
}

// MARK: - Response DTO

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
