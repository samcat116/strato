import Foundation

// MARK: - Main VM Configuration

public struct VmConfig: Codable, Sendable {
    public let cpus: CpusConfig?
    public let memory: MemoryConfig?
    public let payload: PayloadConfig
    public let disks: [DiskConfig]?
    public let net: [NetConfig]?
    public let rng: RngConfig?
    public let serial: ConsoleConfig?
    public let console: ConsoleConfig?
    public let iommu: Bool?
    public let watchdog: Bool?
    public let pvpanic: Bool?
    
    public init(
        cpus: CpusConfig? = nil,
        memory: MemoryConfig? = nil,
        payload: PayloadConfig,
        disks: [DiskConfig]? = nil,
        net: [NetConfig]? = nil,
        rng: RngConfig? = nil,
        serial: ConsoleConfig? = nil,
        console: ConsoleConfig? = nil,
        iommu: Bool? = nil,
        watchdog: Bool? = nil,
        pvpanic: Bool? = nil
    ) {
        self.cpus = cpus
        self.memory = memory
        self.payload = payload
        self.disks = disks
        self.net = net
        self.rng = rng
        self.serial = serial
        self.console = console
        self.iommu = iommu
        self.watchdog = watchdog
        self.pvpanic = pvpanic
    }
}

// MARK: - CPU Configuration

public struct CpusConfig: Codable, Sendable {
    public let bootVcpus: Int
    public let maxVcpus: Int
    public let topology: CpuTopology?
    public let kvmHyperv: Bool?
    public let maxPhysBits: Int?
    public let features: CpuFeatures?
    
    enum CodingKeys: String, CodingKey {
        case bootVcpus = "boot_vcpus"
        case maxVcpus = "max_vcpus"
        case topology
        case kvmHyperv = "kvm_hyperv"
        case maxPhysBits = "max_phys_bits"
        case features
    }
    
    public init(
        bootVcpus: Int,
        maxVcpus: Int,
        topology: CpuTopology? = nil,
        kvmHyperv: Bool? = nil,
        maxPhysBits: Int? = nil,
        features: CpuFeatures? = nil
    ) {
        self.bootVcpus = bootVcpus
        self.maxVcpus = maxVcpus
        self.topology = topology
        self.kvmHyperv = kvmHyperv
        self.maxPhysBits = maxPhysBits
        self.features = features
    }
}

public struct CpuTopology: Codable, Sendable {
    public let threadsPerCore: Int?
    public let coresPerDie: Int?
    public let diesPerPackage: Int?
    public let packages: Int?
    
    enum CodingKeys: String, CodingKey {
        case threadsPerCore = "threads_per_core"
        case coresPerDie = "cores_per_die"
        case diesPerPackage = "dies_per_package"
        case packages
    }
    
    public init(
        threadsPerCore: Int? = nil,
        coresPerDie: Int? = nil,
        diesPerPackage: Int? = nil,
        packages: Int? = nil
    ) {
        self.threadsPerCore = threadsPerCore
        self.coresPerDie = coresPerDie
        self.diesPerPackage = diesPerPackage
        self.packages = packages
    }
}

public struct CpuFeatures: Codable, Sendable {
    public let amx: Bool?
    
    public init(amx: Bool? = nil) {
        self.amx = amx
    }
}

// MARK: - Memory Configuration

public struct MemoryConfig: Codable, Sendable {
    public let size: Int64
    public let hotplugSize: Int64?
    public let hotpluggedSize: Int64?
    public let mergeable: Bool?
    public let hotplugMethod: String?
    public let shared: Bool?
    public let hugepages: Bool?
    public let hugepageSize: Int64?
    public let prefault: Bool?
    public let thp: Bool?
    public let zones: [MemoryZoneConfig]?
    
    enum CodingKeys: String, CodingKey {
        case size
        case hotplugSize = "hotplug_size"
        case hotpluggedSize = "hotplugged_size"
        case mergeable
        case hotplugMethod = "hotplug_method"
        case shared
        case hugepages
        case hugepageSize = "hugepage_size"
        case prefault
        case thp
        case zones
    }
    
    public init(
        size: Int64,
        hotplugSize: Int64? = nil,
        hotpluggedSize: Int64? = nil,
        mergeable: Bool? = nil,
        hotplugMethod: String? = nil,
        shared: Bool? = nil,
        hugepages: Bool? = nil,
        hugepageSize: Int64? = nil,
        prefault: Bool? = nil,
        thp: Bool? = nil,
        zones: [MemoryZoneConfig]? = nil
    ) {
        self.size = size
        self.hotplugSize = hotplugSize
        self.hotpluggedSize = hotpluggedSize
        self.mergeable = mergeable
        self.hotplugMethod = hotplugMethod
        self.shared = shared
        self.hugepages = hugepages
        self.hugepageSize = hugepageSize
        self.prefault = prefault
        self.thp = thp
        self.zones = zones
    }
}

public struct MemoryZoneConfig: Codable, Sendable {
    public let id: String
    public let size: Int64
    public let file: String?
    public let mergeable: Bool?
    public let shared: Bool?
    public let hugepages: Bool?
    public let hugepageSize: Int64?
    public let hostNumaNode: Int?
    public let hotplugSize: Int64?
    public let hotpluggedSize: Int64?
    public let prefault: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id, size, file, mergeable, shared, hugepages
        case hugepageSize = "hugepage_size"
        case hostNumaNode = "host_numa_node"
        case hotplugSize = "hotplug_size"
        case hotpluggedSize = "hotplugged_size"
        case prefault
    }
    
    public init(
        id: String,
        size: Int64,
        file: String? = nil,
        mergeable: Bool? = nil,
        shared: Bool? = nil,
        hugepages: Bool? = nil,
        hugepageSize: Int64? = nil,
        hostNumaNode: Int? = nil,
        hotplugSize: Int64? = nil,
        hotpluggedSize: Int64? = nil,
        prefault: Bool? = nil
    ) {
        self.id = id
        self.size = size
        self.file = file
        self.mergeable = mergeable
        self.shared = shared
        self.hugepages = hugepages
        self.hugepageSize = hugepageSize
        self.hostNumaNode = hostNumaNode
        self.hotplugSize = hotplugSize
        self.hotpluggedSize = hotpluggedSize
        self.prefault = prefault
    }
}

// MARK: - Payload Configuration

public struct PayloadConfig: Codable, Sendable {
    public let firmware: String?
    public let kernel: String?
    public let cmdline: String?
    public let initramfs: String?
    
    public init(
        firmware: String? = nil,
        kernel: String? = nil,
        cmdline: String? = nil,
        initramfs: String? = nil
    ) {
        self.firmware = firmware
        self.kernel = kernel
        self.cmdline = cmdline
        self.initramfs = initramfs
    }
}

// MARK: - Disk Configuration

public struct DiskConfig: Codable, Sendable {
    public let path: String
    public let readonly: Bool?
    public let direct: Bool?
    public let iommu: Bool?
    public let numQueues: Int?
    public let queueSize: Int?
    public let vhostUser: Bool?
    public let vhostSocket: String?
    public let pciSegment: Int?
    public let id: String?
    public let serial: String?
    public let rateLimitGroup: String?
    
    enum CodingKeys: String, CodingKey {
        case path, readonly, direct, iommu
        case numQueues = "num_queues"
        case queueSize = "queue_size"
        case vhostUser = "vhost_user"
        case vhostSocket = "vhost_socket"
        case pciSegment = "pci_segment"
        case id, serial
        case rateLimitGroup = "rate_limit_group"
    }
    
    public init(
        path: String,
        readonly: Bool? = nil,
        direct: Bool? = nil,
        iommu: Bool? = nil,
        numQueues: Int? = nil,
        queueSize: Int? = nil,
        vhostUser: Bool? = nil,
        vhostSocket: String? = nil,
        pciSegment: Int? = nil,
        id: String? = nil,
        serial: String? = nil,
        rateLimitGroup: String? = nil
    ) {
        self.path = path
        self.readonly = readonly
        self.direct = direct
        self.iommu = iommu
        self.numQueues = numQueues
        self.queueSize = queueSize
        self.vhostUser = vhostUser
        self.vhostSocket = vhostSocket
        self.pciSegment = pciSegment
        self.id = id
        self.serial = serial
        self.rateLimitGroup = rateLimitGroup
    }
}

// MARK: - Network Configuration

public struct NetConfig: Codable, Sendable {
    public let tap: String?
    public let ip: String?
    public let mask: String?
    public let mac: String?
    public let hostMac: String?
    public let mtu: Int?
    public let iommu: Bool?
    public let numQueues: Int?
    public let queueSize: Int?
    public let vhostUser: Bool?
    public let vhostSocket: String?
    public let vhostMode: String?
    public let id: String?
    public let pciSegment: Int?
    
    enum CodingKeys: String, CodingKey {
        case tap, ip, mask, mac
        case hostMac = "host_mac"
        case mtu, iommu
        case numQueues = "num_queues"
        case queueSize = "queue_size"
        case vhostUser = "vhost_user"
        case vhostSocket = "vhost_socket"
        case vhostMode = "vhost_mode"
        case id
        case pciSegment = "pci_segment"
    }
    
    public init(
        tap: String? = nil,
        ip: String? = nil,
        mask: String? = nil,
        mac: String? = nil,
        hostMac: String? = nil,
        mtu: Int? = nil,
        iommu: Bool? = nil,
        numQueues: Int? = nil,
        queueSize: Int? = nil,
        vhostUser: Bool? = nil,
        vhostSocket: String? = nil,
        vhostMode: String? = nil,
        id: String? = nil,
        pciSegment: Int? = nil
    ) {
        self.tap = tap
        self.ip = ip
        self.mask = mask
        self.mac = mac
        self.hostMac = hostMac
        self.mtu = mtu
        self.iommu = iommu
        self.numQueues = numQueues
        self.queueSize = queueSize
        self.vhostUser = vhostUser
        self.vhostSocket = vhostSocket
        self.vhostMode = vhostMode
        self.id = id
        self.pciSegment = pciSegment
    }
}

// MARK: - Console Configuration

public struct ConsoleConfig: Codable, Sendable {
    public let file: String?
    public let socket: String?
    public let mode: String
    public let iommu: Bool?
    
    public init(
        file: String? = nil,
        socket: String? = nil,
        mode: String,
        iommu: Bool? = nil
    ) {
        self.file = file
        self.socket = socket
        self.mode = mode
        self.iommu = iommu
    }
}

// MARK: - RNG Configuration

public struct RngConfig: Codable, Sendable {
    public let src: String
    public let iommu: Bool?
    
    public init(src: String, iommu: Bool? = nil) {
        self.src = src
        self.iommu = iommu
    }
}

// MARK: - Response DTOs

public struct VmInfo: Codable, Sendable {
    public let config: VmConfig
    public let state: String
    public let memoryActualSize: Int64?
    
    enum CodingKeys: String, CodingKey {
        case config, state
        case memoryActualSize = "memory_actual_size"
    }
    
    public init(
        config: VmConfig,
        state: String,
        memoryActualSize: Int64? = nil
    ) {
        self.config = config
        self.state = state
        self.memoryActualSize = memoryActualSize
    }
}

public struct VmmPingResponse: Codable, Sendable {
    public let buildVersion: String?
    public let version: String
    public let pid: Int64?
    public let features: [String]?
    
    enum CodingKeys: String, CodingKey {
        case buildVersion = "build_version"
        case version, pid, features
    }
    
    public init(
        buildVersion: String? = nil,
        version: String,
        pid: Int64? = nil,
        features: [String]? = nil
    ) {
        self.buildVersion = buildVersion
        self.version = version
        self.pid = pid
        self.features = features
    }
}

public struct VmCounters: Codable, Sendable {
    public let counters: [String: [String: Int64]]
    
    public init(counters: [String: [String: Int64]]) {
        self.counters = counters
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.counters = try container.decode([String: [String: Int64]].self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counters)
    }
}

// MARK: - Error Types

public enum CloudHypervisorError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case vmNotFound(String)
    case vmAlreadyExists(String)
    case vmNotCreated(String)
    case vmNotStarted(String)
    case vmNotPaused(String)
    case invalidConfiguration(String)
    case hypervisorError(Int, String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "Failed to connect to cloud-hypervisor: \(message)"
        case .vmNotFound(let id):
            return "VM with ID \(id) not found in hypervisor"
        case .vmAlreadyExists(let id):
            return "VM with ID \(id) already exists in hypervisor"
        case .vmNotCreated(let id):
            return "VM with ID \(id) is not created yet"
        case .vmNotStarted(let id):
            return "VM with ID \(id) is not started"
        case .vmNotPaused(let id):
            return "VM with ID \(id) is not paused"
        case .invalidConfiguration(let message):
            return "Invalid VM configuration: \(message)"
        case .hypervisorError(let status, let message):
            return "Hypervisor error (\(status)): \(message)"
        }
    }
}