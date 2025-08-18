import Foundation

// MARK: - VM Network Configuration

public struct VMNetworkConfig: Codable, Sendable {
    public let networkName: String
    public let macAddress: String?
    public let ipAddress: String?
    public let subnet: String
    public let gateway: String?
    public let vlanId: Int?
    public let portSecurity: Bool
    public let dhcp: Bool
    
    public init(
        networkName: String,
        macAddress: String? = nil,
        ipAddress: String? = nil,
        subnet: String,
        gateway: String? = nil,
        vlanId: Int? = nil,
        portSecurity: Bool = true,
        dhcp: Bool = true
    ) {
        self.networkName = networkName
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.subnet = subnet
        self.gateway = gateway
        self.vlanId = vlanId
        self.portSecurity = portSecurity
        self.dhcp = dhcp
    }
}

// MARK: - VM Network Information

public struct VMNetworkInfo: Codable, Sendable {
    public let vmId: String
    public let networkName: String
    public let portName: String
    public let portUUID: String?
    public let tapInterface: String
    public let macAddress: String
    public let ipAddress: String
    public let status: NetworkPortStatus
    public let createdAt: Date
    
    public init(
        vmId: String,
        networkName: String,
        portName: String,
        portUUID: String? = nil,
        tapInterface: String,
        macAddress: String,
        ipAddress: String,
        status: NetworkPortStatus = .active,
        createdAt: Date = Date()
    ) {
        self.vmId = vmId
        self.networkName = networkName
        self.portName = portName
        self.portUUID = portUUID
        self.tapInterface = tapInterface
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.status = status
        self.createdAt = createdAt
    }
}

// MARK: - Network Information

public struct NetworkInfo: Codable, Sendable {
    public let name: String
    public let uuid: String
    public let subnet: String
    public let gateway: String?
    public let vlanId: Int?
    public let dhcpEnabled: Bool
    public let dnsServers: [String]
    public let status: NetworkStatus
    public let portCount: Int
    public let createdAt: Date
    public let updatedAt: Date
    
    public init(
        name: String,
        uuid: String,
        subnet: String,
        gateway: String? = nil,
        vlanId: Int? = nil,
        dhcpEnabled: Bool = true,
        dnsServers: [String] = [],
        status: NetworkStatus = .active,
        portCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.name = name
        self.uuid = uuid
        self.subnet = subnet
        self.gateway = gateway
        self.vlanId = vlanId
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.status = status
        self.portCount = portCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Network Security Group

public struct NetworkSecurityGroup: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String?
    public let rules: [SecurityRule]
    public let appliedPorts: [String] // Port UUIDs
    public let organizationId: String?
    public let createdAt: Date
    public let updatedAt: Date
    
    public init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        rules: [SecurityRule] = [],
        appliedPorts: [String] = [],
        organizationId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.rules = rules
        self.appliedPorts = appliedPorts
        self.organizationId = organizationId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Security Rule

public struct SecurityRule: Codable, Sendable {
    public let id: UUID
    public let direction: TrafficDirection
    public let action: SecurityAction
    public let networkProtocol: NetworkProtocol
    public let sourceAddress: String? // CIDR or IP
    public let destinationAddress: String? // CIDR or IP
    public let sourcePort: PortRange?
    public let destinationPort: PortRange?
    public let priority: Int
    public let description: String?
    
    public init(
        id: UUID = UUID(),
        direction: TrafficDirection,
        action: SecurityAction,
        networkProtocol: NetworkProtocol,
        sourceAddress: String? = nil,
        destinationAddress: String? = nil,
        sourcePort: PortRange? = nil,
        destinationPort: PortRange? = nil,
        priority: Int = 1000,
        description: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.action = action
        self.networkProtocol = networkProtocol
        self.sourceAddress = sourceAddress
        self.destinationAddress = destinationAddress
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.priority = priority
        self.description = description
    }
}

// MARK: - Port Range

public struct PortRange: Codable, Sendable {
    public let start: Int
    public let end: Int
    
    public init(start: Int, end: Int? = nil) {
        self.start = start
        self.end = end ?? start
    }
    
    public var isSingle: Bool {
        return start == end
    }
    
    public var description: String {
        return isSingle ? "\(start)" : "\(start)-\(end)"
    }
}

// MARK: - Load Balancer Configuration

public struct LoadBalancerConfig: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let algorithm: LoadBalancingAlgorithm
    public let frontendIPs: [String]
    public let frontendPort: Int
    public let backendIPs: [String]
    public let backendPort: Int
    public let networkProtocol: NetworkProtocol
    public let healthCheck: HealthCheckConfig?
    public let stickySession: Bool
    
    public init(
        id: UUID = UUID(),
        name: String,
        algorithm: LoadBalancingAlgorithm = .roundRobin,
        frontendIPs: [String],
        frontendPort: Int,
        backendIPs: [String],
        backendPort: Int,
        networkProtocol: NetworkProtocol = .tcp,
        healthCheck: HealthCheckConfig? = nil,
        stickySession: Bool = false
    ) {
        self.id = id
        self.name = name
        self.algorithm = algorithm
        self.frontendIPs = frontendIPs
        self.frontendPort = frontendPort
        self.backendIPs = backendIPs
        self.backendPort = backendPort
        self.networkProtocol = networkProtocol
        self.healthCheck = healthCheck
        self.stickySession = stickySession
    }
}

// MARK: - Health Check Configuration

public struct HealthCheckConfig: Codable, Sendable {
    public let networkProtocol: NetworkProtocol
    public let port: Int
    public let path: String? // For HTTP health checks
    public let interval: TimeInterval
    public let timeout: TimeInterval
    public let retries: Int
    
    public init(
        networkProtocol: NetworkProtocol,
        port: Int,
        path: String? = nil,
        interval: TimeInterval = 30,
        timeout: TimeInterval = 5,
        retries: Int = 3
    ) {
        self.networkProtocol = networkProtocol
        self.port = port
        self.path = path
        self.interval = interval
        self.timeout = timeout
        self.retries = retries
    }
}

// MARK: - Network Statistics

public struct NetworkStatistics: Codable, Sendable {
    public let portName: String
    public let bytesReceived: UInt64
    public let bytesSent: UInt64
    public let packetsReceived: UInt64
    public let packetsSent: UInt64
    public let droppedPackets: UInt64
    public let errors: UInt64
    public let timestamp: Date
    
    public init(
        portName: String,
        bytesReceived: UInt64 = 0,
        bytesSent: UInt64 = 0,
        packetsReceived: UInt64 = 0,
        packetsSent: UInt64 = 0,
        droppedPackets: UInt64 = 0,
        errors: UInt64 = 0,
        timestamp: Date = Date()
    ) {
        self.portName = portName
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.packetsReceived = packetsReceived
        self.packetsSent = packetsSent
        self.droppedPackets = droppedPackets
        self.errors = errors
        self.timestamp = timestamp
    }
}

// MARK: - Enums

public enum NetworkPortStatus: String, Codable, CaseIterable, Sendable {
    case active = "active"
    case inactive = "inactive"
    case error = "error"
    case pending = "pending"
}

public enum NetworkStatus: String, Codable, CaseIterable, Sendable {
    case active = "active"
    case inactive = "inactive"
    case error = "error"
    case creating = "creating"
    case deleting = "deleting"
}

public enum TrafficDirection: String, Codable, CaseIterable, Sendable {
    case ingress = "ingress"
    case egress = "egress"
}

public enum SecurityAction: String, Codable, CaseIterable, Sendable {
    case allow = "allow"
    case deny = "deny"
    case drop = "drop"
}

public enum NetworkProtocol: String, Codable, CaseIterable, Sendable {
    case tcp = "tcp"
    case udp = "udp"
    case icmp = "icmp"
    case any = "any"
}

public enum LoadBalancingAlgorithm: String, Codable, CaseIterable, Sendable {
    case roundRobin = "round_robin"
    case leastConnections = "least_connections"
    case sourceIP = "source_ip"
    case weighted = "weighted"
}

// MARK: - Extensions

public extension VMNetworkInfo {
    var isActive: Bool {
        return status == .active
    }
    
    var canDetach: Bool {
        return status == .active || status == .inactive
    }
}

public extension NetworkInfo {
    var isActive: Bool {
        return status == .active
    }
    
    var canDelete: Bool {
        return portCount == 0 && status != .deleting
    }
    
    var subnetInfo: (network: String, prefixLength: Int)? {
        let components = subnet.split(separator: "/")
        guard components.count == 2,
              let prefixLength = Int(components[1]) else {
            return nil
        }
        return (network: String(components[0]), prefixLength: prefixLength)
    }
}

public extension SecurityRule {
    var isIngressRule: Bool {
        return direction == .ingress
    }
    
    var isEgressRule: Bool {
        return direction == .egress
    }
    
    var allowsTraffic: Bool {
        return action == .allow
    }
}