import Foundation
import Logging
import StratoShared

// First-class L3 network reconciliation (issue #342, epic #341).
//
// The control plane sends the authoritative set of logical networks an agent
// should realize (`DesiredStateMessage.networks`). This file is the pure,
// unit-testable core that turns that desired set into an OVN topology plan
// (routers, router ports, external uplinks, SNAT rules) and diffs it against
// what OVN currently has to compute teardown actions. It has no SwiftOVN
// dependency — the live OVSDB side effects live in `NetworkServiceLinux`
// behind `NetworkActuator`, mirroring how `OVNChassisBootstrap` keeps the
// chassis decisions testable off the wire.
//
// Router scope is per-project: every network sharing a `routerKey` shares one
// logical router, so VMs on different switches route to each other (east-west);
// a project-less network keys its router on its own id and still gets SNAT.

// MARK: - Naming and derivation

/// Deterministic OVN object names derived from desired-network identity, so a
/// replayed sync always targets the same rows (idempotency) and teardown can
/// find them again without persisted state.
public enum OVNNaming {
    /// The tenant logical switch name for a network. Derived from the network's
    /// UUID, never its user-chosen name, so a user cannot pick a name that
    /// collides with a Strato-managed switch (e.g. a provider `ls-ext-*` switch)
    /// in OVN's shared `Logical_Switch` namespace (issue #342).
    public static func switchName(networkId: UUID) -> String {
        "net-\(networkId.uuidString.lowercased())"
    }
    public static func routerName(routerKey: String) -> String { "lr-\(routerKey)" }
    /// A network attaches to exactly one router, so its id uniquely names the
    /// router port.
    public static func routerPortName(networkId: UUID) -> String {
        "lrp-\(networkId.uuidString.lowercased())"
    }
    /// The `type=router` switch port peering the tenant switch to its router port.
    public static func switchRouterPortName(networkId: UUID) -> String {
        "lsp-\(networkId.uuidString.lowercased())-router"
    }
    public static func externalSwitchName(routerKey: String) -> String { "ls-ext-\(routerKey)" }
    public static func externalRouterPortName(routerKey: String) -> String { "lrp-ext-\(routerKey)" }
    /// The `type=router` switch port peering the external switch to the router's
    /// gateway port (the external-side counterpart of a tenant switch port).
    public static func externalSwitchRouterPortName(routerKey: String) -> String {
        "lsp-ext-\(routerKey)-router"
    }
    public static func localnetPortName(routerKey: String) -> String { "ln-ext-\(routerKey)" }
    /// The `Gateway_Chassis` row pinning a router's external port to a chassis,
    /// named `<port>-<chassis>` to match `ovn-nbctl lrp-set-gateway-chassis`.
    public static func gatewayChassisName(portName: String, chassis: String) -> String {
        "\(portName)-\(chassis)"
    }

    /// A stable, locally-administered unicast MAC for a router port, derived
    /// from its gateway IP (gateways are unique per network, so the MAC is too).
    /// `02:` sets the locally-administered bit and clears the multicast bit;
    /// the low four octets are the gateway address. Deterministic, so a replayed
    /// sync never churns the port's MAC. Nil when the gateway isn't IPv4.
    public static func routerPortMAC(gateway: String) -> String? {
        guard let ip = IPv4Address(gateway) else { return nil }
        return String(
            format: "02:00:%02x:%02x:%02x:%02x",
            (ip.raw >> 24) & 0xff, (ip.raw >> 16) & 0xff, (ip.raw >> 8) & 0xff, ip.raw & 0xff)
    }

    /// OVN logical switch port name for one NIC of a VM. NIC 0 keeps the
    /// historical `vm-<vmId>` name so ports created by older agents are still
    /// found and torn down; additional NICs are suffixed with their index.
    /// `vmId` is the canonical (uppercase) UUID string, matching the manifest
    /// keys and the ids the control plane sends in `DesiredVMState`.
    public static func vmPortName(vmId: String, nicIndex: Int) -> String {
        nicIndex == 0 ? "vm-\(vmId)" : "vm-\(vmId)-\(nicIndex)"
    }

    /// A stable, locally-administered unicast MAC for a floating IP, derived
    /// from the floating address itself (floating IPs are unique per site, so
    /// the MAC is too). Used as the `dnat_and_snat` rule's `external_mac`, the
    /// address the VM's chassis answers external ARP with for distributed NAT.
    /// The `02:01:` prefix keeps it disjoint from `routerPortMAC`'s `02:00:`
    /// namespace so a floating IP can never mint a router port's MAC. Nil when
    /// the address isn't IPv4.
    public static func floatingIPMAC(externalIP: String) -> String? {
        guard let ip = IPv4Address(externalIP) else { return nil }
        return String(
            format: "02:01:%02x:%02x:%02x:%02x",
            (ip.raw >> 24) & 0xff, (ip.raw >> 16) & 0xff, (ip.raw >> 8) & 0xff, ip.raw & 0xff)
    }
}

// MARK: - Desired topology plan

/// A tenant logical switch the plan wants to exist.
public struct DesiredSwitch: Equatable, Sendable {
    /// The UUID-derived OVN switch name (`OVNNaming.switchName`).
    public let name: String
    public let subnet: String
    /// The network's user-facing name, i.e. the switch name older agents used
    /// before UUID naming. The actuator renames such a legacy switch in place to
    /// `name` on upgrade, so existing VM ports migrate without re-creation.
    public let legacyName: String

    public init(name: String, subnet: String, legacyName: String) {
        self.name = name
        self.subnet = subnet
        self.legacyName = legacyName
    }
}

/// A router port giving one tenant network its L3 gateway, plus the peering
/// `type=router` switch port on that network's switch.
public struct DesiredRouterPort: Equatable, Sendable {
    public let name: String
    public let switchName: String
    public let switchPortName: String
    public let mac: String
    /// The router port's addresses, `gateway/prefix` per family — v4 first
    /// (e.g. `192.168.1.1/24`), then the v6 gateway (`fd..::1/64`) when the
    /// network is dual-stack. Both live on one port; OVN's `networks` column
    /// is a set.
    public let cidrs: [String]
    /// OVN `ipv6_ra_configs` for the port when the network is dual-stack —
    /// Router Advertisements are what hand guests their default route (DHCPv6
    /// cannot), so `address_mode: dhcpv6_stateful` RAs accompany DHCPv6-
    /// assigned addresses. Nil on v4-only ports (actuators clear the column).
    public let ipv6RAConfigs: [String: String]?

    public init(
        name: String, switchName: String, switchPortName: String, mac: String, cidrs: [String],
        ipv6RAConfigs: [String: String]? = nil
    ) {
        self.name = name
        self.switchName = switchName
        self.switchPortName = switchPortName
        self.mac = mac
        self.cidrs = cidrs
        self.ipv6RAConfigs = ipv6RAConfigs
    }
}

/// One floating IP the plan wants realized as a `dnat_and_snat` rule on a
/// router (issue #344). `externalIP` is the floating address, `logicalIP` the
/// VM NIC's fixed address. `logicalPort`/`externalMAC` make the NAT
/// *distributed* — OVN then handles the FIP on the chassis hosting the VM's
/// port instead of the gateway chassis; when either is nil the rule stays
/// centralized (still correct, just hairpinned through the gateway).
public struct DesiredDNATRule: Hashable, Sendable {
    public let externalIP: String
    public let logicalIP: String
    public let logicalPort: String?
    public let externalMAC: String?

    public init(externalIP: String, logicalIP: String, logicalPort: String?, externalMAC: String?) {
        self.externalIP = externalIP
        self.logicalIP = logicalIP
        self.logicalPort = logicalPort
        self.externalMAC = externalMAC
    }
}

/// One per-project (or per-global-network) logical router the plan wants.
public struct DesiredRouter: Equatable, Sendable {
    public let name: String
    public let routerKey: String
    public let ports: [DesiredRouterPort]
    /// Tenant subnets (CIDR) that should egress via SNAT to the site uplink.
    public let snatSubnets: [String]
    /// Floating IPs to realize as `dnat_and_snat` rules on this router.
    public let dnatRules: [DesiredDNATRule]

    public init(
        name: String, routerKey: String, ports: [DesiredRouterPort], snatSubnets: [String],
        dnatRules: [DesiredDNATRule] = []
    ) {
        self.name = name
        self.routerKey = routerKey
        self.ports = ports
        self.snatSubnets = snatSubnets
        self.dnatRules = dnatRules
    }

    /// Whether this router needs an external uplink attachment (any NAT — a
    /// floating IP needs the uplink exactly like subnet SNAT does).
    public var needsUplink: Bool { !snatSubnets.isEmpty || !dnatRules.isEmpty }
    public var externalSwitchName: String { OVNNaming.externalSwitchName(routerKey: routerKey) }
    public var externalRouterPortName: String { OVNNaming.externalRouterPortName(routerKey: routerKey) }
    public var externalSwitchRouterPortName: String {
        OVNNaming.externalSwitchRouterPortName(routerKey: routerKey)
    }
    public var localnetPortName: String { OVNNaming.localnetPortName(routerKey: routerKey) }
}

/// The complete desired OVN L3 topology for one agent, derived purely from the
/// control plane's desired networks. Concrete uplink addressing (the host's
/// outbound IP) is resolved later by the actuator, not here.
public struct NetworkTopologyPlan: Equatable, Sendable {
    public let switches: [DesiredSwitch]
    public let routers: [DesiredRouter]

    public init(switches: [DesiredSwitch], routers: [DesiredRouter]) {
        self.switches = switches
        self.routers = routers
    }

    /// The observed topology this plan implies once fully realized — the set of
    /// object identities the diff should converge to. Used to compute teardown
    /// (observed − desired) and as the fixture for idempotency tests.
    public var expectedTopology: ObservedNetworkTopology {
        var routerNames = Set<String>()
        var routerPortNames = Set<String>()
        var switchRouterPortNames = Set<String>()
        var externalSwitchNames = Set<String>()
        var snatRules = Set<SNATRuleKey>()
        var dnatRules = Set<DNATRuleKey>()

        for router in routers {
            routerNames.insert(router.name)
            for port in router.ports {
                routerPortNames.insert(port.name)
                switchRouterPortNames.insert(port.switchPortName)
            }
            if router.needsUplink {
                externalSwitchNames.insert(router.externalSwitchName)
                routerPortNames.insert(router.externalRouterPortName)
                switchRouterPortNames.insert(router.externalSwitchRouterPortName)
                for subnet in router.snatSubnets {
                    snatRules.insert(SNATRuleKey(router: router.name, logicalIP: subnet))
                }
                for rule in router.dnatRules {
                    dnatRules.insert(DNATRuleKey(router: router.name, externalIP: rule.externalIP))
                }
            }
        }

        return ObservedNetworkTopology(
            routerNames: routerNames,
            routerPortNames: routerPortNames,
            switchRouterPortNames: switchRouterPortNames,
            externalSwitchNames: externalSwitchNames,
            snatRules: snatRules,
            dnatRules: dnatRules)
    }
}

// MARK: - Observed topology and teardown

/// Identity of one SNAT rule, keyed by the router it lives on and the tenant
/// subnet it translates. The external IP is deliberately excluded: it can be
/// re-set in place (the uplink IP may change) without a delete/recreate.
public struct SNATRuleKey: Hashable, Sendable {
    public let router: String
    public let logicalIP: String
    public init(router: String, logicalIP: String) {
        self.router = router
        self.logicalIP = logicalIP
    }
}

/// Identity of one `dnat_and_snat` (floating IP) rule, keyed by the router it
/// lives on and the floating (external) address. The logical IP is
/// deliberately excluded: re-attaching a floating IP to another VM re-points
/// the same rule in place (like SNAT's re-pointable external IP) rather than
/// delete/recreate.
public struct DNATRuleKey: Hashable, Sendable {
    public let router: String
    public let externalIP: String
    public init(router: String, externalIP: String) {
        self.router = router
        self.externalIP = externalIP
    }
}

/// A snapshot of the OVN L3 objects this reconciler owns, as observed on the
/// host. Gathered by the actuator from OVSDB; diffed against a plan to find
/// what to tear down. Tenant logical switches are intentionally absent — their
/// lifecycle stays with the VM-attach path, not this reconciler.
public struct ObservedNetworkTopology: Equatable, Sendable {
    public var routerNames: Set<String>
    public var routerPortNames: Set<String>
    public var switchRouterPortNames: Set<String>
    public var externalSwitchNames: Set<String>
    public var snatRules: Set<SNATRuleKey>
    public var dnatRules: Set<DNATRuleKey>

    public init(
        routerNames: Set<String> = [],
        routerPortNames: Set<String> = [],
        switchRouterPortNames: Set<String> = [],
        externalSwitchNames: Set<String> = [],
        snatRules: Set<SNATRuleKey> = [],
        dnatRules: Set<DNATRuleKey> = []
    ) {
        self.routerNames = routerNames
        self.routerPortNames = routerPortNames
        self.switchRouterPortNames = switchRouterPortNames
        self.externalSwitchNames = externalSwitchNames
        self.snatRules = snatRules
        self.dnatRules = dnatRules
    }
}

/// One teardown side effect: an owned OVN object present on the host that the
/// desired plan no longer wants. Ordered by the reconciler so dependents go
/// before the objects they reference.
public enum NetworkTeardownAction: Equatable, Sendable {
    case dnat(router: String, externalIP: String)
    case snat(router: String, logicalIP: String)
    case switchRouterPort(name: String)
    case routerPort(name: String)
    case externalSwitch(name: String)
    case router(name: String)
}

/// OVN object identities that teardown must never touch, regardless of the plan.
/// Built only from the networks a sync *skipped as stale* (present in the sync
/// but at a generation older than one already applied), so those networks —
/// absent from the applied plan yet still live — are left exactly as-is. It is
/// deliberately NOT built from current networks: a current network's dropped
/// objects (e.g. SNAT after `externalAccess` is turned off) must still be torn
/// down. SNAT is protected precisely by (router, subnet), not by router, so a
/// stale network can't shield a current sibling's SNAT on a shared router.
public struct ProtectedTopology: Equatable, Sendable {
    public var routerNames: Set<String>
    public var routerPortNames: Set<String>
    public var switchRouterPortNames: Set<String>
    public var externalSwitchNames: Set<String>
    public var snatRules: Set<SNATRuleKey>
    public var dnatRules: Set<DNATRuleKey>

    public init(
        routerNames: Set<String> = [],
        routerPortNames: Set<String> = [],
        switchRouterPortNames: Set<String> = [],
        externalSwitchNames: Set<String> = [],
        snatRules: Set<SNATRuleKey> = [],
        dnatRules: Set<DNATRuleKey> = []
    ) {
        self.routerNames = routerNames
        self.routerPortNames = routerPortNames
        self.switchRouterPortNames = switchRouterPortNames
        self.externalSwitchNames = externalSwitchNames
        self.snatRules = snatRules
        self.dnatRules = dnatRules
    }

    public var isEmpty: Bool {
        routerNames.isEmpty && routerPortNames.isEmpty && switchRouterPortNames.isEmpty
            && externalSwitchNames.isEmpty && snatRules.isEmpty && dnatRules.isEmpty
    }
}

// MARK: - Reconciler

/// Pure planning for L3 network reconciliation. No side effects, fully testable.
public enum NetworkReconciler {

    /// Build the desired OVN topology from the control plane's desired networks.
    ///
    /// * One tenant switch per network.
    /// * Networks grouped by `routerKey` share one logical router; each network
    ///   with a gateway contributes a router port (its L3 gateway) — this is
    ///   what gives cross-switch east-west within a project.
    /// * A network with a gateway and `externalAccess` contributes a SNAT subnet
    ///   on its router — outbound internet.
    /// * A router-key group with no gatewayed network yields no router (nothing
    ///   to route). Output is fully sorted, so the plan is deterministic.
    public static func plan(networks: [DesiredNetworkState]) -> NetworkTopologyPlan {
        let sorted = networks.sorted { $0.name < $1.name }

        let switches = sorted.map {
            DesiredSwitch(
                name: OVNNaming.switchName(networkId: $0.networkId), subnet: $0.subnet, legacyName: $0.name)
        }

        // Group by router key, preserving deterministic order.
        var groups: [String: [DesiredNetworkState]] = [:]
        for network in sorted { groups[network.routerKey, default: []].append(network) }

        var routers: [DesiredRouter] = []
        for routerKey in groups.keys.sorted() {
            let members = groups[routerKey] ?? []
            var ports: [DesiredRouterPort] = []
            var snatSubnets: [String] = []
            var dnatRules: [DesiredDNATRule] = []

            for network in members {
                // L3 needs a gateway (the router-port IP) and a prefix from the
                // subnet CIDR; a network missing either is switch-only. The MAC
                // stays derived from the v4 gateway (v4 remains mandatory) —
                // rederiving it would rewrite every existing port's MAC on
                // upgrade and invalidate guest neighbor caches.
                guard let gateway = network.gateway,
                    let prefix = prefixLength(ofCIDR: network.subnet),
                    let mac = OVNNaming.routerPortMAC(gateway: gateway)
                else { continue }

                // Dual-stack: the same port carries the v6 gateway and sends
                // RAs. Unparsable v6 config degrades the port to v4-only —
                // never drops it (v4 service must survive a bad v6 edit).
                var cidrs = ["\(gateway)/\(prefix)"]
                var raConfigs: [String: String]?
                var snatSubnet6: String?
                if let subnet6 = network.subnet6, let gateway6 = network.gateway6,
                    let cidr6 = IPv6CIDR(subnet6), let gw6 = IPv6Address(gateway6),
                    cidr6.contains(gw6)
                {
                    cidrs.append("\(gw6)/\(cidr6.prefix)")
                    raConfigs = ipv6RAConfigs
                    snatSubnet6 = cidr6.description
                }

                ports.append(
                    DesiredRouterPort(
                        name: OVNNaming.routerPortName(networkId: network.networkId),
                        switchName: OVNNaming.switchName(networkId: network.networkId),
                        switchPortName: OVNNaming.switchRouterPortName(networkId: network.networkId),
                        mac: mac,
                        cidrs: cidrs,
                        ipv6RAConfigs: raConfigs))

                // Dual-stack egress: the v6 prefix gets its own SNAT rule beside
                // the v4 one, so the default route the port's RAs advertise
                // actually leads somewhere (issue #519). Planned whenever the
                // port is dual-stack — the actuator skips it when the operator
                // configured no IPv6 uplink, exactly as it skips v4 SNAT with no
                // `[ovn_uplink]` at all. Canonical (RFC 5952, masked) form, so
                // the key matches what OVN reports back and never churns.
                if network.externalAccess {
                    snatSubnets.append(network.subnet)
                    if let snatSubnet6 { snatSubnets.append(snatSubnet6) }

                    // Floating IPs (issue #344): each attachment becomes a
                    // `dnat_and_snat` rule on this router, with the VM's LSP
                    // name + a derived MAC so the NAT is distributed to the
                    // VM's chassis. Gated on `externalAccess` — an isolated
                    // (`-internal`) router must never grow an uplink, and the
                    // control plane rejects attaching to no-egress networks.
                    for fip in network.floatingIPs ?? [] {
                        dnatRules.append(
                            DesiredDNATRule(
                                externalIP: fip.externalIP,
                                logicalIP: fip.logicalIP,
                                logicalPort: OVNNaming.vmPortName(
                                    vmId: fip.vmId.uuidString, nicIndex: fip.nicIndex),
                                externalMAC: OVNNaming.floatingIPMAC(externalIP: fip.externalIP)))
                    }
                }
            }

            // No gatewayed network in this group → no router to create.
            guard !ports.isEmpty else { continue }

            routers.append(
                DesiredRouter(
                    name: OVNNaming.routerName(routerKey: routerKey),
                    routerKey: routerKey,
                    ports: ports,
                    snatSubnets: snatSubnets,
                    dnatRules: dnatRules.sorted { $0.externalIP < $1.externalIP }))
        }

        return NetworkTopologyPlan(switches: switches, routers: routers)
    }

    /// The OVN objects protected from teardown for the networks a sync skipped
    /// as stale — every object each (and its shared router/uplink) could own, so
    /// a stale network keeps its live objects. Pass ONLY the stale-skipped
    /// networks: current networks are governed by the plan so their dropped
    /// objects are still torn down. SNAT is protected precisely by (router,
    /// subnet) so a stale network shields only its own SNAT on a shared router.
    public static func protectedTopology(forStale stale: [DesiredNetworkState]) -> ProtectedTopology {
        var protected = ProtectedTopology()
        for network in stale {
            let routerName = OVNNaming.routerName(routerKey: network.routerKey)
            protected.routerPortNames.insert(OVNNaming.routerPortName(networkId: network.networkId))
            protected.switchRouterPortNames.insert(
                OVNNaming.switchRouterPortName(networkId: network.networkId))
            protected.routerNames.insert(routerName)
            protected.externalSwitchNames.insert(OVNNaming.externalSwitchName(routerKey: network.routerKey))
            protected.routerPortNames.insert(OVNNaming.externalRouterPortName(routerKey: network.routerKey))
            protected.switchRouterPortNames.insert(
                OVNNaming.externalSwitchRouterPortName(routerKey: network.routerKey))
            protected.snatRules.insert(SNATRuleKey(router: routerName, logicalIP: network.subnet))
            // Protect the v6 SNAT rule on the same terms. Keyed off `subnet6`
            // parsing alone — a superset of the condition that plans the rule —
            // because over-protecting only defers a teardown, while
            // under-protecting drops a stale network's live egress.
            if let subnet6 = network.subnet6, let cidr6 = IPv6CIDR(subnet6) {
                protected.snatRules.insert(SNATRuleKey(router: routerName, logicalIP: cidr6.description))
            }
            // A stale network's floating IPs keep their live NAT rules, on the
            // same over-protection-is-safe terms as SNAT.
            for fip in network.floatingIPs ?? [] {
                protected.dnatRules.insert(DNATRuleKey(router: routerName, externalIP: fip.externalIP))
            }
        }
        return protected
    }

    /// Owned OVN objects present on the host that the plan no longer wants,
    /// ordered so dependents are removed before the objects they reference
    /// (SNAT rules and peered ports before their routers/switches). Objects in
    /// `protected` are never torn down — they belong to a network still present
    /// in the sync whose (stale) generation kept it out of the applied plan.
    public static func teardownActions(
        desired: NetworkTopologyPlan,
        observed: ObservedNetworkTopology,
        protected: ProtectedTopology = ProtectedTopology()
    ) -> [NetworkTeardownAction] {
        let want = desired.expectedTopology
        var actions: [NetworkTeardownAction] = []

        for rule in observed.dnatRules.subtracting(want.dnatRules).sorted(by: dnatOrder)
        where !protected.dnatRules.contains(rule) {
            actions.append(.dnat(router: rule.router, externalIP: rule.externalIP))
        }
        for rule in observed.snatRules.subtracting(want.snatRules).sorted(by: snatOrder)
        where !protected.snatRules.contains(rule) {
            actions.append(.snat(router: rule.router, logicalIP: rule.logicalIP))
        }
        for name in observed.switchRouterPortNames.subtracting(want.switchRouterPortNames).sorted()
        where !protected.switchRouterPortNames.contains(name) {
            actions.append(.switchRouterPort(name: name))
        }
        for name in observed.routerPortNames.subtracting(want.routerPortNames).sorted()
        where !protected.routerPortNames.contains(name) {
            actions.append(.routerPort(name: name))
        }
        for name in observed.externalSwitchNames.subtracting(want.externalSwitchNames).sorted()
        where !protected.externalSwitchNames.contains(name) {
            actions.append(.externalSwitch(name: name))
        }
        for name in observed.routerNames.subtracting(want.routerNames).sorted()
        where !protected.routerNames.contains(name) {
            actions.append(.router(name: name))
        }
        return actions
    }

    // MARK: - Helpers

    /// The `ipv6_ra_configs` map for a dual-stack router port. Stateful mode:
    /// addresses come from DHCPv6 (control-plane IPAM pins them), while the RA
    /// carries the on-link prefix and default route — the piece DHCPv6 cannot
    /// deliver. Periodic sends keep guests' routes alive without solicitation.
    public static let ipv6RAConfigs: [String: String] = [
        "address_mode": "dhcpv6_stateful",
        "send_periodic": "true",
        "max_interval": "900",
        "min_interval": "300",
    ]

    /// The prefix length of a CIDR string such as `192.168.1.0/24` → 24.
    static func prefixLength(ofCIDR cidr: String) -> Int? {
        guard let slash = cidr.firstIndex(of: "/") else { return nil }
        let value = cidr[cidr.index(after: slash)...]
        guard let prefix = Int(value), (0...32).contains(prefix) else { return nil }
        return prefix
    }

    private static func snatOrder(_ a: SNATRuleKey, _ b: SNATRuleKey) -> Bool {
        (a.router, a.logicalIP) < (b.router, b.logicalIP)
    }

    private static func dnatOrder(_ a: DNATRuleKey, _ b: DNATRuleKey) -> Bool {
        (a.router, a.externalIP) < (b.router, b.externalIP)
    }
}

// MARK: - Actuator and apply orchestration

/// The live OVN side effects the reconciler drives, implemented by
/// `NetworkServiceLinux`. Every method must be idempotent at the "already
/// satisfied" level — level-triggered syncs re-drive them — so ensuring a
/// router that exists or removing one that is already gone is a no-op.
public protocol NetworkActuator: Sendable {
    /// Snapshot of the L3 objects this reconciler owns, from OVSDB.
    func observeTopology() async throws -> ObservedNetworkTopology
    func ensureSwitch(_ desired: DesiredSwitch) async throws
    func ensureRouter(_ router: DesiredRouter) async throws
    /// Create the tenant router port and its peering `type=router` switch port.
    func ensureRouterPort(_ port: DesiredRouterPort, onRouter routerName: String) async throws
    /// Ensure the external uplink attachment (external switch + localnet + a
    /// gateway router port) for a router that needs SNAT. Returns false when the
    /// host has no detectable uplink, in which case SNAT is skipped this pass.
    func ensureUplink(for router: DesiredRouter) async throws -> Bool
    func ensureSNAT(router routerName: String, logicalIP: String) async throws
    func removeSNAT(router routerName: String, logicalIP: String) async throws
    /// Ensure a floating IP's `dnat_and_snat` rule (issue #344), re-pointing
    /// an existing rule for the same external IP in place when the attachment
    /// moved to another VM.
    func ensureDNAT(router routerName: String, rule: DesiredDNATRule) async throws
    func removeDNAT(router routerName: String, externalIP: String) async throws
    /// Converge OVN native dynamic routing (issue #344) on an uplinked router:
    /// apply the operator's `[ovn_dynamic_routing]` options to the router and
    /// its gateway port when enabled, and strip them when disabled. No-op on
    /// platforms/configs without the feature.
    func ensureDynamicRouting(for router: DesiredRouter) async throws
    func removeSwitchRouterPort(name: String) async throws
    func removeRouterPort(name: String) async throws
    func removeExternalSwitch(name: String) async throws
    func removeRouter(name: String) async throws
}

extension NetworkReconciler {
    /// Converge the host's OVN L3 topology toward the desired networks. Ensures
    /// desired objects first (idempotent), then tears down owned objects the
    /// plan no longer wants. Best-effort per object: a single failing network is
    /// logged and skipped so it can't stall the rest of the sync — the periodic
    /// level-triggered sync retries it. Throws only when the topology snapshot
    /// itself can't be read (teardown can't be computed safely without it).
    public static func reconcile(
        networks: [DesiredNetworkState],
        actuator: any NetworkActuator,
        logger: Logger,
        protected: ProtectedTopology = ProtectedTopology()
    ) async throws {
        let topology = plan(networks: networks)

        for desired in topology.switches {
            await attempt(logger, "ensure switch \(desired.name)") {
                try await actuator.ensureSwitch(desired)
            }
        }

        for router in topology.routers {
            let ensured = await attempt(logger, "ensure router \(router.name)") {
                try await actuator.ensureRouter(router)
            }
            guard ensured else { continue }

            for port in router.ports {
                await attempt(logger, "ensure router port \(port.name)") {
                    try await actuator.ensureRouterPort(port, onRouter: router.name)
                }
            }

            guard router.needsUplink else { continue }
            var uplinkReady = false
            _ = await attempt(logger, "ensure uplink for \(router.name)") {
                uplinkReady = try await actuator.ensureUplink(for: router)
            }
            guard uplinkReady else {
                logger.warning(
                    "No detectable host uplink; skipping SNAT this pass",
                    metadata: ["router": .string(router.name)])
                continue
            }
            for subnet in router.snatSubnets {
                await attempt(logger, "ensure SNAT \(subnet) on \(router.name)") {
                    try await actuator.ensureSNAT(router: router.name, logicalIP: subnet)
                }
            }
            for rule in router.dnatRules {
                await attempt(logger, "ensure floating IP \(rule.externalIP) on \(router.name)") {
                    try await actuator.ensureDNAT(router: router.name, rule: rule)
                }
            }
            await attempt(logger, "ensure dynamic routing on \(router.name)") {
                try await actuator.ensureDynamicRouting(for: router)
            }
        }

        let observed = try await actuator.observeTopology()
        for action in teardownActions(desired: topology, observed: observed, protected: protected) {
            await attempt(logger, "teardown \(action)") {
                switch action {
                case .dnat(let router, let externalIP):
                    try await actuator.removeDNAT(router: router, externalIP: externalIP)
                case .snat(let router, let logicalIP):
                    try await actuator.removeSNAT(router: router, logicalIP: logicalIP)
                case .switchRouterPort(let name):
                    try await actuator.removeSwitchRouterPort(name: name)
                case .routerPort(let name):
                    try await actuator.removeRouterPort(name: name)
                case .externalSwitch(let name):
                    try await actuator.removeExternalSwitch(name: name)
                case .router(let name):
                    try await actuator.removeRouter(name: name)
                }
            }
        }
    }

    /// Run one side effect, logging and swallowing its error. Returns whether it
    /// succeeded, so callers can skip dependent steps for a failed object.
    @discardableResult
    private static func attempt(
        _ logger: Logger, _ what: String, _ body: () async throws -> Void
    ) async -> Bool {
        do {
            try await body()
            return true
        } catch {
            logger.error(
                "Network reconcile step failed",
                metadata: ["step": .string(what), "error": .string(error.localizedDescription)])
            return false
        }
    }
}
