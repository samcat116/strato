import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// The chassis half of the metadata dataplane (STR-49) lives in a pure plan for
/// the reason `SandboxNetnsAttachmentPlanTests` gives: `NetworkServiceLinux` is
/// in the executable target and cannot be imported here, so a wrong-but-plausible
/// command sequence would otherwise ship untested — and it fails silently, as an
/// interface that binds, reports healthy, and answers nothing.
@Suite("Metadata Chassis Plan")
struct MetadataChassisPlanTests {

    private let networkId = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    private func plan() -> MetadataChassisPlan {
        MetadataChassisPlan.plan(
            networkId: networkId, ipBinaryPath: "/sbin/ip", bridge: "br-int", ovsTimeoutSeconds: 10)
    }

    private func argv(_ commands: [NetnsCommand]) -> [String] {
        commands.map { ([$0.executable] + $0.arguments).joined(separator: " ") }
    }

    @Test("Device and namespace names are derived and within IFNAMSIZ")
    func namesAreDerived() {
        let plan = plan()
        #expect(plan.interfaceName == metadataInterfaceName(networkId: networkId.uuidString))
        #expect(plan.interfaceName.hasPrefix("mdp"))
        // Linux caps interface names at 15 characters; the logical port name is
        // 41, which is why this needs its own derivation at all.
        #expect(plan.interfaceName.count == 15)
        #expect(plan.netnsName == "strato-md-\(networkId.uuidString.lowercased())")
    }

    @Test("The OVS attach claims the logical port and marks the interface as ours")
    func ovsAttachClaimsLogicalPort() {
        let plan = plan()
        let attach = plan.ovsAttach.joined(separator: " ")

        #expect(plan.logicalPortName == OVNNaming.metadataPortName(networkId: networkId))
        #expect(attach.contains("--may-exist add-port br-int \(plan.interfaceName)"))
        #expect(attach.contains("type=internal"))
        // Without `iface-id` ovn-controller never binds the port to the
        // localport, and the interface sits on the bridge carrying nothing.
        #expect(attach.contains("external_ids:iface-id=\(plan.logicalPortName)"))
        // Observation keys off these, never the name prefix, so an operator's
        // own internal port on br-int is never a removal candidate.
        #expect(attach.contains("external_ids:strato-managed=true"))
        #expect(attach.contains("external_ids:strato-role=metadata"))
        #expect(attach.contains("external_ids:strato-network-id=\(networkId.uuidString.lowercased())"))
    }

    @Test("Setup creates the namespace first, then moves and addresses the device")
    func setupOrder() {
        let plan = plan()
        let device = plan.interfaceName
        let ns = plan.netnsName

        #expect(argv(plan.namespaceSetup) == ["/sbin/ip netns add \(ns)"])
        #expect(
            argv(plan.interfaceSetup) == [
                "/sbin/ip link set \(device) netns \(ns)",
                "/sbin/ip -n \(ns) link set dev \(device) address \(OVNNaming.metadataPortMAC(networkId: networkId))",
                "/sbin/ip -n \(ns) link set dev \(device) up",
                "/sbin/ip -n \(ns) link set dev lo up",
                "/sbin/ip -n \(ns) addr add 169.254.169.254/32 dev \(device)",
                "/sbin/ip -n \(ns) addr add fd00:ec2::254/128 dev \(device) nodad",
                "/sbin/ip -n \(ns) route add default dev \(device) src 169.254.169.254",
                "/sbin/ip -n \(ns) -6 route add default dev \(device) src fd00:ec2::254",
            ])
    }

    @Test("The namespace is created before the OVS attach the executor runs between")
    func namespacePrecedesAttach() {
        // Ordering is forced from both sides: the device cannot move into a
        // namespace that does not exist, and it cannot move before OVS creates
        // it. The two-part split is what keeps the executor from having to know
        // which index of a flat list the attach belongs between.
        #expect(plan().namespaceSetup.allSatisfy { $0.arguments.prefix(2) == ["netns", "add"] })
        #expect(plan().interfaceSetup[0].arguments == ["link", "set", plan().interfaceName, "netns", plan().netnsName])
    }

    @Test("The interface takes the MAC the OVN responder advertises")
    func interfaceTakesResponderMAC() {
        // The guest addresses frames to the MAC in the localport's `addresses`,
        // so a netdev with a different one drops them as not-for-us.
        let plan = plan()
        let expected = OVNNaming.metadataPortMAC(networkId: networkId)
        #expect(
            argv(plan.interfaceSetup).contains(
                "/sbin/ip -n \(plan.netnsName) link set dev \(plan.interfaceName) address \(expected)"))
    }

    @Test("The IPv6 address is added with nodad")
    func ipv6SkipsDuplicateAddressDetection() throws {
        // DAD leaves the address tentative for ~1s, during which bind() fails
        // with EADDRNOTAVAIL — a startup race on every agent restart, for a
        // duplicate that cannot happen (one address per namespace).
        let command = try #require(
            plan().interfaceSetup.first { $0.arguments.contains(InstanceMetadataEndpoint.cidrV6) })
        #expect(command.arguments.last == "nodad")
    }

    @Test("Each family gets its own default route out the device")
    func bothFamiliesRouteBack() {
        // Replies go to the guest's tenant address, which the namespace has no
        // route for otherwise; a default route is unambiguous because there is
        // exactly one non-loopback interface in it.
        let lines = argv(plan().interfaceSetup)
        #expect(lines.contains { $0.contains("route add default") && $0.contains("src 169.254.169.254") })
        #expect(lines.contains { $0.contains("-6 route add default") && $0.contains("src fd00:ec2::254") })
    }

    @Test("Setup is idempotent: every command that can re-run tolerates its own success")
    func setupIsIdempotent() {
        // A retried pass, or an agent restart, re-runs the whole sequence.
        for command in plan().namespaceSetup + plan().interfaceSetup
        where command.arguments.contains("add") {
            #expect(!command.tolerated.isEmpty, "\(command.arguments) would fail on a second pass")
        }
        #expect(plan().interfaceSetup[0].tolerates("Cannot find device mdp0123456789"))
    }

    @Test("Teardown removes the OVS port and then the namespace")
    func teardownOrder() {
        let plan = plan()
        #expect(plan.ovsDetach == ["--timeout=10", "--if-exists", "del-port", "br-int", plan.interfaceName])
        #expect(argv(plan.teardown) == ["/sbin/ip netns del \(plan.netnsName)"])
        #expect(plan.teardown[0].tolerates("Cannot remove namespace file: No such file or directory"))
    }

    @Test("The standalone teardown derives the same names as the full plan")
    func standaloneTeardownMatches() {
        // Two paths deriving different names is how cleanup silently leaks; one
        // of them runs on an agent that can no longer build the full plan.
        let full = plan()
        let removal = MetadataChassisPlan.teardownPlan(
            networkId: networkId, ipBinaryPath: "/sbin/ip", bridge: "br-int", ovsTimeoutSeconds: 10)
        #expect(removal.ovsDetach == full.ovsDetach)
        #expect(argv(removal.commands) == argv(full.teardown))
    }

    @Test("Teardown removes the observed device rather than a rederived one")
    func teardownPrefersObservedInterface() {
        // They agree by construction; passing the observation is what keeps them
        // agreeing if the derivation ever changes under a live deployment.
        let removal = MetadataChassisPlan.teardownPlan(
            networkId: networkId, interfaceName: "mdpdeadbeef123", ipBinaryPath: "/sbin/ip",
            bridge: "br-int", ovsTimeoutSeconds: 10)
        #expect(removal.ovsDetach.last == "mdpdeadbeef123")
    }

    @Test("Different networks get different namespaces and devices")
    func perNetworkIsolation() {
        // One namespace per network per chassis is what makes the caller
        // identifiable when two networks use overlapping subnets.
        let other = MetadataChassisPlan.plan(
            networkId: UUID(), ipBinaryPath: "/sbin/ip", bridge: "br-int", ovsTimeoutSeconds: 10)
        #expect(other.netnsName != plan().netnsName)
        #expect(other.interfaceName != plan().interfaceName)
    }

    @Test("The namespace path is on tmpfs, which is why it is observed separately")
    func netnsPathIsUnderRunNetns() {
        #expect(
            MetadataChassisPlan.netnsPath(networkId: networkId)
                == "/var/run/netns/\(MetadataChassisPlan.netnsName(networkId: networkId))")
    }
}

/// The chassis *diff* — the half that deletes namespaces, and the half a live
/// deployment gets wrong in ways that are invisible to the OVSDB rows.
@Suite("Metadata Chassis Reconciler")
struct MetadataChassisReconcilerTests {

    private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private func observed(
        _ networkId: UUID, namespacePresent: Bool = true, interfaceName: String = "mdpaaaa00000000"
    ) -> ObservedMetadataPort {
        ObservedMetadataPort(
            networkId: networkId, interfaceName: interfaceName, namespacePresent: namespacePresent)
    }

    @Test("A network with no interface is realized")
    func realizesMissingNetwork() {
        #expect(
            MetadataChassisReconciler.actions(desired: [a], observed: []) == [.realize(networkId: a)])
    }

    @Test("A fully realized network needs no action")
    func convergedNeedsNothing() {
        #expect(MetadataChassisReconciler.actions(desired: [a], observed: [observed(a)]).isEmpty)
    }

    @Test("An interface whose namespace is gone is realized again")
    func rebuildsWhenNamespaceMissing() {
        // The host-reboot case, and the reason `namespacePresent` exists at all.
        // OVS's conf.db is on disk and the interface row survives; /var/run/netns
        // is tmpfs and does not. ovn-controller rebinds the localport and starts
        // answering guest ARP for the metadata address while nothing terminates
        // it — so guests hang rather than failing fast, which is worse than
        // having no metadata port at all. Keying the diff on the OVS row alone
        // would never rebuild this.
        #expect(
            MetadataChassisReconciler.actions(
                desired: [a], observed: [observed(a, namespacePresent: false)])
                == [.realize(networkId: a)])
    }

    @Test("A network no longer wanted is removed, by its observed device name")
    func removesUnwanted() {
        #expect(
            MetadataChassisReconciler.actions(
                desired: [], observed: [observed(b, interfaceName: "mdpbbbb11111111")])
                == [.remove(networkId: b, interfaceName: "mdpbbbb11111111")])
    }

    @Test("A nil desired list is silence, not an instruction to remove everything")
    func nilDesiredConvergesNothing() {
        // A control plane predating `metadataEnabled` says nothing; reading that
        // as "remove" would tear down every namespace on the fleet on a
        // rollback. An empty *non-nil* list is an opinion and does remove.
        #expect(MetadataChassisReconciler.actions(desired: nil, observed: [observed(a)]).isEmpty)
        #expect(!MetadataChassisReconciler.actions(desired: [], observed: [observed(a)]).isEmpty)
    }

    @Test("Realizations are ordered before removals, and both are deterministic")
    func actionsAreOrderedAndDeterministic() {
        let actions = MetadataChassisReconciler.actions(
            desired: [b, a], observed: [observed(b, namespacePresent: false, interfaceName: "mdpb")])
        // Sorted by id, so a replayed sync produces an identical action list.
        #expect(
            actions == [
                .realize(networkId: a), .realize(networkId: b),
            ])
    }

    @Test("A mixed pass realizes, rebuilds, and removes in one go")
    func mixedPass() {
        let stale = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        let actions = MetadataChassisReconciler.actions(
            desired: [a, b],
            observed: [
                observed(a, namespacePresent: false, interfaceName: "mdpa"),
                observed(stale, interfaceName: "mdpc"),
            ])
        #expect(
            actions == [
                .realize(networkId: a),
                .realize(networkId: b),
                .remove(networkId: stale, interfaceName: "mdpc"),
            ])
    }
}
