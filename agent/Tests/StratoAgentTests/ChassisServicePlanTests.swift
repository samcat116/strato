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

    private func plan(
        metadata: Bool = true, resolver: Bool = false, ratePPS: Int = 0
    ) -> ChassisServicePlan {
        ChassisServicePlan.plan(
            networkId: networkId, metadata: metadata, resolver: resolver,
            ipBinaryPath: "/sbin/ip", tcBinaryPath: "/sbin/tc", bridge: "br-int",
            ovsTimeoutSeconds: 10, ratePPS: ratePPS)
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

    @Test("The role marker stays `metadata` even when the port carries both services")
    func roleMarkerIsStable() {
        // It is an ownership marker on rows every live site already has.
        // Changing it would make every existing interface unrecognized, so each
        // agent would build a second one beside it and never reap the first.
        let both = plan(metadata: true, resolver: true).ovsAttach.joined(separator: " ")
        #expect(both.contains("external_ids:strato-role=metadata"))
    }

    @Test("The attach stamps which services the namespace was built for")
    func attachStampsServiceSet() {
        // The stamp is what lets a reconcile tell "already realized" from
        // "realized for a different service set" without probing the namespace's
        // addresses on every sync.
        #expect(plan(metadata: true, resolver: false).ovsAttach.contains("external_ids:strato-services=metadata"))
        #expect(plan(metadata: false, resolver: true).ovsAttach.contains("external_ids:strato-services=resolver"))
        #expect(
            plan(metadata: true, resolver: true).ovsAttach
                .contains("external_ids:strato-services=metadata+resolver"))
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

    @Test("A resolver-enabled network also gets the resolver addresses")
    func resolverAddressesAreAdded() {
        let plan = plan(metadata: true, resolver: true)
        let lines = argv(plan.interfaceSetup)
        #expect(lines.contains { $0.contains("addr add 169.254.169.253/32") })
        #expect(lines.contains { $0.contains("addr add fd00:ec2::253/128") && $0.hasSuffix("nodad") })
    }

    @Test("A metadata-only network gets no resolver addresses, and vice versa")
    func servicesAreIndependent() {
        let metadataOnly = argv(plan(metadata: true, resolver: false).interfaceSetup)
        #expect(!metadataOnly.contains { $0.contains("169.254.169.253") })
        #expect(!metadataOnly.contains { $0.contains("fd00:ec2::253") })

        let resolverOnly = argv(plan(metadata: false, resolver: true).interfaceSetup)
        #expect(!resolverOnly.contains { $0.contains("169.254.169.254") })
        #expect(!resolverOnly.contains { $0.contains("fd00:ec2::254") })
    }

    @Test("The default route's preferred source is an address that actually exists")
    func preferredSourceFollowsTheEnabledService() {
        // `ip route add ... src <addr>` is rejected outright when the address is
        // not configured, so hardcoding the metadata one would fail the whole
        // namespace build on a resolver-only network.
        let lines = argv(plan(metadata: false, resolver: true).interfaceSetup)
        #expect(lines.contains { $0.contains("route add default") && $0.hasSuffix("src 169.254.169.253") })
        #expect(lines.contains { $0.contains("-6 route add default") && $0.hasSuffix("src fd00:ec2::253") })
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

    @Test("Every IPv6 address is added with nodad")
    func ipv6SkipsDuplicateAddressDetection() throws {
        // DAD leaves the address tentative for ~1s, during which bind() fails
        // with EADDRNOTAVAIL — a startup race on every agent restart, for a
        // duplicate that cannot happen (one set per namespace).
        let setup = plan(metadata: true, resolver: true).interfaceSetup
        for cidr in [InstanceMetadataEndpoint.cidrV6, NetworkResolverEndpoint.cidrV6] {
            let command = try #require(setup.first { $0.arguments.contains(cidr) })
            #expect(command.arguments.last == "nodad")
        }
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

        let policed = argv(plan(metadata: true, resolver: true, ratePPS: 1024).interfaceSetup)
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
        let plan = plan(metadata: true, resolver: true, ratePPS: 1024)
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
            networkId: UUID(), metadata: true, resolver: false, ipBinaryPath: "/sbin/ip",
            tcBinaryPath: "/sbin/tc", bridge: "br-int", ovsTimeoutSeconds: 10, ratePPS: 0)
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

/// The service-set stamp, which is what makes turning a service on reach a
/// namespace that already exists for the other one.
@Suite("Chassis Service Set")
struct ChassisServiceSetTests {

    @Test("The external-id value is stable and ordered")
    func externalIDValueIsCanonical() {
        #expect(ChassisServiceSet(metadata: true, resolver: false).externalIDValue == "metadata")
        #expect(ChassisServiceSet(metadata: false, resolver: true).externalIDValue == "resolver")
        #expect(ChassisServiceSet(metadata: true, resolver: true).externalIDValue == "metadata+resolver")
        #expect(ChassisServiceSet(metadata: false, resolver: false).externalIDValue == "")
    }

    @Test("A missing stamp reads as metadata-only, which is a fact rather than a guess")
    func absentStampIsLegacyMetadata() {
        // Every interface built before STR-40 was built for metadata alone; the
        // resolver did not exist. Reading absence this way is what makes an
        // upgraded agent re-realize exactly the namespaces whose networks want a
        // resolver, rather than all of them.
        #expect(ChassisServiceSet.parse(nil) == ChassisServiceSet(metadata: true, resolver: false))
        #expect(ChassisServiceSet.parse("") == ChassisServiceSet(metadata: true, resolver: false))
    }

    @Test("An unrecognized stamp is treated as legacy and re-realized")
    func unknownStampIsLegacy() {
        // The safe direction: the plan is idempotent, so a needless realize
        // costs a pass, while trusting a value we cannot read costs a namespace
        // that never converges.
        #expect(ChassisServiceSet.parse("imds+quic") == ChassisServiceSet(metadata: true, resolver: false))
    }

    @Test("A stamp round-trips")
    func roundTrips() {
        for set in [
            ChassisServiceSet(metadata: true, resolver: false),
            ChassisServiceSet(metadata: false, resolver: true),
            ChassisServiceSet(metadata: true, resolver: true),
        ] {
            #expect(ChassisServiceSet.parse(set.externalIDValue) == set)
        }
    }
}

/// The chassis *diff* — the half that deletes namespaces, and the half a live
/// deployment gets wrong in ways that are invisible to the OVSDB rows.
@Suite("Chassis Service Reconciler")
struct ChassisServiceReconcilerTests {

    private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private let metadataOnly = ChassisServiceSet(metadata: true, resolver: false)
    private let both = ChassisServiceSet(metadata: true, resolver: true)

    private func observed(
        _ networkId: UUID, namespacePresent: Bool = true, interfaceName: String = "mdpaaaa00000000",
        services: ChassisServiceSet? = nil
    ) -> ObservedChassisServicePort {
        ObservedChassisServicePort(
            networkId: networkId, interfaceName: interfaceName, namespacePresent: namespacePresent,
            services: services ?? metadataOnly)
    }

    @Test("A network with no interface is realized")
    func realizesMissingNetwork() {
        #expect(
            ChassisServiceReconciler.actions(desired: [a: metadataOnly], observed: [])
                == [.realize(networkId: a, services: metadataOnly)])
    }

    @Test("A fully realized network needs no action")
    func convergedNeedsNothing() {
        #expect(
            ChassisServiceReconciler.actions(desired: [a: metadataOnly], observed: [observed(a)]).isEmpty)
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
                desired: [a: metadataOnly], observed: [observed(a, namespacePresent: false)])
                == [.realize(networkId: a, services: metadataOnly)])
    }

    @Test("Turning a service on re-realizes a namespace that already exists")
    func serviceSetChangeRebuilds() {
        // Without this, enabling the resolver on a network whose namespace was
        // built for metadata would converge to "nothing to do" and the resolver
        // address would never be added — a network whose guests are handed an
        // address nothing on the host holds.
        #expect(
            ChassisServiceReconciler.actions(
                desired: [a: both], observed: [observed(a, services: metadataOnly)])
                == [.realize(networkId: a, services: both)])
    }

    @Test("Turning a service off re-realizes too, rather than leaving the address published")
    func serviceSetShrinkRebuilds() {
        #expect(
            ChassisServiceReconciler.actions(
                desired: [a: metadataOnly], observed: [observed(a, services: both)])
                == [.realize(networkId: a, services: metadataOnly)])
    }

    @Test("A network wanting no service at all is removed, not realized empty")
    func emptyServiceSetIsRemoval() {
        // "No port" and "a port with nothing on it" are the same state, so the
        // caller need not filter an empty set out before calling.
        #expect(
            ChassisServiceReconciler.actions(
                desired: [a: ChassisServiceSet(metadata: false, resolver: false)],
                observed: [observed(a)])
                == [.remove(networkId: a, interfaceName: "mdpaaaa00000000")])
    }

    @Test("A network no longer wanted is removed, by its observed device name")
    func removesUnwanted() {
        #expect(
            ChassisServiceReconciler.actions(
                desired: [:], observed: [observed(b, interfaceName: "mdpbbbb11111111")])
                == [.remove(networkId: b, interfaceName: "mdpbbbb11111111")])
    }

    @Test("A nil desired map is silence, not an instruction to remove everything")
    func nilDesiredConvergesNothing() {
        // A control plane predating both service flags says nothing; reading
        // that as "remove" would tear down every namespace on the fleet on a
        // rollback. An empty *non-nil* map is an opinion and does remove.
        #expect(ChassisServiceReconciler.actions(desired: nil, observed: [observed(a)]).isEmpty)
        #expect(!ChassisServiceReconciler.actions(desired: [:], observed: [observed(a)]).isEmpty)
    }

    @Test("Realizations are ordered before removals, and both are deterministic")
    func actionsAreOrderedAndDeterministic() {
        let actions = ChassisServiceReconciler.actions(
            desired: [b: metadataOnly, a: metadataOnly],
            observed: [observed(b, namespacePresent: false, interfaceName: "mdpb")])
        // Sorted by id, so a replayed sync produces an identical action list.
        #expect(
            actions == [
                .realize(networkId: a, services: metadataOnly),
                .realize(networkId: b, services: metadataOnly),
            ])
    }

    @Test("A mixed pass realizes, rebuilds, and removes in one go")
    func mixedPass() {
        let stale = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
        let actions = ChassisServiceReconciler.actions(
            desired: [a: metadataOnly, b: both],
            observed: [
                observed(a, namespacePresent: false, interfaceName: "mdpa"),
                observed(stale, interfaceName: "mdpc"),
            ])
        #expect(
            actions == [
                .realize(networkId: a, services: metadataOnly),
                .realize(networkId: b, services: both),
                .remove(networkId: stale, interfaceName: "mdpc"),
            ])
    }
}
