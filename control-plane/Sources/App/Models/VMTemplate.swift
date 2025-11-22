import Fluent
import Vapor

final class VMTemplate: Model, @unchecked Sendable {
    static let schema = "vm_templates"

    @ID(key: .id)
    var id: UUID?

    // Template identification
    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    @Field(key: "image_name")
    var imageName: String

    // Default resource specifications
    @Field(key: "default_cpu")
    var defaultCpu: Int

    @Field(key: "default_memory")
    var defaultMemory: Int64

    @Field(key: "default_disk")
    var defaultDisk: Int64

    // Payload paths for this template
    @Field(key: "kernel_path")
    var kernelPath: String

    @OptionalField(key: "initramfs_path")
    var initramfsPath: String?

    @Field(key: "base_disk_path")
    var baseDiskPath: String

    @OptionalField(key: "firmware_path")
    var firmwarePath: String?

    @Field(key: "default_cmdline")
    var defaultCmdline: String

    // Default network configuration
    @OptionalField(key: "default_mac_prefix")
    var defaultMacPrefix: String?

    @OptionalField(key: "default_ip_range")
    var defaultIpRange: String?

    // Template settings
    @Field(key: "is_active")
    var isActive: Bool

    @Field(key: "supports_hugepages")
    var supportsHugepages: Bool

    @Field(key: "supports_shared_memory")
    var supportsSharedMemory: Bool

    // Minimum requirements
    @Field(key: "min_cpu")
    var minCpu: Int

    @Field(key: "min_memory")
    var minMemory: Int64

    @Field(key: "min_disk")
    var minDisk: Int64

    // Maximum limits
    @Field(key: "max_cpu")
    var maxCpu: Int

    @Field(key: "max_memory")
    var maxMemory: Int64

    @Field(key: "max_disk")
    var maxDisk: Int64

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
        imageName: String,
        defaultCpu: Int,
        defaultMemory: Int64,
        defaultDisk: Int64,
        kernelPath: String,
        baseDiskPath: String,
        defaultCmdline: String,
        initramfsPath: String? = nil,
        firmwarePath: String? = nil,
        isActive: Bool = true,
        supportsHugepages: Bool = false,
        supportsSharedMemory: Bool = false,
        minCpu: Int = 1,
        minMemory: Int64 = 512 * 1024 * 1024, // 512MB
        minDisk: Int64 = 1024 * 1024 * 1024, // 1GB
        maxCpu: Int = 32,
        maxMemory: Int64 = 32 * 1024 * 1024 * 1024, // 32GB
        maxDisk: Int64 = 1024 * 1024 * 1024 * 1024 // 1TB
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.imageName = imageName
        self.defaultCpu = defaultCpu
        self.defaultMemory = defaultMemory
        self.defaultDisk = defaultDisk
        self.kernelPath = kernelPath
        self.initramfsPath = initramfsPath
        self.baseDiskPath = baseDiskPath
        self.firmwarePath = firmwarePath
        self.defaultCmdline = defaultCmdline
        self.isActive = isActive
        self.supportsHugepages = supportsHugepages
        self.supportsSharedMemory = supportsSharedMemory
        self.minCpu = minCpu
        self.minMemory = minMemory
        self.minDisk = minDisk
        self.maxCpu = maxCpu
        self.maxMemory = maxMemory
        self.maxDisk = maxDisk
    }
}

extension VMTemplate: Content {}

// MARK: - Validation and Utility Methods

extension VMTemplate {
    func validateResourceLimits(cpu: Int, memory: Int64, disk: Int64) throws {
        if cpu < minCpu || cpu > maxCpu {
            throw VMTemplateError.cpuOutOfRange(min: minCpu, max: maxCpu, requested: cpu)
        }

        if memory < minMemory || memory > maxMemory {
            throw VMTemplateError.memoryOutOfRange(min: minMemory, max: maxMemory, requested: memory)
        }

        if disk < minDisk || disk > maxDisk {
            throw VMTemplateError.diskOutOfRange(min: minDisk, max: maxDisk, requested: disk)
        }
    }

    func createVMInstance(
        name: String,
        description: String,
        projectID: UUID,
        environment: String = "development",
        cpu: Int? = nil,
        memory: Int64? = nil,
        disk: Int64? = nil,
        cmdline: String? = nil
    ) throws -> VM {
        let finalCpu = cpu ?? defaultCpu
        let finalMemory = memory ?? defaultMemory
        let finalDisk = disk ?? defaultDisk
        let finalCmdline = cmdline ?? defaultCmdline

        try validateResourceLimits(cpu: finalCpu, memory: finalMemory, disk: finalDisk)

        return VM(
            name: name,
            description: description,
            image: imageName,
            projectID: projectID,
            environment: environment,
            cpu: finalCpu,
            memory: finalMemory,
            disk: finalDisk,
            maxCpu: finalCpu
        )
    }

    func generateDiskPath(for vmId: UUID) -> String {
        let fileExtension = (baseDiskPath as NSString).pathExtension
        let fileName = "\(vmId.uuidString).\(fileExtension)"
        let baseDir = (baseDiskPath as NSString).deletingLastPathComponent
        return "\(baseDir)/\(fileName)"
    }

    func generateMacAddress() -> String {
        if let prefix = defaultMacPrefix {
            let randomBytes = (0..<3).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
            return "\(prefix):\(randomBytes.joined(separator: ":"))"
        } else {
            // Generate a random MAC with VMware OUI (00:0c:29)
            let randomBytes = (0..<3).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
            return "00:0c:29:\(randomBytes.joined(separator: ":"))"
        }
    }
}

// MARK: - Errors

enum VMTemplateError: Error, LocalizedError, Sendable {
    case cpuOutOfRange(min: Int, max: Int, requested: Int)
    case memoryOutOfRange(min: Int64, max: Int64, requested: Int64)
    case diskOutOfRange(min: Int64, max: Int64, requested: Int64)
    case templateNotFound(String)
    case templateInactive(String)

    var errorDescription: String? {
        switch self {
        case .cpuOutOfRange(let min, let max, let requested):
            return "CPU count \(requested) is out of range. Must be between \(min) and \(max)."
        case .memoryOutOfRange(let min, let max, let requested):
            return "Memory \(requested) bytes is out of range. Must be between \(min) and \(max) bytes."
        case .diskOutOfRange(let min, let max, let requested):
            return "Disk size \(requested) bytes is out of range. Must be between \(min) and \(max) bytes."
        case .templateNotFound(let name):
            return "VM template '\(name)' not found."
        case .templateInactive(let name):
            return "VM template '\(name)' is not active."
        }
    }
}
