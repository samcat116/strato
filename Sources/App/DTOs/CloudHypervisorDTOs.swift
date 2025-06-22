import Foundation
import Vapor

// MARK: - Main VM Configuration

struct VmConfig: Content {
    let cpus: CpusConfig?
    let memory: MemoryConfig?
    let payload: PayloadConfig
    let disks: [DiskConfig]?
    let net: [NetConfig]?
    let rng: RngConfig?
    let serial: ConsoleConfig?
    let console: ConsoleConfig?
    let iommu: Bool?
    let watchdog: Bool?
    let pvpanic: Bool?
    
    init(
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

struct CpusConfig: Content {
    let bootVcpus: Int
    let maxVcpus: Int
    let topology: CpuTopology?
    let kvmHyperv: Bool?
    let maxPhysBits: Int?
    let features: CpuFeatures?
    
    enum CodingKeys: String, CodingKey {
        case bootVcpus = "boot_vcpus"
        case maxVcpus = "max_vcpus"
        case topology
        case kvmHyperv = "kvm_hyperv"
        case maxPhysBits = "max_phys_bits"
        case features
    }
    
    init(
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

struct CpuTopology: Content {
    let threadsPerCore: Int?
    let coresPerDie: Int?
    let diesPerPackage: Int?
    let packages: Int?
    
    enum CodingKeys: String, CodingKey {
        case threadsPerCore = "threads_per_core"
        case coresPerDie = "cores_per_die"
        case diesPerPackage = "dies_per_package"
        case packages
    }
}

struct CpuFeatures: Content {
    let amx: Bool?
}

// MARK: - Memory Configuration

struct MemoryConfig: Content {
    let size: Int64
    let hotplugSize: Int64?
    let hotpluggedSize: Int64?
    let mergeable: Bool?
    let hotplugMethod: String?
    let shared: Bool?
    let hugepages: Bool?
    let hugepageSize: Int64?
    let prefault: Bool?
    let thp: Bool?
    let zones: [MemoryZoneConfig]?
    
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
    
    init(
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

struct MemoryZoneConfig: Content {
    let id: String
    let size: Int64
    let file: String?
    let mergeable: Bool?
    let shared: Bool?
    let hugepages: Bool?
    let hugepageSize: Int64?
    let hostNumaNode: Int?
    let hotplugSize: Int64?
    let hotpluggedSize: Int64?
    let prefault: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id, size, file, mergeable, shared, hugepages
        case hugepageSize = "hugepage_size"
        case hostNumaNode = "host_numa_node"
        case hotplugSize = "hotplug_size"
        case hotpluggedSize = "hotplugged_size"
        case prefault
    }
}

// MARK: - Payload Configuration

struct PayloadConfig: Content {
    let firmware: String?
    let kernel: String?
    let cmdline: String?
    let initramfs: String?
    
    init(
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

struct DiskConfig: Content {
    let path: String
    let readonly: Bool?
    let direct: Bool?
    let iommu: Bool?
    let numQueues: Int?
    let queueSize: Int?
    let vhostUser: Bool?
    let vhostSocket: String?
    let pciSegment: Int?
    let id: String?
    let serial: String?
    let rateLimitGroup: String?
    
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
    
    init(
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

struct NetConfig: Content {
    let tap: String?
    let ip: String?
    let mask: String?
    let mac: String?
    let hostMac: String?
    let mtu: Int?
    let iommu: Bool?
    let numQueues: Int?
    let queueSize: Int?
    let vhostUser: Bool?
    let vhostSocket: String?
    let vhostMode: String?
    let id: String?
    let pciSegment: Int?
    
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
    
    init(
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

struct ConsoleConfig: Content {
    let file: String?
    let socket: String?
    let mode: String
    let iommu: Bool?
    
    init(
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

struct RngConfig: Content {
    let src: String
    let iommu: Bool?
    
    init(src: String, iommu: Bool? = nil) {
        self.src = src
        self.iommu = iommu
    }
}

// MARK: - Response DTOs

struct VmInfo: Content {
    let config: VmConfig
    let state: String
    let memoryActualSize: Int64?
    let deviceTree: [String: DeviceNode]?
    
    enum CodingKeys: String, CodingKey {
        case config, state
        case memoryActualSize = "memory_actual_size"
        case deviceTree = "device_tree"
    }
}

struct DeviceNode: Content {
    let id: String?
    let resources: [Resource]?
    let children: [String]?
    let pciBdf: String?
    
    enum CodingKeys: String, CodingKey {
        case id, resources, children
        case pciBdf = "pci_bdf"
    }
}

struct Resource: Content {
    // This would be a complex enum in Rust, simplified here
    let type: String?
    let data: [String: AnyCodable]?
}

struct AnyCodable: Content {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else {
            throw DecodingError.typeMismatch(AnyCodable.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let intValue = value as? Int {
            try container.encode(intValue)
        } else if let stringValue = value as? String {
            try container.encode(stringValue)
        } else if let boolValue = value as? Bool {
            try container.encode(boolValue)
        } else if let doubleValue = value as? Double {
            try container.encode(doubleValue)
        } else {
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

struct VmmPingResponse: Content {
    let buildVersion: String?
    let version: String
    let pid: Int64?
    let features: [String]?
    
    enum CodingKeys: String, CodingKey {
        case buildVersion = "build_version"
        case version, pid, features
    }
}

struct VmCounters: Content {
    let counters: [String: [String: Int64]]
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.counters = try container.decode([String: [String: Int64]].self)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(counters)
    }
}

struct PciDeviceInfo: Content {
    let id: String
    let bdf: String
}

// MARK: - VM Operation DTOs

struct VmResize: Content {
    let desiredVcpus: Int?
    let desiredRam: Int64?
    let desiredBalloon: Int64?
    
    enum CodingKeys: String, CodingKey {
        case desiredVcpus = "desired_vcpus"
        case desiredRam = "desired_ram"
        case desiredBalloon = "desired_balloon"
    }
}

struct VmResizeZone: Content {
    let id: String?
    let desiredRam: Int64?
    
    enum CodingKeys: String, CodingKey {
        case id
        case desiredRam = "desired_ram"
    }
}

struct VmRemoveDevice: Content {
    let id: String?
}

struct VmSnapshotConfig: Content {
    let destinationUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case destinationUrl = "destination_url"
    }
}

struct VmCoredumpData: Content {
    let destinationUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case destinationUrl = "destination_url"
    }
}

struct RestoreConfig: Content {
    let sourceUrl: String
    let prefault: Bool?
    
    enum CodingKeys: String, CodingKey {
        case sourceUrl = "source_url"
        case prefault
    }
}

// MARK: - Error Types

enum CloudHypervisorError: Error, LocalizedError {
    case connectionFailed(String)
    case vmNotFound(String)
    case vmAlreadyExists(String)
    case vmNotCreated(String)
    case vmNotStarted(String)
    case vmNotPaused(String)
    case invalidConfiguration(String)
    case hypervisorError(HTTPResponseStatus, String)
    
    var errorDescription: String? {
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