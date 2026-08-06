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
    /// Realizes one NIC for a workload on this host. `nicIndex` is the NIC's
    /// position in the workload's interface list; it namespaces host-side
    /// resources (TAP device, logical switch port) so multi-NIC VMs don't
    /// collide. `placement` decides *where* the device is realized and what OVN
    /// calls the port — a jailed sandbox's VMM cannot see the host namespace, so
    /// its NIC takes a different path (issue STR-100).
    func createVMNetwork(
        vmId: String, nicIndex: Int, config: VMNetworkConfig, placement: NICPlacement
    ) async throws -> VMNetworkInfo
    /// Tears down the host-side resources of one NIC. Must be idempotent: it is
    /// called on delete and on create-failure rollback, possibly after a crash.
    /// `placement` must match the one the NIC was created with, so teardown
    /// looks for the right devices and port name.
    func detachVMFromNetwork(vmId: String, nicIndex: Int, placement: NICPlacement) async throws

    // Network Topology Management
    //
    // There is no imperative create/delete/attach surface: topology is
    // level-triggered from `reconcileNetworkTopology` alone. The old
    // message-driven path named its OVN objects after user-chosen network
    // names, which two projects may now share (issue #765), and nothing had
    // sent those messages since desired-state sync landed.

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
    ///
    /// `metadataNetworks` is the same shape for the same reason: the networks
    /// this host runs a metadata-enabled NIC on, whose link-local metadata
    /// address it must materialize in a local namespace (STR-49). Derived from
    /// this agent's own workload specs, not from `networks`, because a
    /// non-authoritative agent receives an empty topology list and still has
    /// guests to serve. Nil ≙ a control plane with no opinion — converge
    /// nothing, rather than reading silence as "tear every namespace down".
    ///
    /// Default no-op so platforms without a real SDN (macOS user-mode) ignore it.
    func reconcileNetworks(
        _ networks: [DesiredNetworkState], authoritative: Bool,
        securityGroups: [DesiredSecurityGroup]?, portMemberships: [DesiredPortMembership],
        metadataNetworks: [UUID]?
    ) async
}

extension NetworkServiceProtocol {
    /// Realizes a VM NIC — the overwhelmingly common case, and the only shape
    /// that existed before sandbox NICs.
    func createVMNetwork(vmId: String, nicIndex: Int, config: VMNetworkConfig) async throws -> VMNetworkInfo {
        try await createVMNetwork(vmId: vmId, nicIndex: nicIndex, config: config, placement: .hostNamespace)
    }

    /// Detaches a VM's first NIC (the only one pre-multi-NIC agents created).
    func detachVMFromNetwork(vmId: String) async throws {
        try await detachVMFromNetwork(vmId: vmId, nicIndex: 0, placement: .hostNamespace)
    }

    /// Detaches a VM NIC by index.
    func detachVMFromNetwork(vmId: String, nicIndex: Int) async throws {
        try await detachVMFromNetwork(vmId: vmId, nicIndex: nicIndex, placement: .hostNamespace)
    }

    /// No-op by default: only SDN-backed services (OVN on Linux) realize L3.
    func reconcileNetworks(
        _ networks: [DesiredNetworkState], authoritative: Bool,
        securityGroups: [DesiredSecurityGroup]?, portMemberships: [DesiredPortMembership],
        metadataNetworks: [UUID]?
    ) async {}
}

// MARK: - Network Configuration Models

struct VMNetworkConfig: Sendable {
    /// Human label for logs and external-ids. Never an identifier: names are
    /// unique only within a project (issue #765).
    let networkName: String
    /// The network's id. Every OVN object the NIC touches is named after it —
    /// the logical switch and the DHCP row's `network-id` external-id — so
    /// user-chosen names never enter the OVN namespace (issue #342).
    let networkId: UUID
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
    /// MTU to apply to every host-side device this NIC creates, so the host path
    /// and the guest are told the same number. Nil leaves the kernel default.
    /// (Before issue STR-100 this stopped at `ResolvedNetworkAttachment` and only
    /// ever reached the guest's cloud-init, so host devices kept 1500 even on a
    /// network whose MTU had been lowered for an encapsulated uplink.)
    let mtu: Int?

    init(
        networkName: String, networkId: UUID, macAddress: String? = nil, ipAddress: String? = nil,
        subnet: String? = nil, gateway: String? = nil, ip6Address: String? = nil, prefixLength6: Int? = nil,
        gateway6: String? = nil, subnet6: String? = nil, dhcpEnabled: Bool = false, dnsServers: [String] = [],
        domainName: String? = nil, leaseTime: Int? = nil, securityGroupIds: [UUID]? = nil, mtu: Int? = nil
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
        self.mtu = mtu
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
