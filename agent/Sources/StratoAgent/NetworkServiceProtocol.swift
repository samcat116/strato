import Foundation
import Logging
import StratoShared

// MARK: - Network Service Protocol

protocol NetworkServiceProtocol: Sendable {
    // Connection Management
    func connect() async throws
    func disconnect() async

    // VM Network Lifecycle
    func createVMNetwork(vmId: String, config: VMNetworkConfig) async throws -> VMNetworkInfo
    func attachVMToNetwork(vmId: String, networkName: String, macAddress: String?) async throws -> VMNetworkInfo
    func detachVMFromNetwork(vmId: String) async throws
    func getVMNetworkInfo(vmId: String) async throws -> VMNetworkInfo?

    // Network Topology Management
    func createLogicalNetwork(name: String, subnet: String, gateway: String?) async throws -> UUID
    func deleteLogicalNetwork(name: String) async throws
    func listLogicalNetworks() async throws -> [NetworkInfo]
}

// MARK: - Network Configuration Models

struct VMNetworkConfig: Sendable {
    let networkName: String
    let macAddress: String?
    let ipAddress: String?
    let subnet: String?
    let gateway: String?

    init(networkName: String, macAddress: String? = nil, ipAddress: String? = nil, subnet: String? = nil, gateway: String? = nil) {
        self.networkName = networkName
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.subnet = subnet
        self.gateway = gateway
    }
}

struct VMNetworkInfo: Codable, Sendable {
    let vmId: String
    let networkName: String
    let portName: String
    let portUUID: String?
    let tapInterface: String
    let macAddress: String
    let ipAddress: String
}

struct NetworkInfo: Codable, Sendable {
    let name: String
    let uuid: String
    let subnet: String
    let gateway: String?
    let vlanId: Int?
    let dhcpEnabled: Bool?
    let dnsServers: [String]?

    init(name: String, uuid: String, subnet: String, gateway: String? = nil, vlanId: Int? = nil, dhcpEnabled: Bool? = nil, dnsServers: [String]? = nil) {
        self.name = name
        self.uuid = uuid
        self.subnet = subnet
        self.gateway = gateway
        self.vlanId = vlanId
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
    }
}

// MARK: - Mock Types for Development

/// Mock network type used for development/testing on macOS
struct MockNetwork: Sendable {
    let name: String
    let subnet: String
    let gateway: String?
}

/// Mock VM network attachment type used for development/testing on macOS
struct MockVMNetworkAttachment: Sendable {
    let vmId: String
    let networkName: String
    let macAddress: String
    let ipAddress: String
}
