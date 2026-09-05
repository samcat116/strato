import Foundation
import Logging
import StratoAgentCore
import StratoShared

// MARK: - Network Service Protocol

protocol NetworkServiceProtocol: Sendable {
    // Connection Management
    func connect() async throws
    func disconnect() async

    /// Read-only functional health for the dependency manager. This must not
    /// create bridges, rewrite chassis configuration, or reconnect sockets.
    func inspectDependencyHealth() async -> NetworkDependencyHealth

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
    /// `resolverNetworks` is `metadataNetworks`' twin (STR-40): the networks
    /// this host runs a resolver-enabled NIC on, whose link-local resolver
    /// address pair it must materialize — on that network's *own* localport,
    /// terminated in the **host** namespace rather than the chassis one (ADR
    /// 0008) — and answer on from the host's single CoreDNS. Nil ≙ no opinion,
    /// on the same terms. It carries each network's forwarders and search
    /// domain alongside the id, because a non-authority agent's `networks` list
    /// is empty and the NIC specs are the only input it has.
    ///
    /// `dnsZones` is the DNS desired state (STR-39, widened by STR-40): every
    /// zone attached to a network this agent either authors topology for or
    /// runs a local NIC on, with the zone's full effective record set —
    /// assembled fleet-wide, since a zone's names span every agent's VMs. The
    /// OVN `DNS` rows are still written only under `authoritative`; the
    /// resolver's zone files are rendered regardless. Nil ≙ no opinion (a
    /// pre-v36 control plane, or an agent with nothing to do for any zone):
    /// leave every managed row and rendered file alone.
    ///
    /// Returns the observations produced by this pass. Nil fields mean this
    /// adapter has no opinion; callers retain the latest result for the next
    /// `ObservedStateReport`.
    func reconcileNetworks(
        _ networks: [DesiredNetworkState], authoritative: Bool,
        securityGroups: [DesiredSecurityGroup]?, portMemberships: [DesiredPortMembership],
        metadataNetworks: [UUID]?, resolverNetworks: [ResolverNetworkConfig]?,
        dnsZones: [DesiredDNSZone]?
    ) async -> NetworkReconcileOutcome

    /// Latest native LB programming view. Nil means this service is not the
    /// site's topology author (or has not received a v43 opinion).
    func observedLoadBalancers() async -> [ObservedLoadBalancerState]?
}

extension NetworkServiceProtocol {
    func inspectDependencyHealth() async -> NetworkDependencyHealth { .healthy }

    func observedLoadBalancers() async -> [ObservedLoadBalancerState]? { nil }
}

/// Network-fabric observations from one level-triggered pass. This is the
/// network module's interface to the agent: actuator errors and OVN details stay
/// behind it, while the caller gets only wire-ready resource outcomes.
struct NetworkReconcileOutcome: Sendable {
    let networks: [ObservedNetworkState]?
    let securityGroups: [ObservedSecurityGroupState]?
    let portMemberships: [ObservedPortMembershipState]?

    static let noOpinion = NetworkReconcileOutcome(
        networks: nil, securityGroups: nil, portMemberships: nil)
}

typealias NetworkDependencyHealth = NodeDependencyFunctionalHealth

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
    /// Whether this NIC's workload has its per-instance metadata switch off
    /// (STR-185), which adds the metadata deny group to the set the port joins
    /// at creation — for `securityGroupIds`' reason, so a fresh VM is never
    /// briefly able to reach an endpoint its operator switched off. Only
    /// consulted for a managed NIC; an unmanaged one joins no groups at all.
    let metadataDenied: Bool
    /// MTU to apply to every host-side device this NIC creates, so the host path
    /// and the guest are told the same number. Nil leaves the kernel default.
    /// (Before issue STR-100 this stopped at `ResolvedNetworkAttachment` and only
    /// ever reached the guest's cloud-init, so host devices kept 1500 even on a
    /// network whose MTU had been lowered for an encapsulated uplink.)
    let mtu: Int?
    /// Whether this NIC's network publishes the instance metadata service. Its
    /// only effect here is DHCP option 121: the network's `DHCP_Options` row
    /// gains an on-link route to `InstanceMetadataEndpoint.address` (STR-53).
    /// False both when the network has the service off and when the control
    /// plane predates the field — the row simply keeps today's options, which
    /// is what a sender with no opinion should get.
    let metadataEnabled: Bool
    /// This NIC's network's own resolver addresses, or empty when it has no
    /// resolver (STR-40). Decides what the OVN `DHCP_Options` row hands the
    /// guest as `dns_server`, and what route the row advertises to reach it.
    let resolverAddresses: [String]

    init(
        networkName: String, networkId: UUID, macAddress: String? = nil, ipAddress: String? = nil,
        subnet: String? = nil, gateway: String? = nil, ip6Address: String? = nil, prefixLength6: Int? = nil,
        gateway6: String? = nil, subnet6: String? = nil, dhcpEnabled: Bool = false, dnsServers: [String] = [],
        domainName: String? = nil, leaseTime: Int? = nil, securityGroupIds: [UUID]? = nil,
        metadataDenied: Bool = false, mtu: Int? = nil,
        metadataEnabled: Bool = false,
        resolverAddresses: [String] = []
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
        self.metadataDenied = metadataDenied
        self.mtu = mtu
        self.metadataEnabled = metadataEnabled
        self.resolverAddresses = resolverAddresses
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
