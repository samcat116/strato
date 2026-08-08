import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// The resolver's foot in the **host** namespace (STR-40, ADR 0008).
///
/// Asserted at the argv level for a sharper reason than the metadata plan's.
/// This one programs rules in the *host's* policy table: getting a namespace
/// wrong costs one network, getting a rule wrong here can put tenant traffic
/// into the hypervisor's own routing. That is the blast radius ADR 0003 rejected
/// and ADR 0008 accepts with mitigations, and mitigations that are not tested
/// are decoration.
@Suite("Resolver Host Port Plan")
struct ResolverHostPortPlanTests {

    private let networkId = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let addresses = ["169.254.1.0", "fd00:ec2:1::100"]

    private func plan(_ addresses: [String]? = nil) -> ResolverHostPortPlan {
        ResolverHostPortPlan.plan(
            networkId: networkId, addresses: addresses ?? self.addresses, ipBinaryPath: "/sbin/ip",
            bridge: "br-int", ovsTimeoutSeconds: 10)
    }

    private func argv(_ commands: [NetnsCommand]) -> [String] {
        commands.map { ([$0.executable] + $0.arguments).joined(separator: " ") }
    }

    // MARK: - Identity

    @Test("The interface is distinguishable from the metadata foot at a glance")
    func interfaceNaming() {
        // This one shows up in the *host's* `ip link`, beside VM TAPs and the
        // operator's own devices, so telling it apart matters more than it did
        // for a device tucked inside a namespace.
        let plan = plan()
        #expect(plan.interfaceName.hasPrefix("rsv"))
        #expect(plan.interfaceName.count == 15)
        #expect(plan.interfaceName != chassisServiceInterfaceName(networkId: networkId.uuidString))
        #expect(plan.logicalPortName == OVNNaming.resolverPortName(networkId: networkId))
        #expect(plan.logicalPortName != OVNNaming.serviceLocalPortName(networkId: networkId))
    }

    @Test("The OVS attach claims the resolver port and marks the interface as ours")
    func ovsAttach() {
        let attach = plan().ovsAttach.joined(separator: " ")
        #expect(attach.contains("type=internal"))
        #expect(attach.contains("external_ids:iface-id=\(plan().logicalPortName)"))
        #expect(attach.contains("external_ids:strato-managed=true"))
        // A distinct role, so observation never confuses the two feet — they sit
        // on the same bridge with the same managed marker.
        #expect(attach.contains("external_ids:strato-role=resolver"))
        #expect(attach.contains("external_ids:strato-network-id=\(networkId.uuidString.lowercased())"))
        #expect(attach.contains("external_ids:strato-resolver-addresses=169.254.1.0,fd00:ec2:1::100"))
    }

    @Test("The MAC namespace is disjoint from every other derived MAC")
    func macNamespace() {
        #expect(OVNNaming.resolverPortMAC(networkId: networkId).hasPrefix("02:03:"))
        #expect(
            OVNNaming.resolverPortMAC(networkId: networkId)
                != OVNNaming.serviceLocalPortMAC(networkId: networkId))
    }

    // MARK: - Isolation

    @Test("Forwarding is disabled on both families")
    func forwardingIsOff() {
        // The one mitigation that turns a routing bug into a dropped packet
        // rather than a cross-tenant leak: without it the host could route
        // between two tenant networks it happens to have feet in, which is the
        // failure ADR 0003 named when it rejected this shape.
        let lines = argv(plan().setup)
        let device = plan().interfaceName
        #expect(lines.contains("/sbin/ip sysctl -w net.ipv4.conf.\(device).forwarding=0"))
        #expect(lines.contains("/sbin/ip sysctl -w net.ipv6.conf.\(device).forwarding=0"))
    }

    @Test("Reverse-path filtering is loose, not strict")
    func reversePathFilteringIsLoose() {
        // Strict would drop every query: a guest's packet arrives with a tenant
        // source this interface has no route for in the main table. Loose still
        // rejects a source no interface could reach.
        let device = plan().interfaceName
        #expect(argv(plan().setup).contains("/sbin/ip sysctl -w net.ipv4.conf.\(device).rp_filter=2"))
    }

    @Test("The sysctls tolerate a kernel that does not expose them")
    func sysctlsAreTolerant() {
        // A missing knob costs the mitigation, not the resolver — and the setup
        // runs fail-fast, so an untolerated failure would roll back the whole
        // foot and leave the network with no resolver at all.
        for command in plan().setup where command.arguments.first == "sysctl" {
            #expect(!command.tolerated.isEmpty)
        }
    }

    // MARK: - Policy routing

    @Test("Replies are routed by a table keyed on this network's own address")
    func policyRoutingIsPerNetwork() {
        // This is what replaces the namespace's default route. A reply leaves
        // from this network's address toward a guest whose 10.0.0.5 may exist on
        // three other switches, so the main table has no correct answer. Keying
        // on the *source* works because that address is unique per network.
        let device = plan().interfaceName
        let table = ResolverHostPortPlan.routingTable(networkId: networkId, address: "169.254.1.0")
        #expect(table != nil)
        let lines = argv(plan().setup)
        #expect(
            lines.contains(
                "/sbin/ip route replace default dev \(device) src 169.254.1.0 table \(table!)"))
        #expect(lines.contains("/sbin/ip rule add from 169.254.1.0 table \(table!)"))
        #expect(
            lines.contains(
                "/sbin/ip -6 route replace default dev \(device) src fd00:ec2:1::100 table \(table!)"))
        #expect(lines.contains("/sbin/ip -6 rule add from fd00:ec2:1::100 table \(table!)"))
    }

    @Test("Two networks get different routing tables")
    func tablesAreDistinct() {
        let one = ResolverHostPortPlan.routingTable(networkId: networkId, address: "169.254.1.0")
        let two = ResolverHostPortPlan.routingTable(networkId: UUID(), address: "169.254.1.1")
        #expect(one != nil && two != nil)
        #expect(one != two)
    }

    @Test("The table id is derived from the address, well clear of the reserved ones")
    func tableIdIsSafe() {
        // 253/254/255 are `default`/`main`/`local`. Colliding with one of those
        // would not fail — it would silently merge this network's routes into
        // the host's own table, which is the worst available outcome.
        for address in ["169.254.1.0", "169.254.254.255"] {
            let table = ResolverHostPortPlan.routingTable(networkId: networkId, address: address)
            #expect(table != nil)
            #expect(table! > 255)
        }
    }

    @Test("A rule is deleted before it is added, so retries do not stack")
    func rulesDoNotStack() {
        // `ip rule add` happily creates duplicates, and setup re-runs on every
        // retry and after every agent restart — so without the delete the host's
        // policy table would gain one rule per attempt, forever.
        let lines = argv(plan().setup)
        let addIndex = lines.firstIndex { $0.contains("rule add from 169.254.1.0") }
        let delIndex = lines.firstIndex { $0.contains("rule del from 169.254.1.0") }
        #expect(addIndex != nil && delIndex != nil)
        #expect(delIndex! < addIndex!)
        // And the delete tolerates there being nothing to delete, which is the
        // common case on a first realize.
        let del = plan().setup.first { $0.arguments.contains("del") && $0.arguments.contains("rule") }
        #expect(del?.tolerates("RTNETLINK answers: No such file or directory") == true)
    }

    @Test("A v4-only network programs no v6 routing")
    func v4OnlyNetwork() {
        // An IPv6-less host never gets the ULA configured, so a rule naming it
        // would fail and roll back the whole foot.
        let lines = argv(plan(["169.254.1.0"]).setup)
        #expect(!lines.contains { $0.contains("-6") })
        #expect(lines.contains { $0.contains("rule add from 169.254.1.0") })
    }

    @Test("The addresses are added, v6 with nodad")
    func addressesAreAdded() {
        // `nodad` matters more here than in the namespace: DAD leaves the
        // address tentative for about a second, and one failed bind costs *every*
        // network on the host its resolver, because one process binds them all.
        let lines = argv(plan().setup)
        let device = plan().interfaceName
        #expect(lines.contains("/sbin/ip addr add 169.254.1.0/32 dev \(device)"))
        #expect(lines.contains("/sbin/ip addr add fd00:ec2:1::100/128 dev \(device) nodad"))
    }

    // MARK: - Teardown

    @Test("Teardown removes the rules before the port that owns their addresses")
    func teardownOrder() {
        // Deleting the port destroys the device, and a rule naming an address on
        // a device that no longer exists is cleaned up by nothing — those
        // accumulate in the host's policy table, which is exactly the state this
        // design has to keep tidy.
        let removal = ResolverHostPortPlan.teardownPlan(
            networkId: networkId, interfaceName: "rsvdeadbeef123", addresses: addresses,
            ipBinaryPath: "/sbin/ip", bridge: "br-int", ovsTimeoutSeconds: 10)
        let lines = argv(removal.commands)
        #expect(lines.contains { $0.contains("rule del from 169.254.1.0") })
        #expect(lines.contains { $0.contains("-6 rule del from fd00:ec2:1::100") })
        #expect(lines.contains { $0.contains("route flush table") })
        #expect(removal.ovsDetach.last == "rsvdeadbeef123")
    }

    @Test("Teardown tolerates rules that are already gone")
    func teardownIsIdempotent() {
        let removal = ResolverHostPortPlan.teardownPlan(
            networkId: networkId, interfaceName: "rsvdeadbeef123", addresses: addresses,
            ipBinaryPath: "/sbin/ip", bridge: "br-int", ovsTimeoutSeconds: 10)
        for command in removal.commands {
            #expect(command.tolerates("RTNETLINK answers: No such file or directory"))
        }
    }

    // MARK: - Address parsing

    @Test("The routing table is recovered from the address, needing no second field")
    func indexRoundTrips() {
        for index in [NetworkResolverEndpoint.firstIndex, 1_000, NetworkResolverEndpoint.lastIndex] {
            let address = NetworkResolverEndpoint.address(forIndex: index)
            #expect(ResolverHostPortPlan.index(ofAddress: address) == index)
        }
    }

    @Test("An address outside the allocation range yields no table")
    func foreignAddressesRejected() {
        // Including the metadata address, which is link-local but not ours to
        // route for — and the reserved first/last /24 RFC 3927 sets aside.
        for address in ["169.254.169.254", "169.254.0.5", "169.254.255.1", "10.0.0.1", "nonsense"] {
            #expect(ResolverHostPortPlan.index(ofAddress: address) == nil, "\(address)")
        }
    }

    @Test("The address stamp round-trips")
    func addressStampRoundTrips() {
        #expect(ResolverHostPortPlan.parseAddresses("169.254.1.0,fd00:ec2:1::100") == addresses)
        #expect(ResolverHostPortPlan.parseAddresses(nil).isEmpty)
        #expect(ResolverHostPortPlan.parseAddresses("").isEmpty)
    }
}

/// The diff for the host-namespace feet.
@Suite("Resolver Host Port Reconciler")
struct ResolverHostPortReconcilerTests {

    private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let pair = ["169.254.1.0", "fd00:ec2:1::100"]

    private func observed(_ networkId: UUID, addresses: [String]) -> ObservedResolverHostPort {
        ObservedResolverHostPort(
            networkId: networkId, interfaceName: "rsvaaaa00000000", addresses: addresses)
    }

    @Test("A network with no foot is realized")
    func realizesMissing() {
        #expect(
            ResolverHostPortReconciler.actions(desired: [a: pair], observed: [])
                == [.realize(networkId: a, addresses: pair)])
    }

    @Test("A converged foot needs nothing")
    func convergedNeedsNothing() {
        #expect(
            ResolverHostPortReconciler.actions(
                desired: [a: pair], observed: [observed(a, addresses: pair)]
            ).isEmpty)
    }

    @Test("A foot built for a different pair is realized again")
    func movedAddressesRebuild() {
        // Realized rather than patched: the setup is idempotent, and the
        // alternative is a partial update that leaves the old address bound
        // while CoreDNS is told the new one.
        #expect(
            ResolverHostPortReconciler.actions(
                desired: [a: pair], observed: [observed(a, addresses: ["169.254.9.9"])])
                == [.realize(networkId: a, addresses: pair)])
    }

    @Test("A network no longer wanted is removed, with its observed addresses")
    func removesUnwanted() {
        // The *observed* pair, so teardown deletes the rules that actually
        // exist rather than the ones current desired state would imply.
        #expect(
            ResolverHostPortReconciler.actions(
                desired: [:], observed: [observed(b, addresses: ["169.254.9.9"])])
                == [
                    .remove(
                        networkId: b, interfaceName: "rsvaaaa00000000", addresses: ["169.254.9.9"])
                ])
    }

    @Test("A network desired with no addresses is a removal, not an empty realize")
    func emptyAddressesIsRemoval() {
        // The control plane withholds the pair for a network whose resolver it
        // has not allocated, and an interface with no addresses is one CoreDNS
        // would bind nothing on.
        #expect(
            ResolverHostPortReconciler.actions(
                desired: [b: []], observed: [observed(b, addresses: pair)])
                == [.remove(networkId: b, interfaceName: "rsvaaaa00000000", addresses: pair)])
    }

    @Test("Actions are deterministic across a replayed sync")
    func actionsAreOrdered() {
        let actions = ResolverHostPortReconciler.actions(desired: [b: pair, a: pair], observed: [])
        #expect(
            actions == [
                .realize(networkId: a, addresses: pair),
                .realize(networkId: b, addresses: pair),
            ])
    }
}
