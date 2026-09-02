import Foundation
import StratoShared

/// The chassis-local half of a network's DNS resolver: an OVS internal port that
/// terminates the network's resolver `localport` in the **host** namespace,
/// carrying that network's own address pair (STR-40).
///
/// Pure by construction, like `ChassisServicePlan`, and here the reason is
/// sharper than "the actor cannot be imported from tests". This plan programs
/// routing rules in the *host's* policy table. Getting a namespace wrong costs
/// one network; getting a rule wrong here can put tenant traffic into the
/// hypervisor's own routing, which is precisely the blast radius ADR 0003
/// rejected and ADR 0008 accepts with mitigations. The exact argv is therefore
/// something a test asserts rather than something a reviewer eyeballs.
///
/// ## Why the host namespace at all
///
/// Because a resolver has to *forward*. Inside the network's chassis namespace
/// its only addresses are link-local and its only egress is on-link out the
/// tenant switch, so a query to a public resolver either ARPs for it where
/// nothing answers or leaves with a source no SNAT rule matches and no router
/// can route back. In the host namespace, forwarding is the hypervisor's own —
/// which is what makes it work even on a network with no external access at all,
/// the case the whole phase exists for.
///
/// ## What replaces the namespace
///
/// The namespace gave metadata two things: it said *which network* asked, and it
/// gave replies somewhere to go. Here the network's **distinct address** does
/// the first — CoreDNS binds one server block per address — and a per-network
/// **routing rule keyed on that address** does the second.
public struct ResolverHostPortPlan: Sendable, Equatable {
    /// The host-side OVS internal interface name (15 chars, `IFNAMSIZ`).
    public let interfaceName: String
    /// The logical switch port this interface claims via `external_ids:iface-id`.
    public let logicalPortName: String

    /// `ovs-vsctl` arguments creating the internal port on the integration
    /// bridge and claiming the logical port.
    public let ovsAttach: [String]
    /// `ovs-vsctl` arguments reading back the port's *real* binding state. Row
    /// existence proves nothing; only `ofport` and the `error` column do.
    public let ovsVerify: [String]
    /// Everything done to the interface once OVS has created it: addressing,
    /// isolation sysctls, and the policy routing that returns replies.
    public let setup: [NetnsCommand]

    /// `ovs-vsctl` arguments removing the internal port from the bridge.
    public let ovsDetach: [String]

    /// The routing table this network's replies are routed by.
    public static func routingTable(networkId: UUID, address: String) -> Int? {
        guard let index = index(ofAddress: address) else { return nil }
        return NetworkResolverEndpoint.routingTable(forIndex: index)
    }

    /// The allocation index behind a v4 resolver address, recovered from the
    /// address itself so the agent needs no second field to derive its routing
    /// table from.
    static func index(ofAddress address: String) -> Int? {
        let parts = address.split(separator: ".").map(String.init)
        guard parts.count == 4, parts[0] == "169", parts[1] == "254",
            let third = Int(parts[2]), let fourth = Int(parts[3])
        else { return nil }
        let index = (third << 8) | fourth
        return NetworkResolverEndpoint.isValidIndex(index) ? index : nil
    }

    /// Builds the setup-and-teardown plan for one network's resolver foot.
    ///
    /// `ratePPS` caps the packet rate guests may push at this network's
    /// resolver; 0 disables the policer. `tcBinaryPath` is only consulted when
    /// it is non-zero.
    public static func plan(
        networkId: UUID, addresses: [String], ipBinaryPath: String, sysctlBinaryPath: String,
        tcBinaryPath: String, bridge: String, ovsTimeoutSeconds: Int, ratePPS: Int
    ) -> ResolverHostPortPlan {
        let device = resolverHostInterfaceName(networkId: networkId.uuidString)
        let logicalPort = OVNNaming.resolverPortName(networkId: networkId)
        let mac = OVNNaming.resolverPortMAC(networkId: networkId)
        let v4 = addresses.first(where: IPFamily.ipv4.matches)
        let v6 = addresses.first(where: IPFamily.ipv6.matches)

        let ip = { (args: [String], tolerated: [String]) in
            NetnsCommand(ipBinaryPath, args, tolerated: tolerated)
        }
        let sysctl = { (setting: String, tolerated: [String]) in
            NetnsCommand(sysctlBinaryPath, ["-w", setting], tolerated: tolerated)
        }
        var setup: [NetnsCommand] = [
            // The guest sends to the MAC OVN's ARP/ND responder advertised for
            // the logical port, so the netdev has to own that MAC or the frames
            // are dropped as not-for-us.
            ip(["link", "set", "dev", device, "address", mac], []),
            ip(["link", "set", "dev", device, "up"], []),
        ]

        // **Isolation, and the reason this plan is watched closely.** The
        // interface is an L3 foot inside a tenant network, sitting in the host's
        // own namespace. Forwarding off on both families is what stops the host
        // routing between two tenant networks it happens to have feet in — the
        // failure ADR 0003 named when it rejected this shape, and the one thing
        // that would turn a routing bug into a cross-tenant leak rather than a
        // dropped packet.
        for setting in [
            "net.ipv4.conf.\(device).forwarding=0",
            "net.ipv6.conf.\(device).forwarding=0",
            // Loose reverse-path filtering, not strict: a guest's packet arrives
            // with a tenant source address this interface has no route for in
            // the *main* table, so strict mode would drop every query. Loose
            // still rejects a source no interface could reach.
            //
            // **Only half the setting, and the other half is not ours.** The
            // kernel validates against `max(conf.all.rp_filter,
            // conf.<dev>.rp_filter)`, so a host whose `all` is 1 — the default
            // on RHEL-family and on most hardening baselines — stays strict
            // here and drops every guest query. Lowering `all` would weaken
            // source validation on the hypervisor's own NICs, which is not a
            // trade this feature gets to make on an operator's behalf, so
            // `HostPreflight` reports it instead.
            "net.ipv4.conf.\(device).rp_filter=2",
            // **The host must not answer for addresses that are not on this
            // interface.** With the default `arp_ignore=0` the host replies to
            // any ARP arriving here for any local address — including its
            // management address — which would put the hypervisor's own
            // services one ARP reply away from a tenant L2 domain. `1` answers
            // only for the resolver pair actually configured on the device, and
            // `arp_announce=2` keeps the host from sourcing ARP requests here
            // with an address from another interface.
            "net.ipv4.conf.\(device).arp_ignore=1",
            "net.ipv4.conf.\(device).arp_announce=2",
            // The v6 counterpart of `arp_ignore`, and one more: a tenant guest
            // can emit Router Advertisements, and a host that accepted them
            // from inside a tenant network would take routes and a default
            // gateway from it.
            "net.ipv6.conf.\(device).accept_ra=0",
        ] {
            setup.append(sysctl(setting, ["cannot stat", "No such file"]))
        }

        if let v4 {
            setup.append(ip(["addr", "add", "\(v4)/32", "dev", device], ["File exists"]))
        }
        if let v6 {
            // `nodad` for `ChassisServicePlan`'s reason: DAD leaves the address
            // `tentative` for about a second, during which `bind()` fails with
            // EADDRNOTAVAIL — and one failed bind here costs *every* network on
            // the host its resolver, because one process binds them all.
            setup.append(
                ip(["addr", "add", "\(v6)/128", "dev", device, "nodad"], ["File exists"]))
        }

        // **Policy routing is what replaces the namespace's default route.**
        // A reply leaves from this network's address toward a guest whose
        // `10.0.0.5` may exist on three other switches, so the host cannot route
        // it from the main table — there is no correct answer there. Keying a
        // table on the *source* address works because that address is unique per
        // network by construction, and it is tight: nothing else on this host
        // ever sources from it.
        if let v4, let table = routingTable(networkId: networkId, address: v4) {
            setup.append(
                ip(
                    ["route", "replace", "default", "dev", device, "src", v4, "table", String(table)],
                    []))
            // `replace`-then-add is not available for rules, so an existing rule
            // is deleted first: `ip rule add` happily stacks duplicates, and a
            // retried setup would otherwise leave one per attempt in the host's
            // policy table forever.
            setup.append(
                ip(["rule", "del", "from", v4, "table", String(table)], ["No such file or directory"]))
            setup.append(ip(["rule", "add", "from", v4, "table", String(table)], []))

            if let v6 {
                setup.append(
                    ip(
                        [
                            "-6", "route", "replace", "default", "dev", device, "src", v6,
                            "table", String(table),
                        ], []))
                setup.append(
                    ip(
                        ["-6", "rule", "del", "from", v6, "table", String(table)],
                        ["No such file or directory"]))
                setup.append(ip(["-6", "rule", "add", "from", v6, "table", String(table)], []))
            }
        }

        // **The ingress policer belongs here, not on the metadata foot.** Before
        // ADR 0008 the resolver shared the chassis namespace and `tc` on that
        // interface capped both services; the move to the host namespace left
        // the cap behind on an interface DNS no longer traverses. It matters
        // more on this side than it ever did on that one: one CoreDNS answers
        // every network on the host, from the host's *own* namespace, so an
        // unbounded query rate from a single guest is a lever on every other
        // guest here and on the hypervisor itself.
        //
        // Policed on ingress so a flood is paid for before the resolver wakes
        // up, and in packets rather than bytes because a DNS query is small to
        // send and not small to answer.
        if ratePPS > 0 {
            // Every policer command tolerates its own unavailability, for
            // `ChassisServicePlan`'s reason: `setup` is executed fail-fast and a
            // throw rolls the whole foot back, so an untolerated `tc` failure
            // would not merely skip the limiter — it would destroy the port and
            // the next sync would rebuild and destroy it again, costing this
            // network its resolver entirely. `police pkts_rate` needs iproute2
            // >= 5.10 and a 5.11 kernel, so an older LTS host rejects these as
            // unknown arguments. An unlimited resolver beats no resolver.
            let unsupported = [
                "Unknown", "unknown", "Illegal", "illegal", "invalid", "Invalid", "Usage:",
                "not supported", "No such file or directory",
            ]
            let tc = { (args: [String], tolerated: [String]) in
                NetnsCommand(tcBinaryPath, args, tolerated: tolerated)
            }
            setup.append(
                tc(["qdisc", "add", "dev", device, "handle", "ffff:", "ingress"], ["File exists"] + unsupported))
            setup.append(
                tc(
                    [
                        "filter", "replace", "dev", device, "parent", "ffff:",
                        "handle", "0x1", "prio", "1", "protocol", "all", "matchall",
                        "action", "police",
                        "pkts_rate", String(ratePPS),
                        // A quarter-second of headroom, floored so a very low
                        // configured rate still admits a burst of one query and
                        // its retry rather than dropping every other packet.
                        "pkts_burst", String(max(ratePPS / 4, 32)),
                        "conform-exceed", "drop",
                    ], unsupported))
        }

        let timeout = "--timeout=\(ovsTimeoutSeconds)"
        return ResolverHostPortPlan(
            interfaceName: device,
            logicalPortName: logicalPort,
            ovsAttach: [
                timeout, "--may-exist", "add-port", bridge, device,
                "--", "set", "Interface", device, "type=internal",
                "external_ids:iface-id=\(logicalPort)",
                "external_ids:\(ChassisServicePlan.managedKey)=\(ChassisServicePlan.managedValue)",
                "external_ids:\(ChassisServicePlan.roleKey)=\(roleValue)",
                "external_ids:\(ChassisServicePlan.networkIDKey)=\(networkId.uuidString.lowercased())",
                // The addresses are stamped so observation can tell "realized"
                // from "realized for a different pair" without probing the
                // interface — the same trick the chassis stamp used, and it
                // matters more here because a stale pair means CoreDNS binds an
                // address the switch no longer advertises.
                "external_ids:\(addressesKey)=\(addresses.joined(separator: ","))",
            ],
            ovsVerify: [timeout, "get", "Interface", device, "ofport", "error"],
            setup: setup,
            ovsDetach: [timeout, "--if-exists", "del-port", bridge, device])
    }

    /// Teardown: the rules and routes first, then the port.
    ///
    /// Order matters and is the reverse of setup for a reason the OVS detach
    /// makes unavoidable — deleting the port destroys the device, and a rule
    /// naming an address on a device that no longer exists is not cleaned up by
    /// anything. Those accumulate in the host's policy table, which is exactly
    /// the state this design is meant to keep tidy.
    public static func teardownPlan(
        networkId: UUID, interfaceName: String, addresses: [String], ipBinaryPath: String,
        bridge: String, ovsTimeoutSeconds: Int
    ) -> (ovsDetach: [String], commands: [NetnsCommand]) {
        let ip = { (args: [String], tolerated: [String]) in
            NetnsCommand(ipBinaryPath, args, tolerated: tolerated)
        }
        let gone = ["No such file or directory", "No such process", "Cannot find device"]
        var commands: [NetnsCommand] = []
        if let v4 = addresses.first(where: IPFamily.ipv4.matches),
            let table = routingTable(networkId: networkId, address: v4)
        {
            commands.append(ip(["rule", "del", "from", v4, "table", String(table)], gone))
            commands.append(ip(["route", "flush", "table", String(table)], gone))
            if let v6 = addresses.first(where: IPFamily.ipv6.matches) {
                commands.append(ip(["-6", "rule", "del", "from", v6, "table", String(table)], gone))
                commands.append(ip(["-6", "route", "flush", "table", String(table)], gone))
            }
        }
        return (
            ovsDetach: ["--timeout=\(ovsTimeoutSeconds)", "--if-exists", "del-port", bridge, interfaceName],
            commands: commands
        )
    }

    /// Distinguishes a resolver foot from the metadata one, which carries
    /// `strato-role=metadata` on the same bridge.
    public static let roleValue = "resolver"
    /// The addresses this interface was built for.
    public static let addressesKey = "strato-resolver-addresses"

    /// The stamped address list, or empty when the interface predates the stamp.
    public static func parseAddresses(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(separator: ",").map(String.init)
    }
}

// MARK: - Reconciliation

/// One resolver foot this host owns, as observed.
public struct ObservedResolverHostPort: Equatable, Sendable {
    public let networkId: UUID
    public let interfaceName: String
    /// The addresses the interface was built for, from its stamp.
    public let addresses: [String]

    public init(networkId: UUID, interfaceName: String, addresses: [String]) {
        self.networkId = networkId
        self.interfaceName = interfaceName
        self.addresses = addresses
    }
}

public enum ResolverHostPortAction: Equatable, Sendable {
    /// Run the (idempotent) setup plan: no interface yet, or one built for a
    /// different address pair than the network now has.
    case realize(networkId: UUID, addresses: [String])
    /// Remove the interface and the routing that named its addresses. Carries
    /// the *observed* pair, so teardown deletes the rules that actually exist
    /// rather than the ones the current desired state would imply.
    case remove(networkId: UUID, interfaceName: String, addresses: [String])
}

/// Pure diff for the resolver's host-namespace feet.
public enum ResolverHostPortReconciler {

    /// `desired` maps each network to the addresses it wants published.
    ///
    /// Unlike the chassis reconciler this takes no nil: the caller has already
    /// decided the sync has an opinion by the time it gets here, because the
    /// resolver's nil-is-silence contract is enforced one layer up where the
    /// process lives.
    public static func actions(
        desired: [UUID: [String]], observed: [ObservedResolverHostPort]
    ) -> [ResolverHostPortAction] {
        let byNetwork = Dictionary(
            observed.map { ($0.networkId, $0) }, uniquingKeysWith: { first, _ in first })
        var actions: [ResolverHostPortAction] = []

        for networkId in desired.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let addresses = desired[networkId], !addresses.isEmpty else { continue }
            // An address pair that moved is realized again rather than patched:
            // the setup is idempotent, and the alternative is a partial update
            // that leaves the old address bound while CoreDNS is told the new
            // one.
            if byNetwork[networkId]?.addresses != addresses {
                actions.append(.realize(networkId: networkId, addresses: addresses))
            }
        }
        for port in observed.sorted(by: { $0.networkId.uuidString < $1.networkId.uuidString })
        where (desired[port.networkId] ?? []).isEmpty {
            actions.append(
                .remove(
                    networkId: port.networkId, interfaceName: port.interfaceName,
                    addresses: port.addresses))
        }
        return actions
    }
}
