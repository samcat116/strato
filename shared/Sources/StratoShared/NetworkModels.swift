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
            let prefixLength = Int(components[1])
        else {
            return nil
        }
        return (network: String(components[0]), prefixLength: prefixLength)
    }
}
