import Foundation
import StratoShared

/// The chassis-local half of a network's link-local services: the OVS internal
/// port that terminates the network's `localport` on *this* host, and the
/// network namespace that holds it.
///
/// Two services live here. Instance metadata (STR-49) answers on
/// `InstanceMetadataEndpoint`, and the network's DNS resolver (STR-40) answers
/// on `NetworkResolverEndpoint`. They share one namespace, one OVS internal
/// port and one MAC, because they need exactly the same thing from the chassis
/// — a foot inside the tenant network that can tell which network a request
/// came from and route a reply back to an address another network may also be
/// using.
///
/// Pure by construction, like `SandboxNetnsAttachmentPlan` and for the same
/// reason: `NetworkServiceLinux` lives in the executable target and cannot be
/// imported from tests, so a wrong-but-plausible command sequence would
/// otherwise reach production untested — and its failure mode is not a crash but
/// a port that binds, reports healthy, and carries no packets.
///
/// ## Why this is not part of the network reconcile
///
/// The two halves of the feature have different owners. The `localport` itself
/// is one row in the shared northbound database, authored only by the site's
/// network controller. This half must exist on *every* chassis running a NIC on
/// the network, including the agents that receive an empty `networks` list
/// precisely because they may not author topology. So its input is the agent's
/// own workload specs (`NetworkSpec.metadataEnabled` / `.resolverEnabled`), and
/// its teardown trigger is the last local NIC leaving the network — not the
/// network being deleted.
///
/// ## Why one namespace per network
///
/// Overlapping tenant subnets are supported by design (routers are scoped per
/// project, so two projects may both use `10.0.0.0/24`). Two guests on different
/// networks can therefore both be `10.0.0.5`. A listener in a shared namespace
/// would see identical `(source, destination, port)` for both and could not tell
/// which instance was asking — and "the source address identifies the caller" is
/// the whole security model of an instance metadata service. Reply routing
/// breaks on the same ambiguity. One namespace per network is also what
/// OpenStack's `ovnmeta-<network>` namespaces do, for this reason.
///
/// The resolver inherits both properties for free, which is why STR-40 reuses
/// this namespace instead of the single host-namespace listener its issue
/// originally proposed: the destination address would have identified the
/// network, but nothing would have routed a reply back to a guest whose
/// `10.0.0.5` exists on three switches. See ADR 0007.
///
/// ## On moving the interface into the namespace
///
/// STR-99 measured that moving a **TAP** into a namespace silently destroys its
/// OVS port. That finding does not transfer here: an OVS *internal* port is a
/// datapath port owned by `ovs-vswitchd`, and relocating one into a namespace is
/// the standard pattern OpenStack's router and metadata namespaces rely on. The
/// scar is close enough to be worth naming, so the executor verifies `ofport`
/// and `error` after the move rather than trusting the OVSDB rows.
public struct ChassisServicePlan: Sendable, Equatable {
    /// The host-side OVS internal interface name (15 chars, `IFNAMSIZ`).
    public let interfaceName: String
    /// The namespace holding it.
    public let netnsName: String
    /// The logical switch port this interface claims via `external_ids:iface-id`.
    public let logicalPortName: String

    /// `ovs-vsctl` arguments creating the internal port on the integration
    /// bridge and claiming the logical port. Run through the service's own
    /// `ovs-vsctl` helper so OVS command handling stays in one place.
    public let ovsAttach: [String]
    /// `ovs-vsctl` arguments reading back the port's *real* binding state.
    /// Row existence proves nothing (see the type doc); only `ofport` and the
    /// `error` column do.
    public let ovsVerify: [String]
    /// Namespace creation. Runs *before* `ovsAttach`, because the device the
    /// attach creates is moved into this namespace immediately afterward.
    public let namespaceSetup: [NetnsCommand]
    /// Moving the device in, then everything that happens inside the namespace.
    /// Runs after `ovsAttach`. Split from `namespaceSetup` so the executor never
    /// has to know which index in a flat list the OVS attach belongs between —
    /// the same split `SandboxNetnsAttachmentPlan` makes.
    public let interfaceSetup: [NetnsCommand]

    /// `ovs-vsctl` arguments removing the internal port from the bridge.
    public let ovsDetach: [String]
    /// Namespace removal. Runs after `ovsDetach`, which destroys the device.
    public let teardown: [NetnsCommand]

    /// Where iproute2 keeps its named namespaces.
    public static let netnsDirectory = "/var/run/netns"

    /// The namespace holding a network's service interface on this chassis.
    /// Mirrors `SandboxJail`'s `strato-sbx-<id>`.
    public static func netnsName(networkId: UUID) -> String {
        "strato-md-\(networkId.uuidString.lowercased())"
    }

    /// Where iproute2 keeps that namespace's handle. On tmpfs — which is the
    /// whole reason observation cannot key on the OVS row alone: `conf.db` is on
    /// disk and survives a reboot, this does not.
    public static func netnsPath(networkId: UUID) -> String {
        "\(netnsDirectory)/\(netnsName(networkId: networkId))"
    }

    /// The network a namespace name belongs to, or nil when the name is not one
    /// of ours.
    ///
    /// The inverse of `netnsName`, and the only way to learn which networks this
    /// host was serving before the agent restarted: the namespaces outlive the
    /// agent process (they are created by the chassis reconcile and cleared only
    /// by a host reboot), while the desired-state list that named them does not.
    public static func networkId(fromNetnsName name: String) -> UUID? {
        let prefix = "strato-md-"
        guard name.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))
    }

    /// Builds the full setup-and-teardown plan for one network on this chassis.
    ///
    /// `ipBinaryPath` is injected rather than assumed so the plan stays testable
    /// and a service manager's stripped `PATH` can't break it.
    /// `metadata` and `resolver` say which services this network publishes.
    /// At least one is always true where this is called — a network wanting
    /// neither has no chassis foot to build — but both are passed explicitly so
    /// the addresses the namespace holds and the ones the OVN `localport`
    /// advertises derive from the same two booleans.
    ///
    /// `ratePPS` caps the aggregate packet rate guests may push at these
    /// services; 0 disables the policer. `tcBinaryPath` is only consulted when
    /// it is non-zero.
    public static func plan(
        networkId: UUID,
        metadata: Bool,
        resolver: Bool,
        ipBinaryPath: String,
        tcBinaryPath: String,
        bridge: String,
        ovsTimeoutSeconds: Int,
        ratePPS: Int
    ) -> ChassisServicePlan {
        let device = chassisServiceInterfaceName(networkId: networkId.uuidString)
        let namespace = netnsName(networkId: networkId)
        let logicalPort = OVNNaming.serviceLocalPortName(networkId: networkId)
        let mac = OVNNaming.serviceLocalPortMAC(networkId: networkId)

        let ip = { (args: [String], tolerated: [String]) in
            NetnsCommand(ipBinaryPath, args, tolerated: tolerated)
        }

        let namespaceSetup: [NetnsCommand] = [ip(["netns", "add", namespace], ["File exists"])]

        var setup: [NetnsCommand] = [
            // On a retry the device is already inside, and `ip` then reports it
            // missing from the host namespace. Safe to tolerate: every command
            // below addresses it *through* the namespace and fails loudly if it
            // is not actually there.
            ip(["link", "set", device, "netns", namespace], ["Cannot find device"]),
            // The guest sends to the MAC OVN's ARP/ND responder advertised for
            // the logical port, so the netdev has to own that MAC or the frames
            // are dropped as not-for-us.
            ip(["-n", namespace, "link", "set", "dev", device, "address", mac], []),
            // Up before addressing, so the IPv6 assignment below lands on a live
            // interface.
            ip(["-n", namespace, "link", "set", "dev", device, "up"], []),
            // The listeners bind to the service addresses, but anything that
            // resolves a local name will also want loopback.
            ip(["-n", namespace, "link", "set", "dev", "lo", "up"], []),
        ]

        // Both families are established independently: on a host without IPv6
        // the v6 commands fail and the v4 services still work, matching how a
        // malformed `external_cidr6` degrades the uplink to v4 rather than
        // failing it.
        //
        // `nodad` on every IPv6 address, deliberately: Duplicate Address
        // Detection leaves an address `tentative` for roughly a second, during
        // which `bind()` fails with EADDRNOTAVAIL. They are unique by
        // construction — one set per namespace, one namespace per network per
        // chassis — so DAD buys nothing and costs each listener a startup race
        // on every agent restart.
        if metadata {
            setup.append(
                ip(
                    ["-n", namespace, "addr", "add", InstanceMetadataEndpoint.cidr, "dev", device],
                    ["File exists"]))
            setup.append(
                ip(
                    [
                        "-n", namespace, "addr", "add", InstanceMetadataEndpoint.cidrV6, "dev", device,
                        "nodad",
                    ], ["File exists"]))
        }
        if resolver {
            setup.append(
                ip(
                    ["-n", namespace, "addr", "add", NetworkResolverEndpoint.cidr, "dev", device],
                    ["File exists"]))
            setup.append(
                ip(
                    [
                        "-n", namespace, "addr", "add", NetworkResolverEndpoint.cidrV6, "dev", device,
                        "nodad",
                    ], ["File exists"]))
        }

        // A service turned *off* has its addresses removed, not merely left
        // unadvertised. Realization re-runs when the `strato-services` stamp
        // changes, so without this the namespace keeps addresses for a service
        // it no longer serves and then reports converged — exactly the drift
        // `ObservedChassisServicePort`'s separate namespace probe exists to
        // catch one layer up. Guests cannot reach them (the NB port stops
        // advertising them, so nothing answers their ARP), but "harmless" and
        // "honest" are different properties, and an operator reading `ip addr`
        // in the namespace should see what it actually serves.
        //
        // Tolerated because the common path is a namespace that never had them.
        let absent = ["Cannot assign requested address", "Cannot find device", "No such"]
        if !metadata {
            setup.append(
                ip(["-n", namespace, "addr", "del", InstanceMetadataEndpoint.cidr, "dev", device], absent))
            setup.append(
                ip(["-n", namespace, "addr", "del", InstanceMetadataEndpoint.cidrV6, "dev", device], absent))
        }
        if !resolver {
            setup.append(
                ip(["-n", namespace, "addr", "del", NetworkResolverEndpoint.cidr, "dev", device], absent))
            setup.append(
                ip(["-n", namespace, "addr", "del", NetworkResolverEndpoint.cidrV6, "dev", device], absent))
        }

        // Replies go to the guest's tenant address, for which the namespace has
        // no route otherwise. A default route is unambiguous here because the
        // namespace has exactly one non-loopback interface, and it covers any
        // number of subnets on the switch without needing an IPAM allocation
        // from each (which is how OpenStack solves the same problem).
        //
        // The preferred source is whichever service address actually exists —
        // `ip route add ... src <addr>` is rejected outright when the address
        // is not configured, so hardcoding the metadata one would fail the
        // whole namespace build on a resolver-only network. It is only a
        // *preference*: each listener binds its own address explicitly, so
        // replies leave from the address the request arrived at regardless.
        let preferredSource = metadata ? InstanceMetadataEndpoint.address : NetworkResolverEndpoint.address
        let preferredSource6 =
            metadata ? InstanceMetadataEndpoint.addressV6 : NetworkResolverEndpoint.addressV6
        setup.append(
            ip(
                [
                    "-n", namespace, "route", "add", "default", "dev", device,
                    "src", preferredSource,
                ], ["File exists", "RTNETLINK answers: File exists"]))
        setup.append(
            ip(
                [
                    "-n", namespace, "-6", "route", "add", "default", "dev", device,
                    "src", preferredSource6,
                ], ["File exists", "RTNETLINK answers: File exists"]))

        // An aggregate ingress rate limit on what guests may push at these
        // services (STR-40). AWS caps its link-local services the same way and
        // for the same reason: one namespace serves every guest on the network
        // from a process on the hypervisor, so an unbounded query rate from a
        // single VM is a noisy-neighbour lever on every other VM on the host.
        //
        // Policed on *ingress*, so the cost of a flood is paid before the
        // listener wakes up, and in packets rather than bytes because a DNS
        // query is small and cheap to send but not cheap to answer.
        //
        // `replace` with an explicit handle rather than `add`: setup re-runs on
        // every retry and after every agent restart, and `tc filter add` would
        // stack a second identical policer each time — halving the effective
        // rate on each pass.
        if ratePPS > 0 {
            // **Every policer command tolerates its own unavailability.**
            // `interfaceSetup` is executed fail-fast, and a throw there rolls
            // the whole namespace back — so an untolerated `tc` failure would
            // not merely skip the limiter, it would destroy the namespace and
            // the OVS port, and the next sync would rebuild and destroy them
            // again. That loop would take instance metadata down on hosts where
            // it works today.
            //
            // It is a real risk rather than a hypothetical: `police pkts_rate`
            // needs iproute2 >= 5.10 and a 5.11 kernel, so an older LTS host
            // rejects these as unknown arguments. The type doc already argues
            // an unlimited resolver beats no resolver; these tolerations are
            // what make the code agree with it.
            let unsupported = [
                "Unknown", "unknown", "Illegal", "illegal", "invalid", "Invalid", "Usage:",
                "not supported", "No such file or directory",
            ]
            let tc = { (args: [String], tolerated: [String]) in
                NetnsCommand(tcBinaryPath, args, tolerated: tolerated)
            }
            setup.append(
                tc(
                    ["-n", namespace, "qdisc", "add", "dev", device, "handle", "ffff:", "ingress"],
                    ["File exists"] + unsupported))
            setup.append(
                tc(
                    [
                        "-n", namespace, "filter", "replace", "dev", device, "parent", "ffff:",
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

        // No `rp_filter` or `disable_ipv6` sysctls here, deliberately. Both
        // looked necessary and are not: network sysctls are per-namespace and a
        // fresh namespace starts at the kernel defaults rather than inheriting
        // the host's, and even under strict reverse-path filtering a request
        // from a guest passes — the reverse lookup for its tenant address hits
        // the default route above and resolves to the interface the packet
        // arrived on. Adding them would mean shelling a third binary into the
        // namespace to establish state that already holds.

        let timeout = "--timeout=\(ovsTimeoutSeconds)"
        return ChassisServicePlan(
            interfaceName: device,
            netnsName: namespace,
            logicalPortName: logicalPort,
            ovsAttach: [
                timeout, "--may-exist", "add-port", bridge, device,
                "--", "set", "Interface", device, "type=internal",
                "external_ids:iface-id=\(logicalPort)",
                "external_ids:\(ChassisServicePlan.managedKey)=\(ChassisServicePlan.managedValue)",
                "external_ids:\(ChassisServicePlan.roleKey)=\(ChassisServicePlan.roleValue)",
                "external_ids:\(ChassisServicePlan.networkIDKey)=\(networkId.uuidString.lowercased())",
                "external_ids:\(ChassisServicePlan.servicesKey)="
                    + ChassisServiceSet(metadata: metadata, resolver: resolver).externalIDValue,
            ],
            ovsVerify: [timeout, "get", "Interface", device, "ofport", "error"],
            namespaceSetup: namespaceSetup,
            interfaceSetup: setup,
            ovsDetach: [timeout, "--if-exists", "del-port", bridge, device],
            teardown: [
                // Deleting the OVS port destroys the device, so only the
                // namespace is left. Doing this twice is a no-op.
                ip(["netns", "del", namespace], ["No such file or directory", "Cannot remove"])
            ]
        )
    }

    /// The teardown half alone, derivable from the network id with no live
    /// state. Split out for the same reason as
    /// `SandboxNetnsAttachmentPlan.teardownCommands`: cleanup has to work for a
    /// network the agent can no longer describe, and rebuilding the full plan to
    /// throw most of it away invites the two paths to derive different names.
    ///
    /// `interfaceName` overrides the derived device name with the one actually
    /// observed on the bridge, so teardown removes what it found rather than
    /// what it recomputed. They agree by construction; passing the observation
    /// is what keeps them agreeing if the derivation ever changes.
    public static func teardownPlan(
        networkId: UUID, interfaceName: String? = nil, ipBinaryPath: String, bridge: String,
        ovsTimeoutSeconds: Int
    ) -> (ovsDetach: [String], commands: [NetnsCommand]) {
        let device = interfaceName ?? chassisServiceInterfaceName(networkId: networkId.uuidString)
        return (
            ovsDetach: ["--timeout=\(ovsTimeoutSeconds)", "--if-exists", "del-port", bridge, device],
            commands: [
                NetnsCommand(
                    ipBinaryPath, ["netns", "del", netnsName(networkId: networkId)],
                    tolerated: ["No such file or directory", "Cannot remove"])
            ]
        )
    }

    // MARK: - External-id markers

    /// Ownership marker, matching the `strato-managed` external-id the network
    /// reconciler stamps on the OVN objects it owns. Observation keys off these,
    /// never a name prefix, so an operator's own internal ports on `br-int` are
    /// never mistaken for Strato's and removed.
    public static let managedKey = "strato-managed"
    public static let managedValue = "true"
    /// Distinguishes a chassis service interface from every other
    /// Strato-managed OVS interface (VM TAPs, sandbox veths) in one lookup.
    ///
    /// The value stays `metadata` although the interface now terminates the
    /// resolver too. It is an ownership marker on rows that already exist on
    /// every live site, and observation keys off it — changing the string would
    /// make every existing interface unrecognized, so every agent would build a
    /// second one beside it and never reap the first.
    public static let roleKey = "strato-role"
    public static let roleValue = "metadata"
    /// Carries the network id so teardown can rederive the namespace to delete
    /// from an observed interface alone.
    public static let networkIDKey = "strato-network-id"
    /// Which services the namespace behind this interface was built for.
    ///
    /// Stamped so the reconcile can tell "already realized" from "realized for
    /// a different service set" without probing the namespace's addresses. The
    /// OVS row is read for observation anyway, so comparing a marker on it is
    /// free, whereas an `ip addr show` per network would be one more exec on
    /// every sync — the same argument `DesiredDNSZone.recordsHash` makes.
    public static let servicesKey = "strato-services"
}

/// Which of a network's link-local services this chassis publishes.
public struct ChassisServiceSet: Equatable, Hashable, Sendable {
    public let metadata: Bool
    public let resolver: Bool

    public init(metadata: Bool, resolver: Bool) {
        self.metadata = metadata
        self.resolver = resolver
    }

    /// Whether anything at all is wanted. A network wanting neither has no
    /// chassis foot, which is the same state as never having had one.
    public var isEmpty: Bool { !metadata && !resolver }

    /// The `external_ids:strato-services` value, in a fixed order so the
    /// stamp compares as a string.
    public var externalIDValue: String {
        ([metadata ? "metadata" : nil, resolver ? "resolver" : nil].compactMap { $0 })
            .joined(separator: "+")
    }

    /// What an observed interface's stamp says it was built for.
    ///
    /// **A missing stamp is metadata-only, not "unknown".** Every interface
    /// that predates STR-40 was built for metadata alone — the resolver did not
    /// exist — so reading absence as metadata-only is a statement of fact
    /// rather than a guess, and it is what makes an upgraded agent re-realize
    /// exactly the namespaces whose networks want a resolver instead of all of
    /// them. An unrecognized value is treated the same way and re-realized,
    /// which is the safe direction: the plan is idempotent.
    public static func parse(_ raw: String?) -> ChassisServiceSet {
        guard let raw, !raw.isEmpty else { return ChassisServiceSet(metadata: true, resolver: false) }
        let parts = Set(raw.split(separator: "+").map(String.init))
        let known = parts.isSubset(of: ["metadata", "resolver"])
        guard known else { return ChassisServiceSet(metadata: true, resolver: false) }
        return ChassisServiceSet(
            metadata: parts.contains("metadata"), resolver: parts.contains("resolver"))
    }
}

// MARK: - Chassis-side reconciliation

/// One chassis service interface this chassis owns, as observed on the host.
public struct ObservedChassisServicePort: Equatable, Sendable {
    public let networkId: UUID
    /// The device name read off the OVS row, not rederived.
    public let interfaceName: String
    /// Whether the namespace that should hold it still exists.
    ///
    /// Tracked separately from the OVS row because the two have **different
    /// lifetimes**, and conflating them is a silent failure. OVS's `conf.db`
    /// is on disk; `/var/run/netns` is tmpfs. After a host reboot the interface
    /// row comes back, `ovs-vswitchd` recreates the netdev, and
    /// `ovn-controller` rebinds the localport and starts answering guest ARP
    /// for the metadata address — while the namespace, the addresses, and the
    /// routes are all gone. Guests then hang on a connection that will never be
    /// answered, which is strictly worse than the fast failure they get with no
    /// metadata port at all.
    public let namespacePresent: Bool
    /// The service set this interface was built for, read off its
    /// `external_ids` stamp — see `ChassisServicePlan.servicesKey`.
    public let services: ChassisServiceSet

    public init(
        networkId: UUID, interfaceName: String, namespacePresent: Bool,
        services: ChassisServiceSet = ChassisServiceSet(metadata: true, resolver: false)
    ) {
        self.networkId = networkId
        self.interfaceName = interfaceName
        self.namespacePresent = namespacePresent
        self.services = services
    }
}

/// One chassis-side side effect.
public enum ChassisServiceAction: Equatable, Sendable {
    /// Run the (idempotent) setup plan. Three causes, one action: the network
    /// has no interface yet, it has one whose namespace went missing, or it has
    /// one built for a different set of services than it now wants.
    case realize(networkId: UUID, services: ChassisServiceSet)
    /// Remove the interface and its namespace. Carries the observed device name
    /// so teardown deletes what was found.
    case remove(networkId: UUID, interfaceName: String)
}

/// Pure diff for the chassis half, mirroring `NetworkReconciler.teardownActions`.
///
/// Lives here rather than in the actor because this is the half that *deletes*
/// namespaces, and `NetworkServiceLinux` is in the executable target where no
/// test can reach it.
public enum ChassisServiceReconciler {

    /// The side effects that converge this chassis toward `desired`.
    ///
    /// `desired` nil ≙ a control plane that predates both service flags: no
    /// actions at all, so silence is never read as "tear every namespace down".
    /// An empty (non-nil) map *is* an opinion and removes everything. A network
    /// present with an empty service set is the same opinion for that one
    /// network, so callers need not filter it out first.
    public static func actions(
        desired: [UUID: ChassisServiceSet]?, observed: [ObservedChassisServicePort]
    ) -> [ChassisServiceAction] {
        guard let desired else { return [] }
        let wanted = desired.filter { !$0.value.isEmpty }
        let byNetwork = Dictionary(observed.map { ($0.networkId, $0) }, uniquingKeysWith: { first, _ in first })

        var actions: [ChassisServiceAction] = []
        // Realize covers "never built", "built, but its namespace is gone", and
        // "built for a different service set". The plan is idempotent, so one
        // path serves all three and there is no repair-only branch to get subtly
        // wrong. The last case is what makes turning a resolver on reach a
        // network whose namespace already exists for metadata.
        for networkId in wanted.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let services = wanted[networkId] else { continue }
            let port = byNetwork[networkId]
            guard port?.namespacePresent == true, port?.services == services else {
                actions.append(.realize(networkId: networkId, services: services))
                continue
            }
        }
        for port in observed.sorted(by: { $0.networkId.uuidString < $1.networkId.uuidString })
        where wanted[port.networkId] == nil {
            actions.append(.remove(networkId: port.networkId, interfaceName: port.interfaceName))
        }
        return actions
    }
}
