import Foundation
import StratoShared

/// The chassis-local half of the instance metadata dataplane (STR-49): the OVS
/// internal port that terminates a network's metadata `localport` on *this*
/// host, and the network namespace that holds it.
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
/// own workload specs (`NetworkSpec.metadataEnabled`), and its teardown trigger
/// is the last local NIC leaving the network — not the network being deleted.
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
/// ## On moving the interface into the namespace
///
/// STR-99 measured that moving a **TAP** into a namespace silently destroys its
/// OVS port. That finding does not transfer here: an OVS *internal* port is a
/// datapath port owned by `ovs-vswitchd`, and relocating one into a namespace is
/// the standard pattern OpenStack's router and metadata namespaces rely on. The
/// scar is close enough to be worth naming, so the executor verifies `ofport`
/// and `error` after the move rather than trusting the OVSDB rows.
public struct MetadataChassisPlan: Sendable, Equatable {
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

    /// The namespace holding a network's metadata interface on this chassis.
    /// Mirrors `SandboxJail`'s `strato-sbx-<id>`.
    public static func netnsName(networkId: UUID) -> String {
        "strato-md-\(networkId.uuidString.lowercased())"
    }

    /// Where iproute2 keeps its named namespaces.
    public static let netnsDirectory = "/var/run/netns"

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
    /// host was serving metadata on before the agent restarted: the namespaces
    /// outlive the agent process (they are created by the chassis reconcile and
    /// cleared only by a host reboot), while the desired-state list that named
    /// them does not.
    public static func networkId(fromNetnsName name: String) -> UUID? {
        let prefix = "strato-md-"
        guard name.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))
    }

    /// Builds the full setup-and-teardown plan for one network on this chassis.
    ///
    /// `ipBinaryPath` is injected rather than assumed so the plan stays testable
    /// and a service manager's stripped `PATH` can't break it.
    public static func plan(
        networkId: UUID,
        ipBinaryPath: String,
        bridge: String,
        ovsTimeoutSeconds: Int
    ) -> MetadataChassisPlan {
        let device = metadataInterfaceName(networkId: networkId.uuidString)
        let namespace = netnsName(networkId: networkId)
        let logicalPort = OVNNaming.metadataPortName(networkId: networkId)
        let mac = OVNNaming.metadataPortMAC(networkId: networkId)

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
            // The listener binds to the metadata addresses, but anything that
            // resolves a local name will also want loopback.
            ip(["-n", namespace, "link", "set", "dev", "lo", "up"], []),
        ]

        // Both families are established independently: on a host without IPv6
        // the v6 commands fail and the v4 metadata service still works, matching
        // how a malformed `external_cidr6` degrades the uplink to v4 rather than
        // failing it.
        setup.append(
            ip(["-n", namespace, "addr", "add", InstanceMetadataEndpoint.cidr, "dev", device], ["File exists"]))
        // `nodad` deliberately: Duplicate Address Detection leaves an IPv6
        // address `tentative` for roughly a second, during which `bind()` fails
        // with EADDRNOTAVAIL. The address is unique by construction — one per
        // namespace, one namespace per network per chassis — so DAD buys nothing
        // and costs the listener a startup race on every agent restart.
        setup.append(
            ip(
                ["-n", namespace, "addr", "add", InstanceMetadataEndpoint.cidrV6, "dev", device, "nodad"],
                ["File exists"]))

        // Replies go to the guest's tenant address, for which the namespace has
        // no route otherwise. A default route is unambiguous here because the
        // namespace has exactly one non-loopback interface, and it covers any
        // number of subnets on the switch without needing an IPAM allocation
        // from each (which is how OpenStack solves the same problem).
        setup.append(
            ip(
                [
                    "-n", namespace, "route", "add", "default", "dev", device,
                    "src", InstanceMetadataEndpoint.address,
                ], ["File exists", "RTNETLINK answers: File exists"]))
        setup.append(
            ip(
                [
                    "-n", namespace, "-6", "route", "add", "default", "dev", device,
                    "src", InstanceMetadataEndpoint.addressV6,
                ], ["File exists", "RTNETLINK answers: File exists"]))

        // No `rp_filter` or `disable_ipv6` sysctls here, deliberately. Both
        // looked necessary and are not: network sysctls are per-namespace and a
        // fresh namespace starts at the kernel defaults rather than inheriting
        // the host's, and even under strict reverse-path filtering a request
        // from a guest passes — the reverse lookup for its tenant address hits
        // the default route above and resolves to the interface the packet
        // arrived on. Adding them would mean shelling a third binary into the
        // namespace to establish state that already holds.

        let timeout = "--timeout=\(ovsTimeoutSeconds)"
        return MetadataChassisPlan(
            interfaceName: device,
            netnsName: namespace,
            logicalPortName: logicalPort,
            ovsAttach: [
                timeout, "--may-exist", "add-port", bridge, device,
                "--", "set", "Interface", device, "type=internal",
                "external_ids:iface-id=\(logicalPort)",
                "external_ids:\(MetadataChassisPlan.managedKey)=\(MetadataChassisPlan.managedValue)",
                "external_ids:\(MetadataChassisPlan.roleKey)=\(MetadataChassisPlan.roleValue)",
                "external_ids:\(MetadataChassisPlan.networkIDKey)=\(networkId.uuidString.lowercased())",
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
        let device = interfaceName ?? metadataInterfaceName(networkId: networkId.uuidString)
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
    /// Distinguishes a metadata interface from every other Strato-managed OVS
    /// interface (VM TAPs, sandbox veths) in one lookup.
    public static let roleKey = "strato-role"
    public static let roleValue = "metadata"
    /// Carries the network id so teardown can rederive the namespace to delete
    /// from an observed interface alone.
    public static let networkIDKey = "strato-network-id"
}

// MARK: - Chassis-side reconciliation

/// One metadata interface this chassis owns, as observed on the host.
public struct ObservedMetadataPort: Equatable, Sendable {
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

    public init(networkId: UUID, interfaceName: String, namespacePresent: Bool) {
        self.networkId = networkId
        self.interfaceName = interfaceName
        self.namespacePresent = namespacePresent
    }
}

/// One chassis-side side effect.
public enum MetadataChassisAction: Equatable, Sendable {
    /// Run the (idempotent) setup plan: either the network has no interface yet,
    /// or it has one whose namespace went missing.
    case realize(networkId: UUID)
    /// Remove the interface and its namespace. Carries the observed device name
    /// so teardown deletes what was found.
    case remove(networkId: UUID, interfaceName: String)
}

/// Pure diff for the chassis half, mirroring `NetworkReconciler.teardownActions`.
///
/// Lives here rather than in the actor because this is the half that *deletes*
/// namespaces, and `NetworkServiceLinux` is in the executable target where no
/// test can reach it.
public enum MetadataChassisReconciler {

    /// The side effects that converge this chassis toward `desired`.
    ///
    /// `desired` nil ≙ a control plane that predates `metadataEnabled`: no
    /// actions at all, so silence is never read as "tear every namespace down".
    /// An empty (non-nil) list *is* an opinion and removes everything.
    public static func actions(
        desired: [UUID]?, observed: [ObservedMetadataPort]
    ) -> [MetadataChassisAction] {
        guard let desired else { return [] }
        let wanted = Set(desired)
        let byNetwork = Dictionary(observed.map { ($0.networkId, $0) }, uniquingKeysWith: { first, _ in first })

        var actions: [MetadataChassisAction] = []
        // Realize covers both "never built" and "built, but its namespace is
        // gone". The plan is idempotent, so one path serves both and there is no
        // repair-only branch to get subtly wrong.
        for networkId in wanted.sorted(by: { $0.uuidString < $1.uuidString })
        where byNetwork[networkId]?.namespacePresent != true {
            actions.append(.realize(networkId: networkId))
        }
        for port in observed.sorted(by: { $0.networkId.uuidString < $1.networkId.uuidString })
        where !wanted.contains(port.networkId) {
            actions.append(.remove(networkId: port.networkId, interfaceName: port.interfaceName))
        }
        return actions
    }
}
