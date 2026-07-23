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

    /// Converge this host's L3 network topology (logical routers, router ports,
    /// SNAT uplinks) toward the control plane's authoritative desired network
    /// set (issue #342). Level-triggered and idempotent, like VM reconciliation:
    /// a network omitted from `networks` has its owned L3 objects torn down.
    /// `authoritative: false` (issue #343) means another agent authors the
    /// shared site NB — topology must be left entirely alone, teardown included.
    ///
    /// `securityGroups` is the authority's port-group + ACL desired state (nil
    /// from control planes without an opinion — never "tear down all port
    /// groups"); `portMemberships` is this host's own VM ports' desired group
    /// membership, converged on *every* agent regardless of authority.
    /// Default no-op so platforms without a real SDN (macOS user-mode) ignore it.
    func reconcileNetworks(
        _ networks: [DesiredNetworkState], authoritative: Bool,
        securityGroups: [DesiredSecurityGroup]?, portMemberships: [DesiredPortMembership]
    ) async
}

extension NetworkServiceProtocol {
    /// Detaches a VM's first NIC (the only one pre-multi-NIC agents created).
    func detachVMFromNetwork(vmId: String) async throws {
        try await detachVMFromNetwork(vmId: vmId, nicIndex: 0)
    }

    /// No-op by default: only SDN-backed services (OVN on Linux) realize L3.
    func reconcileNetworks(
        _ networks: [DesiredNetworkState], authoritative: Bool,
        securityGroups: [DesiredSecurityGroup]?, portMemberships: [DesiredPortMembership]
    ) async {}
}

// MARK: - Network Configuration Models

struct VMNetworkConfig: Sendable {
    let networkName: String
    /// The network's id; when present the agent names the OVN logical switch
    /// after it (not `networkName`), matching the network reconciler and keeping
    /// user-chosen names out of the OVN namespace (issue #342).
    let networkId: UUID?
    let macAddress: String?
    let ipAddress: String?
    let subnet: String?
    let gateway: String?
    /// IPv6 assignment on a dual-stack network: address, prefix length, the
    /// per-family gateway, and the network CIDR (keys the DHCPv6 options row).
    let ip6Address: String?
    let prefixLength6: Int?
    let gateway6: String?
    let subnet6: String?
    /// When true, program OVN's native DHCP responder for this NIC's subnet so
    /// the guest learns its `ipAddress`, `gateway`, and `dnsServers` over DHCP.
    /// Covers both families: a dual-stack NIC gets DHCPv4 and DHCPv6.
    let dhcpEnabled: Bool
    /// DNS resolvers to advertise over DHCP (`dns_server` option). May be
    /// mixed-family; each DHCP family's options take their own entries.
    let dnsServers: [String]
    /// DNS search domain to advertise over DHCP (`domain_name` option).
    let domainName: String?
    /// DHCP lease time in seconds; a default is applied when nil.
    let leaseTime: Int?
    /// Security groups this NIC belongs to: the port joins each group's OVN
    /// port group (plus the global drop group) at creation, so a fresh VM is
    /// never briefly unfiltered. Nil means unmanaged (specs from control
    /// planes without security groups, and sandbox NICs) — the port joins no
    /// groups at all.
    let securityGroupIds: [UUID]?

    init(
        networkName: String, networkId: UUID? = nil, macAddress: String? = nil, ipAddress: String? = nil,
        subnet: String? = nil, gateway: String? = nil, ip6Address: String? = nil, prefixLength6: Int? = nil,
        gateway6: String? = nil, subnet6: String? = nil, dhcpEnabled: Bool = false, dnsServers: [String] = [],
        domainName: String? = nil, leaseTime: Int? = nil, securityGroupIds: [UUID]? = nil
    ) {
        self.networkName = networkName
        self.networkId = networkId
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.subnet = subnet
        self.gateway = gateway
        self.ip6Address = ip6Address
        self.prefixLength6 = prefixLength6
        self.gateway6 = gateway6
        self.subnet6 = subnet6
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.leaseTime = leaseTime
        self.securityGroupIds = securityGroupIds
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
    /// The IPv6 address bound to the port on a dual-stack network, same
    /// provenance as `ipAddress`.
    let ip6Address: String?

    init(
        vmId: String, networkName: String, portName: String, portUUID: String?,
        attachment: NetworkAttachment, macAddress: String, ipAddress: String?, ip6Address: String? = nil
    ) {
        self.vmId = vmId
        self.networkName = networkName
        self.portName = portName
        self.portUUID = portUUID
        self.attachment = attachment
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.ip6Address = ip6Address
    }
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
