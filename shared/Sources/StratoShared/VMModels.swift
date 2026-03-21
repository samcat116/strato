import Foundation

// MARK: - VM Status and Enums

public enum VMStatus: String, Codable, CaseIterable, Sendable {
    case created = "Created"
    case running = "Running"
    case shutdown = "Shutdown"
    case paused = "Paused"
}

public enum ConsoleMode: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case pty = "Pty"
    case tty = "Tty"
    case file = "File"
    case socket = "Socket"
    case null = "Null"
}

// MARK: - Shared VM Data Model

public struct VMData: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let image: String
    public let status: VMStatus
    public let hypervisorId: String?
    public let hypervisorType: HypervisorType

    // CPU configuration
    public let cpu: Int
    public let maxCpu: Int
    
    // Memory configuration (in bytes)
    public let memory: Int64
    public let hugepages: Bool
    public let sharedMemory: Bool
    
    // Disk configuration
    public let disk: Int64
    public let diskPath: String?
    public let readonlyDisk: Bool
    
    // Payload configuration
    public let kernelPath: String?
    public let initramfsPath: String?
    public let cmdline: String?
    public let firmwarePath: String?
    
    // Network configuration
    public let macAddress: String?
    public let ipAddress: String?
    public let networkMask: String?
    
    // Console configuration
    public let consoleMode: ConsoleMode
    public let serialMode: ConsoleMode
    public let consoleSocket: String?
    public let serialSocket: String?
    
    // Timestamps
    public let createdAt: Date?
    public let updatedAt: Date?
    
    public init(
        id: UUID,
        name: String,
        description: String,
        image: String,
        status: VMStatus,
        hypervisorId: String? = nil,
        hypervisorType: HypervisorType = .qemu,
        cpu: Int,
        maxCpu: Int,
        memory: Int64,
        hugepages: Bool = false,
        sharedMemory: Bool = false,
        disk: Int64,
        diskPath: String? = nil,
        readonlyDisk: Bool = false,
        kernelPath: String? = nil,
        initramfsPath: String? = nil,
        cmdline: String? = nil,
        firmwarePath: String? = nil,
        macAddress: String? = nil,
        ipAddress: String? = nil,
        networkMask: String? = nil,
        consoleMode: ConsoleMode = .pty,
        serialMode: ConsoleMode = .pty,
        consoleSocket: String? = nil,
        serialSocket: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.image = image
        self.status = status
        self.hypervisorId = hypervisorId
        self.hypervisorType = hypervisorType
        self.cpu = cpu
        self.maxCpu = maxCpu
        self.memory = memory
        self.hugepages = hugepages
        self.sharedMemory = sharedMemory
        self.disk = disk
        self.diskPath = diskPath
        self.readonlyDisk = readonlyDisk
        self.kernelPath = kernelPath
        self.initramfsPath = initramfsPath
        self.cmdline = cmdline
        self.firmwarePath = firmwarePath
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.networkMask = networkMask
        self.consoleMode = consoleMode
        self.serialMode = serialMode
        self.consoleSocket = consoleSocket
        self.serialSocket = serialSocket
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - VM Computed Properties

public extension VMData {
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
        return status == .created || status == .shutdown
    }
    
    var canStop: Bool {
        return status == .running || status == .paused
    }
    
    var canPause: Bool {
        return status == .running
    }
    
    var canResume: Bool {
        return status == .paused
    }
}