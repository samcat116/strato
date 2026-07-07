import Foundation
import Logging
import StratoAgentCore
import StratoShared

// MARK: - Network Service Protocol

protocol NetworkServiceProtocol: Sendable {
    // Connection Management
    func connect() async throws
    func disconnect() async

    // VM Network Lifecycle
    /// Realizes one NIC for a VM on this host. `nicIndex` is the NIC's position
    /// in the VM's interface list; it namespaces host-side resources (TAP device,
    /// logical switch port) so multi-NIC VMs don't collide.
    func createVMNetwork(vmId: String, nicIndex: Int, config: VMNetworkConfig) async throws -> VMNetworkInfo
    func attachVMToNetwork(vmId: String, networkName: String, macAddress: String?) async throws -> VMNetworkInfo
    /// Tears down the host-side resources of one NIC. Must be idempotent: it is
    /// called on delete and on create-failure rollback, possibly after a crash.
    func detachVMFromNetwork(vmId: String, nicIndex: Int) async throws
    func getVMNetworkInfo(vmId: String) async throws -> VMNetworkInfo?

    // Network Topology Management
    func createLogicalNetwork(name: String, subnet: String, gateway: String?) async throws -> UUID
    func deleteLogicalNetwork(name: String) async throws
    func listLogicalNetworks() async throws -> [NetworkInfo]
}

extension NetworkServiceProtocol {
    /// Detaches a VM's first NIC (the only one pre-multi-NIC agents created).
    func detachVMFromNetwork(vmId: String) async throws {
        try await detachVMFromNetwork(vmId: vmId, nicIndex: 0)
    }
}

// MARK: - Network Configuration Models

struct VMNetworkConfig: Sendable {
    let networkName: String
    let macAddress: String?
    let ipAddress: String?
    let subnet: String?
    let gateway: String?
    /// When true, program OVN's native DHCP responder for this NIC's subnet so
    /// the guest learns its `ipAddress`, `gateway`, and `dnsServers` over DHCP.
    let dhcpEnabled: Bool
    /// DNS resolvers to advertise over DHCP (`dns_server` option).
    let dnsServers: [String]
    /// DNS search domain to advertise over DHCP (`domain_name` option).
    let domainName: String?
    /// DHCP lease time in seconds; a default is applied when nil.
    let leaseTime: Int?

    init(
        networkName: String, macAddress: String? = nil, ipAddress: String? = nil, subnet: String? = nil,
        gateway: String? = nil, dhcpEnabled: Bool = false, dnsServers: [String] = [],
        domainName: String? = nil, leaseTime: Int? = nil
    ) {
        self.networkName = networkName
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.subnet = subnet
        self.gateway = gateway
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.leaseTime = leaseTime
    }
}

struct VMNetworkInfo: Codable, Sendable {
    let vmId: String
    let networkName: String
    let portName: String
    let portUUID: String?
    /// How the hypervisor should realize this NIC on the host.
    let attachment: NetworkAttachment
    let macAddress: String
    /// The IP bound to the port, when one was assigned (control-plane IPAM or an
    /// existing port's addresses). Nil when the network hands out addresses
    /// itself (user-mode SLIRP) or no allocation exists.
    let ipAddress: String?
}

struct NetworkInfo: Codable, Sendable {
    let name: String
    let uuid: String
    let subnet: String
    let gateway: String?
    let vlanId: Int?
    let dhcpEnabled: Bool?
    let dnsServers: [String]?

    init(
        name: String, uuid: String, subnet: String, gateway: String? = nil, vlanId: Int? = nil,
        dhcpEnabled: Bool? = nil, dnsServers: [String]? = nil
    ) {
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
