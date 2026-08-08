import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

/// The chassis half of the link-local services (STR-49 metadata, STR-40
/// resolver) lives in a pure plan for the reason `SandboxNetnsAttachmentPlanTests`
/// gives: `NetworkServiceLinux` is in the executable target and cannot be
/// imported here, so a wrong-but-plausible command sequence would otherwise ship
/// untested — and it fails silently, as an interface that binds, reports
/// healthy, and answers nothing.
@Suite("Chassis Service Plan")
struct ChassisServicePlanTests {

    private let networkId = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!

    private func plan(ratePPS: Int = 0) -> ChassisServicePlan {
        ChassisServicePlan.plan(
            networkId: networkId, ipBinaryPath: "/sbin/ip", tcBinaryPath: "/sbin/tc",
            bridge: "br-int", ovsTimeoutSeconds: 10, ratePPS: ratePPS)
    }

    private func argv(_ commands: [NetnsCommand]) -> [String] {
        commands.map { ([$0.executable] + $0.arguments).joined(separator: " ") }
    }

    @Test("Device and namespace names are derived and within IFNAMSIZ")
    func namesAreDerived() {
        let plan = plan()
        #expect(plan.interfaceName == chassisServiceInterfaceName(networkId: networkId.uuidString))
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

        #expect(plan.logicalPortName == OVNNaming.serviceLocalPortName(networkId: networkId))
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
                "/sbin/ip -n \(ns) link set dev \(device) address \(OVNNaming.serviceLocalPortMAC(networkId: networkId))",
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
        let expected = OVNNaming.serviceLocalPortMAC(networkId: networkId)
        #expect(
            argv(plan.interfaceSetup).contains(
                "/sbin/ip -n \(plan.netnsName) link set dev \(plan.interfaceName) address \(expected)"))
    }

    @Test("The IPv6 address is added with nodad")
    func ipv6SkipsDuplicateAddressDetection() throws {
        // DAD leaves the address tentative for ~1s, during which bind() fails
        // with EADDRNOTAVAIL — a startup race on every agent restart, for a
        // duplicate that cannot happen (one set per namespace).
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

    @Test("A rate limit installs an ingress policer, and zero installs nothing")
    func ratePolicerIsOptional() {
        #expect(!argv(plan(ratePPS: 0).interfaceSetup).contains { $0.contains("/sbin/tc") })

        let policed = argv(plan(ratePPS: 1024).interfaceSetup)
        let device = plan().interfaceName
        let ns = plan().netnsName
        #expect(policed.contains("/sbin/tc -n \(ns) qdisc add dev \(device) handle ffff: ingress"))
        // `filter replace` with an explicit handle rather than `add`: setup
        // re-runs on every retry and after every agent restart, and `add` would
        // stack a second identical policer each time — halving the effective
        // rate on each pass.
        #expect(
            policed.contains(
                "/sbin/tc -n \(ns) filter replace dev \(device) parent ffff: handle 0x1 prio 1 "
                    + "protocol all matchall action police pkts_rate 1024 pkts_burst 256 conform-exceed drop"))
    }

    @Test("Every policer command tolerates an iproute2 that does not support it")
    func policerFailureIsNotFatal() {
        // `interfaceSetup` runs fail-fast and a throw rolls the namespace *and*
        // the OVS port back, so an untolerated `tc` failure on an older host
        // would not skip the limiter — it would destroy the chassis foot and
        // rebuild it on every sync, taking instance metadata down with it.
        // `police pkts_rate` needs iproute2 >= 5.10, so this is reachable.
        let policerCommands = plan(ratePPS: 1024).interfaceSetup.filter { $0.executable == "/sbin/tc" }
        #expect(policerCommands.count == 2)
        for command in policerCommands {
            #expect(command.tolerates("Unknown action \"police\""))
            #expect(command.tolerates("Illegal \"pkts_rate\""))
            #expect(command.tolerates("Usage: ... police ..."))
        }
    }

    @Test("A very low rate limit still admits a burst of one query and its retry")
    func burstIsFloored() {
        let policed = argv(plan(ratePPS: 8).interfaceSetup)
        #expect(policed.contains { $0.contains("pkts_rate 8 pkts_burst 32") })
    }

    @Test("Setup is idempotent: every command that can re-run tolerates its own success")
    func setupIsIdempotent() {
        // A retried pass, or an agent restart, re-runs the whole sequence.
        let plan = plan(ratePPS: 1024)
        for command in plan.namespaceSetup + plan.interfaceSetup
        where command.arguments.contains("add") {
            #expect(!command.tolerated.isEmpty, "\(command.arguments) would fail on a second pass")
        }
        #expect(plan.interfaceSetup[0].tolerates("Cannot find device mdp0123456789"))
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
        let removal = ChassisServicePlan.teardownPlan(
            networkId: networkId, ipBinaryPath: "/sbin/ip", bridge: "br-int", ovsTimeoutSeconds: 10)
        #expect(removal.ovsDetach == full.ovsDetach)
        #expect(argv(removal.commands) == argv(full.teardown))
    }

    @Test("Teardown removes the observed device rather than a rederived one")
    func teardownPrefersObservedInterface() {
        // They agree by construction; passing the observation is what keeps them
        // agreeing if the derivation ever changes under a live deployment.
        let removal = ChassisServicePlan.teardownPlan(
            networkId: networkId, interfaceName: "mdpdeadbeef123", ipBinaryPath: "/sbin/ip",
            bridge: "br-int", ovsTimeoutSeconds: 10)
        #expect(removal.ovsDetach.last == "mdpdeadbeef123")
    }

    @Test("Different networks get different namespaces and devices")
    func perNetworkIsolation() {
        // One namespace per network per chassis is what makes the caller
        // identifiable when two networks use overlapping subnets.
        let other = ChassisServicePlan.plan(
            networkId: UUID(), ipBinaryPath: "/sbin/ip", tcBinaryPath: "/sbin/tc",
            bridge: "br-int", ovsTimeoutSeconds: 10, ratePPS: 0)
        #expect(other.netnsName != plan().netnsName)
        #expect(other.interfaceName != plan().interfaceName)
    }

    @Test("The namespace path is on tmpfs, which is why it is observed separately")
    func netnsPathIsUnderRunNetns() {
        #expect(
            ChassisServicePlan.netnsPath(networkId: networkId)
                == "/var/run/netns/\(ChassisServicePlan.netnsName(networkId: networkId))")
    }
}

/// The chassis *diff* — the half that deletes namespaces, and the half a live
/// deployment gets wrong in ways that are invisible to the OVSDB rows.
@Suite("Chassis Service Reconciler")
struct ChassisServiceReconcilerTests {

    private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private func observed(
        _ networkId: UUID, namespacePresent: Bool = true, interfaceName: String = "mdpaaaa00000000"
    ) -> ObservedChassisServicePort {
        ObservedChassisServicePort(
            networkId: networkId, interfaceName: interfaceName, namespacePresent: namespacePresent)
    }

    @Test("A network with no interface is realized")
    func realizesMissingNetwork() {
        #expect(
            ChassisServiceReconciler.actions(desired: [a], observed: [])
                == [.realize(networkId: a)])
    }

    @Test("A fully realized network needs no action")
    func convergedNeedsNothing() {
        #expect(
            ChassisServiceReconciler.actions(desired: [a], observed: [observed(a)]).isEmpty)
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
            ChassisServiceReconciler.actions(
                desired: [a], observed: [observed(a, namespacePresent: false)])
                == [.realize(networkId: a)])
    }

    @Test("A network no longer wanted is removed, by its observed device name")
    func removesUnwanted() {
        #expect(
            ChassisServiceReconciler.actions(
                desired: [], observed: [observed(b, interfaceName: "mdpbbbb11111111")])
                == [.remove(networkId: b, interfaceName: "mdpbbbb11111111")])
    }

    @Test("A nil desired map is silence, not an instruction to remove everything")
    func nilDesiredConvergesNothing() {
        // A control plane predating both service flags says nothing; reading
        // that as "remove" would tear down every namespace on the fleet on a
        // rollback. An empty *non-nil* map is an opinion and does remove.
        #expect(ChassisServiceReconciler.actions(desired: nil, observed: [observed(a)]).isEmpty)
        #expect(!ChassisServiceReconciler.actions(desired: [], observed: [observed(a)]).isEmpty)
    }

    @Test("Realizations are ordered before removals, and both are deterministic")
    func actionsAreOrderedAndDeterministic() {
        let actions = ChassisServiceReconciler.actions(
            desired: [b, a],
            observed: [observed(b, namespacePresent: false, interfaceName: "mdpb")])
        // Sorted by id, so a replayed sync produces an identical action list.
        #expect(
            actions == [
                .realize(networkId: a),
                .realize(networkId: b),
            ])
    }

    @Test("A mixed pass realizes, rebuilds, and removes in one go")
    func mixedPass() {
        let stale = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        let actions = ChassisServiceReconciler.actions(
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

    @Test("A namespace name round-trips to the network it belongs to")
    func netnsNameRoundTrips() {
        // The inverse is what a restarting agent uses to learn which networks it
        // was serving on: the namespaces outlive the process, the desired-state
        // list that named them does not.
        let networkId = UUID()
        let name = ChassisServicePlan.netnsName(networkId: networkId)
        #expect(ChassisServicePlan.networkId(fromNetnsName: name) == networkId)
    }

    @Test("Namespaces that are not ours are not claimed")
    func foreignNamespacesIgnored() {
        // /var/run/netns is shared with everything else on the host, including
        // Strato's own sandbox jails.
        for name in [
            "strato-sbx-11111111-1111-1111-1111-111111111111",
            "ovnmeta-11111111-1111-1111-1111-111111111111",
            "strato-md-not-a-uuid",
            "strato-md-",
            "default",
        ] {
            #expect(ChassisServicePlan.networkId(fromNetnsName: name) == nil, "\(name) must not be claimed")
        }
    }
}
